package com.mahad.fastcompanion

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StrikethroughSpan
import android.view.View
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONObject

/**
 * A task shows a LIVE ticking countdown when it is due within this long.
 * Further away than this it shows static text like "2d 3h left" (refreshed
 * about every 30 minutes). Lower it, e.g. to 60L * 60 * 1000, if you'd rather
 * only tick during the last hour.
 */
private const val LIVE_COUNTDOWN_MAX_MS = 24L * 60 * 60 * 1000

/**
 * Feeds the scrolling list inside the widget. Android calls this service to
 * build each row on demand, which is what lets a small widget scroll through
 * a long note instead of cutting it off.
 */
class NotesWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        NotesWidgetFactory(applicationContext, intent)
}

private class NotesWidgetFactory(
    private val context: Context,
    intent: Intent
) : RemoteViewsService.RemoteViewsFactory {

    private val appWidgetId = intent.getIntExtra(
        AppWidgetManager.EXTRA_APPWIDGET_ID,
        AppWidgetManager.INVALID_APPWIDGET_ID
    )

    private var uid = ""
    private var noteId = ""
    private var type = "text"
    private var items: List<JSONObject> = emptyList()

    override fun onCreate() {}

    // Called whenever the provider calls notifyAppWidgetViewDataChanged().
    override fun onDataSetChanged() {
        uid = ""
        noteId = ""
        type = "text"
        items = emptyList()
        try {
            val raw = HomeWidgetPlugin.getData(context)
                .getString("payload_$appWidgetId", null)
            if (raw.isNullOrEmpty()) return

            val payload = JSONObject(raw)
            uid = payload.optString("uid")
            noteId = payload.optString("noteId")
            type = payload.optString("type", "text")

            val array = when (type) {
                "todo", "timed" -> payload.optJSONArray("todoList")
                "counter" -> payload.optJSONArray("counterList")
                else -> null
            }
            items = if (array == null) emptyList()
            else List(array.length()) { array.getJSONObject(it) }
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetFactory", "Failed to load list data", e)
        }
    }

    override fun onDestroy() {
        items = emptyList()
    }

    override fun getCount(): Int = items.size

    override fun getViewAt(position: Int): RemoteViews? {
        val item = items.getOrNull(position) ?: return null
        return if (type == "counter") counterRow(item, position) else todoRow(item, position)
    }

    private fun todoRow(item: JSONObject, position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_item_todo)

        val isDone = item.optBoolean("isDone", false)
        val text = item.optString("text")
        val styled = SpannableString(text)
        if (isDone && text.isNotEmpty()) {
            styled.setSpan(StrikethroughSpan(), 0, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        views.setTextViewText(R.id.item_text, styled)
        views.setTextColor(
            R.id.item_text,
            if (isDone) 0x80FFFFFF.toInt() else 0xFFFFFFFF.toInt()
        )
        views.setImageViewResource(
            R.id.item_check,
            if (isDone) R.drawable.ic_checkbox_checked else R.drawable.ic_checkbox_unchecked
        )

        // NEW: live countdown. A Chronometer is ticked by the launcher itself,
        // so it counts down every second without waking your app. It needs
        // Android 7.0+ (API 24) for count-down mode; older phones fall back
        // to the static text below.
        val liveMs = liveRemainingMs(item)
        if (liveMs != null && Build.VERSION.SDK_INT >= 24) {
            views.setViewVisibility(R.id.item_meta, View.GONE)
            views.setViewVisibility(R.id.item_countdown, View.VISIBLE)
            views.setChronometerCountDown(R.id.item_countdown, true)
            views.setChronometer(
                R.id.item_countdown,
                SystemClock.elapsedRealtime() + liveMs,
                "%s left",
                true
            )
        } else {
            views.setViewVisibility(R.id.item_countdown, View.GONE)
            val meta = formatMeta(item)
            if (meta.isNotEmpty()) {
                views.setTextViewText(R.id.item_meta, meta)
                views.setViewVisibility(R.id.item_meta, View.VISIBLE)
            } else {
                views.setViewVisibility(R.id.item_meta, View.GONE)
            }
        }

        views.setOnClickFillInIntent(R.id.todo_item_root, fillIn("toggleTodo", position, null))
        return views
    }

    private fun counterRow(item: JSONObject, position: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_item_counter)
        views.setTextViewText(R.id.counter_label, item.optString("label"))
        views.setTextViewText(R.id.counter_count, item.optInt("count", 0).toString())
        views.setOnClickFillInIntent(R.id.counter_minus, fillIn("adjustCounter", position, -1))
        views.setOnClickFillInIntent(R.id.counter_plus, fillIn("adjustCounter", position, 1))
        return views
    }

    private fun fillIn(host: String, index: Int, delta: Int?): Intent {
        val deltaPart = if (delta != null) "&delta=$delta" else ""
        return Intent().setData(
            Uri.parse(
                "notesWidget://$host?uid=${Uri.encode(uid)}&noteId=${Uri.encode(noteId)}&index=$index$deltaPart"
            )
        )
    }

    /**
     * Milliseconds left for an un-ticked task that is due soon enough to show
     * a live countdown, or null when it should show static text instead
     * (ticked, no due time, already expired, or too far away).
     */
    private fun liveRemainingMs(item: JSONObject): Long? {
        if (item.optBoolean("isDone", false) || item.isNull("dueMs")) return null
        val diff = item.getLong("dueMs") - System.currentTimeMillis()
        return if (diff > 0 && diff <= LIVE_COUNTDOWN_MAX_MS) diff else null
    }

    // Static text: used for ticked tasks (frozen time), tasks far in the
    // future, expired tasks, and as the fallback on very old phones.
    private fun formatMeta(item: JSONObject): String {
        val isDone = item.optBoolean("isDone", false)
        if (isDone && !item.isNull("remainingMs")) {
            return "${formatDuration(item.getLong("remainingMs"))} left"
        }
        if (!item.isNull("dueMs")) {
            val diff = item.getLong("dueMs") - System.currentTimeMillis()
            if (diff < 0) {
                // The app shows "Time expired" for timed tasks.
                return if (type == "timed") "Time expired"
                else "Overdue by ${formatDuration(-diff)}"
            }
            return "${formatDuration(diff)} left"
        }
        if (!item.isNull("remainingMs")) {
            return "${formatDuration(item.getLong("remainingMs"))} left"
        }
        return ""
    }

    // Matches the app's wording: "2d 3h", "5h 20m", "12m".
    private fun formatDuration(ms: Long): String {
        val totalMinutes = ms / 60000
        val d = totalMinutes / 1440
        val h = (totalMinutes % 1440) / 60
        val m = totalMinutes % 60
        return when {
            d >= 1 -> "${d}d ${h}h"
            h >= 1 -> "${h}h ${m}m"
            else -> "${m}m"
        }
    }

    override fun getLoadingView(): RemoteViews? = null
    override fun getViewTypeCount(): Int = 2
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}