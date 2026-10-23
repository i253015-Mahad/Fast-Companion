// lib/services/flex_background_poller.dart
//
// ONE check for new marks, some hours after the student signs in, with the
// app closed.
//
// Why it is one, and why it is only marks:
//
// The portal serves a session exactly five requests and then refuses the
// sixth, forever — no pause, no re-read of the cookie, no `Set-Cookie` in
// any response ever observed. Nothing refills it but signing in again
// through the WebView, which means the Turnstile challenge and the
// student's password. That budget is also shared with every page the
// student loads themselves.
//
// So a periodic task would sign the student out of Flex continuously: an
// hourly job exhausts the session within the hour. This is the design that
// survives the arithmetic — a single deferred check per sign-in, at two
// requests (`/Home` for the rotating link tokens, then `StudentMarks`),
// that never re-arms itself. Re-signing in REPLACES the pending check
// rather than stacking one per sign-in.
//
// Nothing here schedules the next run. That is the whole point: the only
// thing that may spend another five requests is a student who has signed
// in again.
import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'flex_alert_extract.dart';
import 'flex_alert_poller.dart';
import 'flex_session_service.dart';

/// WorkManager's entry point for this task.
///
/// Top-level and `vm:entry-point` because it is looked up by name from
/// native code in an isolate where nothing references it — the release
/// build's tree shaker would otherwise remove it, and the task would run
/// nothing at all with no error anywhere.
@pragma('vm:entry-point')
void flexBackgroundCallback() {
  Workmanager().executeTask((task, input) async {
    if (task == FlexBackgroundPoller.taskName) {
      await FlexBackgroundPoller.run(input ?? const {});
    }
    // ALWAYS true, including when nothing happened: WorkManager retries a
    // failed one-off task on a backoff schedule, and a retry here spends
    // scarce portal requests on an answer we already have. A missed check
    // costs the student one notification; a retried one can cost them their
    // session.
    return true;
  });
}

class FlexBackgroundPoller {
  FlexBackgroundPoller._();

  /// The unique name of the one deferred check. Used for both scheduling
  /// and cancelling, so there is only ever one in flight.
  static const String taskName = 'com.mahad.fastcompanion.flex_marks_poll';

  /// How long after a sign-in the check runs.
  ///
  /// Long enough that the student has stopped using Flex — they sign in,
  /// read their marks, and close the tab — and short enough that a
  /// same-day upload is still same-day news.
  static const Duration delay = Duration(hours: 3);

  /// Only marks, never the transcript or the challan. `/Home` is still
  /// fetched, because the portal mints a rotating token onto the marks link
  /// and a path written down here would 404 in silence. Two requests, not
  /// four; the other two are worth a term's notice at best and are read
  /// when the student next opens the tab anyway.
  static const Set<String> sources = {FlexAlertSources.marks};

  static const String _uidKey = 'uid';

  /// Registers the callback with WorkManager. Call once from `main()`.
  ///
  /// Idempotent in effect: WorkManager keeps its own state, and re-running
  /// this only re-binds the same callback name.
  static Future<void> initialize() async {
    try {
      await Workmanager().initialize(flexBackgroundCallback);
    } catch (e) {
      // Without it the feature is simply absent; the foreground poll still
      // works, and the app must not fail to start over a nicety.
      debugPrint('Flex background poller init failed: $e');
    }
  }

  /// Arranges exactly one check, [delay] from now.
  ///
  /// `replace` rather than `keep`: a second sign-in supersedes the first,
  /// so a student who signs in five times before the delay elapses still
  /// gets ONE check, not five. Five checks would be fifteen requests —
  /// three times what the session can serve.
  static Future<void> schedule(String uid) async {
    if (uid.isEmpty) return;
    try {
      await Workmanager().registerOneOffTask(
        taskName,
        taskName,
        initialDelay: delay,
        inputData: {_uidKey: uid},
        existingWorkPolicy: ExistingWorkPolicy.replace,
      );
    } catch (e) {
      debugPrint('Flex background check schedule failed: $e');
    }
  }

  /// Drops the pending check.
  ///
  /// The foreground poll has just told the student what changed at a cost
  /// of four requests; firing this after it would spend two more for an
  /// answer they already have.
  static Future<void> cancel() async {
    try {
      await Workmanager().cancelByUniqueName(taskName);
    } catch (e) {
      debugPrint('Flex background check cancel failed: $e');
    }
  }

  /// Runs in WorkManager's isolate.
  ///
  /// [input] carries the uid because nothing else in this isolate has one:
  /// the main isolate's `_activeNotesUid` is plain memory, and polling
  /// under a wrong uid writes a snapshot nobody will ever read while
  /// leaving the real account uncompared.
  static Future<void> run(Map<String, dynamic> input) async {
    final uid = uidOf(input);
    if (uid == null) return;

    // The cookie is only in SharedPreferences, and this isolate shares none
    // of the main one's state. Without this fetchPage would see no session,
    // return nothing, and the whole check would no-op in silence.
    final service = FlexSessionService.instance;
    await service.restore();
    if (!service.hasSession) return;

    try {
      await FlexAlertPoller(onlySources: sources).poll(uid);
    } catch (e) {
      debugPrint('Flex background check failed: $e');
    }
  }

  /// The uid a task's input data actually carries, or `null` when it cannot
  /// be trusted.
  ///
  /// Strict on purpose, and the only thing standing between a corrupt or
  /// absent input and a poll that spends four portal requests writing a
  /// snapshot under a key nobody will ever read — while leaving the real
  /// account's snapshot uncompared, so the student is never told anything.
  static String? uidOf(Map<String, dynamic> input) {
    final uid = input[_uidKey];
    return uid is String && uid.isNotEmpty ? uid : null;
  }
}
