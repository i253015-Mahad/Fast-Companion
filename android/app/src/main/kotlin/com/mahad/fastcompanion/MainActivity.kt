package com.mahad.fastcompanion

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val openNoteChannel = "notes_widget_open_note"
    private var methodChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            openNoteChannel
        )
        // App launched fresh via the widget's edit button — extras are
        // already on `intent` by the time the engine attaches.
        sendOpenNoteExtrasIfPresent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Widget's edit button tapped again while the app is already
        // running — requires android:launchMode="singleTop" on this
        // Activity in AndroidManifest.xml, or this never fires.
        setIntent(intent)
        sendOpenNoteExtrasIfPresent(intent)
    }

    private fun sendOpenNoteExtrasIfPresent(intent: Intent?) {
        val uid = intent?.getStringExtra("open_note_uid")
        val noteId = intent?.getStringExtra("open_note_id")
        val type = intent?.getStringExtra("open_note_type")
        if (uid != null && noteId != null) {
            methodChannel?.invokeMethod(
                "openNote",
                mapOf("uid" to uid, "noteId" to noteId, "type" to type)
            )
        }
    }
}
