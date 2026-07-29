# Build instructions

## Requirements

| Tool | Version | Notes |
|---|---|---|
| Flutter | 3.44+ (stable) | Verified against 3.44.6 / Dart 3.12.2 |
| Android SDK | Platform 36 | `compileSdk` comes from the Flutter tool |
| Android NDK | Per Flutter's default | Needed by the FFmpeg native libraries |
| JDK | 17 | Set in `android/app/build.gradle.kts` |
| Min Android | API 24 (7.0) | Floor set by FFmpegKit, not by choice |

Check the toolchain:

```bash
flutter doctor -v
```

## First run

```bash
flutter pub get
flutter run
```

The first build downloads the FFmpeg AARs (~90 MB) and can take several
minutes. Later builds are incremental.

## Debug build

```bash
flutter build apk --debug
```

Debug installs alongside release: `applicationIdSuffix = ".debug"` lets both
sit on one device, which matters when comparing export output between them.

## Release build

### 1. Create a keystore

```bash
keytool -genkey -v -keystore ~/.keys/procut/upload.jks \
  -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

### 2. Point the build at it

Create `android/key.properties` — gitignored, never commit it:

```properties
storePassword=<store password>
keyPassword=<key password>
keyAlias=upload
storeFile=/home/you/.keys/procut/upload.jks
```

Without this file the release build falls back to debug keys so a fresh clone
still produces something installable. It just cannot be published.

### 3. Build

```bash
# App bundle for Play — recommended, Play splits per-ABI for you
flutter build appbundle --release

# Universal APK for direct distribution
flutter build apk --release

# Per-ABI APKs, ~30 MB smaller each
flutter build apk --release --split-per-abi -PsplitPerAbi=true
```

Output:

```
build/app/outputs/flutter-apk/app-release.apk
build/app/outputs/bundle/release/app-release.aab
```

## APK size

FFmpeg dominates. Measured on this project (Flutter 3.44.6, 3 ABIs):

| Build | Size |
|---|---|
| Debug, universal | 174 MB |
| **Release, universal (armeabi-v7a + arm64-v8a + x86_64)** | **110 MB** |
| Release, per-ABI (estimated) | ~40 MB |

Most of it is the FFmpeg native libraries — roughly 28 MB per ABI.

Ship an App Bundle. Play delivers one ABI and users download ~40 MB rather
than 110.

To go smaller, build FFmpeg with only the codecs you need — see
[SCALABILITY.md](SCALABILITY.md#trimming-ffmpeg).

## Verifying a build

```bash
flutter analyze                      # must report: No issues found
flutter test                         # 119 tests
flutter build apk --debug            # compiles shaders + Kotlin + native
```

`flutter analyze` will not catch a broken shader — only a real build compiles
the `.frag` files to device bytecode. Always run a build before shipping shader
changes.

## Troubleshooting

**`cannot find symbol: class FilePickerPlugin` at `:app:compileDebugJavaWithJavac`**
`file_picker` 11.0.2 skips applying the Kotlin Gradle plugin when AGP ≥ 9,
assuming AGP 9's built-in Kotlin support is active — it is not enabled by
default, so the plugin's Kotlin sources are never compiled. The shim at the
bottom of `android/build.gradle.kts` applies it back. Remove that block once
`file_picker` ships an AGP 9-aware release.

**`WARNING: Your app uses plugins that apply Kotlin Gradle Plugin (KGP)`**
Informational. `ffmpeg_kit_flutter_new`, `file_picker` and `share_plus` have
not migrated to Flutter's built-in Kotlin support. Builds succeed today; a
future Flutter will require the migration upstream.

**`SkSL does not support array initializers`**
A shader used a construct Impeller accepts and Skia does not. Skia is still the
fallback on devices without a usable Vulkan driver, so the effect would
silently fail there. Rewrite the shader to compute values in a loop — see
`shaders/gaussian_blur.frag` for the pattern. `flutter analyze` will not catch
this; only a real build does.

**`Execution failed for task ':app:checkDebugAarMetadata'`**
FFmpegKit needs `compileSdk` 35+. It comes from the Flutter tool; run
`flutter upgrade` if yours is older.

**`NoSuchMethodError` from FFmpeg, release builds only**
R8 stripped the JNI entry points. `android/app/proguard-rules.pro` keeps them —
verify it was not dropped from `proguardFiles`.

**`UnsatisfiedLinkError: dlopen failed` for `libffmpegkit.so`**
Native libs were compressed. `packaging { jniLibs { useLegacyPackaging = true } }`
in `android/app/build.gradle.kts` prevents this.

**Export fails only on one device, `cannot open encoder`**
That vendor's MediaCodec rejected the format. The engine already retries in
software automatically; if it still fails, turn off hardware encoding in export
settings and check Settings → Diagnostics → Recent logs for the FFmpeg tail.

**`Failed to load shader` at startup**
The `.frag` file is missing from the `shaders:` list in `pubspec.yaml`. The app
degrades to unfiltered preview rather than crashing, and logs which one failed.

**Text renders in the wrong font**
`google_fonts` fetches families on first use. Offline with nothing cached, it
falls back to the platform font. To guarantee a font offline, bundle the `.ttf`
and add it under `fonts:` in `pubspec.yaml`.

## Licensing

**FFmpegKit is LGPL v3.** This build links it dynamically, which is what LGPL
requires — do not statically link it into your binary.

If you enable GPL components (x264, x265) you must license the whole
application under GPL. The default build does **not** include them; `libx264`
and `libx265` referenced in `VideoCodec` resolve only if your FFmpeg build
provides them. For a closed-source app, ship the MediaCodec (hardware) encoders
and an LGPL FFmpeg build.

Attribution for bundled library assets lives in
`assets/data/library_manifest.json` and is surfaced in the app.
