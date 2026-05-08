#!/bin/bash
# Capture macOS BT subsystem log activity around a keyboard reconnect,
# to determine whether macOS actively QUERIES battery (Hypothesis C)
# or just receives the connect-time push (Hypothesis A/B).
#
# Run from Terminal.app — needs:
#   - Terminal granted Bluetooth permission (for blueutil)
#   - Your sudo password (for `log stream` private data)
#
# Output:
#   docs/kbd-mac-logstream.txt  — full BT subsystem stream around reconnect
#   stdout summary              — filtered to the keyboard address
#
# Interpretation:
#   - "GetReport" / "SET_REPORT" / "L2CAP TX" entries → macOS sends requests
#     (Hypothesis C: investigate further with HCI capture)
#   - Only "RX" / "InputReport" / "BatteryLevel" entries → macOS just listens
#     (Hypothesis A/B: existing Windows strategy is correct)

set -uo pipefail

KBD_ADDR_BU="e8-06-88-4b-07-41"
KBD_ADDR_BT="E8:06:88:4B:07:41"
KBD_ADDR_NOSEP="e806884b0741"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${REPO_ROOT}/docs/kbd-mac-logstream.txt"

if ! command -v blueutil >/dev/null 2>&1; then
  echo "blueutil not found. Install with: brew install blueutil" >&2
  exit 1
fi

if ! blueutil --paired >/dev/null 2>&1; then
  echo "Terminal lacks Bluetooth permission. Enable in:" >&2
  echo "  System Settings > Privacy & Security > Bluetooth" >&2
  exit 1
fi

echo "About to run: sudo log stream (BT subsystem)"
echo "You'll be prompted for your macOS password."
echo
sudo -v || { echo "sudo declined"; exit 1; }

ts() { date '+%H:%M:%S'; }

echo "[$(ts)] starting log stream -> $OUT"
sudo log stream \
  --predicate 'subsystem CONTAINS "bluetooth" OR subsystem CONTAINS "BluetoothManager" OR subsystem CONTAINS "IOBluetooth" OR processImagePath CONTAINS "bluetoothd"' \
  --style compact --info --debug \
  > "$OUT" 2>&1 &
LOGPID=$!

# Bridge sudo for the kill at end
sleep 2
echo "[$(ts)] disconnecting keyboard"
blueutil --disconnect "$KBD_ADDR_BU"

sleep 3
echo "[$(ts)] reconnecting keyboard"
blueutil --connect "$KBD_ADDR_BU"

echo
echo "***************************************************************"
echo "* PRESS ANY KEY ON THE APPLE KEYBOARD NOW to wake it for       *"
echo "* reconnection. Tap a few keys over the next 60 seconds.       *"
echo "* (We need traffic so the battery push gets sent.)             *"
echo "***************************************************************"
echo
echo "[$(ts)] holding 60s to capture post-connect traffic"
sleep 60

echo "[$(ts)] stopping log stream"
sudo kill "$LOGPID" 2>/dev/null
wait 2>/dev/null

echo
echo "==== Summary ===="
echo "Total log lines:  $(wc -l < "$OUT")"
echo
echo "---- Lines mentioning the keyboard address ----"
grep -iE "${KBD_ADDR_BT}|${KBD_ADDR_NOSEP}" "$OUT" | head -40 || echo "(none)"
echo
echo "---- Lines mentioning battery / 0x47 / RID 71 ----"
grep -iE "battery|0x47|RID *71|report.*47|report.*71|GetReport|SetReport" "$OUT" \
  | grep -viE "AirPods|HeadPhone|HeadSet|Mouse|D0:C0:50|04:F1:3E|80:C3:BA|2C:FD:B4|F0:EF:86" \
  | head -60 || echo "(none)"
echo
echo "Full stream:  $OUT"
echo
echo "Look for:"
echo "  TX / SetReport / GetReport from host  -> macOS is actively querying"
echo "  RX / InputReport / pushed             -> macOS just listening"
