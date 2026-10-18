package com.mahad.fastcompanion

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Receives widget taps and hands them to Dart.
 *
 * Deliberately not home_widget's own receiver: that one initialises Flutter on
 * the main thread and then routes the tap through WorkManager, and scheduling
 * that job is what makes the launcher rebuild both widgets a second later
 * (see [WidgetTapDispatcher]).
 */
class WidgetTapReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        WidgetTapDispatcher.dispatch(context, intent)
    }
}
