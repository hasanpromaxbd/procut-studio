# Scalability and extension

Where the seams are, what they cost to use, and what has to change for the
larger moves.

---

## Adding a new effect

One literal in `EffectCatalog.all`, plus one `.frag` file:

```dart
EffectSpec(
  type: EffectType.myEffect,           // add to the enum
  label: 'My effect',
  description: 'What it does.',
  icon: Icons.something,
  stage: EffectStage.stylise,          // decides ordering vs other effects
  shaderAsset: 'shaders/my_effect.frag',
  params: const [
    EffectParamSpec(key: 'amount', label: 'Amount', min: 0, max: 1,
                    defaultValue: 0.5),
  ],
  buildFilters: (fx) {
    final amount = fx.value('amount', 0.5) * fx.intensity;
    if (amount < 0.02) return const [];   // always no-op cheaply
    return [Filter('myfilter', {'strength': amount})];
  },
),
```

Then add the shader to `pubspec.yaml` under `shaders:` and a uniform mapping in
`ShaderUniforms.apply`. The effects browser, inspector sliders, keyframing,
serialisation and the export path all pick it up with no further work.

**Two things to get right.** Uniform *order* in `ShaderUniforms.apply` must
match the declaration order in the `.frag` file — `setFloat` is positional and
a mismatch silently produces a wrong image. And avoid constructs SkSL rejects
(array initializers especially): Impeller accepts them, Skia does not, and Skia
is still the fallback on devices without a usable Vulkan driver. `flutter build`
warns; `flutter analyze` does not.

## Adding a new transition

Add to `TransitionType` and `TransitionCatalog.all`. If `xfade` has a native
equivalent, name it. If not, supply a `customExpression` *and* the closest
native name as the fast approximation — the export screen exposes the choice
rather than making it silently.

## Adding a new clip kind

`Clip` is a sealed hierarchy, so this is the one change the compiler helps with:
adding a subclass breaks every exhaustive `switch` until each is handled.
Those switches are in `TimelineCompiler`, `LayerPainter`, `PreviewStage`,
`TimelinePainter` and `TimelineOperations._splitClip` — exactly the places that
must know. That is the point of sealing it.

## Plugging in an AI backend

Implement `AiBackend` and override the provider:

```dart
ProviderScope(
  overrides: [
    aiBackendProvider.overrideWithValue(MyBackend(dio: …, baseUrl: …)),
  ],
  child: const ProCutApp(),
)
```

`AiWireFormat` already parses the response shapes, so an implementation only
deals with transport. `availableCapabilities()` drives the UI: capabilities the
backend does not report stay marked "needs setup" instead of failing at the
point of use.

The interface is deliberately transport-agnostic. Swapping the HTTP backend for
an on-device TFLite/ONNX runtime is a new `AiBackend`, not a change anywhere
else.

## Enabling the remote asset library

```dart
assetCatalogBaseUrlProvider.overrideWithValue('https://assets.example.com'),
```

`AssetLibraryRepositoryImpl` merges remote items over the bundled manifest and
falls back to bundled-only when the network is unreachable — browsing never
fails because of connectivity.

---

## Larger moves

### iOS

The domain, data and engine layers are platform-neutral already. What needs
work:

| Area | Change |
|---|---|
| FFmpegKit | `ffmpeg_kit_flutter_new` supports iOS; add the pod |
| Gallery export | `MediaStorePublisher` needs a `PHPhotoLibrary` sibling behind the same interface |
| Permissions | `PermissionService._resolve` returns `Permission.photos` for non-Android; verify against Info.plist keys |
| Hardware encoding | `h264_videotoolbox` / `hevc_videotoolbox` — add to `VideoCodec`, extend `HardwareEncoderProbe.choose` |
| Shaders | Same `.frag` files; Impeller is the only backend on iOS, so the SkSL constraints relax |

`PathService` and `HiveStore` need no changes.

### Background export

Exports currently die with the process. The manifest already declares
`FOREGROUND_SERVICE_MEDIA_PROCESSING`; what remains is a foreground service
that hosts the FFmpeg session and a notification with progress. `ExportEngine`
already exposes a `Stream<ExportProgress>` and a `jobId`, so the service is a
consumer of the existing API rather than a rewrite.

### Collaborative or cloud projects

The persistence seam is `ProjectRepository`. A cloud implementation slots in
behind it. Two things the current model already gets right for this: projects
are canonical JSON (diffable, mergeable) and every edit is a pure function
(replayable as an operation log). Conflict resolution would need per-clip
version vectors — `Clip.id` is already stable across edits, which is the
prerequisite.

### Trimming FFmpeg

FFmpeg is ~28 MB per ABI, most of the download. A custom build with only the
needed decoders (H.264, HEVC, AAC, MP3, VP9) and filters cuts it substantially.
`ffmpeg-kit`'s build scripts support this; the app needs no changes as long as
the filters named in `EffectCatalog` and `TransitionCatalog` survive — a
startup check against `-filters` would catch a mismatch early.

### Very large projects

Current behaviour at scale:

| Clips | Behaviour |
|---|---|
| < 100 | Everything comfortable |
| 100–500 | Painter is fine (viewport-bounded); undo stack is the memory driver |
| 500–2000 | JSON save grows; consider incremental persistence |
| > 2000 | `Timeline.editPoints` rebuilds a sorted set per call — cache it |

The first thing to break is not rendering — it is `editPoints`, recomputed on
every snap. It should memoise against the timeline identity when that becomes
real.

---

## Deliberate limits

Stated so they are choices rather than surprises.

- **Preview composites at most 4 video layers.** Android's decoder pool is
  small and device-dependent. Export is unaffected — FFmpeg composites all of
  them. The preview labels the layers it dropped.
- **Effect parameters are scalars.** A gradient-map effect needing a colour
  ramp would need `stringParams` or a new parameter type.
- **Keyframes interpolate scalars only.** Position is two independent tracks,
  which is how NLEs model it, but it means no motion-path with a shared
  tangent.
- **Nested sequences are not modelled.** A `Timeline` cannot contain another
  timeline as a clip. Adding it means a `SequenceClip` kind and recursion in
  the compiler — feasible, and the sealed hierarchy would flag every site.
- **Single-user, single-device.** No sync, no conflict resolution.
