# Fresh install: full setup for a MacBookPro14,3 on Omarchy

The complete order after installing Omarchy (or Arch) from scratch. Part A is the hardware setup this repo is about. Part B is optional personal settings that work well on this Mac. If you use an AI agent, point it at this file and at [`AGENTS.md`](../AGENTS.md).

## Part A: hardware (in this order)

**1. Touch Bar driver** ([creolben/macbook-t1-touchbar](https://github.com/creolben/macbook-t1-touchbar))

```bash
git clone https://github.com/creolben/macbook-t1-touchbar ~/macbook-t1-touchbar
cd ~/macbook-t1-touchbar/standalone && sudo ./bootstrap-t1-touchbar.sh
```

**2. Keep the Touch Bar from switching itself off for good**

```bash
echo 'options apple-ib-tb fnmode=1 idle_timeout=-1 dim_timeout=-1' | sudo tee /etc/modprobe.d/apple-ib-tb.conf
```

The driver's default 5-minute idle off can leave the bar dark until a full shutdown. The trade-off of `-1` is that the OLED never turns off.

**3. Helper for the Touch Bar panel signal around sleep**

```bash
sudo pacman -S --needed acpi_call-dkms
```

**4. This repo**, after the Touch Bar driver so `install.sh` can patch it

```bash
git clone https://github.com/mihneadevries/mbp14-3-linux-sleep-fix ~/mbp14-3-linux-sleep-fix
cd ~/mbp14-3-linux-sleep-fix && sudo ./install.sh
```

**5. Shut down fully** (not a reboot), wait about 10 seconds, then power on. The T1 chip only reloads cleanly from a cold start.

**6. Check it**

- Boot reaches the desktop without a 30-second black screen.
- The Touch Bar shows Esc and media keys, and F1-F12 while you hold Fn.
- A sleep test wakes by itself, with the Touch Bar and Wi-Fi back: `sudo rtcwake -m no -s 60 && systemctl suspend` (save your work first).

**Later: if you install `usbmuxd`** (iPhone over USB), **re-run `sudo ./install.sh`**. Arch's `usbmuxd` package switches the T1 off at boot, and `install.sh` only adds its override when `usbmuxd` is present. Re-run it after `usbmuxd` updates too.

## Part B: optional personal settings

### Escape on the key left of 1 (ISO keyboards)

On ISO MacBook keyboards the key left of `1` sends `<LSGT>` (it types `<`). This makes it Escape, which is handy because Esc otherwise lives on the Touch Bar.

`~/.config/xkb/symbols/local`:

```
partial alphanumeric_keys
xkb_symbols "grave_escape" {
  key <LSGT> { [ Escape, Escape ] };
};
```

`~/.config/xkb/rules/evdev`:

```
! include %E/evdev

! option = symbols
  local:grave_escape = +local(grave_escape)
```

In `~/.config/hypr/input.lua`, add `local:grave_escape` to `kb_options` and keep whatever is already there:

```lua
hl.config({
  input = {
    kb_options = "omarchy:shift_caps_compose,local:grave_escape",
  },
})
```

Log out and back in. Hyprland doesn't always pick up xkb changes on a plain reload.

### Natural (reversed) touchpad scrolling

In `~/.config/hypr/input.lua`:

```lua
hl.config({
  input = {
    touchpad = {
      natural_scroll = true,
    },
  },
})
```

### Low-battery behaviour: warn, then shut down cleanly at 7%

`install.sh` already changes the critical action from hibernate (which crashes this Mac) to power off. To also set the thresholds:

```bash
sudo sed -i -E 's/^PercentageLow=.*/PercentageLow=20.0/; s/^PercentageCritical=.*/PercentageCritical=10.0/; s/^PercentageAction=.*/PercentageAction=7.0/' /etc/UPower/UPower.conf
sudo systemctl restart upower
```

Warning sound on low battery (an Omarchy hook):

```bash
cp ~/.config/omarchy/hooks/battery-low.d/play-warning-sound.sample ~/.config/omarchy/hooks/battery-low.d/play-warning-sound
chmod +x ~/.config/omarchy/hooks/battery-low.d/play-warning-sound
```

### Stay awake (no idle lock or sleep)

Toggle it from the Omarchy menu, or run `omarchy-toggle-idle`. With it on, the machine only sleeps when you close the lid, and the screen still locks before sleeping.

The battery isn't checked while the machine is asleep, so plug it in for long lid-closed breaks.

### Backups with Pika Backup

```bash
sudo pacman -S --needed pika-backup
```

Set up the repository and schedule in Pika's window (on an external drive, with encryption on), then make its scheduler start at login by adding this to `~/.config/hypr/autostart.lua`:

```lua
o.launch_on_start("pika-backup-monitor")
```

With Omarchy's auto-login after the disk password, the GNOME keyring stays locked, so Pika may ask for the backup password each time instead of saving it.

### T1 firmware backup (recommended once)

The T1's firmware lives on the Mac's EFI partition (`EFI/APPLE/EMBEDDEDOS`). Copy that folder somewhere off the Mac, such as a USB stick formatted exFAT so macOS can read it too, before experimenting with Touch Bar software. creolben's repo includes `standalone/backup-t1-firmware.sh` for this.
