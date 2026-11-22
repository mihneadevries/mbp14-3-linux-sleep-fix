# mbp14-3-linux-sleep-fix

Makes suspend work on the 2017 15" MacBook Pro (**MacBookPro14,3**, T1 / Touch Bar) under Linux. It was built and tested on [Omarchy](https://omarchy.org), and should apply to other Arch-based systems.

Without these fixes, every sleep looks like a hard hang: the lid closes, the screen goes black, it never wakes up, and the log stops at `PM: suspend entry`. You have to hold the power button.

With them, lid close/open and timed sleeps resume cleanly: display, keyboard, Wi-Fi, Thunderbolt/USB-C and the Touch Bar all come back.

## Tested on

| | |
|---|---|
| Model | MacBookPro14,3 (Radeon Pro 560 `1002:67ef`, Samsung SM961 NVMe `144d:a804`, BCM43602 Wi-Fi) |
| OS | Omarchy 4.x, kernel `7.2.15-1-omarchy` |
| Touch Bar driver | [creolben/macbook-t1-touchbar](https://github.com/creolben/macbook-t1-touchbar) (`appleibridge` DKMS) |

Other 2016-2017 models (13,x / 14,1 / 14,2) share most of these problems, but this exact set is untested on them. The installer refuses to run on anything other than a 14,3 unless you pass `--force`.

## What was wrong, and what each fix does

| Problem | Symptom | Fix |
|---|---|---|
| **Thunderbolt** (main cause). Apple firmware cuts power to the two Alpine Ridge controllers during sleep. The kernel then waits on the dead bridges for 80-100 s in the noirq phase. | Looks like a hard hang on suspend/resume. `pm_test=devices` passes, `pm_test=platform` "freezes". | The sleep hook removes both Thunderbolt upstream ports before sleep and rescans their root ports after. Based on [omarchy#11570](https://github.com/omacom/omarchy/pull/11570), which only does this for S3; on the 14,3 the stall also happens in **s2idle**. |
| **NVMe D3cold**. Omarchy's `fix-suspend-nvme.sh` hard-codes `01:00.0`, which is the **Radeon** on 15" models, so the SSD was never covered ([omarchy#18669](https://github.com/omacom/omarchy/issues/18669)). | Disk gone after resume. | A udev rule disables D3cold on every NVMe controller, matched by PCI class. |
| **S3 "deep" sleep breaks amdgpu** on the Radeon Pro 560 (`SMU load firmware failed`, `-22`). | Black screen after resume. | Use **s2idle** (`MemorySleepMode=s2idle`). |
| **Hibernate** hits the same amdgpu restore failure. | Session crashes after restore. | Hibernate, suspend-then-hibernate and hybrid sleep are disabled; lid = plain suspend; UPower critical action `Hibernate` → `PowerOff`. Re-enable once your kernel has "drm/amdgpu: reset VI ASIC on Apple boards with VRAM at 0". |
| **Wi-Fi** (brcmfmac). | Flaky after resume. | Unload/reload `brcmfmac` around sleep, keep the card out of D3cold, disable its root port's wake. |
| **Touch Bar dark after sleep**. `apple-ib-tb` turns the bar off on suspend but only turns it back on in `.reset_resume`. s2idle resumes without a USB reset, so it stays off. | Touch Bar black after every wake. | [`patches/apple-ib-tb-s2idle-resume.patch`](patches/apple-ib-tb-s2idle-resume.patch) adds `.resume`. The hook also sends the `ASOC.SOCW` panel off/on pair macOS sends (needs `acpi_call`; see [t1bridge#68](https://github.com/standardagents/t1bridge/issues/68)). |
| **usbmuxd** (the iPhone service) has a udev rule that matches `05ac:8600`, the T1 iBridge, and sets it to USB configuration 0 at boot. Fixed upstream in 2023 ([usbmuxd#138](https://github.com/libimobiledevice/usbmuxd/issues/138), commit `61b99ab`), but Arch's `usbmuxd 1.1.1-4` still ships the old rule. | Touch Bar and FaceTime camera disappear. A Touch Bar handover service waits 30 s at boot (black screen). | A local override of `39-usbmuxd.rules` without `05ac:8600`, in `/etc/udev/rules.d/`. iPhones still work. |

## Touch Bar

This repo doesn't install the Touch Bar driver. It fixes what sleep and boot do to it. For a working Touch Bar on a T1 Mac:

1. **Install the driver** from [creolben/macbook-t1-touchbar](https://github.com/creolben/macbook-t1-touchbar) by [Ben Jerome (@creolben)](https://github.com/creolben). It packages the original T1 driver by [Ronald Tschalär (@roadrunner2)](https://github.com/roadrunner2/macbook12-spi-driver) with DKMS and a boot-time handover service:
   ```bash
   git clone https://github.com/creolben/macbook-t1-touchbar
   cd macbook-t1-touchbar/standalone && sudo ./bootstrap-t1-touchbar.sh
   ```
2. **Stop the driver's idle auto-off.** By default the driver switches the bar off after 5 minutes idle. On a 14,3 it then never came back, even after a reboot, until a full shutdown. Set this in `/etc/modprobe.d/apple-ib-tb.conf`:
   ```
   options apple-ib-tb fnmode=1 idle_timeout=-1 dim_timeout=-1
   ```
   It takes effect at the next boot. The trade-off: the OLED strip never turns off, so static keys may slowly burn in.
3. **Run this repo's `install.sh`.** It adds the s2idle resume fix to the driver (until [creolben/macbook-t1-touchbar#1](https://github.com/creolben/macbook-t1-touchbar/pull/1) is merged), the `ASOC.SOCW` panel signal around sleep, and the usbmuxd override that otherwise switches the T1 off at boot.

**Is the Touch Bar hardware dead?** Probably not. Boot macOS: if the bar lights up there, or after a sleep and wake there, the hardware is fine and the problem is on the Linux side. Apple Diagnostics often doesn't test the Touch Bar at all.

**Custom buttons and Touch ID:** the driver above only shows Apple's built-in layouts (Esc and media keys, or F1-F12 while holding Fn). For custom graphics and Touch ID on T1, see [standardagents/t1bridge](https://github.com/standardagents/t1bridge) (experimental). Its [issue #68](https://github.com/standardagents/t1bridge/issues/68) documents the `SOCW` sleep/wake pair used here.

## Install

```bash
git clone https://github.com/mihneadevries/mbp14-3-linux-sleep-fix
cd mbp14-3-linux-sleep-fix
sudo ./install.sh
```

No reboot is needed. Optional, for the Touch Bar panel signal on Arch:

```bash
sudo pacman -S acpi_call-dkms
```

Test with a 60-second self-waking sleep:

```bash
sudo rtcwake -m no -s 60 && systemctl suspend
```

The hook logs to the journal: `journalctl -t mbp-sleep`.

## Using an AI agent?

`AGENTS.md` has instructions for coding agents (Claude Code, Codex, Cursor and others). Clone the repo, open your agent in it, and paste:

> Read AGENTS.md and README.md. My MacBook freezes when it sleeps. Check my model, install this fix, and walk me through one test sleep. Before anything that blanks the screen, list the steps and wait for me to say "go".

## Uninstall

```bash
sudo ./install.sh --undo
```

This removes every file it installed, restores `UPower.conf`, and reverts the driver patch.

## Files installed

| File | Purpose |
|---|---|
| `/usr/lib/systemd/system-sleep/90-mbp-sleep` | Thunderbolt remove/rescan, Wi-Fi, Touch Bar `SOCW` |
| `/etc/udev/rules.d/90-mbp-nvme-no-d3cold.rules` | NVMe D3cold off |
| `/etc/systemd/sleep.conf.d/90-mbp-sleep.conf` | s2idle, hibernate off |
| `/etc/systemd/logind.conf.d/90-mbp-lid.conf` | lid → suspend |
| `/etc/tmpfiles.d/90-mbp-pm.conf` | `pm_async=0` |
| `/etc/udev/rules.d/39-usbmuxd.rules` | usbmuxd override (only if usbmuxd is installed) |
| `/etc/modules-load.d/acpi_call.conf` | only if `acpi_call` is available |
| `/usr/src/appleibridge-*/apple-ib-tb.c` | patched and rebuilt with DKMS (only if the Touch Bar driver is installed) |

## Known limits

- **Hibernate is off** until the amdgpu fix reaches your kernel.
- **The battery isn't checked while asleep.** A very long sleep on battery can run it flat, and unsaved work is lost.
- A device left plugged into a USB-C port during sleep may not come back until the next sleep or reboot (see the known limits in [omarchy#11570](https://github.com/omacom/omarchy/pull/11570)).
- On this machine the lid wakes it from s2idle. Others report needing a key press instead.

## How it was debugged

`/sys/power/pm_test` with `pm_print_times=1`: `devices` passed, `platform` hung, and removing the Thunderbolt trees before sleep made `platform` pass in 7 s. Note that `pm_trace` is useless on these Macs, because the firmware resets the RTC to 2024-01-01 on a forced power-off.

## Credits

- Thunderbolt remove/rescan approach: [omacom/omarchy#11570](https://github.com/omacom/omarchy/pull/11570) and the people testing it there.
- NVMe and amdgpu findings: [omacom/omarchy#18669](https://github.com/omacom/omarchy/issues/18669).
- `ASOC.SOCW` sleep/wake pair: [standardagents/t1bridge#68](https://github.com/standardagents/t1bridge/issues/68).
- T1 Touch Bar driver: [Ronald Tschalär (@roadrunner2)](https://github.com/roadrunner2) ([macbook12-spi-driver](https://github.com/roadrunner2/macbook12-spi-driver)), packaged for current kernels by [Ben Jerome (@creolben)](https://github.com/creolben) ([macbook-t1-touchbar](https://github.com/creolben/macbook-t1-touchbar)).
- T1 research, custom Touch Bar and Touch ID: [standardagents/t1bridge](https://github.com/standardagents/t1bridge).

## License

GPL-2.0. The driver patch applies to GPL-2.0 code.
