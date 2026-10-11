package com.mahad.fastcompanion

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

// How many widget taps have been handed to Dart but not finished yet.
// Dart (widget_background_main.dart) reads and lowers this number, and uses it
// to avoid redrawing the widget with a half-finished value in the middle of a
// quick series of taps.
private const val PENDING_TAPS_KEY = "pending_taps"
private const val PENDING_TAPS_TIME_KEY = "pending_taps_ts"

// If the last tap is older than this, assume the counter is stale and restart.
private const val PENDING_TAPS_STALE_MS = 30_000L

/**
 * Scrollable widget with live countdowns and a collapsible "checked items"
 * group.
 *
 * Taps update the widget INSTANTLY (see applyOptimisticTap). That only
 * refreshes the list. Every system update request (onUpdate) always answers
 * with a full redraw, which is the safe thing to do: skipping it made the
 * widget go blank.
 */
class NotesWidgetProvider : AppWidgetProvider() {

    companion object {
        // Every tap on a list row comes here first (see attachList).
        const val ACTION_ITEM_CLICK = "com.mahad.fastcompanion.ACTION_ITEM_CLICK"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (widgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, widgetId)
        }
    }

    // Remove a deleted widget's stored note, open/closed state and alarm.
    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        val editor = HomeWidgetPlugin.getData(context).edit()
        for (id in appWidgetIds) {
            editor.remove("payload_$id")
            editor.remove(checkedExpandedKey(id))
            editor.remove("sig_$id") // left over from the earlier shortcut version
            cancelExpiryRefresh(context, id)
        }
        editor.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_ITEM_CLICK) {
            try {
                handleItemClick(context, intent.data)
            } catch (e: Exception) {
                android.util.Log.e("NotesWidgetProvider", "Tap handling failed", e)
            }
            return
        }
        super.onReceive(context, intent)
    }

    /**
     * Taps on list rows arrive here.
     *  - the checked-items header is handled right here (instant, no Dart);
     *  - ticking a task or pressing + / - first updates the widget on the spot,
     *    then hands the real work (saving to Firebase) to Dart as before.
     */
    private fun handleItemClick(context: Context, uri: Uri?) {
        if (uri == null) return

        if (uri.host.equals("toggleChecked", ignoreCase = true)) {
            val widgetId = uri.getQueryParameter("widgetId")?.toIntOrNull() ?: return
            val prefs = HomeWidgetPlugin.getData(context)
            val key = checkedExpandedKey(widgetId)
            val isOpen = prefs.getBoolean(key, DEFAULT_CHECKED_EXPANDED)
            prefs.edit().putBoolean(key, !isOpen).apply()
            AppWidgetManager.getInstance(context)
                .notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list)
        } else {
            // 1) show the change immediately
            applyOptimisticTap(context, uri)
            // 2) remember that Dart still owes us a result
            markTapPending(context)
            // 3) do the real work (Firebase etc.) in the background
            try {
                HomeWidgetBackgroundIntent.getBroadcast(context, uri).send()
            } catch (e: PendingIntent.CanceledException) {
                android.util.Log.e("NotesWidgetProvider", "Could not forward widget tap", e)
            }
        }
    }

    private fun markTapPending(context: Context) {
        val prefs = HomeWidgetPlugin.getData(context)
        val now = System.currentTimeMillis()
        val last = (prefs.all[PENDING_TAPS_TIME_KEY] as? Number)?.toLong() ?: 0L
        val current = if (now - last > PENDING_TAPS_STALE_MS) 0
        else (prefs.all[PENDING_TAPS_KEY] as? Number)?.toInt() ?: 0
        prefs.edit()
            .putInt(PENDING_TAPS_KEY, current + 1)
            .putLong(PENDING_TAPS_TIME_KEY, now)
            .apply()
    }

    /**
     * Applies the tap to the widget's stored copy of the note and refreshes
     * just the list, so the number or tick changes the instant you tap. When
     * Dart finishes saving, it writes the real value over this one.
     */
    private fun applyOptimisticTap(context: Context, uri: Uri) {
        val uid = uri.getQueryParameter("uid") ?: return
        val noteId = uri.getQueryParameter("noteId") ?: return
        val index = uri.getQueryParameter("index")?.toIntOrNull() ?: return
        val isToggle = uri.host.equals("toggleTodo", ignoreCase = true)
        val isAdjust = uri.host.equals("adjustCounter", ignoreCase = true)
        if (!isToggle && !isAdjust) return
        val delta = uri.getQueryParameter("delta")?.toIntOrNull() ?: 0

        val prefs = HomeWidgetPlugin.getData(context)
        val manager = AppWidgetManager.getInstance(context)
        val ids = manager.getAppWidgetIds(ComponentName(context, NotesWidgetProvider::class.java))

        // Every widget showing this note changes, not just the one tapped.
        for (id in ids) {
            val key = "payload_$id"
            val raw = prefs.getString(key, null)
            if (raw.isNullOrEmpty()) continue
            try {
                val payload = JSONObject(raw)
                if (payload.optString("uid") != uid || payload.optString("noteId") != noteId) continue

                if (isToggle) {
                    val array = payload.optJSONArray("todoList") ?: continue
                    val item = array.optJSONObject(index) ?: continue
                    val nowDone = !item.optBoolean("isDone", false)
                    item.put("isDone", nowDone)
                    // Same rule as the app: ticking freezes the remaining time,
                    // unticking clears it.
                    if (nowDone && !item.isNull("dueMs")) {
                        val left = item.getLong("dueMs") - System.currentTimeMillis()
                        item.put("remainingMs", if (left > 0) left else 0L)
                    } else if (!nowDone) {
                        item.put("remainingMs", JSONObject.NULL)
                    }
                } else {
                    val array = payload.optJSONArray("counterList") ?: continue
                    val item = array.optJSONObject(index) ?: continue
                    item.put("count", item.optInt("count", 0) + delta)
                }

                prefs.edit().putString(key, payload.toString()).apply()
                manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
            } catch (e: Exception) {
                android.util.Log.e("NotesWidgetProvider", "Optimistic update failed", e)
            }
        }
    }

    // Always a FULL redraw. Android asks for this on every onUpdate, and
    // answering with nothing is what made the widget go blank.
    private fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            val views = RemoteViews(context.packageName, R.layout.notes_widget_layout)

            views.setViewVisibility(R.id.row_text, View.GONE)
            views.setViewVisibility(R.id.widget_list, View.GONE)

            val prefs = HomeWidgetPlugin.getData(context)
            val payloadStr = prefs.getString("payload_$appWidgetId", null)

            if (payloadStr.isNullOrEmpty()) {
                cancelExpiryRefresh(context, appWidgetId)
                views.setTextViewText(R.id.widget_title, "No note pinned")
                views.setViewVisibility(R.id.btn_edit, View.GONE)
                views.setTextViewText(
                    R.id.row_text,
                    "This note was deleted or its account was signed out. Long-press a note in the app to pin another."
                )
                views.setViewVisibility(R.id.row_text, View.VISIBLE)
                appWidgetManager.updateAppWidget(appWidgetId, views)
                return
            }

            val payload = JSONObject(payloadStr)
            val uid = payload.optString("uid")
            val noteId = payload.optString("noteId")
            val type = payload.optString("type", "text")
            val title = payload.optString("title", "Untitled")

            views.setTextViewText(R.id.widget_title, title)

            when (type) {
                "todo", "timed" -> {
                    val count = payload.optJSONArray("todoList")?.length() ?: 0
                    if (count == 0) {
                        views.setViewVisibility(R.id.row_text, View.VISIBLE)
                        views.setTextViewText(R.id.row_text, "No items yet")
                    } else {
                        attachList(context, views, appWidgetId)
                    }
                    scheduleExpiryRefresh(context, appWidgetId, payload)
                }

                "counter" -> {
                    cancelExpiryRefresh(context, appWidgetId)
                    val count = payload.optJSONArray("counterList")?.length() ?: 0
                    if (count == 0) {
                        views.setViewVisibility(R.id.row_text, View.VISIBLE)
                        views.setTextViewText(R.id.row_text, "No counters yet")
                    } else {
                        attachList(context, views, appWidgetId)
                    }
                }

                else -> {
                    cancelExpiryRefresh(context, appWidgetId)
                    val body = payload.optString("body", "No content")
                    views.setViewVisibility(R.id.row_text, View.VISIBLE)
                    views.setTextViewText(R.id.row_text, body)
                }
            }

            // Edit button: opens the app straight into this note.
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null && noteId.isNotEmpty()) {
                launchIntent.putExtra("open_note_uid", uid)
                launchIntent.putExtra("open_note_id", noteId)
                launchIntent.putExtra("open_note_type", type)
                launchIntent.addFlags(
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP
                )
                val editPendingIntent = PendingIntent.getActivity(
                    context,
                    noteId.hashCode(),
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setViewVisibility(R.id.btn_edit, View.VISIBLE)
                views.setOnClickPendingIntent(R.id.btn_edit, editPendingIntent)
            } else {
                views.setViewVisibility(R.id.btn_edit, View.GONE)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
            appWidgetManager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to update widget", e)
        }
    }

    /** Shows the scrolling list and wires up tapping on its rows. */
    private fun attachList(context: Context, views: RemoteViews, appWidgetId: Int) {
        views.setViewVisibility(R.id.widget_list, View.VISIBLE)

        val serviceIntent = Intent(context, NotesWidgetService::class.java).apply {
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
            data = Uri.parse(toUri(Intent.URI_INTENT_SCHEME))
        }
        views.setRemoteAdapter(R.id.widget_list, serviceIntent)

        // Row taps go to THIS provider (handleItemClick above). Must be MUTABLE
        // so each row can add its own URI.
        val template = Intent(context, NotesWidgetProvider::class.java).apply {
            action = ACTION_ITEM_CLICK
        }
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= 31) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        views.setPendingIntentTemplate(
            R.id.widget_list,
            PendingIntent.getBroadcast(context, appWidgetId, template, flags)
        )
    }

    // ---- expiry refresh -------------------------------------------------
    // A ticking countdown keeps counting past zero. To avoid that, schedule
    // ONE refresh just after the soonest due time among un-ticked tasks. It
    // is an inexact alarm (no special permission), so Android may delay it a
    // little when the phone is idle.

    private fun expiryPendingIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, NotesWidgetProvider::class.java).apply {
            action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, intArrayOf(appWidgetId))
        }
        return PendingIntent.getBroadcast(
            context,
            appWidgetId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun scheduleExpiryRefresh(context: Context, appWidgetId: Int, payload: JSONObject) {
        try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pending = expiryPendingIntent(context, appWidgetId)
            alarmManager.cancel(pending)

            val items = payload.optJSONArray("todoList") ?: return
            val now = System.currentTimeMillis()
            var next = Long.MAX_VALUE
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                if (item.optBoolean("isDone", false) || item.isNull("dueMs")) continue
                val due = item.getLong("dueMs")
                if (due > now && due < next) next = due
            }
            if (next != Long.MAX_VALUE) {
                alarmManager.set(AlarmManager.RTC, next + 1000, pending)
            }
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to schedule expiry refresh", e)
        }
    }

    private fun cancelExpiryRefresh(context: Context, appWidgetId: Int) {
        try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(expiryPendingIntent(context, appWidgetId))
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to cancel expiry refresh", e)
        }
    }
}