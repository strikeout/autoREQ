#!/bin/sh
# Runs the self-test and the flow test of build/AutoREQ.app on a loop-through device.
# `open -W` exits with 0 also when the app stops, so the script checks the last line of each test.
# Usage: sh scripts/flowtest.sh "VB-Cable"
set -u
DEVICE="${1:-VB-Cable}"
OUT="$(mktemp -d)"
status=0
for mode in selftest flowtest; do
  open -W --stdout "$OUT/$mode.txt" build/AutoREQ.app --args "--$mode" "$DEVICE"
  cat "$OUT/$mode.txt"
  if [ "$(tail -n 1 "$OUT/$mode.txt")" != "PASS" ]; then
    echo "The $mode did not pass. If the output stops early, the app stopped: see ~/Library/Logs/DiagnosticReports." >&2
    status=1
  fi
done
rm -rf "$OUT"
exit $status
