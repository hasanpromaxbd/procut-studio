# Implementation status

Per-feature, honestly. "Implemented" means the code path exists end to end.
"Wired" means the dependency and engine work are done but no UI surface calls
it yet. "Architected" means the interface and integration point exist but an
external piece is required.

Verified state: `flutter analyze` clean, 273 tests passing, debug and release
APKs build. `tool/verify_shaders.sh`, `tool/verify_sendcmd.sh` and
`tool/verify_ducking.sh` all pass against real impellerc/ffmpeg binaries.

---

## Video editing

| Feature | Status | Where |
|---|---|---|
| Multi-layer timeline | Implemented | `domain/entities/timeline.dart` |
| Unlimited video tracks | Implemented | `TrackType.video` / `.overlay` |
| Unlimited audio tracks | Implemented | `TrackType.audio` |
| Image overlays | Implemented | `ImageClip` |
| Text layers | Implemented | `TextClip` + `LayerPainter` |
| Sticker layers | Implemented | `StickerClip` (emoji + image) |
| Speed 0.1×–10× | Implemented + tested | `TimelineOperations.setSpeed` |
| Reverse | Implemented + tested | Pre-render pass; see note 1 |
| Split | Implemented + tested | `TimelineOperations.split` |
| Trim | Implemented + tested | `trimStart` / `trimEnd` |
| Crop | Implemented | Normalised insets, `CropRect` |
| Rotate | Implemented | 90° steps use `transpose`; free angle uses `rotate` |
| Flip | Implemented | `hflip` / `vflip` |
| Duplicate | Implemented + tested | `TimelineOperations.duplicate` |
| Delete (+ ripple) | Implemented + tested | `TimelineOperations.delete` |
| Freeze frame | Implemented + tested | Split + still segment, see note 2 |
| Keyframe animation | Implemented + tested | `AnimatableDouble`, 7 easing curves |
| Speed ramping (curve speed) | Implemented + tested | See note 7 |
| Shape masks (rect/ellipse/linear) | Implemented + tested | Animatable; shader + `geq` |
| Multi-select and copy/paste | Implemented + tested | Long-press extends the selection |
| Markers and chapters | Implemented + tested | Snap targets; beat markers from detection |
| Adjustment layers | Implemented + tested | `TrackType.adjustment`, gated by `enable` |
| Stabilisation | Implemented + tested | Two-pass `vidstab`, see note 8 |
| Auto-reframe | Implemented | Recentres on aspect change; follows tracking when supplied |
| Project templates | Implemented + tested | Slot-based, browse/save UI, preserves the edit's rhythm |
| Motion tracking → keyframes | Implemented + tested | Region or face; drives a sticker or title |
| Chroma-key eyedropper | Implemented + tested | Samples the composited preview, see note 9 |
| Platform export presets | Implemented + tested | Reels/Shorts/TikTok/YouTube/master |

**Note 1 — reverse.** FFmpeg's `reverse` buffers the whole segment, so it runs
as a pre-render pass rather than inline. Correctly handled in `split`: for a
reversed clip the source ranges of the two halves swap, which is covered by a
test.

**Note 2 — freeze frame.** Modelled as three clips (before / frozen / after)
rather than a special clip type, so every other operation keeps working on the
result.

**Note 7 — speed ramping.** `MediaClip.speedCurve` is an optional animatable
rate. Source consumption is the *integral* of the rate, computed on a midpoint
grid because an eased curve has no closed form — and the clip's timeline length
is solved by bisection so it consumes exactly its source window. FFmpeg's
`setpts` cannot express that integral either, so the export approximates the
ramp with constant-rate segments and warns that a very long ramp may step.

**Note 8 — stabilisation.** Modelled as an effect the compiler intercepts, not
a field on the clip: `vidstabdetect` writes a motion file that
`vidstabtransform` then consumes, so it needs two passes. It reuses the
`PreRenderStep` machinery originally built for reversed clips.

## Effects

All 14 have both a GPU shader (preview) and an FFmpeg filter (export).

| Effect | Shader | FFmpeg |
|---|---|---|
| Blur | `gaussian_blur.frag` | `gblur` |
| Motion blur | `motion_blur.frag` | `tmix` — see note 3 |
| Glow | `glow.frag` | `gblur` + `eq` |
| Flash | `glow.frag` | `eq` |
| VHS | `vhs.frag` | `chromashift` + `noise` + `eq` |
| RGB split | `rgb_split.frag` | `rgbashift` |
| Vintage | `vintage.frag` | `curves` + `eq` |
| Film grain | `film_grain.frag` | `noise` (temporal) |
| Vignette | `vintage.frag` | `vignette` |
| Sharpen | `sharpen.frag` | `unsharp` |
| Noise reduction | `gaussian_blur.frag` | `hqdn3d` |
| Cinematic LUT | `lut3d.frag` | `lut3d` |
| Colour adjust | `ColorFilter.matrix` | `eq` + `colorbalance` |
| Chroma key | — | `chromakey` |

**Note 3 — motion blur.** Temporal in export (`tmix` averages real neighbouring
frames), spatial in preview (only one frame is available). The inspector says
so rather than letting the user find out at render time.

**Keyframed effects on export.** Animated effect parameters are driven by an
FFmpeg `sendcmd` script generated per clip and sampled at 10 Hz, so a blur that
ramps over two seconds ramps in the render too. This works for every effect
whose filter advertises command support. Three do not — **Sharpen**
(`unsharp`), **Film grain** (`noise`) and **Vignette** — and those export at
their first-frame value, with an export warning saying so. Verified against a
real ffmpeg binary by `tool/verify_sendcmd.sh`.

**Note 9 — the eyedropper.** The preview is a stack of platform video
textures, so there is no pixel buffer to read. The colour is obtained by
rasterising the preview's `RepaintBoundary` and reading one pixel out of it.
That means the sample is what the preview *shows*, including effects already
applied — which is normally what you want, since you are keying the graded
picture rather than the raw source.

## Transitions

| Transition | Export | Preview |
|---|---|---|
| Fade | `xfade=fade` | `transition_fade.frag` |
| Zoom | `xfade=zoomin` | `transition_warp.frag` |
| Slide | `xfade=slide{left,right,up,down}` | `transition_fade.frag` |
| Push | `xfade=wipe{left,right,up,down}` | `transition_fade.frag` |
| Flash | `xfade=fadewhite` | `transition_fade.frag` |
| Blur | `xfade=hblur` | `transition_fade.frag` |
| Spin | custom expression (fast: `circleopen`) | `transition_warp.frag` |
| Warp | custom expression (fast: `squeezeh`) | `transition_warp.frag` |
| Ripple | custom expression (fast: `radial`) | `transition_ripple.frag` |
| Glitch | custom expression (fast: `pixelize`) | `transition_glitch.frag` |

The four custom-expression transitions evaluate per pixel per plane per frame —
roughly 10–30× slower than a native one. Both implementations ship and the UI
marks the expensive ones.

## Audio

| Feature | Status | Notes |
|---|---|---|
| Volume automation | Implemented | Keyframed `AnimatableDouble` |
| Fade in / out | Implemented | `afade` |
| 5-band EQ | Implemented | Fixed bands, `equalizer` filter |
| Pitch shift | Implemented | `asetrate` + `atempo` + `aresample` |
| Speed (pitch-preserving) | Implemented | `atempo` cascade — see note 4 |
| Mixing | Implemented | `amix` with `normalize=0` |
| Beat detection | Implemented | Local DSP, `WaveformService.detectBeats` |
| Waveforms | Implemented | 8 kHz PCM, cached |
| Noise reduction / voice isolation | Implemented | `afftdn` + speech-band chain |
| Voice recording | Implemented | Level meter, pause/resume, clipping warning, inserts at playhead |
| Background music library | Implemented | Bundled manifest + optional remote |

**Note 4 — atempo.** Only accepts 0.5–2.0 per instance, so larger changes are
decomposed into a cascade. Ignoring this silently produces broken audio; a test
covers it.

## Text

| Feature | Status |
|---|---|
| Animated titles (11 animations) | Implemented |
| 300+ fonts | Implemented — Google Fonts, ~1500 families |
| Shadow / gradient / outline / stroke / glow | Implemented |
| Auto subtitle | Architected — needs a caption backend |

Text is rasterised by the same painter the preview uses, so export matches
what was composed.

## AI

| Feature | Status | How |
|---|---|---|
| Scene detection | Implemented | `scdet`, log-parsed |
| Colour enhancement | Implemented | `signalstats` → derived correction |
| Upscaling | Implemented | Lanczos + unsharp — see note 5 |
| Voice isolation | Implemented | Speech-band chain — see note 5 |
| Auto caption | Implemented | Needs a configured server; result becomes real caption clips |
| Background removal | Implemented | Needs a server implementing `POST /matte` |
| Object tracking | Implemented | Needs a server implementing `POST /track` |
| Face tracking | Implemented | Needs a server implementing `POST /track/faces` |

All seven are reachable from **AI** in the editor tool rail. The four local
tools work with no setup. The model-backed ones need an endpoint configured in
Settings → AI server; until then they are shown disabled with a route to set
one up, rather than hidden or failing on tap.

`HttpAiBackend` speaks the **OpenAI-compatible** API, so any of
faster-whisper-server, speaches or whisper.cpp's server works by pointing
Settings at `http://host:port/v1`. Captions come back as timed cues and are
converted into real `TextClip`s on their own caption track, wrapped to a
readable line length, with low-confidence cues flagged for review.

**Note 5 — naming.** Upscaling is classical resampling: it does not invent
detail, because nothing running locally without a model can. Voice isolation
cleans a voice note substantially but will not lift a vocal out of a music mix.
The UI copy says both things rather than implying otherwise.

## Export

| Feature | Status |
|---|---|
| 480p / 720p / 1080p / 2K / 4K / source | Implemented + tested |
| H.264 and HEVC | Implemented + tested (HEVC tagged `hvc1`) |
| MP4 and MOV | Implemented |
| Custom bitrate or CRF quality | Implemented + tested |
| Hardware encoding + software fallback | Implemented |
| Progress, speed, ETA, cancel | Implemented |
| Background export (foreground service) | Implemented — see note 6 |
| Save to gallery (MediaStore) | Implemented — Kotlin bridge |
| Share sheet | Implemented |

**Note 6 — background export.** A foreground service promotes the process to
foreground importance for the duration of a render, with a progress
notification and a Cancel action. FFmpeg still runs inside the Flutter process;
the service does not relocate it. What it buys is that the export survives the
user leaving the app, the screen turning off, and memory pressure from other
apps — the things that actually kill long renders. It does **not** survive a
force-stop or a reboot, and it is not a headless service: it keeps the existing
process alive rather than running without one.

`mediaProcessing` is API 34+, so the manifest declares
`mediaProcessing|dataSync` and the service picks the right one at runtime —
declaring the wrong type on Android 14 is a hard crash, not a warning.

## Project management

| Feature | Status |
|---|---|
| Auto-save (debounced + periodic + lifecycle flush) | Implemented |
| Rolling backups (5 per project) | Implemented |
| Import / export `.pcstudio` bundles | Implemented |
| Recent projects | Implemented |
| Schema migration | Implemented + tested (v1→v2→v3) |

## Performance

| Feature | Status |
|---|---|
| Smooth scrolling timeline | Implemented — viewport-bounded painter |
| Thumbnail caching | Implemented — two-tier, quantised keys |
| Lazy loading | Implemented — `ProjectSummary` skips the timeline |
| GPU rendering | Implemented — `ui.ImageFilter.shader` |
| Memory optimization | Implemented — bounded caches, decoder pool |
| Background rendering | Partial — survives navigation, not process death |

## UI

| Feature | Status |
|---|---|
| Material 3, dark + light | Implemented — hand-built schemes |
| Glassmorphism | Implemented — transport bar and sheets only |
| Rounded components, smooth animations | Implemented |
| Gesture support | Implemented — tap, drag, pinch-zoom, long-press |
| Tablet support | Implemented — breakpoint layout, side tool rail |
| Bottom navigation | Not implemented — the editor uses a tool rail, which
suits an editor better than tabs |

---

## Second wave (July 2026)

| Feature | Status |
|---|---|
| Selection-aware commands — every edit acts on the whole multi-selection | Implemented + tested |
| Slip / slide / roll three-point trims | Implemented + tested — compound edits refuse rather than clamp |
| Beat-synced auto-cut (razor across beat markers, every-nth control) | Implemented + tested — cuts applied latest-first |
| Ken Burns camera moves on stills | Implemented + tested — preview via keyframes, export via `zoompan` (verified against real ffmpeg) |
| Audio ducking (per-track side-chain, strength/sensitivity/release) | Implemented + tested — `tool/verify_ducking.sh` measures a real 6 dB duck |
| Colour scopes: histogram, waveform, RGB parade, vectorscope | Implemented — measures the preview raster, and says so |
| Composition guides: safe zones, thirds, golden ratio, centre, social-UI shade | Implemented — drawn outside the sampled boundary so scopes stay honest |
| Waveforms on video clips (embedded audio strip) | Implemented |
| Keyboard shortcuts + generated cheat sheet (Shift+?) | Implemented — one table drives both bindings and help |
| Undo history scrubber (jump anywhere in the stack) | Implemented |
| Export queue (snapshot at enqueue, strictly serial) | Implemented |
| Bengali localisation (hand-written, compiler-enforced parity) | Implemented + tested — Devanagari-leak test, danda-aware |
| Crash reporting (local-only, breadcrumbed, shareable diagnostics) | Implemented — nothing leaves the device unless the user shares it |
| End-to-end integration test (edit → persist → compile) | Implemented — caught the Ken Burns export gap on its first run |

The camera-move export renders endpoints with a smoothstep ease. A
hand-built move with more than two keyframes per channel is approximated by
its endpoints, and the export plan warns when that happens.

Localisation covers the main surfaces (home, tool rail, editor chrome,
export, settings). Sheet-internal prose is still English; the string table
in `lib/core/l10n/app_strings.dart` is the single place to extend.

## Third wave (July 2026)

| Feature | Status |
|---|---|
| Proxy editing (auto-build on import, preview-quality setting, originals at export) | Implemented |
| Jump-cut assistant (relative-threshold silence detection, preview chips, one-step apply) | Implemented + tested |
| Compound clips (single-track v1: group/ungroup, lossless, export flattens through real track machinery) | Implemented + tested |
| Saved versions in the history sheet (auto-backup rotation, two-way restore) | Implemented |
| −14 LUFS loudness normalisation (single-pass `loudnorm`, said plainly) | Implemented — verified against real ffmpeg |
| Voice presets: deep/helium/robot/telephone/echo/cave | Implemented — all chains verified against real ffmpeg |
| Audio crossfade (equal-power `qsin` fades at the joint) | Implemented |
| LUT import (`.cube` validation, bundled LUTs extracted to disk, picker in Effects) | Implemented |
| Karaoke captions (word timestamps requested; per-word highlight; per-frame raster on export) | Implemented — needs a server that returns word timings |
| Frame snapshot (preview raster → PNG → share) | Implemented |
| GIF export (in-graph palettegen/paletteuse, no-audio, size guardrails) | Implemented — verified against real ffmpeg |
| TTS voiceover (`/audio/speech`, lands at the playhead) | Implemented + tested against a mock server |
| Bdrive backup (real NimbusDrive protocol: login/folders/resumable chunked upload) | Implemented + tested, including the resume path |

Compound-clip limits, stated plainly: single-track membership, no nesting,
splitting requires ungrouping first, and a compound's animated transform is
preview-only (static scale/flips do export). The jump-cut assistant requires
un-reversed, un-ramped clips and says so.

## Known gaps

Worth stating plainly:

1. **The model-backed AI features need a server.** No model weights ship with
   the app, and none can — they are hundreds of megabytes and licence-encumbered.
   `HttpAiBackend` makes them work against a self-hosted endpoint; the app
   states this plainly rather than implying on-device inference.
2. **Background export does not survive a force-stop or reboot.** The
   foreground service covers backgrounding, screen-off and memory pressure;
   nothing short of a second process would cover the rest, and that would mean
   shipping FFmpeg twice.
3. **Preview caps at 4 concurrent video layers.** Android's decoder pool is
   small and device-dependent. Export is unaffected.
4. **Three effects cannot animate on export.** Sharpen, Film grain and Vignette
   use FFmpeg filters with no runtime-command support, so a keyframed one
   renders at its first-frame value. The export warns rather than silently
   flattening it.
5. **`file_picker` needs an AGP 9 shim.** See `android/build.gradle.kts` — the
   plugin skips applying the Kotlin plugin on AGP 9. Removable once upstream
   ships a fix.
