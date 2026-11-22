# Instructions for AI agents

You are helping someone fix suspend/resume on a 2016-2017 T1 MacBook Pro running Linux, most likely a MacBookPro14,3 on Omarchy or Arch. Read `README.md` first. It explains each problem and fix. This file tells you how to work safely with the user.

## Ground rules

1. **Never start anything that blanks or freezes the screen in the same turn as the instructions for it.** That covers suspend, hibernate, `pm_test`, reboots and GPU changes. First give short, numbered instructions: what will happen, how long to wait, what to press if it doesn't come back, and what to type afterwards (for example how to reopen the agent session). Then wait for the user to say "go". The user can't read your message once the screen is black.
2. **Tell the user to wait at least 3 minutes before holding the power button.** On these Macs, what looks like a frozen suspend is often an 80-100 s stall on dead Thunderbolt bridges. Forcing a power-off too early destroys the evidence and costs a reboot.
3. **Don't hibernate to test anything.** Hibernate restore kills the Radeon (`SMU load firmware failed`, `-22`) and crashes the desktop session. `install.sh` disables it on purpose.
4. **Don't use `pm_trace`.** The Mac firmware resets the RTC to 2024-01-01 on a forced power-off, so the trace is lost, and any "hash matches" line it prints is meaningless.
5. **Don't send raw USB/HID commands to the T1 iBridge (`05ac:8600`)**, and don't use t1bridge's FRST/recovery. Raw commands can wedge the T1 until a full shutdown, and recovery mode can leave it in recovery.
6. **Don't unload the Touch Bar modules (`apple_ib_tb`, `apple_ibridge`) inside a sleep hook.** On a test machine, that step was followed by a suspend that never came back.
7. Disk encryption (LUKS) means the user must type a password at every boot. Plan reboots around that.

## Install

```bash
cat /sys/class/dmi/id/product_name   # expect MacBookPro14,3
sudo ./install.sh                    # needs a sudo password: ask the user to run it if you can't
```

On another model, explain which parts may not apply (see README "Tested on") before suggesting `--force`. The optional Touch Bar panel signal needs `acpi_call` (Arch: `sudo pacman -S acpi_call-dkms`).

## Verify (follow ground rule 1)

Sleep test that wakes itself after 60 s:

```bash
sudo rtcwake -m no -s 60 && systemctl suspend
```

Afterwards, check:

```bash
journalctl -b -k | grep -E 'PM: suspend (entry|exit)|Touchbar (suspended|resumed)'
journalctl -t mbp-sleep -b              # hook ran: SOCW, Thunderbolt removed/rescanned, Wi-Fi
cat /sys/power/suspend_stats/{success,fail}
ls /sys/bus/pci/drivers/xhci_hcd | grep -c 0000   # 3 on a 14,3 after resume
```

Ask the user whether the Touch Bar is lit and whether Wi-Fi reconnected.

## If it still hangs

- The previous boot's journal ends at `PM: suspend entry` with no `suspend exit`: run `journalctl -b -1 -k | tail`. The kernel log of the hang itself is never saved, so bisect instead of reading logs.
- Bisect with `/sys/power/pm_test` (`devices`, then `platform`) and `echo 1 > /sys/power/pm_print_times`. Each test resumes by itself after about 5 s. Set `pm_test` back to `none` afterwards. `devices` passing while `platform` hangs points at a device's late/noirq power-down. On the 14,3 that device was the Thunderbolt controllers.
- Check what the hook did: `journalctl -b -1 -t mbp-sleep`.
- Check `cat /sys/power/mem_sleep` and `/etc/systemd/sleep.conf.d/90-mbp-sleep.conf`. It should sleep in s2idle, not deep.

## Common problems

| Symptom | Check / fix |
|---|---|
| Touch Bar dark after every wake | Is the driver patched? `grep '\.resume = appletb_reset_resume' /usr/src/appleibridge-*/apple-ib-tb.c`. Rebuild with DKMS, then `modprobe -r apple_ib_tb && modprobe apple_ib_tb` while awake. |
| Touch Bar dark at boot, 30 s black screen | `cat /sys/bus/usb/devices/1-3/bConfigurationValue` is empty: the usbmuxd rule unconfigured the T1. Check `/etc/udev/rules.d/39-usbmuxd.rules` exists. |
| Touch Bar dark even in macOS | Only then suspect hardware. It lighting up in macOS means the hardware is fine. |
| USB-C device lost after sleep | Known limit (see README). Unplug and replug, or reboot. |

## Undo

```bash
sudo ./install.sh --undo
```
