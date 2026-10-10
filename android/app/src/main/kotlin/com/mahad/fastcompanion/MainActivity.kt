package com.mahad.fastcompanion

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val openNoteChannel = "notes_widget_open_note"
    private var methodChannel: MethodChannel? = null

    // Cold start: Dart isn't listening yet, so we hold the request here and
    // Dart asks for it ("getInitialNote") once it's ready.
    private var pendingOpenNote: Map<String, String?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            openNoteChannel
        )
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            if (call.method == "getInitialNote") {
                result.success(pendingOpenNote)
                pendingOpenNote = null
            } else {
                result.notImplemented()
            }
        }
        pendingOpenNote = extractOpenNote(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // App already running, so Dart's handler exists. Push directly.
        extractOpenNote(intent)?.let { methodChannel?.invokeMethod("openNote", it) }
    }

    private fun extractOpenNote(intent: Intent?): Map<String, String?>? {
        if (intent == null) return null
        val uid = intent.getStringExtra("open_note_uid")
        val noteId = intent.getStringExtra("open_note_id")
        if (uid == null || noteId == null) return null
        val type = intent.getStringExtra("open_note_type")
        // Consume the extras so a later re-launch doesn't replay this request.
        intent.removeExtra("open_note_uid")
        intent.removeExtra("open_note_id")
        intent.removeExtra("open_note_type")
        return mapOf("uid" to uid, "noteId" to noteId, "type" to type)
    }
}