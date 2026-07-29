# Implementation status

Per-feature, honestly. "Implemented" means the code path exists end to end.
"Wired" means the dependency and engine work are done but no UI surface calls
it yet. "Architected" means the interface and integration point exist but an
external piece is required.

Verified state: `flutter analyze` clean, 119 tests passing, debug and release
APKs build.

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

**Note 1 — reverse.** FFmpeg's `reverse` buffers the whole segment, so it runs
as a pre-render pass rather than inline. Correctly handled in `split`: for a
reversed clip the source ranges of the two halves swap, which is covered by a
test.

**Note 2 — freeze frame.** Modelled as three clips (before / frozen / after)
rather than a special clip type, so every other operation keeps working on the
result.

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
| Voice recording | **Wired** | `record` configured; no UI surface yet |
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
| Auto caption | Architected | Needs `AiBackend` |
| Background removal | Architected | Needs `AiBackend` |
| Object tracking | Architected | Needs `AiBackend` |
| Face tracking | Architected | Needs `AiBackend` |

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
| Save to gallery (MediaStore) | Implemented — Kotlin bridge |
| Share sheet | Implemented |

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

## Known gaps

Worth stating plainly:

1. **Voice recording has no UI.** The engine and permission plumbing are done.
2. **Auto-caption needs a backend.** No model ships with the app.
3. **Background export does not survive process death.** The permission is
   declared; the foreground service is not written.
4. **Preview caps at 4 concurrent video layers.** Export is unaffected.
5. **Effect keyframes are not exported per-frame.** The compiler resolves
   effect parameters at `t=0`; animated *effect* parameters render as static on
   export. Transform and volume keyframes are unaffected. Fixing this needs
   `sendcmd`-driven filter parameters or segment splitting.
6. **`file_picker` needs an AGP 9 shim.** See `android/build.gradle.kts` — the
   plugin skips applying the Kotlin plugin on AGP 9. Removable once upstream
   ships a fix.
