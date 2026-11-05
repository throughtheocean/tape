# Tape report

## M1: Open, see, play

Date: 2026-11-05. Machine: MacBook Pro M3 Max, built-in XDR display (120 Hz) plus Studio Display (60 Hz). Xcode 26.4 beta, Swift 6.3 compiler in Swift 5 language mode with complete strict concurrency checking.

### What was built

TapeCore (Swift package, no AppKit, no SwiftUI):

- Document model: `Project`, `Region`, `SourceRef`, `Fade`, `ViewState`, stored as `project.json` with `"version": 1` inside a `.tape` package with `sources/` and `peaks/`. Newer versions are rejected with an error. Writes are atomic.
- Imports are referenced by bookmark plus path. Resolution tries the bookmark first, then the path.
- File IO: `FileSource` reads WAV, AIFF, CAF, FLAC and M4A through AVAudioFile, with a 32 MB block cache and prefetch of the next block.
- Session rate is the rate of the first imported source. Sources at other rates are converted once with AVAudioConverter (mastering quality) into `peaks/<id>-<rate>.caf`.
- Peak pyramid: levels 16, 256, 4096 and 65536 frames per block, Float16 min and max per channel, 256 byte header (magic, version, layout). It is built in parallel segments off the main thread with vDSP, and read back through mmap.
- Fade tables with 4096 points for linear, S curve, log and exp, with a blend between neighbouring shapes.
- `EditListRenderer`: one renderer for gain, fades and region summing. Playback uses it now; export will use the same one in M5.
- `PlaybackEngine`: AVAudioEngine with an AVAudioSourceNode.
  - A producer thread renders through `EditListRenderer` into a lock-free ring.
  - The render callback only copies from the ring.
  - Shuttle runs at 1, 2, 4 and 8x, forward and reverse.
  - Loop over the range.
  - Sample-accurate position from the render callback host time.

Tape.app (AppKit host, SwiftUI panels, Metal timeline):

- Window: transport and inspector in the upper third, timeline in the lower two thirds, split position persisted.
- Inspector is 280 px wide by default, resizable, toggled with Cmd Opt I. Width and visibility are kept in UserDefaults.
- Transport row: play, loop, timecode (display type and frame rate in its menu), session rate, zoom slider.
- Metal timeline:
  - One draw call per region for the waveform.
  - Pyramid columns per device pixel at coarse zoom, raw sample min and max between 1 and 16 frames per pixel, and sample lines with dots below 1 sample per pixel.
  - Ruler with timecode, milliseconds or samples. Below one millisecond per tick the ruler counts samples.
  - Minimap: drag to scroll, drag the window edges to zoom.
  - Range and loop overlays, playhead.
- Zoom: Cmd scroll, pinch, Cmd =, Cmd -, Shift Z (fit), slider. Option scroll for amplitude (1x to 32x). Plain scroll pans.
- Keys: Space play and pause, J K L shuttle, I and O range, Option X clear range, Cmd L loop, Home and End.
- Documents:
  - New starts an untitled package in `~/Library/Application Support/Tape/Untitled/`.
  - Open opens `.tape` packages or audio files.
  - Import Audio is Cmd I.
  - Save As moves the package.
  - Closing an untitled document asks Save, Cancel or Delete.
- Autosave is debounced at 500 ms and runs after every model change and view change.
- Undo is NSUndoManager with named commands on the document model. In M1 that is "Import Audio".
- Crash recovery: the list of open documents is kept in UserDefaults and reopened on launch.

### Measured numbers

Test file: 3 h stereo, 48 kHz, 24 bit WAV, 3.1 GB (`/tmp/tape-perf-3.0h.wav`).

| Measurement | Result | Target |
| --- | --- | --- |
| Peak pyramid build, 3 h stereo, warm file cache | 0.20 s (unit test), 0.22 to 0.72 s (in app) | under 6 s |
| Import to waveform on screen | 0.85 s | |
| Main thread work per frame (playhead, waveform, encode, ruler, labels) | p50 0.99 ms, p99 1.68 ms, max 2.14 ms | 8.33 ms at 120 Hz |
| GPU time per frame | p50 0.36 ms, p99 0.38 ms | |
| Presented frame rate, scripted 10 s zoom and pan | 60.0 fps, see open items | 120 fps |
| Play start, engine part (request to first frame at the output unit), n = 20 | min 1.0 ms, median 8.9 ms, max 10.9 ms | under 50 ms |
| Output device latency (AirPods Pro over Bluetooth) | 160 ms | |
| Dropouts in playback tests | 0 | |

The frame rate figure comes from a run where Tape was not the active app. macOS gives background apps display link callbacks at 60 per second even on a 120 Hz panel. A standalone test reproduced this: inactive, 60 ticks per second with a reported frame duration of 8.33 ms. Per-frame cost is under 2 ms at p99, so the 120 Hz budget has room to spare. The presented rate still has to be measured with the window active; see open items.

Play start: the engine part is well under 50 ms. With Bluetooth headphones the audible start adds the 160 ms device latency, which Tape cannot change. On the built-in speakers or a wired interface that latency is a few milliseconds.

### Tests

23 unit tests in TapeCore, all green. The 3 hour performance test is opt in (`TAPE_PERF=1`).

- Pyramid: known extremes reproduced at every level, from memory and from a file, including the write and mmap read round trip. Also column aggregation and corrupt file rejection.
- Fades and renderer: tables monotonic from exactly 0 to exactly 1, S curve symmetry, blend, overlapping regions with gain and fades against a hand computed buffer, fades longer than the region.
- Document: save and reopen keeps every region and the version, newer version rejected, missing peaks rebuilt, 22.05 kHz source resampled to the 48 kHz session, all five formats load, block reads across boundaries and past the end.
- Playback (manual rendering mode): forward, fades, reverse, 2x, loop wrap, end of document and pause. Each is compared sample by sample with the renderer (tolerance 1e-6). The suite passed 8 out of 8 repeated runs.

### Tested by hand

- Imported WAV (48 kHz, 24 bit, stereo), AIFF, FLAC, M4A and CAF (22.05 kHz mono, resampled) together in one document. Five regions appear back to back, stereo in two lanes and mono in one, with names.
- The 3 h file imports and draws its waveform in under 1 s.
- Opening several files at launch creates one document and one window.
- Crash recovery: killed Tape with `kill -9` and relaunched without arguments. The document reopened with all five regions, and the waveforms came from the peak cache without a rebuild.
- Sample level zoom (0.15 samples per point): dots joined by lines, range overlay, loop bar and playhead drawn correctly. The ruler now labels samples at this zoom; before the fix it showed no labels.
- The view state (zoom, scroll, amplitude, range, loop, playhead) is saved and restored on relaunch.
- Play start latency was measured 20 times with output muted (numbers above).

I have not tested keyboard and mouse input myself. Computer Use needs Screen Recording permission, which is not granted on this Mac. The saved view state shows that Maik used amplitude zoom, scrolling and the loop toggle during the session.

### Open

- 120 Hz presented frame rate: run `scripts/benchmark.sh` and click the Tape window once when it appears. The results are written to `/tmp/tape-benchmark.txt`.
- Peak build time from a cold disk cache was not measured. Purging the file cache needs sudo.
- The top row with record controls is part of M2. The left part of the upper third is empty until then.
- Hand check of all keys and gestures listed above, ideally with Screen Recording granted to Cursor so I can run it next time.

### Deviations from the spec, with reasons

1. Repo path is `~/xcode/Tape`, not `~/dev-app/tape`. The workspace opened in Cursor is `~/xcode/Tape` and `~/dev-app` does not exist. The folder can be moved without changes.
2. `Tape.xcodeproj` is generated by xcodegen from `project.yml`. xcodegen is a build tool, not a runtime dependency. The generated project is committed so Xcode opens it without xcodegen.
3. Swift 5.10 is not available in Xcode 26.4. The project uses the Swift 6.3 compiler in Swift 5 language mode with complete strict concurrency checking, which is the closest match.
4. App Sandbox is off. Bookmarks are created with security scope when the system allows it, otherwise a plain bookmark plus the path is stored. Turning on the sandbox later needs the security scope to be started around every source read.
5. Resampled sources are cached as a full float32 CAF in `peaks/` rather than resampled per block during playback. This keeps the real-time path free of converter state and makes seeking exact.
6. Playback runs on a producer thread that renders into a lock-free ring, which the AVAudioSourceNode callback reads. Running the edit list renderer inside the callback would read files on the audio thread.
7. Atomics come from a small C target (`TapeAtomics`) because the Swift Synchronization module requires macOS 15.
8. Layout: I read "transport row" and "inspector" as sharing the upper third, transport on the left and the inspector on the right, with the timeline full width below. If you want the inspector beside the timeline instead, that is a small change.
9. Docs naming: the spec asks for `YYMMDD-name-01` file names and also names `docs/report.md` and `docs/v2.md` explicitly. I used the explicit names. New docs files will follow `YYMMDD-name-01`.
10. PolyTracker has no separate presets package. In M5 the hardware presets will be taken from its `ExportPreset.swift` and `SampleProcessor` code.
11. A `-TapeBenchmark <file>` launch argument runs the scripted measurement. It is a test harness, not a user feature.
