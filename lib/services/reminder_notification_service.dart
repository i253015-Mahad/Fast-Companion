// lib/services/reminder_notification_service.dart
//
// Local notifications that remind the user about timed tasks at fixed
// points before their deadline — 3 days, 1 day, 2 hours, 1 hour,
// 30 min, 10 min, 5 min — plus one final "time expired" notice when the
// deadline itself passes.
//
// How it works:
//  * Driven entirely from the local note cache, so it covers ALL signed-in
//    accounts without touching the network.
//  * flutter_local_notifications persists every scheduled alarm natively
//    (and its boot receiver re-registers them after a reboot), so reminders
//    fire even when the app has been killed.
//  * Each note is fully re-synced — its pending reminders are cancelled
//    first — whenever it is saved (DatabaseService.updateNote) or deleted
//    (DatabaseService.deleteNote), and everything is re-synced on app start
//    (main.dart). Milestones that are already in the past are skipped, so
//    opening the app never triggers a burst of catch-up notifications.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/note.dart';
import 'local_storage_service.dart';

class ReminderNotificationService {
  ReminderNotificationService._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'timed_task_reminders';
  static const String _enabledKey = 'reminders_enabled';
  static const String _permissionAskedKey = 'reminders_permission_asked';

  static bool _initialized = false;

  /// Set by main.dart. Receives a tapped reminder's `uid|noteId` payload so
  /// the app can open the matching note. A callback (instead of a direct
  /// import) keeps this file free of a circular import with main.dart.
  static void Function(String payload)? onNotificationTap;

  /// How long before the deadline each reminder fires, and the wording used
  /// in the notification body. The last entry fires AT the deadline.
  static const List<(Duration, String)> _milestones = [
    (Duration(days: 3), 'due in 3 days'),
    (Duration(days: 1), 'due in 1 day'),
    (Duration(hours: 2), 'due in 2 hours'),
    (Duration(hours: 1), 'due in 1 hour'),
    (Duration(minutes: 30), 'due in 30 minutes'),
    (Duration(minutes: 10), 'due in 10 minutes'),
    (Duration(minutes: 5), 'due in 5 minutes'),
    (Duration.zero, 'time expired'),
  ];

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Timed task reminders',
      channelDescription: 'Deadline reminders for your timed tasks',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.reminder,
    ),
    iOS: DarwinNotificationDetails(),
  );

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  // ---------------------------------------------------------------- setup

  /// Idempotent — safe to call from the main isolate, the widget's headless
  /// background isolate, and cold starts alike.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    tzdata.initializeTimeZones();

    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _handleTap,
    );

    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        'Timed task reminders',
        description: 'Deadline reminders for your timed tasks',
        importance: Importance.max,
      ),
    );
  }

  static void _handleTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload == null || payload.isEmpty) return;
    onNotificationTap?.call(payload);
  }

  /// Launch details when the app was started by tapping a notification
  /// (the "app was killed" case — while the app is alive, [_handleTap]
  /// fires instead).
  static Future<NotificationAppLaunchDetails?> launchDetails() async {
    await init();
    return _plugin.getNotificationAppLaunchDetails();
  }

  // ------------------------------------------------------ user settings

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_enabledKey) ?? true;
  }

  /// Turns every reminder on/off and immediately (re)schedules accordingly.
  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, enabled);
    if (enabled) {
      await syncAll();
    } else {
      await _plugin.cancelAll();
    }
  }

  /// Android 13+: runtime permission to show notifications at all.
  /// Prompted at most once per install; denying is remembered.
  static Future<void> requestPermissionOnce() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_permissionAskedKey) ?? false) return;
    await prefs.setBool(_permissionAskedKey, true);
    await _android?.requestNotificationsPermission();
  }

  /// Asks again regardless of the once-guard — used when the user flips the
  /// reminders toggle back on (if already denied, Android simply re-denies
  /// silently and the user must allow it in system settings).
  static Future<void> requestNotificationPermission() async {
    await _android?.requestNotificationsPermission();
  }

  /// Whether reminders can fire at the exact minute. On Android 14+ this is
  /// denied by default; without it we fall back to inexact alarms (which
  /// Android may delay a little while the device is idle).
  static Future<bool> canScheduleExact() async {
    return await _android?.canScheduleExactNotifications() ?? false;
  }

  /// Opens the system screen where the user can allow exact alarms.
  static Future<void> openExactAlarmSettings() async {
    await _android?.requestExactAlarmsPermission();
  }

  // ------------------------------------------------------------- syncing

  /// Re-syncs reminders for every note of every signed-in account.
  /// Cancel-first also clears reminders belonging to accounts that were
  /// signed out since the previous sync.
  static Future<void> syncAll() async {
    await init();
    await _plugin.cancelAll();
    if (!await isEnabled()) return;

    final accounts = await LocalStorageService.loadAccounts();
    for (final account in accounts) {
      final uid = account['uid'];
      if (uid == null || uid.isEmpty) continue;
      final notes = await LocalStorageService.loadNotes(uid);
      for (final note in notes) {
        if (note.type == 'timed') {
          await _scheduleNote(uid, note);
        }
      }
    }
  }

  /// Re-syncs a single note — called after every save so edits, newly added
  /// tasks, deadlines and checked-off items all take effect immediately.
  static Future<void> syncNote(String uid, String noteId) async {
    await init();
    await _cancelPending(uid, noteId);
    if (!await isEnabled()) return;

    final note = await _loadNote(uid, noteId);
    if (note == null || note.type != 'timed') return;
    await _cancelShown(uid, note);
    await _scheduleNote(uid, note);
  }

  /// Drops a note's reminders — called when the note is deleted.
  static Future<void> cancelNote(String uid, String noteId) async {
    await init();
    await _cancelPending(uid, noteId);
  }

  static Future<Note?> _loadNote(String uid, String noteId) async {
    final notes = await LocalStorageService.loadNotes(uid);
    for (final note in notes) {
      if (note.id == noteId) return note;
    }
    return null;
  }

  static Future<void> _cancelPending(String uid, String noteId) async {
    final payload = _payload(uid, noteId);
    final pending = await _plugin.pendingNotificationRequests();
    for (final request in pending) {
      if (request.payload == payload) {
        await _plugin.cancel(id: request.id);
      }
    }
  }

  /// Clears reminders that have ALREADY fired for the checked-off items of
  /// [note] — [_cancelPending]'s scan only sees notifications still waiting
  /// to fire, so ticking a task off used to leave its delivered "due in 1
  /// hour" sitting in the tray. The ids are deterministic: the very formula
  /// [_scheduleNote] stamps when it schedules, so cancelling them outright
  /// hits exactly this note's notifications, scheduled or shown.
  static Future<void> _cancelShown(String uid, Note note) async {
    for (var i = 0; i < note.todoList.length; i++) {
      if (!note.todoList[i].isDone) continue;
      for (var m = 0; m < _milestones.length; m++) {
        try {
          await _plugin.cancel(id: _stableId('$uid|${note.id}|$i|$m'));
        } catch (e) {
          debugPrint('⚠️ reminder cancel failed (item $i, milestone $m): $e');
        }
      }
    }
  }

  static Future<void> _scheduleNote(String uid, Note note) async {
    // Small margin so a milestone that is "right now" can't trip the
    // plugin's must-be-in-the-future validation.
    final cutoff = DateTime.now().add(const Duration(seconds: 2));

    // Exact timing where permitted; graceful inexact fallback otherwise
    // (Android 14+ denies SCHEDULE_EXACT_ALARM by default).
    final exact = await canScheduleExact();
    final mode = exact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    final title = note.title.trim().isEmpty
        ? 'Timed task reminder'
        : note.title.trim();

    for (var i = 0; i < note.todoList.length; i++) {
      final item = note.todoList[i];
      if (item.isDone || item.text.trim().isEmpty) continue;
      final due = item.dueDateTime;
      if (due == null) continue;

      for (var m = 0; m < _milestones.length; m++) {
        final (before, label) = _milestones[m];
        final fireAt = due.subtract(before);
        // Milestones already behind us are skipped: a scheduled reminder
        // that has passed while the app was closed is simply gone, never
        // delivered late as a catch-up burst.
        if (!fireAt.isAfter(cutoff)) continue;

        try {
          await _plugin.zonedSchedule(
            // Deterministic id: re-syncs overwrite instead of piling up.
            id: _stableId('$uid|${note.id}|$i|$m'),
            title: title,
            body: '${item.text.trim()} — $label',
            // Built from the absolute epoch so the alarm fires at exactly
            // `fireAt`, regardless of the device's timezone bookkeeping.
            scheduledDate: tz.TZDateTime.fromMillisecondsSinceEpoch(
              tz.local,
              fireAt.millisecondsSinceEpoch,
            ),
            payload: _payload(uid, note.id),
            notificationDetails: _details,
            androidScheduleMode: mode,
          );
        } catch (e) {
          debugPrint('⚠️ reminder schedule failed ($label): $e');
        }
      }
    }
  }

  static String _payload(String uid, String noteId) => '$uid|$noteId';

  /// Deterministic 31-bit FNV-1a hash, so the same task/milestone always
  /// maps to the same notification id across launches and isolates.
  static int _stableId(String input) {
    var hash = 0x811c9dc5;
    for (final unit in input.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash & 0x7FFFFFFF;
  }
}
