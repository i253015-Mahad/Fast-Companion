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
import android.os.Handler
import android.os.Looper
import android.os.Message
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
 * refreshes the list. Once the tap settles, both Dart's save and the OS's own
 * follow-up update request ask for content the widget already has — updateWidget
 * recognises those and skips the re-inflate, which is what flashed the widget a
 * second after each tap. A request carrying neither marker still gets a full
 * redraw, since skipping that is what once made the widget go blank.
 */
class NotesWidgetProvider : AppWidgetProvider() {

    companion object {
        // Every tap on a list row comes here first (see attachList).
        const val ACTION_ITEM_CLICK = "com.mahad.fastcompanion.ACTION_ITEM_CLICK"

        // The probe on its own, outside the tap path: ask whether the launcher
        // still holds this widget's views and repair it if not. Useful by hand —
        // `adb shell am broadcast -a com.mahad.fastcompanion.ACTION_REPAINT
        // --ei android.appwidget.extra.AppWidgetId 82` — and harmless, since
        // it only redraws when the answer says a redraw is owed.
        const val ACTION_REPAINT = "com.mahad.fastcompanion.ACTION_REPAINT"

        // The launcher can throw a widget's RemoteViews away when the provider
        // package is touched — this one does it ~450ms after some taps that
        // run Dart — and re-inflates the layout defaults in their place. The
        // widget then reads its placeholder although the note is still pinned,
        // and nothing in the system tells us: our stored signatures still say
        // the widget is up to date, which is exactly why every later skip used
        // to leave it stranded. See the probe in scheduleRepaint.
        //
        // Deliberately a Handler and not an AlarmManager alarm. Alarms for a
        // cached app are inexact, and one of those landed four seconds late on
        // the very device this bug was found on — four seconds of blank widget
        // where there used to be a permanently blank one. A tap always leaves
        // this process running for a good while afterwards (the WorkManager job
        // that boots Dart and saves takes seconds), so a posted message simply
        // arrives, on time.

        // How long after the tap the probe goes out. The drop is a fraction of
        // a second behind the tap — measured at 440-470ms on this device — so
        // this lands just after it. Before the drop the probe would prove
        // nothing, because the launcher services the tap's own rebind a moment
        // earlier.
        private const val REPAINT_DELAY_MS = 700L

        // How long the probe gets to come back before we conclude it won't.
        // Generous on purpose: mistaking a slow launcher for a dropping one
        // costs a redraw the widget did not need, and that redraw is a flash.
        private const val REPAINT_SETTLE_MS = 600L

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

        // Dart stamps these once per app launch (see ensureWidgetsDrawn in
        // home_widget_service.dart). They mean "check whether the launcher
        // still holds our views"; the provider only repaints when that's
        // provably not the case, so an ordinary launch draws nothing.
        private const val VERIFY_PREFIX = "verify_"
        private const val VERIFY_UPDATE_VALID_MS = 60_000L
        private fun verifyKey(appWidgetId: Int) = "$VERIFY_PREFIX$appWidgetId"

        // RemoteViews live ONLY inside the launcher — nothing on our side
        // keeps them alive. Replacing this app's APK (which is what every
        // `flutter install` does, and what every store update does) makes the
        // launcher drop ours and fall back to the layout's defaults, i.e. the
        // widget sits there showing "no notes pinned" although the note is
        // still pinned. The signatures stored above then claim it is already
        // up to date, so every later SKIP is what keeps it blank. Recording
        // the build we last drew under is the one thing that lets us tell a
        // skip that is safe from one that strands the widget.
        private fun drawnBuildKey(appWidgetId: Int) = "drawn_build_$appWidgetId"
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (widgetId in appWidgetIds) {
            // Safety net for the probe below. A probe that never ran — the
            // process dying in the sub-second window before its Handler fired
            // — leaves its marker set, and this is the first provider
            // broadcast afterwards. The marker only ever holds while a probe's
            // answer is outstanding, so repairing on it can never be a redraw
            // the widget did not need.
            if (unmetProbe(HomeWidgetPlugin.getData(context), widgetId)) {
                android.util.Log.i(
                    "NotesWidgetProvider", "unfinished probe id=$widgetId, repairing"
                )
                repairWidget(context, appWidgetManager, widgetId)
            } else {
                updateWidget(context, appWidgetManager, widgetId)
            }
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
            editor.remove(verifyKey(id))
            editor.remove(drawnBuildKey(id))
            editor.remove("sig_$id") // left over from the earlier shortcut version
            editor.remove(pendingRebindsKey(id))
            editor.remove(rowsRequestedKey(id))
            cancelExpiryRefresh(context, id)
            cancelNextTick(context, id)
            cancelRepaint(id)
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

            ACTION_REPAINT -> {
                val widgetId = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID
                )
                if (widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
                    probeViews(context, widgetId)
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
        val prefs = HomeWidgetPlugin.getData(context)
        val manager = AppWidgetManager.getInstance(context)
        // A rebind paints into views the launcher may have thrown away (see
        // drawnBuildKey); when that's possible, only a full redraw shows
        // anything at all.
        if (viewsAreStale(context, prefs, appWidgetId)) {
            updateWidget(context, manager, appWidgetId)
            return
        }
        manager.notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)
        val raw = prefs.getString("payload_$appWidgetId", null)
        if (raw.isNullOrEmpty()) {
            cancelNextTick(context, appWidgetId)
            return
        }
        scheduleNextTick(context, appWidgetId, JSONObject(raw))
    }

    // ---- does the launcher still hold our views? ---------------------------
    // The one thing a launcher cannot fake is that redrawing the LIST means
    // coming back to NotesWidgetService for the rows, and a view it has thrown
    // away has no adapter to ask with. So after a tap we rebind once more and
    // listen for the answer: none coming back means the request went nowhere
    // and a full redraw is owed.
    //
    // Every tap gets asked rather than guessed at, because the drop is not
    // dependable — this device does it on some taps and not others — and both
    // guesses are wrong half the time. Repainting a view the launcher kept is
    // the flash this whole line of work set out to remove; leaving alone a view
    // it threw away is the stranded widget. Asking costs one extra rebind,
    // which is cheap and invisible, and the answer is never wrong.
    //
    // The redraw that follows is not a flash either: by then the widget is
    // sitting on its defaults, so this is what puts the note back.

    /** `what` is the widget id, so a burst of taps costs one probe. */
    private val repaintHandler = Handler(Looper.getMainLooper())

    private fun scheduleRepaint(context: Context, appWidgetId: Int) {
        val message = Message.obtain(repaintHandler) { probeViews(context, appWidgetId) }
        message.what = appWidgetId
        repaintHandler.removeMessages(appWidgetId)
        repaintHandler.sendMessageDelayed(message, REPAINT_DELAY_MS)
    }

    private fun cancelRepaint(appWidgetId: Int) = repaintHandler.removeMessages(appWidgetId)

    /** True while a probe has gone out and its answer has not come back. */
    private fun unmetProbe(prefs: android.content.SharedPreferences, appWidgetId: Int): Boolean =
        ((prefs.all[pendingRebindsKey(appWidgetId)] as? Number)?.toInt() ?: 0) > 0

    /**
     * Rebind and listen for who comes back. Off the main thread, because it
     * has to wait out REPAINT_SETTLE_MS — and blocking the main thread here
     * would hold up the very request we are waiting for, since
     * NotesWidgetService runs in this process.
     */
    private fun probeViews(context: Context, appWidgetId: Int) {
        Thread {
            try {
                val prefs = HomeWidgetPlugin.getData(context)
                val before = (prefs.all[pendingRebindsKey(appWidgetId)] as? Number)?.toInt() ?: 0
                prefs.edit().putInt(pendingRebindsKey(appWidgetId), before + 1).apply()
                AppWidgetManager.getInstance(context)
                    .notifyAppWidgetViewDataChanged(appWidgetId, R.id.widget_list)

                Thread.sleep(REPAINT_SETTLE_MS)

                val unmet = (prefs.all[pendingRebindsKey(appWidgetId)] as? Number)?.toInt() ?: 0
                prefs.edit().putInt(pendingRebindsKey(appWidgetId), 0).apply()
                android.util.Log.i(
                    "NotesWidgetProvider", "views probe id=$appWidgetId unmet=$unmet"
                )

                if (unmet > 0) {
                    repairWidget(context, AppWidgetManager.getInstance(context), appWidgetId)
                }
            } catch (e: Exception) {
                android.util.Log.e("NotesWidgetProvider", "Views probe failed", e)
            }
        }.start()
    }

    /** A redraw the widget provably needs, hence `force` — never a flash. */
    private fun repairWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        prefsClearProbe(context, appWidgetId)
        updateWidget(context, appWidgetManager, appWidgetId, force = true)
    }

    private fun prefsClearProbe(context: Context, appWidgetId: Int) {
        HomeWidgetPlugin.getData(context).edit()
            .putInt(pendingRebindsKey(appWidgetId), 0)
            .apply()
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
     * True while a tap has been handed to Dart but not finished yet.
     *
     * In that window the widget is not only on screen but freshly painted by
     * [applyOptimisticTap] a moment ago, so any update request arriving now is
     * asking for content the widget already has. That is what makes it safe to
     * answer with a content-only refresh — see [updateWidget].
     */
    private fun tapInFlight(prefs: android.content.SharedPreferences): Boolean {
        val last = (prefs.all[PENDING_TAPS_TIME_KEY] as? Number)?.toLong() ?: return false
        if (System.currentTimeMillis() - last > PENDING_TAPS_STALE_MS) return false
        return ((prefs.all[PENDING_TAPS_KEY] as? Number)?.toInt() ?: 0) > 0
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

                val newPayloadStr = payload.toString()
                prefs.edit()
                    .putString(key, newPayloadStr)
                    // The rows on screen now ARE this payload, so record them
                    // beside the ones last drawn. Until they were recorded the
                    // signature still held the previous full redraw, which made
                    // Dart's follow-up content update read every tap as a row
                    // change: it re-bound an unchanged list, and a re-bind
                    // blanks the list for a frame. That was the flash a couple
                    // of seconds after pressing + or ticking a box.
                    .putString(listSigKey(id), listSignature(newPayloadStr))
                    .apply()
                // Same rule as handleTick: a rebind can't reach a widget whose
                // views the launcher has replaced with the layout defaults.
                if (viewsAreStale(context, prefs, id)) {
                    updateWidget(context, manager, id)
                } else {
                    manager.notifyAppWidgetViewDataChanged(id, R.id.widget_list)
                    // And then come back and make sure it landed: this launcher
                    // drops our views ~450ms after a tap that runs Dart.
                    scheduleRepaint(context, id)
                }
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
        appWidgetId: Int,
        // Set by the post-tap repaint check, the one caller that KNOWS the
        // launcher is no longer holding what we last drew. Every skip below is
        // an argument that the widget already shows this content; `force` is
        // the caller for which that argument has been disproved.
        force: Boolean = false
    ) {
        try {
            val prefs = HomeWidgetPlugin.getData(context)
            val payloadStr = prefs.getString("payload_$appWidgetId", null)

            // ---- flash-free content updates --------------------------------
            // Two kinds of request arrive with content the widget already has,
            // and both used to answer with a full re-inflate — the flash you
            // see about a second after pressing + or ticking a box.
            //
            //  a) Dart stamps the broadcasts it sends after saving a tap with a
            //     short-lived flag.
            //  b) The OS re-sends a bare APPWIDGET_UPDATE ~1.1s after every row
            //     tap: touching the widget makes the system report our package
            //     as changed, and AppWidgetService then re-asks every provider
            //     of that package for its RemoteViews. It carries no flag at
            //     all, but a tap is provably still in flight when it lands (see
            //     tapInFlight), so the widget it targets is on screen and was
            //     painted a moment ago — there is nothing to add.
            //
            // Either way, when the widget's frame (title/type/render mode) is
            // unchanged the list rebind alone shows everything that changed,
            // and if even the list ROWS are unchanged nothing is redrawn at all:
            // on some launchers any rebind blanks the list for a frame, so a
            // pointless rebind is worse than no update.
            //
            // The one thing a skip assumes is that the launcher is still
            // holding what we drew. That assumption is falsifiable, and this
            // device falsifies it: half a second after a row tap it throws our
            // RemoteViews away and re-inflates the layout defaults, so a widget
            // that is content-identical to what we last recorded is sitting on
            // screen showing "no notes pinned". Skipping that update is what
            // stranded it. Hence the two guards below: never skip while the APK
            // has been replaced since we last drew (`stale`), and never skip
            // when the repaint check has just proved the views are gone
            // (`force`).
            //
            // A request with neither marker (boot, launcher restart, first
            // placement) is the case where the launcher may hold no view of us
            // whatsoever, so it always gets the full redraw and the widget can
            // never be left blank.
            val isVerify = consumeVerifyFlag(prefs, appWidgetId)
            val isSoft = consumeSoftFlag(prefs, appWidgetId)
            val build = currentBuild(context)
            val stale = prefs.getLong(drawnBuildKey(appWidgetId), -1L) != build

            // Dart's once-per-launch self-check (ensureWidgetsDrawn). Nothing
            // to repair, so the launcher's views are left exactly as they are
            // — the timers are re-armed only because an app update or a
            // force-stop silently clears every alarm we had scheduled.
            if (!force && isVerify && !stale) {
                android.util.Log.i("NotesWidgetProvider", "verify ok id=$appWidgetId")
                reschedule(context, appWidgetId, payloadStr)
                return
            }

            // A soft update is Dart telling us it saved content the widget
            // already shows, so the frame is unchanged and a full redraw would
            // only flash. Skipping that is right.
            //
            // A BARE update with a tap in flight is a different animal, and
            // skipping it is what stranded the widget. Measured on this
            // device: the launcher throws our RemoteViews away ~920ms after a
            // row tap (re-inflating the layout defaults, so the widget reads
            // its placeholder), and the OS re-asks us for the views 5-8ms
            // LATER. That re-send is therefore not "nothing to add" — it is
            // the one moment we are handed the chance to put the note back,
            // and answering it with a skip is what left the widget blank until
            // something unrelated redrew it. So a tap-marked bare update always
            // gets the redraw.
            //
            // This is not the flash this work set out to remove: by the time
            // it arrives the launcher is already showing the defaults, so the
            // redraw restores the note rather than re-inflating one that was
            // still on screen.
            if (!force && isSoft && payloadStr != null && !stale) {
                val storedSig = prefs.getString(chromeSigKey(appWidgetId), null)
                if (storedSig != null && storedSig == chromeSignature(payloadStr)) {
                    val newSig = listSignature(payloadStr)
                    val rowsChanged =
                        prefs.getString(listSigKey(appWidgetId), null) != newSig
                    android.util.Log.i("NotesWidgetProvider",
                        "soft update id=$appWidgetId rowsChanged=$rowsChanged"
                    )
                    reschedule(context, appWidgetId, payloadStr)
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

            // Reached when the frame really changed, when our APK was replaced
            // under the launcher, when neither marker is present (boot, launcher
            // restart, first placement — the cases where the launcher may hold
            // no view at all), and when a bare update lands with a tap in
            // flight. That last one is a repair, not a flash: the launcher has
            // already dropped the views by then.
            android.util.Log.i("NotesWidgetProvider",
                "full redraw id=$appWidgetId soft=$isSoft verify=$isVerify stale=$stale"
            )
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
                    .putLong(drawnBuildKey(appWidgetId), build)
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
                .putLong(drawnBuildKey(appWidgetId), build)
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
     * Consumes Dart's once-per-launch "please self-check" flag (see
     * ensureWidgetsDrawn in home_widget_service.dart).
     */
    private fun consumeVerifyFlag(
        prefs: android.content.SharedPreferences,
        appWidgetId: Int
    ): Boolean {
        val key = verifyKey(appWidgetId)
        val ts = (prefs.all[key] as? Number)?.toLong() ?: 0L
        prefs.edit().remove(key).apply()
        return ts > 0 && System.currentTimeMillis() - ts < VERIFY_UPDATE_VALID_MS
    }

    /**
     * This build's [PackageInfo.lastUpdateTime]. A value that differs from the
     * one recorded by the last draw means our APK was replaced underneath the
     * launcher, which is exactly when it drops our RemoteViews.
     */
    private fun currentBuild(context: Context): Long = try {
        context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
    } catch (e: Exception) {
        0L
    }

    /**
     * True when the launcher cannot still be holding a view we drew, so a
     * skip or a list rebind would show nothing and only a full redraw can
     * repair the widget. See [drawnBuildKey].
     */
    private fun viewsAreStale(
        context: Context,
        prefs: android.content.SharedPreferences,
        appWidgetId: Int
    ): Boolean = prefs.getLong(drawnBuildKey(appWidgetId), -1L) != currentBuild(context)

    /**
     * Re-arms the countdown/expiry alarms for [payloadStr]. Cheap and safe at
     * any time, and worth doing whenever a redraw is skipped: replacing the
     * APK or force-stopping the app clears every alarm we had scheduled, which
     * would otherwise silently freeze the countdowns.
     */
    private fun reschedule(context: Context, appWidgetId: Int, payloadStr: String?) {
        if (payloadStr.isNullOrEmpty()) return
        try {
            val payload = JSONObject(payloadStr)
            if (payload.optString("type") == "todo" || payload.optString("type") == "timed") {
                scheduleExpiryRefresh(context, appWidgetId, payload)
                scheduleNextTick(context, appWidgetId, payload)
            }
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Reschedule failed", e)
        }
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