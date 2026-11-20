# Tape M6: multitrack view for rough mix planning

Extends `docs/261105-tape-cursor-prompt-01.md`. All rules from that file apply: tests green, used by hand, report in `docs/report.md`, one commit `M6: multitrack`, then stop for Maik's OK. Read `docs/report.md` first so you know the current layout (`2f0d688`).

## 1. Intent

Tape stays a single-track editor by default. A button in the transport bar switches the timeline to a multitrack view so Maik can lay out a handful of recordings against each other and set a rough balance. This is planning, not mixing: gain, pan, mute, solo, master level. No automation, no inserts, no busses, no plugins per track.

The whole mix plays in both views. The view only changes what is shown.

## 2. Document

`project.json` version 2:

- `tracks: [Track]`, `Track {id, name, color, gainDB, pan (-1 to 1), mute, solo, regions: [Region]}`.
- A version 1 document loads as one track named "Track 1" holding all regions. Save writes version 2. A version 2 file with one track behaves exactly like today.
- Regions keep their fields. A region belongs to exactly one track; moving it between tracks changes `trackId`, nothing else.
- `master {gainDB}` on the document.
- Undo covers track add, remove, reorder, rename, gain, pan, mute, solo, region moves between tracks, each as one command.

Migration test: a saved version 1 file from M5 opens, plays sample identical to M5 (compare a manual render against a render stored in the test fixtures), and saves as version 2.

## 3. Engine

`EditListRenderer` renders per track, then sums with track gain and pan, then master gain. Pan law constant power, -3 dB at centre. Mute silences the track, solo silences every track that is not soloed. Mono regions are panned, stereo regions are balanced (attenuate one side). Same code path for playback and export, as before.

Meters: peak per track (post gain and pan) and master, delivered to the UI at display rate, 1.5 s peak hold, latched clip.

Record in multitrack goes to the **selected track**. If no track is selected, the first. Single-track view records as today.

## 4. UI

**Toggle** in the transport bar: a two-segment control "Single · Multi", key Shift Cmd M. State persists per document.

**Multitrack view**
- Track lanes stacked, each with a header column on the left of the timeline (180 pt): color swatch, name (double click to rename), M and S buttons, a horizontal gain slider with dB readout (-inf to +12, double click resets to 0), a pan knob or small slider with L/C/R readout, a thin peak meter along the header's right edge.
- Lane heights: a size control in the right tool strip (small 40 pt, medium 80 pt, large 160 pt). The selected track may be expanded to full waveform detail with a second toggle; the others stay at the chosen size. Vertical scroll when the lanes exceed the window.
- Master strip at the bottom of the header column: gain slider and stereo meter.
- Add track: a "+" at the bottom of the header column and Cmd T. Remove: select header, Delete, with confirmation if the track has regions. Reorder by dragging the header.
- Regions drag vertically between tracks, snapping to lanes. Trim, blade, fades, process and all M3 keys work on any track unchanged. Range selection spans all tracks; Cmd B blades every track at the playhead or range edges.
- Track colors tint the region fill. Default palette of eight, assigned in order.

**Single view**
- Shows the selected track full height, exactly as today. The header column is hidden. A small track popup in the transport bar (next to the toggle) picks which track is shown; it reads "Track 1" and is disabled while the document has one track.
- Switching views keeps the playhead, zoom and horizontal scroll.

**Inspector** gains a Track section when a track header is selected: name, color, gain, pan, mute, solo, region count.

## 5. Export

- Scope "Mix" (whole document through the master) replaces "Document".
- New scope "Stems": one file per track, post gain and pan, mute respected, solo ignored, named `{document}-{track}` by default with the same token system as region export. Hardware presets apply per stem.
- Each-region export works across tracks; the naming pattern gains a `{track}` token.

## 6. Tests (TapeCore)

- Pan law: a mono region at pan 0 renders both channels at -3 dB of the source; at -1 left is full, right is silent.
- Sum: two tracks with known signals render to their sum within 1e-6, then master gain applied.
- Mute and solo: solo on track B silences A; mute on B with solo on B is silent.
- Stems equal the per-track render used for the mix.
- Version 1 to 2 migration as in section 2.
- Region move between tracks preserves every region field except `trackId`.
- Meter: a -6 dBFS peak signal reports -6.0 ±0.1.

By hand (checklist in the report): toggle at 120 Hz on a 2 hour document with eight tracks, drag a region across lanes while playing without a dropout, record onto track 3 with pre-roll, stems export of four tracks opened in Logic line up to the sample.

## 7. Not in M6

Automation, per-track processing chains, busses, sends, track freeze, crossfade editing between tracks, MIDI. If any of these seem necessary to make something above work, stop and write it in the report.
