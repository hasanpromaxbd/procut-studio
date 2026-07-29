# ── FFmpegKit ────────────────────────────────────────────────────────
# The native layer resolves these classes by name through JNI, so R8 must not
# rename or strip them. Without these rules a release build fails at the first
# FFmpeg call with a NoSuchMethodError — and only in release, which is the
# worst possible time to find out.
-keep class com.antonkarpenko.ffmpegkit.** { *; }
-keep class com.arthenica.ffmpegkit.** { *; }
-dontwarn com.antonkarpenko.ffmpegkit.**
-dontwarn com.arthenica.ffmpegkit.**

# ── Flutter embedding ────────────────────────────────────────────────
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# ── Plugins with reflective entry points ─────────────────────────────
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.llfbandit.record.** { *; }
-dontwarn com.google.android.play.core.**

# ── Kotlin coroutines used by the MediaStore bridge ──────────────────
-keepclassmembers class kotlinx.coroutines.** { volatile <fields>; }
-dontwarn kotlinx.coroutines.**

# Keep the method-channel handler in MainActivity reachable.
-keep class com.procutstudio.procut_studio.MainActivity { *; }
