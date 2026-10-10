// TODO: move this file to match your actual package, e.g. if your
// applicationId is "com.mahad.fastcompanion", this file belongs at:
//   android/app/src/main/kotlin/com/mahad/fastcompanion/NotesWidgetProvider.kt
// and the package line below must match exactly (same as MainActivity.kt).
package com.mahad.fastcompanion

import com.mahad.fastcompanion.R
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetBackgroundIntent
import es.antonborri.home_widget.HomeWidgetPlugin
import org.json.JSONArray
import org.json.JSONObject

class NotesWidgetProvider : AppWidgetProvider() {

    // Must match the number of statically-declared rows in
    // notes_widget_layout.xml (row_todo_0..N-1 / row_counter_0..M-1).
    private val maxTodoSlots = 8
    private val maxCounterSlots = 5

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (widgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, widgetId)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle
    ) {
        updateWidget(context, appWidgetManager, appWidgetId)
    }

    private fun updateWidget(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int
    ) {
        try {
            val views = RemoteViews(context.packageName, R.layout.notes_widget_layout)

            // Hide everything by default, then reveal only what this note
            // type / size actually needs.
            views.setViewVisibility(R.id.row_text, View.GONE)
            views.setViewVisibility(R.id.todo_container, View.GONE)
            views.setViewVisibility(R.id.counter_container, View.GONE)
            views.setViewVisibility(R.id.row_more, View.GONE)
            for (i in 0 until maxTodoSlots) {
                views.setViewVisibility(getTodoRowId(context, i), View.GONE)
            }
            for (i in 0 until maxCounterSlots) {
                views.setViewVisibility(getCounterRowId(context, i), View.GONE)
            }

            val prefs = HomeWidgetPlugin.getData(context)
            val payloadStr = prefs.getString("pinned_payload", null)

            if (payloadStr == null) {
                views.setTextViewText(R.id.widget_title, "No note pinned")
                views.setViewVisibility(R.id.btn_edit, View.GONE)
                views.setTextViewText(
                    R.id.row_text,
                    "Add the widget again, or open the app and re-pin a note."
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

            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110)
            val sizeBasedCap = when {
                heightDp < 130 -> 2
                heightDp < 200 -> 4
                heightDp < 280 -> 6
                else -> maxTodoSlots
            }

            when (type) {
                "todo", "timed" -> {
                    views.setViewVisibility(R.id.todo_container, View.VISIBLE)
                    val items = payload.optJSONArray("todoList") ?: JSONArray()
                    val cap = minOf(sizeBasedCap, maxTodoSlots)
                    val shown = minOf(items.length(), cap)

                    for (i in 0 until shown) {
                        val item = items.getJSONObject(i)
                        views.setViewVisibility(getTodoRowId(context, i), View.VISIBLE)
                        views.setTextViewText(getTodoTextId(context, i), item.optString("text"))

                        val isDone = item.optBoolean("isDone", false)
                        views.setImageViewResource(
                            getTodoCheckId(context, i),
                            if (isDone) R.drawable.ic_checkbox_checked else R.drawable.ic_checkbox_unchecked
                        )

                        val meta = if (item.isNull("meta")) "" else item.optString("meta", "")
                        if (meta.isNotEmpty()) {
                            views.setTextViewText(getTodoMetaId(context, i), meta)
                            views.setViewVisibility(getTodoMetaId(context, i), View.VISIBLE)
                        } else {
                            views.setViewVisibility(getTodoMetaId(context, i), View.GONE)
                        }

                        val toggleUri = Uri.parse(
                            "notesWidget://toggleTodo?uid=$uid&noteId=$noteId&index=$i"
                        )
                        views.setOnClickPendingIntent(
                            getTodoRowId(context, i),
                            HomeWidgetBackgroundIntent.getBroadcast(context, toggleUri)
                        )
                    }

                    if (items.length() == 0) {
                        views.setViewVisibility(R.id.row_text, View.VISIBLE)
                        views.setTextViewText(R.id.row_text, "No items yet")
                    } else if (items.length() > shown) {
                        views.setViewVisibility(R.id.row_more, View.VISIBLE)
                        views.setTextViewText(
                            R.id.row_more,
                            "+ ${items.length() - shown} more — resize widget or open app"
                        )
                    }
                }

                "counter" -> {
                    views.setViewVisibility(R.id.counter_container, View.VISIBLE)
                    val items = payload.optJSONArray("counterList") ?: JSONArray()
                    val cap = minOf(sizeBasedCap, maxCounterSlots)
                    val shown = minOf(items.length(), cap)

                    for (i in 0 until shown) {
                        val item = items.getJSONObject(i)
                        views.setViewVisibility(getCounterRowId(context, i), View.VISIBLE)
                        views.setTextViewText(getCounterLabelId(context, i), item.optString("label"))
                        views.setTextViewText(
                            getCounterCountId(context, i),
                            item.optInt("count", 0).toString()
                        )

                        val minusUri = Uri.parse(
                            "notesWidget://adjustCounter?uid=$uid&noteId=$noteId&index=$i&delta=-1"
                        )
                        val plusUri = Uri.parse(
                            "notesWidget://adjustCounter?uid=$uid&noteId=$noteId&index=$i&delta=1"
                        )
                        views.setOnClickPendingIntent(
                            getCounterMinusId(context, i),
                            HomeWidgetBackgroundIntent.getBroadcast(context, minusUri)
                        )
                        views.setOnClickPendingIntent(
                            getCounterPlusId(context, i),
                            HomeWidgetBackgroundIntent.getBroadcast(context, plusUri)
                        )
                    }

                    if (items.length() == 0) {
                        views.setViewVisibility(R.id.row_text, View.VISIBLE)
                        views.setTextViewText(R.id.row_text, "No counters yet")
                    } else if (items.length() > shown) {
                        views.setViewVisibility(R.id.row_more, View.VISIBLE)
                        views.setTextViewText(
                            R.id.row_more,
                            "+ ${items.length() - shown} more — resize widget or open app"
                        )
                    }
                }

                else -> {
                    val body = payload.optString("body", "No content")
                    views.setViewVisibility(R.id.row_text, View.VISIBLE)
                    views.setTextViewText(R.id.row_text, body)
                }
            }

            // Edit button — opens the app straight into this note.
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
        } catch (e: Exception) {
            android.util.Log.e("NotesWidgetProvider", "Failed to update widget", e)
        }
    }

    // Helpers mapping index -> the fixed resource ids declared in XML
    // (row_todo_0, check_0, text_0, meta_0, row_counter_0, label_0, ...).
    // Using getIdentifier() here avoids hand-writing a 13-branch `when` for
    // each of the ~65 generated view ids.
    private fun idFor(context: Context, name: String): Int {
        return context.resources.getIdentifier(name, "id", context.packageName)
    }

    private fun getTodoRowId(context: Context, i: Int) = idFor(context, "row_todo_$i")
    private fun getTodoCheckId(context: Context, i: Int) = idFor(context, "check_$i")
    private fun getTodoTextId(context: Context, i: Int) = idFor(context, "text_$i")
    private fun getTodoMetaId(context: Context, i: Int) = idFor(context, "meta_$i")
    private fun getCounterRowId(context: Context, i: Int) = idFor(context, "row_counter_$i")
    private fun getCounterLabelId(context: Context, i: Int) = idFor(context, "label_$i")
    private fun getCounterMinusId(context: Context, i: Int) = idFor(context, "minus_$i")
    private fun getCounterCountId(context: Context, i: Int) = idFor(context, "count_$i")
    private fun getCounterPlusId(context: Context, i: Int) = idFor(context, "plus_$i")
}
