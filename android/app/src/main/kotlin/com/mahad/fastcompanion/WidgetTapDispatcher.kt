package com.mahad.fastcompanion

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import es.antonborri.home_widget.HomeWidgetBackgroundWorker
import es.antonborri.home_widget.HomeWidgetPlugin
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Runs a widget tap's Dart work without scheduling a WorkManager job.
 *
 * home_widget's own hand-off (HomeWidgetBackgroundWorker) reaches Dart by
 * enqueuing a job with WorkManager. Running that hand-off is what makes this
 * device's launcher rebuild both notes widgets about a second later: it
 * re-inflates them from initialLayout, which is where the blank widget, the
 * flash and the list jumping back to the top all come from.
 *
 * It is not the work the tap does. A tap whose Dart callback returns at once
 * still rebuilds, and so does one whose engine was booted long beforehand —
 * the rebuild tracks the tap, not when Dart happens to start. Nor is it the
 * plugin's receiver: sending the same hand-off through our own receiver
 * changed nothing, and delivering the broadcast without going further did not
 * rebuild at all. What is left is the hand-off itself, with WorkManager's
 * scheduling the prime suspect — the delay matches JobScheduler's, and it is
 * the only part of the chain we can remove.
 *
 * So we keep the plugin's protocol and drop only the transport: boot the same
 * background engine, speak the same `home_widget/background` channel, and let
 * Dart run the same callback. There is no job for the launcher to react to.
 *
 * The plugin's path stays available as [fallback] for the case that matters
 * most — the dispatcher handle isn't registered yet, because Dart hasn't run.
 */
internal object WidgetTapDispatcher {
    private const val TAG = "WidgetTapDispatcher"
    private const val CHANNEL_NAME = "home_widget/background"

    // Mirrors HomeWidgetBackgroundWorker: one engine per process, reused for
    // every later tap, with anything sent before Dart is ready held in a queue.
    @Volatile private var engine: FlutterEngine? = null
    @Volatile private var channel: MethodChannel? = null
    private val dartReady = AtomicBoolean(false)
    private val queue = ArrayDeque<List<Any>>()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Hands [intent] (whose data is the widget action URI) to Dart. */
    fun dispatch(context: Context, intent: Intent) {
        try {
            ensureEngine(context)
            sendOrQueue(context, intent)
        } catch (e: Throwable) {
            // Throwable, not Exception: a failure here surfaces as
            // UnsatisfiedLinkError when the Flutter library isn't loaded yet,
            // and letting that escape would crash the app on a cold tap and
            // lose the save. Fall back instead.
            Log.e(TAG, "direct dispatch failed, falling back to WorkManager", e)
            fallback(context, intent)
        }
    }

    private fun ensureEngine(context: Context) {
        if (engine != null) return

        val dispatcherHandle = HomeWidgetPlugin.getDispatcherHandle(context)
        if (dispatcherHandle == 0L) {
            throw IllegalStateException(
                "No background callback registered yet — Dart has not run"
            )
        }

        // Loads libflutter.so. This has to come FIRST: the callback lookup
        // below resolves a JNI method that only exists once it's loaded, and
        // on a cold process calling it earlier throws UnsatisfiedLinkError.
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)

        val callbackInfo = FlutterCallbackInformation
            .lookupCallbackInformation(dispatcherHandle)
            ?: throw IllegalStateException("Could not resolve the background callback")

        val built = FlutterEngine(context)
        built.dartExecutor.executeDartCallback(
            DartExecutor.DartCallback(
                context.assets,
                loader.findAppBundlePath(),
                callbackInfo,
            )
        )

        val builtChannel = MethodChannel(built.dartExecutor.binaryMessenger, CHANNEL_NAME)
        builtChannel.setMethodCallHandler { call, result ->
            if (call.method == "HomeWidget.backgroundInitialized") {
                dartReady.set(true)
                flushQueue()
                result.success(null)
            } else {
                result.notImplemented()
            }
        }

        channel = builtChannel
        engine = built
    }

    private fun sendOrQueue(context: Context, intent: Intent) {
        val ch = channel ?: throw IllegalStateException("Background channel missing")
        // Same two-element shape the plugin's worker sends: the callback handle
        // and the action URI.
        val args = listOf<Any>(HomeWidgetPlugin.getHandle(context), intent.data?.toString() ?: "")
        if (dartReady.get()) {
            ch.invokeMethod("", args)
        } else {
            queue.add(args)
        }
    }

    private fun flushQueue() {
        val ch = channel ?: return
        while (queue.isNotEmpty()) {
            val args = queue.remove()
            mainHandler.post { ch.invokeMethod("", args) }
        }
    }

    /** Last resort: the plugin's WorkManager path, exactly as shipped. */
    private fun fallback(context: Context, intent: Intent) {
        try {
            HomeWidgetBackgroundWorker.enqueueWork(context, intent)
        } catch (e: Throwable) {
            Log.e(TAG, "WorkManager fallback also failed; widget tap not saved", e)
        }
    }
}
