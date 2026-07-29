package com.procutstudio.procut_studio

import android.content.ContentValues
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts the Flutter engine and provides the MediaStore bridge.
 *
 * Scoped storage (API 29+) forbids an app from writing directly into
 * `Movies/` or `DCIM/`. A finished render has to be inserted through
 * MediaStore, which hands back a content URI the gallery can index. On API 28
 * and below the legacy filesystem path still works, so both are handled.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "com.procutstudio.procut_studio/mediastore"
        const val EXPORT_CHANNEL = "com.procutstudio.procut_studio/export_service"
    }

    private var exportChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "insertVideo" -> handleInsertVideo(call.argument("filePath"),
                    call.argument("displayName"),
                    call.argument("relativePath"),
                    result)

                else -> result.notImplemented()
            }
        }

        configureExportChannel(flutterEngine)
    }

    /**
     * Bridges the export foreground service to Dart.
     *
     * The Activity owns this rather than the service because the Flutter
     * engine's lifecycle is tied to the Activity. The service raises the
     * process's importance so the Activity — and therefore the engine and the
     * running FFmpeg session — is not reclaimed while the user is elsewhere.
     */
    private fun configureExportChannel(flutterEngine: FlutterEngine) {
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXPORT_CHANNEL
        )
        exportChannel = channel

        // A Cancel tap on the notification arrives here and is forwarded to the
        // Dart side, which owns the FFmpeg session and knows how to unwind it.
        ExportService.onCancelRequested = {
            runOnUiThread { channel.invokeMethod("onCancelRequested", null) }
        }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    ExportService.start(
                        this,
                        call.argument<String>("title") ?: "Exporting",
                        call.argument<String>("message") ?: "Preparing"
                    )
                    result.success(true)
                }

                "update" -> {
                    ExportService.update(
                        this,
                        call.argument<String>("message") ?: "",
                        call.argument<Int>("progress") ?: 0,
                        call.argument<Boolean>("indeterminate") ?: false
                    )
                    result.success(true)
                }

                "stop" -> {
                    ExportService.stop(this)
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        ExportService.onCancelRequested = null
        exportChannel?.setMethodCallHandler(null)
        exportChannel = null
        super.onDestroy()
    }

    private fun handleInsertVideo(
        filePath: String?,
        displayName: String?,
        relativePath: String?,
        result: MethodChannel.Result
    ) {
        if (filePath.isNullOrEmpty() || displayName.isNullOrEmpty()) {
            result.error("BAD_ARGS", "filePath and displayName are required", null)
            return
        }

        val source = File(filePath)
        if (!source.exists()) {
            result.error("NOT_FOUND", "Source file does not exist", filePath)
            return
        }

        try {
            val uri = insertVideo(source, displayName, relativePath ?: "Movies/ProCut Studio")
            if (uri == null) {
                result.error("INSERT_FAILED", "MediaStore returned no URI", null)
            } else {
                result.success(uri.toString())
            }
        } catch (e: Exception) {
            result.error("INSERT_FAILED", e.message, null)
        }
    }

    private fun insertVideo(source: File, displayName: String, relativePath: String): Uri? {
        val resolver = contentResolver

        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Video.Media.MIME_TYPE, mimeTypeFor(displayName))
            put(MediaStore.Video.Media.DATE_ADDED, System.currentTimeMillis() / 1000)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.Video.Media.RELATIVE_PATH, relativePath)
                // IS_PENDING hides the entry from the gallery until the copy
                // finishes. Without it, a half-written file briefly appears and
                // gallery apps cache a broken thumbnail for it.
                put(MediaStore.Video.Media.IS_PENDING, 1)
            } else {
                @Suppress("DEPRECATION")
                val target = File(
                    Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_MOVIES
                    ),
                    "ProCut Studio"
                )
                if (!target.exists()) target.mkdirs()
                @Suppress("DEPRECATION")
                put(MediaStore.Video.Media.DATA, File(target, displayName).absolutePath)
            }
        }

        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        }

        val uri = resolver.insert(collection, values) ?: return null

        resolver.openOutputStream(uri)?.use { output ->
            source.inputStream().use { input ->
                input.copyTo(output, DEFAULT_BUFFER_SIZE)
            }
        } ?: run {
            resolver.delete(uri, null, null)
            return null
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.clear()
            values.put(MediaStore.Video.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }

        return uri
    }

    private fun mimeTypeFor(name: String): String = when {
        name.endsWith(".mov", ignoreCase = true) -> "video/quicktime"
        name.endsWith(".mkv", ignoreCase = true) -> "video/x-matroska"
        name.endsWith(".webm", ignoreCase = true) -> "video/webm"
        else -> "video/mp4"
    }
}
