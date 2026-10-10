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
 * Should the "checked items" group start open? false = hidden (arrow up),
 * true = shown (arrow down). The provider uses the same default.
 */
internal const val DEFAULT_CHECKED_EXPANDED = false

/** Where each widget remembers whether its checked items are open. */
internal fun checkedExpandedKey(appWidgetId: Int) = "checked_expanded_$appWidgetId"

/**
 * A task shows a LIVE ticking countdown when it is due within this long.
 * Further away than this it shows static text like "2d 3h left".
 */
private const val LIVE_COUNTDOWN_MAX_MS = 24L * 60 * 60 * 1000

/** One line in the widget list. */
private sealed class Row {
    /** A task or counter. [index] is its position in the SAVED note, which is
     *  what the Dart code needs when you tap it. */
    class Item(val index: Int, val json: JSONObject) : Row()

    /** The "⌃ x checked items" line. */
    class CheckedHeader(val count: Int, val expanded: Boolean) : Row()
}

/**
 * Feeds the scrolling list inside the widget. Android calls this service to
 * build each row on demand.
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
    private var rows: List<Row> = emptyList()

    override fun onCreate() {}

    // Called whenever the provider calls notifyAppWidgetViewDataChanged().
    override fun onDataSetChanged() {
        uid = ""
        noteId = ""
        type = "text"
        rows = emptyList()
        try {
            val prefs = HomeWidgetPlugin.getData(context)
            val raw = prefs.getString("payload_$appWidgetId", null)
            if (raw.isNullOrEmpty()) return

            val payload = JSONObject(raw)
            uid = payload.optString("uid")
            noteId = payload.optString("noteId")
            type = payload.optString("type", "text")

            rows = when (type) {
                "todo", "timed" -> {
                    val array = payload.optJSONArray("todoList")
                    val all = if (array == null) emptyList()
                    else List(array.length()) { Row.Item(it, array.getJSONObject(it)) }

                    // Unchecked first, then a header, then (if open) the
                    // checked ones. Each keeps its ORIGINAL index so tapping
                    // it still toggles the right task.
                    val unchecked = all.filter { !it.json.optBoolean("isDone", false) }
                    val checked = all.filter { it.json.optBoolean("isDone", false) }
                    val expanded = prefs.getBoolean(
                        checkedExpandedKey(appWidgetId),
                        DEFAULT_CHECKED_EXPANDED
                    )

                    buildList<Row> {
                        addAll(unchecked)
                        if (checked.isNotEmpty()) {
                            add(Row.CheckedHeader(checked.size, expanded))
                            if (expanded) addAll(checked)
                        }
                    }
                }

                "counter" -> {
                    val array = payload.optJSONArray("counterList")
                    if (array == null) emptyList()
                    else List(array.length()) { Row.Item(it, array.getJSONObject(it)) }
                }

                else -> emptyList()
            }
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetFactory", "Failed to load list data", e)
        }
    }

    override fun onDestroy() {
        rows = emptyList()
    }

    override fun getCount(): Int = rows.size

    override fun getViewAt(position: Int): RemoteViews? {
        val row = rows.getOrNull(position) ?: return null
        return when (row) {
            is Row.CheckedHeader -> headerRow(row)
            is Row.Item ->
                if (type == "counter") counterRow(row.json, row.index)
                else todoRow(row.json, row.index)
        }
    }

    private fun headerRow(row: Row.CheckedHeader): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_item_checked_header)
        views.setTextViewText(
            R.id.checked_label,
            if (row.count == 1) "1 checked item" else "${row.count} checked items"
        )
        // Arrow UP = hidden, arrow DOWN = shown.
        views.setImageViewResource(
            R.id.checked_arrow,
            if (row.expanded) R.drawable.ic_chevron_down else R.drawable.ic_chevron_up
        )
        // Handled inside the app's own provider (instant, no Dart needed).
        views.setOnClickFillInIntent(
            R.id.checked_header_root,
            Intent().setData(Uri.parse("notesWidget://toggleChecked?widgetId=$appWidgetId"))
        )
        return views
    }

    private fun todoRow(item: JSONObject, index: Int): RemoteViews {
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

        // Live countdown (Chronometer is ticked by the launcher, not the app).
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

        views.setOnClickFillInIntent(R.id.todo_item_root, fillIn("toggleTodo", index, null))
        return views
    }

    private fun counterRow(item: JSONObject, index: Int): RemoteViews {
        val views = RemoteViews(context.packageName, R.layout.widget_item_counter)
        views.setTextViewText(R.id.counter_label, item.optString("label"))
        views.setTextViewText(R.id.counter_count, item.optInt("count", 0).toString())
        views.setOnClickFillInIntent(R.id.counter_minus, fillIn("adjustCounter", index, -1))
        views.setOnClickFillInIntent(R.id.counter_plus, fillIn("adjustCounter", index, 1))
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

    private fun liveRemainingMs(item: JSONObject): Long? {
        if (item.optBoolean("isDone", false) || item.isNull("dueMs")) return null
        val diff = item.getLong("dueMs") - System.currentTimeMillis()
        return if (diff > 0 && diff <= LIVE_COUNTDOWN_MAX_MS) diff else null
    }

    private fun formatMeta(item: JSONObject): String {
        val isDone = item.optBoolean("isDone", false)
        if (isDone && !item.isNull("remainingMs")) {
            return "${formatDuration(item.getLong("remainingMs"))} left"
        }
        if (!item.isNull("dueMs")) {
            val diff = item.getLong("dueMs") - System.currentTimeMillis()
            if (diff < 0) {
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
    // Three row layouts: task, counter, and the checked-items header.
    override fun getViewTypeCount(): Int = 3
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}