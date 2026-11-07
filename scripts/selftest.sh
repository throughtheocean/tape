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
DOMAIN=com.runningoncliffs.tape
SETTINGS=$(mktemp -t tape-settings)
defaults export $DOMAIN "$SETTINGS"
rm -f /tmp/tape-selftest.log
build/dd/Build/Products/Debug/Tape.app/Contents/MacOS/Tape -TapeSelfTest "$PWD/$SCRIPT" -ApplePersistenceIgnoreState YES &
PID=$!
for i in $(seq 1 $LIMIT); do
  sleep 1
  kill -0 $PID 2>/dev/null || break
done
kill $PID 2>/dev/null
# Import merges, so keys the run added would stay: clear the domain first.
defaults delete $DOMAIN 2>/dev/null
defaults import $DOMAIN "$SETTINGS"
rm -f "$SETTINGS"
cat /tmp/tape-selftest.log
# Remove packages the run created.
for p in $(comm -13 <(echo "$before") <(ls "$UNTITLED" 2>/dev/null) | tr '\n' '\0' | xargs -0 -I{} echo "{}" | sed 's/ /%20/g'); do
  rm -rf "$UNTITLED/${p//\%20/ }"
done
