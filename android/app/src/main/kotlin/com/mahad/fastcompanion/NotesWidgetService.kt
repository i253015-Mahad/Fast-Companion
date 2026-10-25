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
        // The launcher pulling this list is a signal that can arrive WITHOUT
        // NotesWidgetProvider having been entered first — after the launcher's
        // own process restarts, for instance. Treat it as one more chance to
        // revive a countdown chain something (a force-stop) killed: the
        // provider answers with alarms only, never with a rebind, so feeding
        // this back can't loop.
        try {
            context.sendBroadcast(
                Intent(context, NotesWidgetProvider::class.java)
                    .setAction(NotesWidgetProvider.ACTION_REARM)
                    // Without this the hook is inert exactly when it matters:
                    // a force-stopped package is in the stopped state, and a
                    // plain broadcast is silently dropped for it. This flag is
                    // what lets "the launcher is asking us for rows again"
                    // revive a chain while we are still marked stopped, instead
                    // of only once something else has already woken us.
                    .addFlags(Intent.FLAG_INCLUDE_STOPPED_PACKAGES)
            )
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetService", "Re-arm broadcast failed", e)
        }

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
        views.setFloat(R.id.item_text, "setAlpha", if (isDone) 0.5f else 1.0f)
        views.setImageViewResource(
            R.id.item_check,
            if (isDone) R.drawable.ic_checkbox_checked else R.drawable.ic_checkbox_unchecked
        )

        // The countdown. Prefer a Chronometer: it is a TextView whose value the
        // LAUNCHER derives from SystemClock every second, so it keeps counting
        // even while our process has been force-stopped — which is exactly what
        // this phone's nightly cleaner does (see rescheduleAll in the provider).
        // Plain text remains the fallback for everything a Chronometer shouldn't
        // carry: past deadlines, the last minute, done items, static durations,
        // and API < 24 where countdown mode doesn't exist.
        val live = liveRemainingMs(item)
        if (live != null && Build.VERSION.SDK_INT >= 24) {
            // ORDER MATTERS. Chronometer only ticks while
            // mVisible && mStarted && isShown() (Chronometer.updateRunning()),
            // and it re-checks that only when updateRunning() happens to run —
            // i.e. on setStarted, on a visibility change, or on attach/detach.
            // A ListView binds rows before attaching them, so setStarted can
            // land while the row is still hidden. Making the view visible AFTER
            // setStarted fires onVisibilityChanged, giving updateRunning() a
            // second chance at a moment when the row is more likely shown.
            views.setChronometerCountDown(R.id.item_countdown, true)
            views.setChronometer(
                R.id.item_countdown,
                SystemClock.elapsedRealtime() + live,
                "%s left",
                true
            )
            views.setViewVisibility(R.id.item_countdown, View.VISIBLE)
            views.setViewVisibility(R.id.item_meta, View.GONE)
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

    /**
     * Milliseconds until this task's deadline, or null when there is nothing a
     * Chronometer should be counting.
     *
     * Only strictly-future deadlines at least a minute out qualify. Below that,
     * [formatMeta] is about to show "less than a minute left" and the expiry
     * alarm is about to rebind the row to "Time expired" — letting a Chronometer
     * run into zero instead would trade a deliberate flip for a bare "0:00
     * left". Past deadlines aren't countdowns either: those are the text's job.
     *
     * This is the same 60_000 threshold formatMeta uses, so exactly one of the
     * two ever renders any given row.
     */
    private fun liveRemainingMs(item: JSONObject): Long? {
        if (item.isNull("dueMs")) return null
        val diff = item.getLong("dueMs") - System.currentTimeMillis()
        return if (diff >= 60_000) diff else null
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
            // The expiry alarm flips it to "Time expired" right at the
            // deadline, so the last minute never needs a negative/zero count.
            if (diff < 60_000) return "less than a minute left"
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
            // The last hour of a multi-day countdown holds no whole hour, so
            // `h` read 0 and "1d 0h" threw that hour away entirely. The
            // minutes are still there — show those instead. This has to say
            // the same thing as formatCountdown() in note_preview.dart, which
            // the in-app timed-task screen uses for the same task.
            d >= 1 -> if (h == 0L) "${d}d ${m}m" else "${d}d ${h}h"
            h >= 1 -> "${h}h ${m}m"
            else -> "${m}m"
        }
    }

    override fun getLoadingView(): RemoteViews? =
    RemoteViews(context.packageName, R.layout.widget_item_loading)
    // Three row layouts: task, counter, and the checked-items header.
    override fun getViewTypeCount(): Int = 3
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = false
}