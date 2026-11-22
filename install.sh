#!/bin/bash
# Install the sleep/resume fixes for 2016-2017 T1 MacBook Pros (MacBookPro14,3).
#   sudo ./install.sh          install
#   sudo ./install.sh --undo   remove everything this script installed
#   sudo ./install.sh --force  install on a model other than MacBookPro14,3
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
cd "$(dirname "$(readlink -f "$0")")"

HOOK=/usr/lib/systemd/system-sleep/90-mbp-sleep
UDEV=/etc/udev/rules.d/90-mbp-nvme-no-d3cold.rules
SLEEP=/etc/systemd/sleep.conf.d/90-mbp-sleep.conf
LID=/etc/systemd/logind.conf.d/90-mbp-lid.conf
TMPF=/etc/tmpfiles.d/90-mbp-pm.conf
ACPI=/etc/modules-load.d/acpi_call.conf
MUX_SRC=/usr/lib/udev/rules.d/39-usbmuxd.rules
MUX=/etc/udev/rules.d/39-usbmuxd.rules
UPOWER=/etc/UPower/UPower.conf
UPOWER_BAK=/etc/UPower/UPower.conf.before-mbp-sleep-fix
PATCH=$PWD/patches/apple-ib-tb-s2idle-resume.patch
MARK="mbp14-3-linux-sleep-fix"

say() { printf '==> %s\n' "$*"; }

tb_src() { ls -d /usr/src/appleibridge-* 2>/dev/null | head -1; }
dkms_rebuild() {
  local src=$1 name ver
  name=$(sed -n 's/^PACKAGE_NAME="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$src/dkms.conf")
  ver=$(sed -n 's/^PACKAGE_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$src/dkms.conf")
  dkms build "$name/$ver" --force >/dev/null && dkms install "$name/$ver" --force >/dev/null
  say "rebuilt $name/$ver (reload apple_ib_tb or reboot to use it)"
}

if [[ ${1:-} == --undo ]]; then
  rm -fv "$HOOK" "$UDEV" "$SLEEP" "$LID" "$TMPF" "$ACPI"
  if [[ -f $MUX ]] && grep -q "$MARK" "$MUX"; then rm -fv "$MUX"; fi
  if [[ -f $UPOWER_BAK ]]; then mv -v "$UPOWER_BAK" "$UPOWER"; systemctl try-restart upower; fi
  src=$(tb_src)
  if [[ -n $src ]] && grep -q '\.resume = appletb_reset_resume' "$src/apple-ib-tb.c"; then
    patch -d "$src" -p1 -R --silent <"$PATCH" && dkms_rebuild "$src"
  fi
  udevadm control --reload
  systemctl kill -s HUP systemd-logind
  say "Removed. NVMe D3cold stays off until the next reboot."
  exit 0
fi

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
if [[ $model != MacBookPro14,3 && ${1:-} != --force ]]; then
  echo "This was tested on MacBookPro14,3; this machine is '$model'." >&2
  echo "Read the README, then re-run with --force if you want it anyway." >&2
  exit 1
fi

say "sleep hook: Thunderbolt remove/rescan, Wi-Fi, Touch Bar panel"
install -Dm755 files/90-mbp-sleep "$HOOK"

say "NVMe: no D3cold (by PCI class)"
install -Dm644 files/90-mbp-nvme-no-d3cold.rules "$UDEV"
udevadm control --reload
for d in /sys/bus/pci/devices/*; do
  [[ $(cat "$d/class") == 0x010802 ]] && echo 0 >"$d/d3cold_allowed"
done

say "s2idle, hibernate off, lid = suspend, sequential device PM"
install -Dm644 files/90-mbp-sleep.conf "$SLEEP"
install -Dm644 files/90-mbp-lid.conf "$LID"
install -Dm644 files/90-mbp-pm.conf "$TMPF"
systemd-tmpfiles --create "$TMPF"
systemctl kill -s HUP systemd-logind

if [[ -f $MUX_SRC ]] && grep -q '5ac/8600' "$MUX_SRC"; then
  say "usbmuxd: stop it from switching off the T1 (05ac:8600) at boot"
  { echo "# $MARK: local override of $MUX_SRC without 05ac:8600 (MacBook T1 iBridge)."
    echo "# Upstream sets that device to USB config 0, which disables the Touch Bar and camera."
    sed 's/|5ac\/8600\/\*//g' "$MUX_SRC"; } >"$MUX"
  udevadm control --reload
fi

if [[ -f $UPOWER ]] && grep -qE '^CriticalPowerAction=(Hibernate|HybridSleep)' "$UPOWER"; then
  say "UPower: critical battery action -> PowerOff (hibernate is disabled)"
  cp -n "$UPOWER" "$UPOWER_BAK"
  sed -i -E 's/^CriticalPowerAction=(Hibernate|HybridSleep)$/CriticalPowerAction=PowerOff/' "$UPOWER"
  systemctl try-restart upower
fi

src=$(tb_src)
if [[ -n $src ]]; then
  if grep -q '\.resume = appletb_reset_resume' "$src/apple-ib-tb.c"; then
    say "Touch Bar driver already has the s2idle resume fix"
  else
    say "Touch Bar driver: add the s2idle resume fix to $src"
    patch -d "$src" -p1 --silent <"$PATCH" && dkms_rebuild "$src"
  fi
  if [[ -w /proc/acpi/call ]] || modinfo acpi_call >/dev/null 2>&1; then
    install -Dm644 files/acpi_call.conf "$ACPI"
    modprobe acpi_call || true
  else
    say "optional: install acpi_call (Arch: acpi_call-dkms) for the Touch Bar panel signal"
  fi
fi

say "Done. No reboot needed. Test: sudo rtcwake -m no -s 60 && systemctl suspend"
