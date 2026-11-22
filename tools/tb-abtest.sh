#!/bin/bash
# A/B test: does removing the Thunderbolt trees fix the s2idle noirq stall?
#   sudo tools/tb-abtest.sh off|on [pm_test level, default: platform]
# Run off, on, off. Each run enters s2idle directly (echo freeze >
# /sys/power/state) with pm_test set, so the kernel walks every device
# suspend phase and then resumes after ~5 s, without sleeping for real.
# The other settings stay fixed: the same Wi-Fi and Touch Bar steps as
# files/90-mbp-sleep, and the same sysfs settings. Only the Thunderbolt
# removal changes. systemd-sleep hooks do not run. Nothing persistent is
# changed, and pm_test is reset to none afterwards.
# A run with removal off may stall for minutes: wait at least 3 minutes
# before calling it a hang. Results are appended to
# /var/log/mbp-tb-abtest.log.
set -u
[[ $EUID -eq 0 ]] || { echo "Run with sudo." >&2; exit 1; }
mode=${1:-}; level=${2:-platform}
[[ $mode == on || $mode == off ]] || { echo "usage: $0 on|off [pm_test level]" >&2; exit 1; }
LOG=/var/log/mbp-tb-abtest.log
SOCW='\_SB.PCI0.XHC1.RHUB.ASOC.SOCW'
note() { echo "$*" | tee -a "$LOG"; }

note "=== $(date -Is) tb_removal=$mode pm_test=$level"
note "model=$(cat /sys/class/dmi/id/product_name) kernel=$(uname -r) hook_sha=$(git -C "$(dirname "$0")/.." rev-parse HEAD 2>/dev/null)"
note "ac_online=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null) battery=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)% usb_c_devices=[$(ls /sys/bus/usb/devices | grep -E '^[3-6]-[0-9]+$' | tr '\n' ' ')]"
note "mem_sleep=$(cat /sys/power/mem_sleep) pm_async=$(cat /sys/power/pm_async) pci_functions=$(ls /sys/bus/pci/devices | wc -l) xhci=$(ls /sys/bus/pci/drivers/xhci_hcd | grep -c 0000)"

# Fixed steps, identical to the hook's pre-sleep.
modprobe acpi_call 2>/dev/null && [[ -w /proc/acpi/call ]] && echo "$SOCW 0x0" >/proc/acpi/call
wifi=$(readlink -f /sys/bus/pci/drivers/brcmfmac/0000:* 2>/dev/null | head -1)
if [[ -n $wifi ]]; then
  echo 0 >"$wifi/d3cold_allowed"; echo disabled >"$(dirname "$wifi")/power/wakeup" 2>/dev/null
  timeout 15 modprobe -r brcmfmac_wcc brcmfmac
fi

# The variable.
roots=()
if [[ $mode == on ]]; then
  for nhi in /sys/bus/pci/drivers/thunderbolt/0000:*; do
    [[ -e $nhi ]] || continue
    n=$(readlink -f "$nhi"); up=$(dirname "$(dirname "$n")"); root=$(dirname "$up")
    roots+=("$(basename "$root")"); echo disabled >"$root/power/wakeup" 2>/dev/null
    echo 1 >"$up/remove"
  done
  note "removed thunderbolt under: ${roots[*]}"
fi

echo 1 >/sys/power/pm_print_times
echo "$level" >/sys/power/pm_test
sync
t0=$(date +%s.%N)
echo freeze >/sys/power/state; rc=$?
t1=$(date +%s.%N)
echo none >/sys/power/pm_test
note "state write rc=$rc elapsed=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')s pm_test_now=$(cat /sys/power/pm_test | grep -o '\[none\]')"

# Undo, identical to the hook's post-wake.
for r in "${roots[@]}"; do echo 1 >"/sys/bus/pci/devices/$r/rescan"; done
[[ -n $wifi ]] && modprobe brcmfmac
[[ -w /proc/acpi/call ]] && echo "$SOCW 0x1" >/proc/acpi/call
sleep 3
note "after: pci_functions=$(ls /sys/bus/pci/devices | wc -l) xhci=$(ls /sys/bus/pci/drivers/xhci_hcd | grep -c 0000)"
journalctl -k --since "@${t0%.*}" --no-pager -o short-monotonic \
  | grep -E 'PM: (suspend|noirq|late|early|resume|start).*(complete|entry|exit)|inaccessible|Unable to change power state|failed to (suspend|resume)' \
  | tee -a "$LOG"
sync
