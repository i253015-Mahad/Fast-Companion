package com.mahad.fastcompanion

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * Scrollable widget with live countdowns and a collapsible "checked items"
 * group. This class sets up the list and handles the title, placeholder
 * messages, text notes, the edit button, taps on list rows, and a one-shot
 * refresh for when a task's countdown reaches zero.
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
            cancelExpiryRefresh(context, id)
        }
        editor.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_ITEM_CLICK) {
            handleItemClick(context, intent.data)
            return
        }
        super.onReceive(context, intent)
    }

    /**
     * Taps on list rows arrive here.
     *  - the checked-items header is handled right here (instant, no Dart);
     *  - everything else (tick a task, + / - on a counter) is passed on to
     *    home_widget's background receiver exactly as before.
     */
    private fun handleItemClick(context: Context, uri: Uri?) {
        if (uri == null) return

        if (uri.host.equals("toggleChecked", ignoreCase = true)) {
            val widgetId = uri.getQueryParameter("widgetId")?.toIntOrNull() ?: return
            val prefs = HomeWidgetPlugin.getData(context)
            val key = checkedExpandedKey(widgetId)
            val isOpen = prefs.getBoolean(key, DEFAULT_CHECKED_EXPANDED)
            prefs.edit().putBoolean(key, !isOpen).apply()
            // Only the list data changed, so refresh just the list. That keeps
            // the scroll position better than a full redraw.
            AppWidgetManager.getInstance(context)
                .notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list)
        } else {
            try {
                HomeWidgetBackgroundIntent.getBroadcast(context, uri).send()
            } catch (e: PendingIntent.CanceledException) {
                android.util.Log.e("NotesWidgetProvider", "Could not forward widget tap", e)
            }
        }
    }

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

        // CHANGED: row taps now go to THIS provider (handleItemClick above),
        // which handles the checked-items header itself and forwards every
        // other tap to home_widget. Must be MUTABLE so each row can add its URI.
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