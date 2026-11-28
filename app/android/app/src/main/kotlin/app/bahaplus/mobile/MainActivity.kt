package app.bahaplus.mobile

import android.app.PictureInPictureParams
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Rect
import android.os.Build
import android.util.Rational
import android.util.LruCache
import android.view.View
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import android.view.WindowManager
import android.media.MediaMetadata
import android.media.AudioManager
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultBandwidthMeter
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.net.URI
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import kotlin.math.max
import kotlin.math.roundToInt

@androidx.annotation.OptIn(markerClass = [UnstableApi::class])
class MainActivity : FlutterActivity() {
    private data class SessionMetadata(
        val document: String,
        val title: String,
        val episode: String,
        val duration: Long,
        val artwork: String?,
    )

    private var nativeMediaSession: MediaSession? = null
    private var playbackChannel: MethodChannel? = null
    private var playbackDocument: String? = null
    private var pictureInPictureChannel: MethodChannel? = null
    private var pictureInPictureRequest: String? = null
    private var keepScreenOn = false
    private var metadataKey: SessionMetadata? = null
    private val artworkCache = LruCache<String, Bitmap>(8)
    private val pendingArtwork = mutableMapOf<String, SessionMetadata>()
    private var artworkExecutor: ExecutorService? = null
    private var noisyReceiverRegistered = false
    private val noisyReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY &&
                nativeMediaSession != null) {
                remoteCommand("pause", source = "audio-route")
            }
        }
    }
    private var downloadChannel: MethodChannel? = null
    private var downloadDocument: String? = null
    private var downloadBytes = 0L
    private var bandwidthMeter: DefaultBandwidthMeter? = null
    private val bandwidthListener = object : BandwidthMeter.EventListener {
        override fun onBandwidthSample(elapsedMs: Int, bytesTransferred: Long, bitrateEstimate: Long) {
            if (downloadDocument != null && bytesTransferred > 0) {
                downloadBytes += bytesTransferred
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pictureInPictureChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.bahaplus.mobile/picture_in_picture").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "isSupported" -> result.success(supportsPictureInPicture())
                    "enter" -> result.success(enterPictureInPicture(call))
                    else -> result.notImplemented()
                }
            }
        }
        // ExoPlayer's default builder uses this singleton for media transfers.
        // It excludes WebView requests, artwork and the rest of the app.
        bandwidthMeter = DefaultBandwidthMeter.getSingletonInstance(applicationContext).also {
            it.addEventListener(Handler(Looper.getMainLooper()), bandwidthListener)
        }
        downloadChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.bahaplus.mobile/playback_download").also { channel ->
            channel.setMethodCallHandler { call, result ->
                val document = call.argument<String>("document")
                when (call.method) {
                    "start" -> {
                        if (document.isNullOrEmpty()) {
                            result.success(false)
                        } else {
                            downloadDocument = document
                            downloadBytes = 0
                            result.success(true)
                        }
                    }
                    "sample" -> result.success(if (document == downloadDocument && document != null)
                        mapOf("bytes" to downloadBytes, "source" to 0) else null)
                    "stop" -> {
                        if (document == downloadDocument) downloadDocument = null
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.bahaplus.mobile/playback_environment")
        playbackChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "update") {
                val desiredKeepAwake = call.argument<Boolean>("keepAwake") == true
                if (desiredKeepAwake != keepScreenOn) {
                    keepScreenOn = desiredKeepAwake
                    if (desiredKeepAwake) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                }
                if (call.argument<Boolean>("active") == true &&
                    call.argument<Boolean>("native") == true) {
                    updateNativeSession(call.arguments as Map<*, *>)
                } else {
                    releaseNativeSession()
                }
                result.success(null)
            } else {
                result.notImplemented()
            }
        }
    }

    private fun supportsPictureInPicture(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    private fun enterPictureInPicture(call: MethodCall): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            !supportsPictureInPicture() || isFinishing || isInPictureInPictureMode) {
            return false
        }
        val request = call.argument<String>("id") ?: return false
        val ratio = call.argument<Double>("aspectRatio")
            ?.takeIf { it.isFinite() && it > 0 } ?: return false
        val aspect = Rational((ratio * 1000).roundToInt(), 1000)
            .coerceIn(Rational(100, 239), Rational(239, 100))
        val params = PictureInPictureParams.Builder()
            .setAspectRatio(aspect)
        val flutterView = findViewById<View>(FLUTTER_VIEW_ID) ?: return false
        val origin = IntArray(2)
        flutterView.getLocationInWindow(origin)
        val density = flutterView.resources.displayMetrics.density
        fun coordinate(name: String, offset: Int): Int =
            ((call.argument<Double>(name) ?: 0.0) * density).roundToInt() + offset

        val source = Rect(
            coordinate("left", origin[0]), coordinate("top", origin[1]),
            coordinate("right", origin[0]), coordinate("bottom", origin[1]),
        )
        if (source.intersect(origin[0], origin[1],
                origin[0] + flutterView.width, origin[1] + flutterView.height)) {
            params.setSourceRectHint(source)
        }
        pictureInPictureRequest = request
        val entered = try {
            enterPictureInPictureMode(params.build())
        } catch (_: IllegalArgumentException) {
            false
        } catch (_: IllegalStateException) {
            false
        } catch (_: SecurityException) {
            false
        }
        if (!entered) pictureInPictureRequest = null
        return entered
    }

    override fun onPictureInPictureModeChanged(active: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(active, newConfig)
        val request = pictureInPictureRequest ?: return
        if (!active) pictureInPictureRequest = null
        pictureInPictureChannel?.invokeMethod("modeChanged", mapOf(
            "id" to request, "active" to active))
    }

    private fun remoteCommand(
        action: String, value: Double? = null, source: String = "remote-command",
    ) {
        val document = playbackDocument ?: return
        playbackChannel?.invokeMethod("remoteCommand", mapOf(
            "document" to document, "action" to action, "value" to value, "source" to source))
    }

    private fun updateNativeSession(state: Map<*, *>) {
        val document = state["document"] as? String ?: return
        playbackDocument = document
        val session = nativeMediaSession ?: MediaSession(this, "BahaPlusNative").also {
            it.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = remoteCommand("play")
                override fun onPause() = remoteCommand("pause")
                override fun onStop() = remoteCommand("pause")
                override fun onRewind() = remoteCommand("rewind")
                override fun onFastForward() = remoteCommand("fastForward")
                override fun onSeekTo(position: Long) =
                    remoteCommand("seek", position / 1000.0)
            })
            it.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            it.isActive = true
            nativeMediaSession = it
            val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(noisyReceiver, filter)
            }
            noisyReceiverRegistered = true
        }
        val title = state["title"] as? String ?: ""
        val episode = state["episode"] as? String ?: ""
        val duration = ((state["duration"] as? Number)?.toDouble() ?: 0.0) * 1000
        val key = SessionMetadata(
            document, title, episode, duration.toLong(),
            artworkUri(state["artwork"] as? String)?.toString(),
        )
        if (key != metadataKey) {
            metadataKey = key
            val artwork = key.artwork?.let { artworkCache.get(it) }
            session.setMetadata(buildMetadata(key, artwork))
            if (artwork == null) key.artwork?.let { requestArtwork(it, key) }
        }
        val playing = state["playing"] == true
        val position = ((state["position"] as? Number)?.toDouble() ?: 0.0) * 1000
        val rate = if (playing) ((state["rate"] as? Number)?.toFloat() ?: 1f) else 0f
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO or
                PlaybackState.ACTION_REWIND or PlaybackState.ACTION_FAST_FORWARD)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                position.toLong(), rate).build())
    }

    private fun buildMetadata(key: SessionMetadata, artwork: Bitmap?): MediaMetadata {
        val builder = MediaMetadata.Builder()
            .putString(MediaMetadata.METADATA_KEY_TITLE, key.title)
            .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, key.episode)
            .putLong(MediaMetadata.METADATA_KEY_DURATION, key.duration)
        if (artwork != null) {
            builder.putBitmap(MediaMetadata.METADATA_KEY_ART, artwork)
            builder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, artwork)
        }
        return builder.build()
    }

    private fun artworkUri(value: String?): URI? {
        if (value.isNullOrEmpty() || value.length > 4096) return null
        val uri = runCatching { URI(value) }.getOrNull() ?: return null
        val host = uri.host?.lowercase() ?: return null
        return uri.takeIf {
            it.scheme == "https" && (it.port == -1 || it.port == 443) &&
                it.rawUserInfo == null && it.rawFragment == null &&
                (host == "bahamut.com.tw" || host.endsWith(".bahamut.com.tw"))
        }
    }

    private fun requestArtwork(url: String, key: SessionMetadata) {
        if (pendingArtwork.put(url, key) != null) return
        val executor = artworkExecutor ?: Executors.newSingleThreadExecutor().also {
            artworkExecutor = it
        }
        executor.execute {
            val artwork = loadArtwork(url)
            runOnUiThread {
                if (artworkExecutor !== executor) return@runOnUiThread
                val requested = pendingArtwork.remove(url)
                if (artwork != null && requested != null) {
                    artworkCache.put(url, artwork)
                    if (requested == metadataKey) {
                        nativeMediaSession?.setMetadata(buildMetadata(requested, artwork))
                    }
                }
            }
        }
    }

    private fun loadArtwork(url: String): Bitmap? {
        val uri = artworkUri(url) ?: return null
        val connection = try {
            uri.toURL().openConnection() as HttpsURLConnection
        } catch (_: IOException) {
            return null
        }
        try {
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            val limit = 4 * 1024 * 1024
            if (connection.responseCode != 200 || connection.contentLength > limit) return null
            val bytes = connection.inputStream.use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > limit) return null
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
            val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
            if (options.outWidth <= 0 || options.outHeight <= 0) return null
            val longest = max(options.outWidth, options.outHeight)
            options.inSampleSize = 1
            while (longest / options.inSampleSize > 1024) options.inSampleSize *= 2
            options.inJustDecodeBounds = false
            val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            val scale = 512.0 / max(image.width, image.height)
            if (scale >= 1) return image
            val resized = Bitmap.createScaledBitmap(
                image, max(1, (image.width * scale).roundToInt()),
                max(1, (image.height * scale).roundToInt()), true,
            )
            image.recycle()
            return resized
        } catch (_: IOException) {
            return null
        } finally {
            connection.disconnect()
        }
    }

    private fun releaseNativeSession() {
        if (noisyReceiverRegistered) {
            unregisterReceiver(noisyReceiver)
            noisyReceiverRegistered = false
        }
        nativeMediaSession?.release()
        nativeMediaSession = null
        playbackDocument = null
        metadataKey = null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        pictureInPictureChannel?.setMethodCallHandler(null)
        pictureInPictureChannel = null
        pictureInPictureRequest = null
        bandwidthMeter?.removeEventListener(bandwidthListener)
        bandwidthMeter = null
        downloadChannel?.setMethodCallHandler(null)
        downloadChannel = null
        downloadDocument = null
        releaseNativeSession()
        artworkExecutor?.shutdownNow()
        artworkExecutor = null
        pendingArtwork.clear()
        artworkCache.evictAll()
        keepScreenOn = false
        playbackChannel?.setMethodCallHandler(null)
        playbackChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
