// TODO: move this file to match your actual package, e.g. if your
// applicationId is "com.example.notes_m", this file belongs at:
//   android/app/src/main/kotlin/com/example/notes_m/NotesWidgetProvider.kt
// and the package line below must match exactly (same as MainActivity.kt).
package com.mahad.fastcompanion

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.os.Bundle
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetPlugin

class NotesWidgetProvider : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (widgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, widgetId)
        }
    }

    // Fires whenever the user resizes the widget — this is what lets us
    // show more or fewer lines of the note as it grows/shrinks.
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
            val prefs = HomeWidgetPlugin.getData(context)
            val title = prefs.getString("pinned_title", null) ?: "No note pinned"
            val body = prefs.getString("pinned_body", null)
                ?: "Open the app and tap the pin icon to choose a note."

            // Pick a whole layout variant based on size instead of mutating a
            // live view via RemoteViews reflection — TextView.setMaxLines()
            // isn't on Android's "remotable" method allowlist, so calling it
            // through RemoteViews.setInt(...) silently fails inside the
            // launcher's process (not ours), which is what was causing
            // "Can't load widget" even though our own logs showed nothing.
            val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
            val heightDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 110)
            val layoutRes = when {
                heightDp < 120 -> R.layout.notes_widget_layout_small
                heightDp < 250 -> R.layout.notes_widget_layout_medium
                else -> R.layout.notes_widget_layout_large
            }

            val views = RemoteViews(context.packageName, layoutRes)
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_body, body)

            // Tapping the widget opens the app. Guarded against null — a null
            // Intent here would crash the provider and show "Can't load widget."
            val launchIntent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (launchIntent != null) {
                val pendingIntent = PendingIntent.getActivity(
                    context,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                views.setOnClickPendingIntent(R.id.widget_title, pendingIntent)
                views.setOnClickPendingIntent(R.id.widget_body, pendingIntent)
            }

            appWidgetManager.updateAppWidget(appWidgetId, views)
        } catch (e: Exception) {
            // Fail loud in Logcat instead of leaving the launcher stuck on a
            // silent crash — search "NotesWidgetProvider" in Logcat if you
            // still see "Can't load widget" after this.
            android.util.Log.e("NotesWidgetProvider", "Failed to update widget", e)
        }
    }
}
