#!/bin/bash
# Force a fresh battery read on Lesley's Apple Keyboard while
# PacketLogger is recording, so we can find the request/response
# pair in the HCI capture and port the protocol to Windows.
#
# Workflow:
#   1. Open PacketLogger.app, hit the red Start button.
#   2. Run this script.
#   3. Stop the capture, save as .pklg, share for analysis.
#
# The script prints high-resolution wall-clock markers around the
# disconnect/reconnect so you can scrub directly to the exchange.

set -uo pipefail

KBD_NAME="Lesley's Keyboard"
KBD_ADDR_BU="e8-06-88-4b-07-41"   # blueutil format
KBD_ADDR_BT="E8:06:88:4B:07:41"   # display format

if ! command -v blueutil >/dev/null 2>&1; then
  echo "blueutil not found. Install with: brew install blueutil" >&2
  exit 1
fi

# Quick permission probe
if ! blueutil --paired >/dev/null 2>&1; then
  echo "blueutil cannot reach the Bluetooth API." >&2
  echo "Grant Bluetooth permission to your terminal app:" >&2
  echo "  System Settings > Privacy & Security > Bluetooth" >&2
  exit 1
fi

ts() { date '+%Y-%m-%d %H:%M:%S.%3N'; }

echo "=================================================================="
echo " Apple Keyboard Battery Capture Trigger"
echo " Device: ${KBD_NAME}  ${KBD_ADDR_BT}"
echo "=================================================================="
echo

echo "[T0  $(ts)]  baseline — PacketLogger should be recording now"
echo "             (current battery per system_profiler:)"
system_profiler SPBluetoothDataType 2>/dev/null \
  | awk '/'"${KBD_NAME%\'s Keyboard}"'/{flag=1} flag && /Battery Level/{print "             " $0; exit}'
echo

echo "[T1  $(ts)]  disconnecting keyboard..."
blueutil --disconnect "${KBD_ADDR_BU}"
sleep 3

echo "[T2  $(ts)]  reconnecting keyboard..."
blueutil --connect "${KBD_ADDR_BU}"

# Poll for reconnection (HID setup, including battery query, runs here)
for i in $(seq 1 15); do
  sleep 1
  if blueutil --is-connected "${KBD_ADDR_BU}" 2>/dev/null | grep -q 1; then
    echo "[T3  $(ts)]  reconnected after ${i}s — battery query should have just fired"
    break
  fi
done

# Give the OS a beat to ingest the battery report before we re-read
sleep 2

echo "[T4  $(ts)]  post-reconnect battery per system_profiler:"
system_profiler SPBluetoothDataType 2>/dev/null \
  | awk '/'"${KBD_NAME%\'s Keyboard}"'/{flag=1} flag && /Battery Level/{print "             " $0; exit}'

echo
echo "Done. In PacketLogger:"
echo "  1. File > Stop"
echo "  2. File > Save As...  ->  docs/kbd-mac-capture-\$(date).pklg"
echo "  3. Filter to address ${KBD_ADDR_BT}"
echo "  4. Look between [T2] and [T3] for L2CAP on PSM 0x11 (HID Control)"
echo "     with HID Get_Report (Feature) -> response containing battery %"
