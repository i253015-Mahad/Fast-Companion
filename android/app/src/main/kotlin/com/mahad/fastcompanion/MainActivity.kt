package com.mahad.fastcompanion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val openNoteChannel = "notes_widget_open_note"
    private var methodChannel: MethodChannel? = null

    // Cold start: Dart isn't listening yet, so we hold the request here and
    // Dart asks for it ("getInitialNote") once it's ready.
    private var pendingOpenNote: Map<String, String?>? = null

    // Since API 26 a manifest receiver cannot hear ACTION_USER_PRESENT, so
    // relaying it falls to whichever component is alive when the phone is
    // unlocked — which is this activity whenever the app is in memory. The
    // widget provider cannot listen for itself, because a broadcast to a
    // stopped package is exactly what it would not receive.
    //
    // This is a nicety, not the fix: the countdown is guaranteed fresh by the
    // RTC_WAKEUP heartbeat regardless. All this buys is that the value is
    // exact the instant the phone is picked up instead of up to 15 minutes
    // old.
    private val unlockRelay = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != Intent.ACTION_USER_PRESENT) return
            context.sendBroadcast(
                Intent(context, NotesWidgetProvider::class.java)
                    .setAction(NotesWidgetProvider.ACTION_UNLOCK_REFRESH)
            )
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val filter = IntentFilter(Intent.ACTION_USER_PRESENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(unlockRelay, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            registerReceiver(unlockRelay, filter)
        }
    }

    override fun onDestroy() {
        // Leaking this receiver keeps the activity alive for as long as the
        // process lives, so it has to go.
        unregisterReceiver(unlockRelay)
        super.onDestroy()
    }

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