#!/bin/zsh
# Runs a self-test script against the Debug build and prints the log.
# Usage: scripts/selftest.sh <script> [timeout seconds]
# The binary is started directly (not through `open`), so it runs as a child of this shell.
cd "$(dirname "$0")/.."
SCRIPT="$1"
LIMIT="${2:-120}"
UNTITLED="$HOME/Library/Application Support/Tape/Untitled"
before=$(ls "$UNTITLED" 2>/dev/null)
# Settings a script changes (device, pre-roll, monitoring, view) are put back afterwards.
SETTINGS=$(mktemp -t tape-settings)
defaults export com.maikbluhm.tape "$SETTINGS"
rm -f /tmp/tape-selftest.log
build/dd/Build/Products/Debug/Tape.app/Contents/MacOS/Tape -TapeSelfTest "$PWD/$SCRIPT" -ApplePersistenceIgnoreState YES &
PID=$!
for i in $(seq 1 $LIMIT); do
  sleep 1
  kill -0 $PID 2>/dev/null || break
done
kill $PID 2>/dev/null
defaults import com.maikbluhm.tape "$SETTINGS"
rm -f "$SETTINGS"
cat /tmp/tape-selftest.log
# Remove packages the run created.
for p in $(comm -13 <(echo "$before") <(ls "$UNTITLED" 2>/dev/null) | tr '\n' '\0' | xargs -0 -I{} echo "{}" | sed 's/ /%20/g'); do
  rm -rf "$UNTITLED/${p//\%20/ }"
done
