package app.bahaplus.mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.view.WindowManager
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState

class MainActivity : FlutterActivity() {
    private var nativeMediaSession: MediaSession? = null
    private var playbackChannel: MethodChannel? = null
    private var playbackDocument: String? = null
    private var metadataKey = ""

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        playbackChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "app.bahaplus.mobile/playback_environment")
        playbackChannel!!.setMethodCallHandler { call, result ->
            if (call.method == "update") {
                if (call.argument<Boolean>("keepAwake") == true) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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

    private fun remoteCommand(action: String, value: Double? = null) {
        val document = playbackDocument ?: return
        playbackChannel?.invokeMethod("remoteCommand", mapOf(
            "document" to document, "action" to action, "value" to value))
    }

    private fun updateNativeSession(state: Map<*, *>) {
        playbackDocument = state["document"] as? String ?: return
        val session = nativeMediaSession ?: MediaSession(this, "BahaPlusNative").also {
            it.setCallback(object : MediaSession.Callback() {
                override fun onPlay() = remoteCommand("play")
                override fun onPause() = remoteCommand("pause")
                override fun onStop() = remoteCommand("pause")
                override fun onSeekTo(position: Long) =
                    remoteCommand("seek", position / 1000.0)
            })
            it.setFlags(MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS)
            it.isActive = true
            nativeMediaSession = it
        }
        val title = state["title"] as? String ?: ""
        val episode = state["episode"] as? String ?: ""
        val duration = ((state["duration"] as? Number)?.toDouble() ?: 0.0) * 1000
        val key = "$title|$episode|$duration"
        if (key != metadataKey) {
            metadataKey = key
            session.setMetadata(MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                .putString(MediaMetadata.METADATA_KEY_DISPLAY_SUBTITLE, episode)
                .putLong(MediaMetadata.METADATA_KEY_DURATION, duration.toLong()).build())
        }
        val playing = state["playing"] == true
        val position = ((state["position"] as? Number)?.toDouble() ?: 0.0) * 1000
        val rate = if (playing) ((state["rate"] as? Number)?.toFloat() ?: 1f) else 0f
        session.setPlaybackState(PlaybackState.Builder()
            .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE or PlaybackState.ACTION_SEEK_TO)
            .setState(if (playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                position.toLong(), rate).build())
    }

    private fun releaseNativeSession() {
        nativeMediaSession?.release()
        nativeMediaSession = null
        playbackDocument = null
        metadataKey = ""
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        releaseNativeSession()
        playbackChannel?.setMethodCallHandler(null)
        playbackChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
