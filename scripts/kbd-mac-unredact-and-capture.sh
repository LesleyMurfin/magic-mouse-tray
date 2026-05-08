#!/bin/bash
# Attempt to un-redact macOS unified-log <private> markers, then re-run the
# keyboard reconnect capture, and grep for the SCO Link State Set Report
# bytes that the bluetoothd logs currently show as <private>.
#
# Run from Terminal.app (with Bluetooth permission and your sudo password).
#
# Outcomes:
#   1. Un-redact succeeds AND bytes appear -> we have the exact init payload.
#   2. Un-redact silently fails (still <private> in re-capture) -> need the
#      Apple "Enable Private Data Logging" config profile, which is gated
#      behind Apple Developer login (same place as the BT Debug profile).
#   3. `log config` rejects the mode change -> SIP and/or system policy
#      prevents un-redaction; only the config-profile path remains.
#
# Output: docs/kbd-mac-unredact-capture.txt + summary on stdout.

set -uo pipefail

KBD_ADDR_BU="e8-06-88-4b-07-41"
KBD_ADDR_BT="E8:06:88:4B:07:41"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${REPO_ROOT}/docs/kbd-mac-unredact-capture.txt"

if ! command -v blueutil >/dev/null 2>&1; then
  echo "blueutil not found. brew install blueutil" >&2
  exit 1
fi
if ! blueutil --paired >/dev/null 2>&1; then
  echo "Terminal lacks Bluetooth permission. Enable in System Settings >" >&2
  echo "Privacy & Security > Bluetooth, then re-run." >&2
  exit 1
fi

ts() { date '+%H:%M:%S'; }

echo "[$(ts)] requesting sudo (needed for log config + log stream)"
sudo -v || { echo "sudo declined"; exit 1; }

echo "[$(ts)] enabling private data logging system-wide"
sudo log config --mode 'private_data:on' 2>&1 | tee /tmp/log-config.out
LOG_CFG_RC=$?

if grep -qiE 'private_data|Operation not permitted|denied|invalid' /tmp/log-config.out; then
  echo
  echo "log config command produced output above. Some macOS versions accept the"
  echo "mode change with sudo alone; others need the Apple 'Logging' config"
  echo "profile installed. Continuing — we'll detect from the capture which case"
  echo "applies."
  echo
fi

echo "[$(ts)] starting log stream -> $OUT"
sudo log stream \
  --predicate 'subsystem CONTAINS "bluetooth" OR processImagePath CONTAINS "bluetoothd"' \
  --style compact --info --debug \
  > "$OUT" 2>&1 &
LOGPID=$!

sleep 2
echo "[$(ts)] disconnecting keyboard"
blueutil --disconnect "$KBD_ADDR_BU"
sleep 3
echo "[$(ts)] reconnecting keyboard"
blueutil --connect "$KBD_ADDR_BU"
echo
echo "*** PRESS A KEY ON THE KEYBOARD a few times over the next 30s ***"
echo
sleep 30

echo "[$(ts)] stopping log stream"
sudo kill "$LOGPID" 2>/dev/null
wait 2>/dev/null

echo
echo "[$(ts)] disabling private data logging again (clean shutdown)"
sudo log config --mode 'private_data:off' 2>&1 | head -3

echo
echo "==== Verification ===="
echo
echo "Looking for the SCO Link State Set Report enqueue line for ${KBD_ADDR_BT}..."

# The redacted form looks like:
#   "Enqueueing SCO Link State feature report to <private>. SCO Link State: 3"
# Un-redacted should replace <private> with the BD address (and possibly bytes).
SCO_LINES=$(grep -nE "SCO Link State|enqueueUserSpaceHIDDataForDevice" "$OUT" \
            | grep -iE "0x05|Set Report|SCO" \
            | head -10)

if [ -z "$SCO_LINES" ]; then
  echo "(no SCO Link State / Set Report lines for the keyboard found)"
  echo "Did the keyboard actually reconnect? Check: $OUT"
else
  echo "$SCO_LINES"
fi

echo
echo "---- Any remaining <private> markers in keyboard-related lines? ----"
PRIVATE_COUNT=$(grep -E "${KBD_ADDR_BT}|0x7[0-9a-f]{3}" "$OUT" | grep -c "<private>")
TOTAL_COUNT=$(grep -cE "${KBD_ADDR_BT}|0x7[0-9a-f]{3}" "$OUT")
echo "Keyboard lines with <private>:    $PRIVATE_COUNT / $TOTAL_COUNT"

echo
echo "---- Lines that reference RAW BYTES (hex dumps, payload arrays) ----"
grep -nE "(0x[0-9a-fA-F]{2}( |,)){3,}" "$OUT" | head -10 || echo "(none)"

echo
echo "Full stream:  $OUT"
echo
echo "Interpretation:"
echo "  * If SCO Link State lines now show the address and a hex payload  -> WIN."
echo "    Update kbd-setfeature-then-getinput-2026-05-08.ps1 with exact bytes."
echo "  * If <private> still dominates  -> install the Apple 'Logging' config"
echo "    profile (requires Apple Developer login):"
echo "      https://developer.apple.com/bug-reporting/profiles-and-logs/"
echo "    The same page hosts the Bluetooth Debug profile, which would also"
echo "    let PacketLogger capture the raw HCI bytes directly."
