# Tape data model and renderer

## Package

A `.tape` package holds `project.json` (version 2) and an `Audio` folder with the recorded and rendered files. Imported files stay where they are (external sources) until Consolidate copies them in.

`project.json` has two parts: `document` (what is saved and undone) and `view` (where the window was, not undone).

## Document

- `sessionRate`, `channelCount`: set by the first audio that enters an empty document (import, drop or recording).
- `sources`: one `SourceRef` per file: id, name, location (inside the package or external with a bookmark), sample rate, channel count, frame count, pre-roll frames for recordings.
- `tracks`: ordered top to bottom. Each has id, name, color, `gainDB`, `pan` (-1 to 1), `mute`, `solo`.
- `regions`: id, name, `trackId`, `sourceId`, `sourceIn`/`sourceOut` (frames in the source), `position` (frame on the timeline), `gainDB`, `fadeIn`/`fadeOut` (length, shape, blend).
- `master`: `gainDB`.

All positions and lengths are frames at the session rate.

## Renderer

`EditListRenderer` renders playback and export through the same code. Per output frame:

1. Every region on a track is read from its source, scaled by its gain and fades, and added into that track's buffer. Regions that overlap on one track sum (an Option drag or Option drop keeps both; a plain drag or drop trims what lies under it first, so they only sum when asked to). Regions on different tracks always sum.
2. The track buffer is scaled by the track gain and panned (see below), then added to the mix.
3. Mute silences a track. When any track is soloed, every track that is not soloed is silent.
4. The mix is scaled by the master gain.

"Only" (single view, Option S) is playback state on the window, not part of the document: the shown track plays alone with its gain and pan, whatever mute and solo say, and the master applies. Export and stems ignore it.

Stems render one track alone with its gain and pan, without the master gain, solo ignored.

## Pan law and track output

Every session plays and renders in stereo, whatever the first source had (`Project.mixChannelCount`). `channelCount` keeps the first source's count; a session recorded with more than two channels keeps them, and pan applies only to two output channels. Mono files are a choice in the export format ("Mono" averages the two channels), not a property of the session.

Every track mixes to stereo.

- Mono regions go through pan with a constant power law, scaled to unity at centre: left gain √2 · cos(θ), right gain √2 · sin(θ), θ = (pan + 1) · π/4. At pan 0 both sides are exactly the source level, so a centred mono file sounds as loud as it did before tracks and stereo sessions existed. At -1 left is +3.01 dB and right is silent. Left² + right² stays 2 at every pan position.
- Stereo regions go through balance: the side away from the pan is attenuated along a quarter cosine, cos(|pan| · π/2); the near side stays at unity. At pan 0 both sides are unity.

The pan law is fixed. It is not a setting, per document or otherwise.

## Process previews

Previews play the document's mix with the target regions swapped for processed copies, so region gain and fades, the track's gain and pan, mute, solo and the master all apply after the process, as after Apply. Processes rendered in Tape (Normalize, Gain and the others) render the copies into memory. The Compressor and Limiter run live: each target region plays through its own Audio Unit as it is read (`LiveAUSource`), in the same 4096 frame slices, with the same latency compensation and the same 2 ms edge crossfade for a partial range as Apply. There is no insert on the master.

## Overdub placement

An overdub is a recording made while playback runs. Its region starts at the timeline frame the player heard when the first live input frame reached the input. The input frames before it (pre-roll) are in the file, hidden before the region start.

```
position = renderFrame(at: captured - inputLatency - outputLatency)

inputLatency  = kAudioDevicePropertyLatency + kAudioDevicePropertySafetyOffset + kAudioStreamPropertyLatency  (input device)
outputLatency = the same three properties                                                                   (default output device)
```

- `captured` is the host time stamp the input tap gives the buffer holding the first live frame, plus that frame's offset in the buffer at the input rate.
- `renderFrame(at:)` maps a host time to a timeline frame through the last buffer playback handed to the output: its first frame and host time (`PlaybackEngine.renderAnchor`), at 1x, in session frames.
- The code is `Overdub.position` in TapeCore, tested in `OverdubTests`.

Why it is exactly this, so that nobody "fixes" it:

1. **The IO buffer size is not added.** The input stamp is the host time at which the buffer's first frame was at the device's IO cycle. Waiting for the buffer to fill is already behind that stamp. Adding the buffer (10.7 ms at 512 frames) puts every take one buffer early. The device's own latency, safety offset and stream latency are not in the stamp, so they are subtracted.
2. **The output latency is subtracted.** The render anchor is the frame handed to the output unit, not the frame coming out of the speaker. The player hears it one output latency later. While singing at host time t, the player hears the frame rendered at t - outputLatency. Leaving it out places every take late by the output latency.
3. **Playback's ring buffer ahead of the output does not matter.** The anchor is taken at the output callback, not at the producer that renders ahead.
4. **Placement waits for a buffer at 1x.** Right after play starts, or after R snaps a shuttle back to 1x, there is no anchor yet; the placement is taken from the first buffer at 1x, a few ms later. Input frames from before that buffer land just before the point where 1x playback resumed.

The check is the loopback test (`scripts/selftest/m10b-loopback.txt`): output fed back into the input, a click recorded against a played click lands within 1 ms. If a change to this formula makes that test worse, the change is wrong.
