package com.mahad.fastcompanion

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Android launches this automatically the instant the user drops the
 * widget onto their home screen (before it's actually placed) — this is
 * what makes the account/note picker "just appear". It runs a SEPARATE
 * Flutter entry point (widgetConfigureMain, in lib/widget_config_main.dart),
 * not your normal app UI.
 */
class NotesWidgetConfigureActivity : FlutterActivity() {

    private var appWidgetId = AppWidgetManager.INVALID_APPWIDGET_ID
    private val channelName = "notes_widget_configure"

    override fun getDartEntrypointFunctionName(): String = "widgetConfigureMain"

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        appWidgetId = intent?.extras?.getInt(
            AppWidgetManager.EXTRA_APPWIDGET_ID,
            AppWidgetManager.INVALID_APPWIDGET_ID
        ) ?: AppWidgetManager.INVALID_APPWIDGET_ID

        // Default to CANCELED so that backing out of the picker (without
        // choosing a note) makes Android discard the widget placement.
        setResult(
            Activity.RESULT_CANCELED,
            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
        )

        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) {
            finish()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // NEW (Fix 4b): lets Dart pin the note to THIS widget.
                    "getWidgetId" -> result.success(appWidgetId)
                    "configComplete" -> {
                        setResult(
                            Activity.RESULT_OK,
                            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                        )
                        result.success(null)
                        finish()
                    }
                    // Lets Dart end the setup explicitly WITHOUT placing the
                    // widget (e.g. the note screen's back button when only
                    // one account is signed in).
                    "configCancel" -> {
                        setResult(
                            Activity.RESULT_CANCELED,
                            Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                        )
                        result.success(null)
                        finish()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}