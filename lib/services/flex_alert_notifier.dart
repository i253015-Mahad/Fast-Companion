// The notifications a Flex poll raises.
//
// Two kinds, both one-per-poll rather than one-per-change:
//
//   * the summary — what moved, named. Four marks uploaded on the same
//     evening produce one alert naming them, not four that arrive while the
//     phone is in a pocket and teach the user to swipe them unread.
//   * the session nudge — once per expiry, telling the student the portal
//     session has died, because an alert that silently stops firing one day
//     is worse than one that says why it stopped.
//
// Both use a fixed id, so a later notification replaces the last of its
// kind instead of stacking behind it: the last thing seen is the current
// state, and a stack of states that have already moved on is noise.
//
// This deliberately does *not* call the plugin's `initialize`. That call
// stores the tap callback in a single field on a shared platform instance,
// so a second one here would silently replace the callback the reminder
// notifications registered, and tapping a deadline reminder would stop
// opening the note. One plugin, one initialize, one owner of it — this
// only adds its own channel beside the reminder channel, so the two can be
// muted independently.
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'reminder_notification_service.dart';

class FlexAlertNotifier {
  FlexAlertNotifier._();

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _channelId = 'flex_alerts';

  /// Marks the summary. "FLEX" — chosen so it cannot collide with a
  /// reminder id by accident.
  static const int _summaryId = 0x464c4558;

  /// Marks the session-expired nudge. Separate from the summary so an
  /// expiry does not erase a list of changes that are still true.
  static const int _expiredId = 0x45585058; // "EXPX"

  /// Every payload this service raises begins with it.
  ///
  /// Reminder payloads are `uid|noteId`, two parts — a prefix is how the
  /// tap handler tells them apart, because position alone cannot: parsing a
  /// Flex payload as a reminder would read its uid as a note id and open
  /// nothing, silently, every time.
  static const String payloadPrefix = 'flex|';

  static bool _initialized = false;

  /// Set when a Flex alert is tapped, so the app can show the tab the
  /// alert is about.
  ///
  /// A signal rather than a navigation call: this object is created before
  /// any widget exists, and the home screen that owns the tabs listens to
  /// it. It carries no payload because the tab it opens is always the same
  /// one — the account comes from whatever account is signed in *now*, not
  /// from whichever account the alert happened to be filed under.
  static final ValueNotifier<bool> pendingTap = ValueNotifier(false);

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      'Flex updates',
      channelDescription: 'Alerts when fees, marks or grades change',
      importance: Importance.max,
      priority: Priority.high,
      category: AndroidNotificationCategory.status,
    ),
    iOS: DarwinNotificationDetails(),
  );

  static AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  /// Idempotent — safe to call from the main isolate and cold starts alike.
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // The one-time plugin initialise, and with it the tap callback. Owned
    // by the reminder service because it got there first and because
    // initialising twice would replace its callback rather than add to it.
    //
    // The OS permission is its to ask as well — there is only one
    // "notifications" permission per app, and main() already asks for it
    // once at startup, before any alert can exist. Asking again here would
    // be a second prompt with no new reason behind it.
    await ReminderNotificationService.init();

    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        'Flex updates',
        description: 'Alerts when fees, marks or grades change',
        importance: Importance.max,
      ),
    );
  }

  /// Shows the one summary for a poll that found changes.
  ///
  /// [lines] are the per-source summaries, already capped at what fits on a
  /// screen. An empty list shows nothing: a poll that found nothing has
  /// nothing to say, and a notification saying so is one more reason to
  /// turn notifications off.
  static Future<void> showSummary({
    required String uid,
    required List<String> lines,
  }) async {
    if (lines.isEmpty) return;
    await init();

    try {
      await _plugin.show(
        id: _summaryId,
        title: 'Flex updates',
        // Joined rather than listed as bullets: three short lines fit in
        // the two the status bar shows before it collapses.
        body: lines.join(' · '),
        notificationDetails: _details,
        payload: '$payloadPrefix$uid',
      );
    } catch (e) {
      debugPrint('Flex alert notification failed: $e');
    }
  }

  /// Tells the student their portal session has expired.
  ///
  /// Worth saying because it is otherwise invisible: the alert simply stops
  /// firing one day, and nothing distinguishes "no news" from "no
  /// connection to the news". The poll decides how often this is allowed —
  /// once per expiry, not once per visit.
  static Future<void> showSessionExpired({required String uid}) async {
    await init();

    try {
      await _plugin.show(
        id: _expiredId,
        title: 'Flex session expired',
        body: 'Open the Flex tab and sign in again to keep alerts coming.',
        notificationDetails: _details,
        payload: '$payloadPrefix$uid',
      );
    } catch (e) {
      debugPrint('Flex session notification failed: $e');
    }
  }
}
