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

        // The widget's own refresh tick. Countdowns are plain text recomputed
        // at every rebind (a launcher-ticked Chronometer freezes at random
        // after rebinds, API 26+), so while a countdown is on screen we drive
        // our own refreshes: every minute boundary while a task is due within
        // 24h, every hour boundary while tasks are due further out, none
        // otherwise.
        const val ACTION_TICK = "com.mahad.fastcompanion.ACTION_TICK"

        // A task shows a per-minute countdown when due within this long.
        // Further away it shows static text like "2d 3h left" (hourly refresh).
        private const val LIVE_COUNTDOWN_MAX_MS = 24L * 60 * 60 * 1000

        // Keeps tick PendingIntents separate from the expiry-refresh one
        // (same action+component+requestCode would be the SAME PendingIntent).
        private const val TICK_REQUEST_CODE_OFFSET = 1_000_000

        // Dart stamps its post-save updateWidget broadcasts with this flag
        // (key + timestamp). Within SOFT_UPDATE_VALID_MS we may answer with a
        // list rebind only instead of replacing the whole RemoteViews — that
        // replacement is what made the widget flash for a frame after a tap.
        private const val SOFT_UPDATE_PREFIX = "soft_update_"
        private const val SOFT_UPDATE_VALID_MS = 10_000L
        private fun softUpdateKey(appWidgetId: Int) = "$SOFT_UPDATE_PREFIX$appWidgetId"

        // What the widget's FRAME shows (title/type/render mode), as opposed
        // to the list's contents. Stored after every full redraw; when it's
        // unchanged, a content update needs no full redraw.
        private fun chromeSigKey(appWidgetId: Int) = "chrome_sig_$appWidgetId"

        // The list ROWS as last drawn (todoList/counterList JSON). When both
        // the frame and these rows are unchanged, not even a list rebind is
        // needed — on some launchers ANY rebind blanks the list for a frame
        // (visible as a flash), so pointless rebinds are skipped entirely.
        private fun listSigKey(appWidgetId: Int) = "list_sig_$appWidgetId"
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
            editor.remove(chromeSigKey(id))
            editor.remove(listSigKey(id))
            editor.remove(softUpdateKey(id))
            editor.remove("sig_$id") // left over from the earlier shortcut version
            cancelExpiryRefresh(context, id)
            cancelNextTick(context, id)
        }
        editor.apply()
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_ITEM_CLICK -> {
                try {
                    handleItemClick(context, intent.data)
                } catch (e: Exception) {
                    android.util.Log.e("NotesWidgetProvider", "Tap handling failed", e)
                }
            }

            ACTION_TICK -> {
                val widgetId = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID
                )
                if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    try {
                        handleTick(context, widgetId)
                    } catch (e: Exception) {
                        android.util.Log.e("NotesWidgetProvider", "Tick handling failed", e)
                    }
                }
            }

            else -> super.onReceive(context, intent)
        }
    }

    /**
     * Self-driven countdown refresh: rebind the list (which recomputes every
     * row's text from the CURRENT time), then schedule the next tick. Only a
     * data-changed notification, NOT a full redraw — keeps the list's scroll
     * position.
     */
    private fun handleTick(context: Context, appWidgetId: Int) {
        AppWidgetManager.getInstance(context)
            .notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        val raw = HomeWidgetPlugin.getData(context).getString("payload_$appWidgetId", null)
        if (raw.isNullOrEmpty()) {
            cancelNextTick(context, appWidgetId)
            return
        }
        scheduleNextTick(context, appWidgetId, JSONObject(raw))
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
            // Rebind only: the payload is untouched, so there's nothing to
            // redraw beyond the list itself — and a full redraw here would
            // just flash the widget for a frame.
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
            val prefs = HomeWidgetPlugin.getData(context)
            val payloadStr = prefs.getString("payload_$appWidgetId", null)

            // ---- flash-free content updates --------------------------------
            // Dart stamps the broadcasts it sends after saving a tap with a
            // short-lived flag. When such an update arrives AND the widget's
            // frame (title/type/render mode) is unchanged, the list rebind
            // alone shows everything that changed — replacing the whole
            // RemoteViews is what made the widget flash for a frame after a
            // tap. If even the list ROWS are unchanged, nothing is redrawn at
            // all: on some launchers any rebind blanks the list for a frame,
            // so a pointless rebind is worse than no update. System requests
            // (boot, launcher restart, first placement) carry no flag, so they
            // always get the full redraw and the widget can never be blank.
            val isSoft = consumeSoftFlag(prefs, appWidgetId)
            if (isSoft && payloadStr != null) {
                val storedSig = prefs.getString(chromeSigKey(appWidgetId), null)
                if (storedSig != null && storedSig == chromeSignature(payloadStr)) {
                    val newSig = listSignature(payloadStr)
                    val rowsChanged =
                        prefs.getString(listSigKey(appWidgetId), null) != newSig
                    try {
                        val payload = JSONObject(payloadStr)
                        if (payload.optString("type") == "todo" ||
                            payload.optString("type") == "timed"
                        ) {
                            scheduleExpiryRefresh(context, appWidgetId, payload)
                            scheduleNextTick(context, appWidgetId, payload)
                        }
                    } catch (e: Exception) {
                        android.util.Log.e("NotesWidgetProvider", "Soft refresh failed", e)
                    }
                    if (rowsChanged) {
                        prefs.edit().putString(listSigKey(appWidgetId), newSig).apply()
                        appWidgetManager.notifyAppWidgetViewDataChanged(
                            appWidgetId,
                            R.id.widget_list
                        )
                    }
                    // Same frame, and (if !rowsChanged) same rows: nothing to
                    // redraw — a pointless rebind would just flash the list.
                    return
                }
            }

            val views = RemoteViews(context.packageName, R.layout.notes_widget_layout)

            views.setViewVisibility(R.id.row_text, View.GONE)
            views.setViewVisibility(R.id.widget_list, View.GONE)

            if (payloadStr.isNullOrEmpty()) {
                cancelExpiryRefresh(context, appWidgetId)
                cancelNextTick(context, appWidgetId)
                views.setTextViewText(R.id.widget_title, "No note pinned")
                views.setViewVisibility(R.id.btn_edit, View.GONE)
                views.setTextViewText(
                    R.id.row_text,
                    "This note was deleted or its account was signed out. Long-press a note in the app to pin another."
                )
                views.setViewVisibility(R.id.row_text, View.VISIBLE)
                appWidgetManager.updateAppWidget(appWidgetId, views)
                prefs.edit()
                    .putString(chromeSigKey(appWidgetId), "blank")
                    .putString(listSigKey(appWidgetId), "[]")
                    .apply()
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
                    scheduleNextTick(context, appWidgetId, payload)
                }

                "counter" -> {
                    cancelExpiryRefresh(context, appWidgetId)
                    cancelNextTick(context, appWidgetId)
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
                    cancelNextTick(context, appWidgetId)
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
            // Remember what the frame shows and which rows are on screen, so a
            // later content-only update can skip the (flashing) redraws — see
            // the soft path above.
            prefs.edit()
                .putString(chromeSigKey(appWidgetId), chromeSignature(payloadStr))
                .putString(listSigKey(appWidgetId), listSignature(payloadStr))
                .apply()
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to update widget", e)
        }
    }

    /**
     * True when Dart flagged this update as a post-save content refresh
     * (see _requestContentUpdate in home_widget_service.dart). Consumes the
     * flag, so a stale one can never make a later SYSTEM update go soft.
     */
    private fun consumeSoftFlag(prefs: android.content.SharedPreferences, appWidgetId: Int): Boolean {
        val key = softUpdateKey(appWidgetId)
        val ts = (prefs.all[key] as? Number)?.toLong() ?: 0L
        prefs.edit().remove(key).apply()
        return ts > 0 && System.currentTimeMillis() - ts < SOFT_UPDATE_VALID_MS
    }

    /**
     * The widget's FRAME: everything a full redraw (but not a list rebind)
     * would change. Note the body is only part of the frame for text notes —
     * for todo/timed/counter notes the body is just a preview of the list,
     * which a rebind already reflects.
     */
    private fun chromeSignature(payloadStr: String): String = try {
        val p = JSONObject(payloadStr)
        val type = p.optString("type", "text")
        val body = if (type == "text") p.optString("body", "No content") else ""
        "$type\u0001${p.optString("title", "Untitled")}\u0001${p.optString("noteId")}\u0001$body"
    } catch (e: Exception) {
        "corrupt"
    }

    /**
     * The list ROWS exactly as they'd be rendered (todoList/counterList JSON).
     * Compared before a content update decides to rebind: identical rows mean
     * a rebind would only flash the list for no visual change. Raw
     * remaining/due timestamps are fine here — a soft update only fires when
     * Dart saw a real difference, so any mismatch it sends through is a real
     * one.
     */
    private fun listSignature(payloadStr: String): String = try {
        val p = JSONObject(payloadStr)
        when (p.optString("type")) {
            "counter" -> p.optJSONArray("counterList")?.toString() ?: "[]"
            else -> p.optJSONArray("todoList")?.toString() ?: "[]"
        }
    } catch (e: Exception) {
        "corrupt"
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
    // ONE refresh just after the soonest due time among un-ticked tasks.
    // Exact (and allow-while-idle) when the SCHEDULE_EXACT_ALARM permission
    // is granted, so the flip to "Time expired" happens within a second even
    // with the screen off. Falls back to setAndAllowWhileIdle — still fires
    // in Doze, permission-free — when Android 14+ has denied exact alarms.

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
                val triggerAt = next + 1000
                val canExact = Build.VERSION.SDK_INT >= 31 && alarmManager.canScheduleExactAlarms()
                if (canExact) {
                    alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC, triggerAt, pending)
                } else {
                    alarmManager.setAndAllowWhileIdle(AlarmManager.RTC, triggerAt, pending)
                }
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

    // ---- self-driven countdown ticks --------------------------------------
    // Countdown text is only as fresh as the last rebind, so while one is on
    // screen we keep rebinds coming on our own: at every MINUTE boundary
    // while an unchecked task is due within 24h (the per-minute window), at
    // every HOUR boundary when tasks are due but only further out, and never
    // when nothing is ticking. Exact when allowed, otherwise
    // setAndAllowWhileIdle (permission-free, still fires in Doze).

    private fun tickPendingIntent(context: Context, appWidgetId: Int): PendingIntent {
        val intent = Intent(context, NotesWidgetProvider::class.java).apply {
            action = ACTION_TICK
            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        }
        return PendingIntent.getBroadcast(
            context,
            appWidgetId + TICK_REQUEST_CODE_OFFSET,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun scheduleNextTick(context: Context, appWidgetId: Int, payload: JSONObject) {
        try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pending = tickPendingIntent(context, appWidgetId)
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
            if (next == Long.MAX_VALUE) return

            // Next minute boundary in the live window, else next hour
            // boundary (static "2d 3h left" text only needs hourly accuracy).
            val triggerAt = if (next - now <= LIVE_COUNTDOWN_MAX_MS) {
                (now / 60_000 + 1) * 60_000
            } else {
                (now / 3_600_000 + 1) * 3_600_000
            }
            val canExact = Build.VERSION.SDK_INT >= 31 && alarmManager.canScheduleExactAlarms()
            if (canExact) {
                alarmManager.setExactAndAllowWhileIdle(AlarmManager.RTC, triggerAt, pending)
            } else {
                alarmManager.setAndAllowWhileIdle(AlarmManager.RTC, triggerAt, pending)
            }
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to schedule countdown tick", e)
        }
    }

    private fun cancelNextTick(context: Context, appWidgetId: Int) {
        try {
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            alarmManager.cancel(tickPendingIntent(context, appWidgetId))
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to cancel countdown tick", e)
        }
    }
}