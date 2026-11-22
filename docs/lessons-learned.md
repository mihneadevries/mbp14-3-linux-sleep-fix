# Lessons learned: what was tried, what failed, and why

A record of the debugging behind this repo (MacBookPro14,3, Omarchy, kernel 7.2.15, Nov 2026), so nobody has to rediscover it. If something breaks again, read this before experimenting.

## Final root causes

| # | Cause | Proof | Fix |
|---|---|---|---|
| 1 | **Thunderbolt (Alpine Ridge) stall**: firmware cuts the controllers' power during sleep, and the kernel waits 80-100 s on the dead bridges. | `pm_test=devices` passed, `pm_test=platform` hung; after removing the TB upstream ports, `platform` passed in 7 s and real sleep worked. | Remove `04:00.0` and `7a:00.0` (grandparents of the two NHIs) before sleep, rescan `00:01.1`/`00:01.2` after. |
| 2 | **NVMe D3cold**: Omarchy's fix targets `01:00.0`, the Radeon on 15" models. | `d3cold_allowed=1` on `02:00.0` with the Omarchy service enabled. | udev rule by PCI class `0x010802`. Needed, but on its own it didn't stop the hangs. |
| 3 | **amdgpu (Radeon Pro 560) can't restore from S3 or hibernate**: `SMU load firmware failed (-22)`, then `ring sdma0 timeout`, GPU reset, and the desktop dies. | A `test_resume` hibernate reproduced it; others in omarchy#18669 see the same in S3. | s2idle only; hibernate disabled; UPower critical action → PowerOff. |
| 4 | **usbmuxd** (Arch 1.1.1-4) sets the T1 (`05ac:8600`) to USB config 0 at boot. | `bConfigurationValue` empty, no HID devices; `apple-touchbar.service` waited 30 s. | `/etc/udev/rules.d/39-usbmuxd.rules` override without `8600`. |
| 5 | **Touch Bar dark after s2idle**: `apple-ib-tb` only restores the bar in `.reset_resume`. | Log showed `Touchbar suspended.` and never `Touchbar resumed.`; `SOCW` alone didn't help. | Add `.resume = appletb_reset_resume` (driver patch). |
| 6 | **Touch Bar idle auto-off**: after 5 minutes idle the driver turns the bar off, and on this Mac it didn't come back until a cold boot. | Went dark ~30 minutes after first working; nothing else had touched it. | `idle_timeout=-1 dim_timeout=-1`. |

## Dead ends and traps

- **"It froze": often it didn't.** Thunderbolt stalls last 80-100 s. Several tests were force-killed after 30-60 s and recorded as "hang". Wait at least 3 minutes.
- **The journal can't show the hang.** Userspace and journald are frozen during suspend, so kernel messages from the hang are never saved. The last line is always `PM: suspend entry`. Bisect with `pm_test` instead of reading logs.
- **`pm_trace` is useless on these Macs.** A forced power-off makes the firmware reset the RTC to 2024-01-01, which erases the trace, so the `hash matches` line it prints is noise.
- **S3 ("deep") vs s2idle:** both hung, for the same Thunderbolt reason. After the TB fix, S3 still breaks amdgpu, so s2idle is the only usable mode.
- **Unloading the Touch Bar modules (`apple_ib_tb`, `apple_ib_als`) in the sleep hook:** the suspend after it never came back (the T1 was also unconfigured by usbmuxd at the time). Don't do it; let the driver's own suspend/resume run.
- **Retiring the Touch Bar stack** (blacklisting the driver) made boot faster but wasn't needed once usbmuxd was fixed, and it left the bar dark. Reverted.
- **"The Touch Bar hardware is dead"** was wrong. It looked dead in Linux *and* macOS for a while after experiments, and Apple Diagnostics gave `ADP000` (no issues found, but it often doesn't test the Touch Bar). A later macOS boot lit it immediately. **Test in macOS before blaming hardware.**
- **Touch works (Esc responds) but the Touch Bar has no light, and the driver says `touch bar ready`:** the T1's display side is stuck. Seen on 2026-11-22 after several quick **warm reboots**; one of those boots even brought the T1 up in recovery mode (`05ac:1281` "Apple Mobile Device (Recovery Mode)" instead of `05ac:8600`, `apple-touchbar.service` then waits 30 s). Neither the `SOCW` off/on pair nor reloading `apple_ib_tb` helped. **A full shutdown, waiting about 30 s, then powering on fixed it.** The T1 only reloads its firmware from a cold start, so go straight to a shutdown in this state.
- **Raw USB/HID commands to the iBridge** (a userspace "set mode/display" script) wedged the T1 until a full shutdown. Use the kernel driver.
- **t1bridge** (custom Touch Bar graphics and Touch ID) was reviewed but never installed. It's untested on 7.2 / Omarchy, sleep/wake is broken on the 14,3, and its FRST recovery can leave the T1 in recovery mode.
- **`ASOC.SOCW` off/on pair** (what macOS sends around sleep): harmless and kept, but on its own it did **not** relight the bar after s2idle; the driver `.resume` patch did.
- **Thunderbolt hook from omarchy#11570** only acts in S3 by design; on the 14,3 it's needed in s2idle too.
- **USB-C devices plugged in during sleep** may be lost until the next sleep or reboot (documented in omarchy#11570).
- **The lid wakes this machine from s2idle.** Others report needing a key press; it may depend on firmware.
- **`sudo` from an agent's shell:** it can't read a password, and `pkexec` needs a polkit agent, which isn't running by default on Omarchy/Hyprland. Have the user run root commands in a terminal, or grant temporary passwordless sudo with an expiry.

## Useful commands

```bash
# Did the last boot end in a hang? (last line = "PM: suspend entry")
journalctl -b -1 -n 30 --no-pager

# Bisect suspend without really sleeping (resumes after ~5 s)
echo 1 | sudo tee /sys/power/pm_print_times
echo devices | sudo tee /sys/power/pm_test && systemctl suspend   # then: platform
echo none | sudo tee /sys/power/pm_test

# Real sleep, wakes itself after 60 s
sudo rtcwake -m no -s 60 && systemctl suspend

# What happened during sleep
journalctl -b -k | grep -E 'PM: suspend (entry|exit)|complete after|Touchbar|inaccessible'
journalctl -b -t mbp-sleep
cat /sys/power/suspend_stats/{success,fail}

# T1 / Touch Bar state
cat /sys/bus/usb/devices/1-3/idProduct             # 8600 = normal, 1281 = T1 in recovery mode (do a full shutdown)
cat /sys/bus/usb/devices/1-3/bConfigurationValue   # 1 = fine, empty = usbmuxd unconfigured it
journalctl -b -u apple-touchbar
dkms status

# Boot time
systemd-analyze; systemd-analyze blame | head
```

## References

- [omacom/omarchy#11570](https://github.com/omacom/omarchy/pull/11570): Thunderbolt remove/rescan hook (S3), with test data from 14,1 / 14,2 / 14,3.
- [omacom/omarchy#18669](https://github.com/omacom/omarchy/issues/18669): NVMe fix on the wrong device; amdgpu S3/hibernate failure on the Radeon Pro 560.
- [omacom/omarchy#14692](https://github.com/omacom/omarchy/pull/14692): draft, s2idle by default on the 14,3. [#11624](https://github.com/omacom/omarchy/pull/11624) / [#12687](https://github.com/omacom/omarchy/pull/12687): NVMe fix scope.
- [omacom/omarchy#11731](https://github.com/omacom/omarchy/pull/11731): adds usbmuxd to Omarchy; would trigger cause 4 on T1 Macs.
- [standardagents/t1bridge#68](https://github.com/standardagents/t1bridge/issues/68): 14,3 suspend fix set and the `SOCW` pair.
- [libimobiledevice/usbmuxd#138](https://github.com/libimobiledevice/usbmuxd/issues/138), [#291](https://github.com/libimobiledevice/usbmuxd/issues/291): the T1 / usbmuxd rule history.
- [creolben/macbook-t1-touchbar#1](https://github.com/creolben/macbook-t1-touchbar/pull/1): the driver resume fix from this repo.
- amdgpu fix to watch for: "drm/amdgpu: reset VI ASIC on Apple boards with VRAM at 0" (mainline `92a5184787b8`, not verified here). When your kernel has it, test hibernate again, carefully.
