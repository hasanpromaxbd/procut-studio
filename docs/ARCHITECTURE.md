# Architecture

## The dependency rule

```
┌──────────────────────────────────────────────────────────┐
│ presentation/   ConsumerWidgets, Notifiers, CustomPainters│
├──────────────────────────────────────────────────────────┤
│ engine/         FFmpeg · timeline maths · shaders · AI    │
├──────────────────────────────────────────────────────────┤
│ data/           Hive · migrations · repository impls      │
├──────────────────────────────────────────────────────────┤
│ domain/         entities · contracts · pure use cases     │
├──────────────────────────────────────────────────────────┤
│ core/           theme · errors · logging · DI · services  │
└──────────────────────────────────────────────────────────┘
        dependencies point downward, never upward
```

`domain/` imports only `package:flutter/foundation.dart` (for `@immutable` and
`listEquals`) and `core/`. It does not know Hive, FFmpeg or Riverpod exist.
That is what lets the entire editing model be tested in milliseconds.

---

## Decisions worth explaining

Anyone can read the code. These are the choices where the code alone does not
tell you *why*, including the trade-offs accepted.

### 1. Edits are pure functions, not methods on a mutable timeline

`TimelineOperations` is a set of static `Timeline → Result<Timeline>`
functions. Nothing mutates.

**Why.** Undo becomes trivial: push the old value, and because entities are
immutable the "copy" shares almost all of its structure — an undo entry costs a
handful of pointers, not a deep clone. Tests need no mocks, no widget tree, no
device. And an invalid edit is a returned `Err`, not an exception thrown
halfway through mutating state and leaving the timeline inconsistent.

**Cost.** Every edit allocates new track and clip lists. For a 500-clip project
that is a few hundred pointer copies per edit — measured at well under a frame,
and it only happens on user input, never in the render loop.

### 2. The playhead lives outside editor state

`PlayheadController` is a separate Riverpod notifier from `EditorController`.

**Why.** The playhead changes 60 times a second during playback. If it lived in
`EditorState`, every widget watching the editor — inspector, toolbar, track
headers, project title — would rebuild 60 times a second for a value none of
them use. Splitting it means playback repaints the ruler and the playhead line
and nothing else.

This is the single highest-impact structural decision for hitting 60fps, and it
is invisible from the widget code, which is why it is documented here.

### 3. The timeline is one `CustomPainter`, not a widget per clip

**Why.** A widget-per-clip tree builds N `RenderObject`s and walks all of them
on every layout pass. Cost scales with project size. One painter draws only the
clips that intersect the viewport, so cost scales with what is *visible* — a
500-clip project paints exactly as fast as a 10-clip one when both show twelve
clips on screen.

The painter is split in two: `TimelinePainter` (clips, thumbnails, waveforms)
and `PlayheadPainter` on a separate layer. Playback repaints only the second,
which is ~200 bytes of geometry rather than re-rasterising every thumbnail.

**Cost.** No free hit-testing — `TimelineViewState.hitTest` implements it.
That is ~60 lines, and it is unit-tested, which a widget tree's implicit
hit-testing would not be.

### 4. Projects are stored as JSON strings in Hive, not TypeAdapters

**Why.** A project is a deep, evolving graph: five clip kinds, animatable
properties, effects with open-ended parameter maps. Binary TypeAdapters bind
that shape into generated code and need a hand-written migration for every
field added — with a corrupted box as the failure mode when one is missed.

Storing canonical JSON keeps Hive doing what it is genuinely excellent at (a
fast, crash-safe key/value log) while schema evolution stays explicit,
readable and testable in `ProjectMigrations`.

**Cost.** A parse on load. For a 200 kB project that is under a millisecond,
and the home screen never pays it — `ProjectSummary.fromJson` walks only the
fields a card needs without materialising the timeline.

*Note:* the dependency is `hive_ce`, the maintained community fork. The
original `hive` package has been unmaintained since 2023.

### 5. Effects are defined once, consumed twice

Each entry in `EffectCatalog` carries UI metadata, an **FFmpeg filter emitter**,
and a **GPU shader binding**. Preview uses the shader; export uses the filter.

**Why.** When preview and export are defined in separate places they drift, and
the user discovers it only after waiting out a render. Keeping both in one
literal makes drift visible at the point of change.

**Cost.** The two paths cannot always match exactly. Motion blur is temporal in
FFmpeg (`tmix` averages real neighbouring frames) and spatial in the shader
(the preview only has one frame). Rather than hide that, the inspector labels
it. Honest beats invisible.

### 6. Text and stickers are rasterised by Flutter, not `drawtext`

The exporter runs `LayerPainter` — the *same* painter the preview uses — into a
`PictureRecorder`, writes PNGs, and overlays them in FFmpeg.

**Why.** `drawtext` cannot do gradient fills, per-glyph animation or Google
Fonts, and would give a different result from the preview. Sharing the painter
makes "what you see is what you get" a property of the architecture rather than
a thing to keep chasing.

**Cost.** One PNG per frame for animated titles. A 3-second animated title at
30fps is 90 PNGs — a few hundred milliseconds of work next to an encode
measured in tens of seconds.

### 7. A transition is a real overlap in the model

Adding a transition ripples the following clips *earlier* by its duration, so
the two clips genuinely overlap. `Track.hasCollision` permits exactly this one
overlap and no other.

**Why.** A cross-dissolve has to consume material from both sides. The
alternatives are worse: pretending clips stay adjacent makes the rendered
output shorter than the timeline says (preview and export disagree), and
extending both clips requires handles that a phone-shot clip may not have.
Modelling the overlap keeps `timeline.duration` equal to what the exporter
produces.

**Cost.** One sanctioned exception to the no-overlap invariant, isolated to a
single well-commented method and covered by tests.

### 8. Non-native transitions ship two implementations

FFmpeg's `xfade` has no spin, warp, ripple or glitch. Each gets an exact
`transition=custom` per-pixel expression *and* a fast native approximation.

**Why.** The exact version evaluates an expression per pixel per plane per
frame — roughly 10–30× slower. Getting a plausible result in 40 seconds is
usually worth more than a perfect one in 6 minutes, but that is the user's call
to make, not a default to bury. The export screen exposes the choice and the
transition picker marks the expensive ones.

### 9. Hardware encoding is preferred, with an automatic software retry

**Why.** MediaCodec is 5–20× faster than libx264 on a phone — the difference
between a 40-second export and a 10-minute one. It is also the least reliable
part of the Android media stack: encoders advertise support they do not have
and fail differently per vendor.

So: probe once, prefer hardware, and on a `MediaProcessingFailure` recompile
the plan for software and retry once. The user gets their file instead of a
vendor error string.

---

## Data flow: one edit

```
tap "Split"
  → EditorController.splitAtPlayhead()
      reads PlayheadController for the position
  → TimelineOperations.split(timeline, clipId, at)      ← pure
      returns Ok(newTimeline) or Err(InvalidEditFailure)
  → EditorState.withEdit(next, 'split')
      pushes the old timeline onto the undo stack
  → state = …   (Riverpod notifies)
  → TimelinePainter.shouldRepaint sees a new Timeline identity → repaints
  → Debouncer schedules a save 900 ms later
  → ProjectRepository.save() rotates a backup, writes JSON to Hive
```

An `Err` becomes a quiet banner. Dragging a clip onto another is normal user
behaviour, not an error worth a dialog.

## Data flow: one export

```
ExportController.start(project, settings)
  → ExportEngine.export()  (a Stream<ExportProgress>)
      ├ validate settings, check free space          ← fail before waiting
      ├ HardwareEncoderProbe.choose()
      ├ TimelineCompiler.compile()  → RenderPlan     ← pure, unit-tested
      ├ phase 1  rasterise text/sticker layers        0 →  10%
      ├ phase 2  pre-render reversed clips           10 →  ~45%
      ├ phase 3  main FFmpeg pass                       →  99%
      │            └ on hardware failure: recompile for software, retry once
      └ finalise, verify non-empty, emit completed         100%
```

`RenderPlan` is data, so `timeline_compiler_test.dart` asserts on the generated
filter graph directly — no device, no encoder, no media files.

## Error handling

`Result<T>` with a sealed `Failure` taxonomy. Nothing throws across a layer
boundary. `FFmpegService` keeps a bounded 40-line log tail and maps the failures
that actually happen in the field to sentences a user can act on:

| FFmpeg log contains | User sees |
|---|---|
| `no space left` | "The device ran out of storage during the render." |
| `no such file or directory` | "A media file used by this project is missing. Relink it and try again." |
| `moov atom not found` | "One of the media files is damaged or incomplete." |
| `cannot open encoder` | "The hardware encoder refused this format. Turn off hardware encoding and retry." |

## Testing strategy

| Layer | How it is tested | Why it works |
|---|---|---|
| `domain/usecases` | Direct unit tests | Pure functions |
| `data/migrations` | Fixtures from each old schema | Pure `Map → Map` |
| `engine/export` | Assertions on the generated graph | Compiler is pure |
| `engine/timeline` | Direct unit tests | View maths is pure |
| `presentation/widgets` | Widget tests | No I/O in leaf widgets |

The parts that genuinely need a device — FFmpeg execution, MediaStore, decoders
— sit behind interfaces (`ExportRepository`, `MediaRepository`, `AiBackend`) so
everything above them is testable without one.
