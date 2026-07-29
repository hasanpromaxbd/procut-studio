# ProCut Studio

A multi-track video editor for Android, built with Flutter.

Original design, architecture and implementation. No code, assets or branding
from any existing editor.

---

## What this is

A production-shaped codebase for a professional mobile NLE: multi-track
timeline, keyframe animation, GPU-accelerated preview, and an FFmpeg export
pipeline. Every layer analyzes clean under a strict lint set and is covered by
tests that run without a device.

```
flutter analyze              →  No issues found
flutter test                 →  199 tests, all passing
flutter build apk --debug    →  built (174 MB, 3 ABIs)
flutter build apk --release  →  built (110 MB, R8 + shrinker)
```

Verified against Flutter 3.44.6 / Dart 3.12.2 / AGP 9.0.1 / Gradle 9.1.

## Feature status

The table is deliberately honest about what is implemented end-to-end versus
what is architected with a working seam but needs an external piece. See
[docs/STATUS.md](docs/STATUS.md) for the detail behind every row.

| Area | Status |
|---|---|
| Multi-track timeline, unlimited tracks | Implemented |
| Split / trim / move / duplicate / delete / ripple | Implemented + tested |
| Speed 0.1×–10×, reverse, freeze frame | Implemented + tested |
| Crop / rotate / flip / opacity / blend modes | Implemented |
| Keyframe animation with easing curves | Implemented + tested — animates on export via `sendcmd` |
| Speed ramping, shape masks, adjustment layers | Implemented + tested |
| Multi-select, copy/paste, markers, templates | Implemented + tested |
| Motion tracking → keyframes, chroma-key eyedropper | Implemented + tested |
| Stabilisation (two-pass `vidstab`), auto-reframe | Implemented + tested |
| Platform export presets (Reels/Shorts/TikTok/YouTube) | Implemented + tested |
| 14 effects (blur, glow, VHS, RGB split, grain, LUT, …) | Implemented — GPU shader + FFmpeg filter |
| 10 transitions | Implemented — 6 native `xfade`, 4 via custom per-pixel expressions |
| Text layers, 1500+ fonts, gradient/stroke/glow/shadow, 11 animations | Implemented |
| Sticker and emoji layers | Implemented |
| Audio: volume automation, fades, EQ, pitch, speed, mixing | Implemented |
| Beat detection, waveforms | Implemented (local DSP) |
| Voice recording | Implemented — level meter, pause/resume, clipping warning |
| Export 480p–4K, H.264/HEVC, MP4/MOV, CRF or CBR, hardware encoding | Implemented + tested |
| Background export with progress notification | Implemented — foreground service |
| Auto-save, backups, project bundles (import/export) | Implemented |
| AI: scene detect, colour enhance, upscale, voice isolation | Implemented — local FFmpeg DSP |
| AI: captions, background removal, object/face tracking | Implemented — needs a self-hosted endpoint, see below |

### About the AI features

They split into two groups, and the app says which is which rather than
blurring them:

- **Local** — scene detection, colour enhancement, upscaling and voice
  isolation are FFmpeg filter chains that ship inside the app. They work
  offline and are deterministic. They are signal processing, not learned
  models, and the code names them accordingly.
- **Model-backed** — captions, background removal and object/face tracking need
  neural weights. **This app bundles none**, and cannot: they are hundreds of
  megabytes and licence-encumbered. `HttpAiBackend` speaks the
  OpenAI-compatible API, so pointing Settings → AI server at a self-hosted
  faster-whisper / speaches / whisper.cpp instance (`http://host:port/v1`)
  makes captions work for real. With nothing configured they are shown disabled
  with a route to set one up, rather than hanging on a spinner.

All seven tools are reachable from **AI** in the editor tool rail.

## Architecture

Clean Architecture with a strict dependency rule — every arrow points inward,
and `domain` imports nothing but Flutter's foundation.

```
presentation/   Riverpod notifiers, screens, painters
     │
engine/         FFmpeg, timeline maths, compositing, shaders, AI
     │
data/           Hive persistence, repository implementations
     │
domain/         Entities, repository contracts, pure edit operations
     │
core/           Theme, errors, logging, DI, platform services
```

The load-bearing decision: **every timeline edit is a pure function**
(`Timeline → Result<Timeline>`) in `domain/usecases/timeline_operations.dart`.
Undo is "keep the previous value". Tests need no mocks. The controller layer
only orchestrates history and persistence.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the reasoning, including
the parts that are counter-intuitive: why the playhead is not in editor state,
why projects are JSON rather than Hive TypeAdapters, and why the timeline is a
single `CustomPainter`.

## Getting started

```bash
flutter pub get
flutter run
```

Full setup, signing and release instructions: [docs/BUILD.md](docs/BUILD.md).

## Documentation

| Document | Contents |
|---|---|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Layer boundaries, data flow, design decisions and their trade-offs |
| [BUILD.md](docs/BUILD.md) | Toolchain, signing, release builds, troubleshooting |
| [OPTIMIZATION.md](docs/OPTIMIZATION.md) | How 60fps is achieved and kept; profiling recipes |
| [SCALABILITY.md](docs/SCALABILITY.md) | Extension points, iOS port, roadmap |
| [STATUS.md](docs/STATUS.md) | Honest per-feature implementation status |

## Project layout

```
lib/
├── core/           constants, DI, errors, logging, theme, services, utils
├── domain/         entities, repository contracts, use cases
├── data/           Hive datasources, migrations, repository implementations
├── engine/
│   ├── ffmpeg/     service, filter-graph builder, ffprobe, encoder selection
│   ├── timeline/   view geometry, snapping, hit-testing, playback clock
│   ├── render/     layer painter, rasteriser, thumbnail cache, shader library
│   ├── export/     timeline compiler, render plan, export engine
│   ├── effects/    effect catalogue (shader + FFmpeg definitions)
│   ├── transitions/transition catalogue
│   ├── audio/      waveform extraction, beat detection
│   └── ai/         AI service and backend contract
├── presentation/   viewmodels, screens, widgets
shaders/            15 GLSL fragment shaders
tool/               reproducible shader + sendcmd verification scripts
assets/luts/        4 original .cube colour LUTs
test/               unit + widget tests
```

## Licence and originality

All source, shaders, LUT transfer functions and design assets here are original
work. The bundled LUTs are generated from transfer functions defined in this
project, not derived from any third-party pack.

Third-party dependencies keep their own licences — note that FFmpegKit is
LGPL. See [docs/BUILD.md](docs/BUILD.md#licensing) before shipping commercially.
