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

Every track mixes to stereo.

- Mono regions go through pan with a constant power law, -3 dB at centre: left gain cos(θ), right gain sin(θ), θ = (pan + 1) · π/4. At pan 0 both sides are 0.7071 (-3.01 dB); at -1 left is unity and right is silent.
- Stereo regions go through balance: the side away from the pan is attenuated along a quarter cosine, cos(|pan| · π/2); the near side stays at unity. At pan 0 both sides are unity.

The pan law is fixed. It is not a setting, per document or otherwise.

Exception today: a session whose first audio was mono has `channelCount` 1 and renders mono. Pan does not apply there, and a stereo region in such a session plays its left channel only. See the M10a report for the proposal.
