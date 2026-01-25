package com.furry.player

import android.app.Activity
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaDataSource
import android.media.MediaPlayer
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors
import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : Activity() {
    private lateinit var webView: WebView
    private val ioPool = Executors.newSingleThreadExecutor()

    private data class LocalSelection(
        val displayName: String,
        val path: String,
        val sizeBytes: Long,
    )

    private var packInput: LocalSelection? = null
    private var pendingExportFile: File? = null
    private var mediaPlayer: MediaPlayer? = null
    private var mediaDataSource: MediaDataSource? = null
    private var playbackState: PlaybackState = PlaybackState.STOPPED
    private var playbackName: String? = null
    private var playbackFile: File? = null

    private val importsDir: File by lazy { File(filesDir, "imports").apply { mkdirs() } }
    private val outputsDir: File by lazy { File(filesDir, "outputs").apply { mkdirs() } }

    private val assetHost = "appassets.androidplatform.net"

    private enum class PlaybackState {
        STOPPED,
        PREPARING,
        PLAYING,
        PAUSED,
    }

    private companion object {
        private const val REQ_PICK_PACK_AUDIO = 1001
        private const val REQ_PICK_PLAY_AUDIO = 1003
        private const val REQ_EXPORT_OUTPUT = 2001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // 触发 System.loadLibrary + JNI init（来自 apps/furry_android/kotlin/NativeLib.kt）
        NativeLib.init()

        webView = WebView(this)
        setContentView(webView)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            cacheMode = WebSettings.LOAD_NO_CACHE
            allowFileAccess = false
            allowContentAccess = false
        }

        webView.webViewClient = LocalAssetClient(assetHost)
        webView.addJavascriptInterface(WebBridge(), "FurryBridge")
        webView.loadUrl("https://$assetHost/assets/index.html")
    }

    override fun onDestroy() {
        super.onDestroy()
        stopPlaybackInternal(emitEvent = false)
        ioPool.shutdown()
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK) {
            when (requestCode) {
                REQ_PICK_PACK_AUDIO -> emit(
                    "packInputSelected",
                    JSONObject().put("ok", false).put("canceled", true),
                )
                REQ_PICK_PLAY_AUDIO -> emit(
                    "playInputSelected",
                    JSONObject().put("ok", false).put("canceled", true),
                )
                REQ_EXPORT_OUTPUT -> emit(
                    "exportFinished",
                    JSONObject().put("ok", false).put("canceled", true),
                )
                else -> emit("activityResultCanceled", JSONObject().put("requestCode", requestCode))
            }
            return
        }
        val uri = data?.data ?: run {
            emit("activityResultError", JSONObject().put("requestCode", requestCode).put("error", "no uri"))
            return
        }

        when (requestCode) {
            REQ_PICK_PACK_AUDIO -> handlePickedUriForPack(uri)
            REQ_PICK_PLAY_AUDIO -> handlePickedUriForPlayback(uri)
            REQ_EXPORT_OUTPUT -> handleExportUri(uri)
            else -> emit("activityResultError", JSONObject().put("requestCode", requestCode).put("error", "unknown requestCode"))
        }
    }

    private inner class WebBridge {
        @JavascriptInterface
        fun pickPackInput() {
            runOnUiThread {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "audio/*"
                }
                try {
                    startActivityForResult(intent, REQ_PICK_PACK_AUDIO)
                } catch (e: Exception) {
                    emit(
                        "packInputSelected",
                        JSONObject().put("ok", false).put("error", e.toString()),
                    )
                }
            }
        }

        @JavascriptInterface
        fun pickPlayAudio() {
            runOnUiThread {
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    // 允许选择音频或 .furry（.furry 没有标准 mime，因此需要放开类型）
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                            "audio/*",
                            "application/octet-stream",
                        ),
                    )
                }
                try {
                    startActivityForResult(intent, REQ_PICK_PLAY_AUDIO)
                } catch (e: Exception) {
                    emit(
                        "playInputSelected",
                        JSONObject().put("ok", false).put("error", e.toString()),
                    )
                }
            }
        }

        @JavascriptInterface
        fun startPack(paddingKb: String) {
            val input = packInput
            if (input == null) {
                emit("packFinished", JSONObject().put("ok", false).put("error", "no pack input selected"))
                return
            }

            val padding = paddingKb.toLongOrNull() ?: 0L
            ioPool.execute {
                emit("packStarted", JSONObject().put("input", input.displayName))
                val base = input.displayName.substringBeforeLast('.', input.displayName)
                val outFile = uniqueFile(outputsDir, "$base.furry")
                val rc = NativeLib.packToFurry(input.path, outFile.absolutePath, padding)
                if (rc == 0) {
                    emit(
                        "packFinished",
                        JSONObject()
                            .put("ok", true)
                            .put("outputName", outFile.name)
                            .put("outputSize", outFile.length()),
                    )
                    emit("outputsChanged", JSONObject())
                } else {
                    emit(
                        "packFinished",
                        JSONObject()
                            .put("ok", false)
                            .put("code", rc),
                    )
                }
            }
        }

        @JavascriptInterface
        fun listOutputs(): String {
            val arr = JSONArray()
            outputsDir.listFiles()
                ?.asSequence()
                ?.filter { it.isFile && it.extension.lowercase(Locale.US) == "furry" }
                ?.sortedByDescending { it.lastModified() }
                ?.forEach { f ->
                    arr.put(
                        JSONObject()
                            .put("name", f.name)
                            .put("size", f.length())
                            .put("modified", f.lastModified()),
                    )
                }
            return arr.toString()
        }

        @JavascriptInterface
        fun deleteOutput(name: String): Boolean {
            val file = File(outputsDir, name)
            val ok = file.exists() && file.isFile && file.delete()
            if (ok) emit("outputsChanged", JSONObject())
            return ok
        }

        @JavascriptInterface
        fun exportOutput(name: String) {
            val file = File(outputsDir, name)
            if (!file.exists() || !file.isFile) {
                emit("exportFinished", JSONObject().put("ok", false).put("error", "file not found"))
                return
            }
            if (file.extension.lowercase(Locale.US) != "furry") {
                emit("exportFinished", JSONObject().put("ok", false).put("error", "export disabled"))
                return
            }

            pendingExportFile = file
            runOnUiThread {
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = guessExportMimeType(file.name)
                    putExtra(Intent.EXTRA_TITLE, file.name)
                }
                startActivityForResult(intent, REQ_EXPORT_OUTPUT)
            }
        }

        @JavascriptInterface
        fun playOutput(name: String) {
            val file = File(outputsDir, name)
            if (!file.exists() || !file.isFile) {
                emit("playbackError", JSONObject().put("name", name).put("error", "file not found"))
                return
            }

            val ext = file.extension.lowercase(Locale.US)
            if (ext == "furry") {
                ioPool.execute {
                    emit("playbackPreparing", JSONObject().put("name", name))
                    val bytes = NativeLib.unpackFromFurryToBytes(file.absolutePath)
                    if (bytes == null || bytes.isEmpty()) {
                        emit("playbackError", JSONObject().put("name", name).put("error", "decrypt failed"))
                        return@execute
                    }
                    runOnUiThread { startPlaybackFromBytes(bytes, name) }
                }
                return
            }

            runOnUiThread { startPlaybackFromFile(file, name) }
        }

        @JavascriptInterface
        fun pausePlayback() {
            runOnUiThread { pausePlaybackInternal() }
        }

        @JavascriptInterface
        fun resumePlayback() {
            runOnUiThread { resumePlaybackInternal() }
        }

        @JavascriptInterface
        fun seekPlayback(positionMs: String) {
            val ms = positionMs.toLongOrNull() ?: return
            runOnUiThread { seekPlaybackInternal(ms) }
        }

        @JavascriptInterface
        fun getPlaybackState(): String {
            val o = JSONObject()
            o.put("state", playbackState.name.lowercase(Locale.US))
            o.put("name", playbackName ?: "")
            o.put("file", playbackFile?.name ?: "")
            o.put("positionMs", safePlayerValue { mediaPlayer?.currentPosition?.toLong() } ?: 0L)
            o.put("durationMs", safePlayerValue { mediaPlayer?.duration?.toLong() } ?: 0L)
            return o.toString()
        }

        @JavascriptInterface
        fun stopPlayback() {
            runOnUiThread {
                stopPlaybackInternal(emitEvent = true)
            }
        }
    }

    private inner class LocalAssetClient(
        private val assetHost: String,
    ) : WebViewClient() {
        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
            val url = request?.url ?: return false
            // 只允许加载本地 assets 域名，避免外链页面拿到 JS bridge
            return url.host != assetHost
        }

        override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
            val url = request?.url ?: return null
            if (url.host != assetHost) return null

            val path = url.path ?: return null
            if (!path.startsWith("/assets/")) return null

            val rel = path.removePrefix("/assets/").ifBlank { "index.html" }
            return try {
                val input = assets.open(rel)
                WebResourceResponse(
                    guessMimeType(rel),
                    "utf-8",
                    input,
                )
            } catch (_: Exception) {
                // 返回 404，便于前端定位问题
                WebResourceResponse(
                    "text/plain",
                    "utf-8",
                    404,
                    "Not Found",
                    mapOf("Cache-Control" to "no-store"),
                    ByteArrayInputStream("Not Found: $rel".toByteArray()),
                )
            }
        }

        private fun guessMimeType(path: String): String {
            val ext = path.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.US)
            return when (ext) {
                "html" -> "text/html"
                "js" -> "application/javascript"
                "css" -> "text/css"
                "json" -> "application/json"
                "svg" -> "image/svg+xml"
                "png" -> "image/png"
                "jpg", "jpeg" -> "image/jpeg"
                "webp" -> "image/webp"
                "woff" -> "font/woff"
                "woff2" -> "font/woff2"
                else -> "application/octet-stream"
            }
        }
    }

    private fun handlePickedUriForPack(uri: Uri) {
        ioPool.execute {
            try {
                val displayName = getDisplayName(uri) ?: "input"
                val safeName = sanitizeFileName(displayName)
                val dest = uniqueFile(importsDir, safeName)
                val size = copyUriToFile(uri, dest)

                packInput = LocalSelection(displayName, dest.absolutePath, size)
                emit(
                    "packInputSelected",
                    JSONObject()
                        .put("ok", true)
                        .put("name", displayName)
                        .put("size", size),
                )
            } catch (e: Exception) {
                emit("packInputSelected", JSONObject().put("ok", false).put("error", e.toString()))
            }
        }
    }

    private fun handlePickedUriForPlayback(uri: Uri) {
        ioPool.execute {
            try {
                val displayName = getDisplayName(uri) ?: "audio"
                val safeName = sanitizeFileName(displayName)
                val dest = uniqueFile(importsDir, safeName)
                val size = copyUriToFile(uri, dest)
                val isFurry = NativeLib.isValidFurryFile(dest.absolutePath)

                emit(
                    "playInputSelected",
                    JSONObject()
                        .put("ok", true)
                        .put("name", displayName)
                        .put("size", size)
                        .put("isFurry", isFurry),
                )

                if (isFurry) {
                    emit("playbackPreparing", JSONObject().put("name", displayName))
                    val bytes = NativeLib.unpackFromFurryToBytes(dest.absolutePath)
                    if (bytes == null || bytes.isEmpty()) {
                        emit("playbackError", JSONObject().put("name", displayName).put("error", "decrypt failed"))
                        return@execute
                    }
                    runOnUiThread { startPlaybackFromBytes(bytes, displayName) }
                } else {
                    runOnUiThread {
                        startPlaybackFromFile(dest, displayName)
                    }
                }
            } catch (e: Exception) {
                emit("playInputSelected", JSONObject().put("ok", false).put("error", e.toString()))
            }
        }
    }

    private fun handleExportUri(uri: Uri) {
        val file = pendingExportFile
        pendingExportFile = null
        if (file == null) {
            emit("exportFinished", JSONObject().put("ok", false).put("error", "no pending export"))
            return
        }

        ioPool.execute {
            try {
                contentResolver.openOutputStream(uri)?.use { out ->
                    file.inputStream().use { input -> input.copyTo(out) }
                } ?: throw IllegalStateException("openOutputStream returned null")

                emit("exportFinished", JSONObject().put("ok", true).put("name", file.name))
            } catch (e: Exception) {
                emit(
                    "exportFinished",
                    JSONObject()
                        .put("ok", false)
                        .put("name", file.name)
                        .put("error", e.toString()),
                )
            }
        }
    }

    private fun emit(event: String, payload: JSONObject) {
        val js = "window.__nativeEmit(${JSONObject.quote(event)}, ${payload.toString()});"
        runOnUiThread {
            if (::webView.isInitialized) {
                webView.evaluateJavascript(js, null)
            }
        }
    }

    private fun getDisplayName(uri: Uri): String? {
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && c.moveToFirst()) c.getString(idx) else null
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun sanitizeFileName(name: String): String {
        val trimmed = name.trim().ifBlank { "file" }
        // Android/Linux 文件名限制：尽量保守
        return trimmed
            .replace('/', '_')
            .replace('\\', '_')
            .replace(':', '_')
            .replace('\u0000', '_')
    }

    private fun uniqueFile(dir: File, fileName: String): File {
        val base = fileName.substringBeforeLast('.', fileName)
        val ext = fileName.substringAfterLast('.', "")
        var n = 0
        while (true) {
            val name = if (n == 0) fileName else if (ext.isBlank()) "$base ($n)" else "$base ($n).$ext"
            val f = File(dir, name)
            if (!f.exists()) return f
            n += 1
        }
    }

    private fun copyUriToFile(uri: Uri, dest: File): Long {
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(dest).use { output ->
                return input.copyTo(output)
            }
        }
        throw IllegalStateException("openInputStream returned null")
    }

    private fun guessExportMimeType(fileName: String): String {
        val ext = fileName.substringAfterLast('.', missingDelimiterValue = "").lowercase(Locale.US)
        return when (ext) {
            "mp3" -> "audio/mpeg"
            "wav" -> "audio/wav"
            "ogg", "opus" -> "audio/ogg"
            "flac" -> "audio/flac"
            "furry" -> "application/octet-stream"
            else -> "application/octet-stream"
        }
    }

    private class ByteArrayMediaDataSource(
        private val data: ByteArray,
    ) : MediaDataSource() {
        override fun getSize(): Long = data.size.toLong()

        override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
            if (position < 0) return -1
            if (position >= data.size.toLong()) return -1
            val pos = position.toInt()
            val len = minOf(size, data.size - pos)
            if (len <= 0) return -1
            System.arraycopy(data, pos, buffer, offset, len)
            return len
        }

        override fun close() {
            // no-op (let GC collect)
        }
    }

    private fun startPlaybackFromFile(file: File, name: String) {
        if (!file.exists() || !file.isFile) {
            emit("playbackError", JSONObject().put("name", name).put("error", "file not found"))
            return
        }

        stopPlaybackInternal(emitEvent = false)

        playbackState = PlaybackState.PREPARING
        playbackName = name
        playbackFile = file
        emit("playbackStateChanged", JSONObject().put("state", "preparing").put("name", name))

        try {
            mediaPlayer = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build(),
                )
                setDataSource(file.absolutePath)
                setOnPreparedListener { mp ->
                    playbackState = PlaybackState.PLAYING
                    emit("playbackStateChanged", JSONObject().put("state", "playing").put("name", name))
                    mp.start()
                }
                setOnCompletionListener {
                    playbackState = PlaybackState.STOPPED
                    emit("playbackEnded", JSONObject().put("name", name))
                    stopPlaybackInternal(emitEvent = false)
                }
                setOnErrorListener { _, what, extra ->
                    playbackState = PlaybackState.STOPPED
                    emit(
                        "playbackError",
                        JSONObject()
                            .put("name", name)
                            .put("what", what)
                            .put("extra", extra),
                    )
                    stopPlaybackInternal(emitEvent = false)
                    true
                }
                prepareAsync()
            }
        } catch (e: Exception) {
            playbackState = PlaybackState.STOPPED
            emit("playbackError", JSONObject().put("name", name).put("error", e.toString()))
            stopPlaybackInternal(emitEvent = false)
        }
    }

    private fun startPlaybackFromBytes(bytes: ByteArray, name: String) {
        stopPlaybackInternal(emitEvent = false)

        playbackState = PlaybackState.PREPARING
        playbackName = name
        playbackFile = null
        emit("playbackStateChanged", JSONObject().put("state", "preparing").put("name", name))

        try {
            mediaPlayer =
                MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build(),
                    )

                    mediaDataSource = ByteArrayMediaDataSource(bytes)
                    setDataSource(mediaDataSource!!)

                    setOnPreparedListener { mp ->
                        playbackState = PlaybackState.PLAYING
                        emit("playbackStateChanged", JSONObject().put("state", "playing").put("name", name))
                        mp.start()
                    }
                    setOnCompletionListener {
                        playbackState = PlaybackState.STOPPED
                        emit("playbackEnded", JSONObject().put("name", name))
                        stopPlaybackInternal(emitEvent = false)
                    }
                    setOnErrorListener { _, what, extra ->
                        playbackState = PlaybackState.STOPPED
                        emit(
                            "playbackError",
                            JSONObject()
                                .put("name", name)
                                .put("what", what)
                                .put("extra", extra),
                        )
                        stopPlaybackInternal(emitEvent = false)
                        true
                    }
                    prepareAsync()
                }
        } catch (e: Exception) {
            playbackState = PlaybackState.STOPPED
            emit("playbackError", JSONObject().put("name", name).put("error", e.toString()))
            stopPlaybackInternal(emitEvent = false)
        }
    }

    private fun pausePlaybackInternal() {
        val mp = mediaPlayer ?: return
        if (playbackState != PlaybackState.PLAYING) return
        try {
            mp.pause()
            playbackState = PlaybackState.PAUSED
            emit("playbackStateChanged", JSONObject().put("state", "paused").put("name", playbackName ?: ""))
        } catch (e: Exception) {
            emit("playbackError", JSONObject().put("error", e.toString()))
        }
    }

    private fun resumePlaybackInternal() {
        val mp = mediaPlayer ?: return
        if (playbackState != PlaybackState.PAUSED) return
        try {
            mp.start()
            playbackState = PlaybackState.PLAYING
            emit("playbackStateChanged", JSONObject().put("state", "playing").put("name", playbackName ?: ""))
        } catch (e: Exception) {
            emit("playbackError", JSONObject().put("error", e.toString()))
        }
    }

    private fun seekPlaybackInternal(positionMs: Long) {
        val mp = mediaPlayer ?: return
        if (playbackState == PlaybackState.STOPPED) return
        val duration = safePlayerValue { mp.duration.toLong() } ?: 0L
        val target = positionMs.coerceIn(0L, duration.takeIf { it > 0 } ?: positionMs)
        try {
            mp.seekTo(target.toInt())
        } catch (e: Exception) {
            emit("playbackError", JSONObject().put("error", e.toString()))
        }
    }

    private fun stopPlaybackInternal(emitEvent: Boolean) {
        val wasActive = playbackState != PlaybackState.STOPPED || mediaPlayer != null
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {
        }
        try {
            mediaPlayer?.release()
        } catch (_: Exception) {
        }
        try {
            mediaDataSource?.close()
        } catch (_: Exception) {
        }
        mediaDataSource = null

        mediaPlayer = null
        playbackState = PlaybackState.STOPPED
        playbackName = null
        playbackFile = null

        if (emitEvent && wasActive) {
            emit("playbackStopped", JSONObject())
        }
    }

    private fun <T> safePlayerValue(get: () -> T?): T? {
        return try {
            get()
        } catch (_: Exception) {
            null
        }
    }
}
