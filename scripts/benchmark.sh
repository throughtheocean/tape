#!/bin/zsh
# M1 acceptance numbers: pyramid build, scroll and zoom frame pacing, play start latency.
# Usage: scripts/benchmark.sh [audio file]   (default: generated 3 hour stereo 48 kHz 24 bit WAV)
# When the Tape window appears, click it once: macOS holds display links of background apps at 60 Hz.
set -e
cd "$(dirname "$0")/.."
FILE="${1:-/tmp/tape-perf-3.0h.wav}"
if [[ ! -f "$FILE" ]]; then
  echo "Generating $FILE"
  (cd TapeCore && TAPE_PERF=1 TAPE_PERF_HOURS=3 swift test -c release --filter PerformanceTests >/dev/null)
fi
xcodebuild -project Tape.xcodeproj -scheme Tape -configuration Release -derivedDataPath build/dd build -quiet
rm -f /tmp/tape-benchmark.txt
echo "Click the Tape window when it appears (waits up to 30 s)."
open -W -a "$PWD/build/dd/Build/Products/Release/Tape.app" --args -TapeBenchmark "$FILE"
cat /tmp/tape-benchmark.txt
