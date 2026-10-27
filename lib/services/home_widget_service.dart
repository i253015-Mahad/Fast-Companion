// lib/services/home_widget_service.dart
import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import '../models/note.dart';
import 'local_storage_service.dart';
import 'multi_account_auth_service.dart';

/// Bridges notes to the Android home screen widgets. Each placed widget
/// (identified by its appWidgetId) has its own pinned note.
class HomeWidgetService {
  // Must match the AppWidgetProvider class name (NotesWidgetProvider.kt).
  static const String _androidWidgetName = 'NotesWidgetProvider';

  // Comma-separated list of widget ids we've pinned something to, e.g. "12,15".
  static const _kIds = 'widget_ids';
  static String _payloadKey(int widgetId) => 'payload_$widgetId';

  /// Key prefix stamped on widget data before an updateWidget broadcast that
  /// only changes CONTENT (title/type/frame unchanged). Lets the Kotlin
  /// provider answer with a list rebind instead of a full redraw, which is
  /// what used to make the widget flash for a frame after a tap. Must match
  /// SOFT_UPDATE_PREFIX in NotesWidgetProvider.kt.
  static const _kSoftUpdatePrefix = 'soft_update_';

  /// Stamped on every widget we know about once per app launch, asking the
  /// provider to check whether the launcher still holds our views at all. The
  /// provider answers with a full redraw ONLY when it can prove it doesn't
  /// (our APK was replaced), so in the normal case this draws nothing. Must
  /// match VERIFY_PREFIX in NotesWidgetProvider.kt.
  static const _kVerifyPrefix = 'verify_';

  /// Flags [ids] as content-only updates, then triggers the broadcast.
  static Future<void> _requestContentUpdate(List<int> ids) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      await HomeWidget.saveWidgetData<int>('$_kSoftUpdatePrefix$id', now);
    }
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }

  /// Repairs widgets whose views the launcher has thrown away.
  ///
  /// RemoteViews live only inside the launcher, and replacing this app's APK
  /// (every `flutter install`, every store update) makes it drop ours and fall
  /// back to the layout's defaults — the widget then sits there reading its
  /// placeholder although the note is still pinned. Nothing else in the app
  /// would fix that, because every content path skips a widget whose stored
  /// signatures already match, and signatures say nothing about what the
  /// launcher is actually holding. Safe to call every launch: the provider
  /// only redraws when there is really something to repair.
  static Future<void> ensureWidgetsDrawn() async {
    // Before anything that can bail out: a report can be waiting even when no
    // widget is pinned any more (the outage happened while one was), and
    // this launch is the first moment we can ship it. Fire-and-forget, so a
    // slow or offline Firebase never delays the widget repair below.
    flushGapQueue();

    final ids = await widgetIds();
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      await HomeWidget.saveWidgetData<int>('$_kVerifyPrefix$id', now);
    }
    await HomeWidget.updateWidget(androidName: _androidWidgetName);

    // The provider answers that broadcast, and answering it is exactly where
    // detectGap gets its chance to see a stale marker — so flush again once
    // it has had a moment. Without this a gap found on this launch would wait
    // for the NEXT one, and an app someone opens once a week would ship
    // almost nothing. Still fire-and-forget: this runs unawaited.
    await Future<void>.delayed(const Duration(seconds: 2));
    flushGapQueue();
  }

  // ---------- overnight gap reports ----------

  /// Key the Kotlin provider queues refresh-chain gap reports under. Must
  /// match GAP_QUEUE_KEY in NotesWidgetProvider.kt.
  static const _kGapQueueKey = 'gap_queue';

  /// Ships whatever the provider recorded while we weren't running.
  ///
  /// A force-stop — this phone ships a stock cleaner, `com.pri.morning.kill`,
  /// that force-stops around 03:00, and every OEM ships an equivalent —
  /// cancels every alarm *and* puts the package in stopped state, so the
  /// countdown chain dies in complete silence: nothing can reach us, and the
  /// launcher keeps painting the RemoteViews it already holds. `detectGap` in
  /// the provider notices the next time anything wakes it and queues the
  /// outage; this is the only place it leaves the device, which is what turns
  /// "one phone looked wrong this morning" into a number across the fleet.
  ///
  /// Called from two moments when we are provably alive *after* an outage —
  /// app launch ([ensureWidgetsDrawn]) and a widget tap
  /// (widget_background_main.dart). Telemetry must never break the app, so
  /// every failure is swallowed and the queue kept for the next attempt;
  /// Kotlin caps it, so an app that is never reopened again cannot grow a
  /// file forever.
  ///
  /// Both calls fire within a couple of seconds of each other on every launch,
  /// and the first can take several because it may have to restore sessions.
  /// They are therefore chained rather than run in parallel: in parallel the
  /// second reads the queue before the first has cleared it and the same
  /// reports go up twice, and merely skipping the second would lose the very
  /// reports it exists to catch (queued while the first was still reading).
  static Future<void> flushGapQueue() {
    final run = _flushChain.then((_) => _flushOnce());
    _flushChain = run.catchError((_) {});
    return run;
  }

  static Future<void> _flushChain = Future<void>.value();

  static Future<void> _flushOnce() async {
    try {
      final raw = await HomeWidget.getWidgetData<String>(_kGapQueueKey);
      if (raw == null || raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return;
      final events = decoded.whereType<Map>().toList();
      if (events.isEmpty) return;

      debugPrint('gap flush: ${events.length} report(s) queued, sending');
      final err = await _pushGapReport(events);
      if (err != null) {
        debugPrint('gap flush: kept for the next launch');
        return; // keep it, try next time
      }
      await HomeWidget.saveWidgetData<String>(_kGapQueueKey, '[]');
      debugPrint('gap flush: ${events.length} report(s) delivered');
    } catch (e) {
      // Diagnostics are never worth surfacing to the user.
      debugPrint('gap flush: threw $e');
    }
  }

  /// Returns null on success, or the reason it didn't take.
  static Future<String?> _pushGapReport(List<Map> events) async {
    final payload = <String, dynamic>{
      'events': events,
      'uploadedAt': ServerValue.timestamp,
      // Deliberately no uid, no note ids and no note content: this is about
      // the device and the OS, not about a person.
    };

    // Restore first: both writes below want a signed-in handle.
    await _ensureSessions();
    final sessions = MultiAccountAuthService.instance.sessions.values.toList();

    // One shared node is what makes a fleet count queryable in one place, so
    // try it first. Its rule is `auth != null`, so it has to be written
    // through a signed-in handle: reaching for FirebaseDatabase.instance here
    // would send it with no auth at all, because this app keeps per-account
    // sessions and the default app is routinely signed out — the exact null
    // uid that made the first version of this fail every time. A denied write
    // must not mean "no telemetry ever" either, hence the fallback below.
    final sharedDb = sessions.isNotEmpty
        ? sessions.first.database
        : FirebaseDatabase.instanceFor(
            app: Firebase.app(),
            databaseURL: kRtdbUrl,
          );

    final sharedErr = await _trySet(sharedDb.ref('diagnostics/widget_gaps'), payload);
    if (sharedErr == null) return null;
    debugPrint('gap flush: shared node refused — $sharedErr');

    // Fall back into the signed-in user's own subtree, which the note writes
    // already prove is writable.
    if (sessions.isEmpty) return 'no live session to write under';

    for (final session in sessions) {
      final err = await _trySet(
        session.database.ref('users/${session.uid}/diagnostics/widget_gaps'),
        payload,
      );
      if (err == null) return null;
      debugPrint('gap flush: users/${session.uid} refused — $err');
    }
    return 'no live session took it';
  }

  /// The flush can run before anything has restored the per-account sessions —
  /// ensureWidgetsDrawn is called a few lines BEFORE restoreSessions in
  /// home_screen — so do it here instead of trusting call-site ordering. A
  /// no-op when there is nothing to restore.
  static Future<void> _ensureSessions() async {
    if (MultiAccountAuthService.instance.sessions.isNotEmpty) return;
    try {
      final accounts = await LocalStorageService.loadAccounts();
      if (accounts.isEmpty) return;
      await MultiAccountAuthService.instance.restoreSessions(
        accounts,
        authTimeout: const Duration(seconds: 8),
      );
    } catch (_) {
      // Leave it empty; we retry on the next launch rather than raise.
    }
  }

  /// Firebase's write future only settles when the server acks, which offline
  /// never happens — so this has to be bounded, or a single launch with no
  /// signal would hang the flush forever.
  static Future<String?> _trySet(DatabaseReference ref, Object? value) async {
    try {
      await ref.push().set(value).timeout(const Duration(seconds: 8));
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  // ---------- id bookkeeping ----------

  /// Ids of widgets that still exist. NotesWidgetProvider.onDeleted removes a
  /// deleted widget's payload; ids without a payload are pruned here.
  static Future<List<int>> widgetIds() async {
    final raw = await HomeWidget.getWidgetData<String>(_kIds) ?? '';
    final ids = raw.split(',').map(int.tryParse).whereType<int>().toList();
    final alive = <int>[];
    for (final id in ids) {
      final payload = await HomeWidget.getWidgetData<String>(_payloadKey(id));
      if (payload != null) alive.add(id);
    }
    if (alive.length != ids.length) await _saveIds(alive);
    return alive;
  }

  static Future<void> _saveIds(List<int> ids) =>
      HomeWidget.saveWidgetData<String>(_kIds, ids.join(','));

  static Future<Map<String, dynamic>?> _readPayload(int widgetId) async {
    final raw = await HomeWidget.getWidgetData<String>(_payloadKey(widgetId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _buildPayload(String uid, Note note) => {
    'uid': uid,
    'noteId': note.id,
    'type': note.type,
    'title': note.title.isEmpty ? 'Untitled' : note.title,
    'body': note.body.isEmpty ? 'No content' : note.body,
    // Raw timestamps, NOT a preformatted "Due in 2h" string. The Kotlin
    // side formats them at draw time.
    'todoList': note.todoList
        .map(
          (t) => {
            'text': t.text,
            'isDone': t.isDone,
            'dueMs': t.dueDateTime?.millisecondsSinceEpoch,
            'remainingMs': t.remainingDuration?.inMilliseconds,
          },
        )
        .toList(),
    'counterList': note.counterList
        .map((c) => {'label': c.label, 'count': c.count})
        .toList(),
  };

  /// Round-trips through JSON so it can be compared with a stored payload.
  static Map<String, dynamic> _normalized(Map<String, dynamic> payload) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map);

  /// NEW: true when two payloads show the same thing. The widget already
  /// updates itself the instant you tap, so when the saved result matches what
  /// it's already showing there's nothing to redraw. 'remainingMs' may differ
  /// by a few seconds (the widget computed it at tap time, Dart a moment
  /// later), which is not worth a redraw.
  static bool _same(Object? a, Object? b, [String? key]) {
    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      // The widget only renders 'body' for plain TEXT notes; for todo/timed/
      // counter notes it's just a preview of the list, which the Kotlin side
      // derives from the list rows itself. Kotlin's instant tap update doesn't
      // rewrite the preview, so comparing it would make every tap look like a
      // change and fire a second widget update — visible as a flash. A body
      // that genuinely differs for a list note still gets saved; it just
      // doesn't need a redraw.
      final type = a['type'];
      final ignoreBody = type != null && type != 'text';
      for (final k in a.keys) {
        if (k == 'body' && ignoreBody) continue;
        if (!b.containsKey(k) || !_same(a[k], b[k], k.toString())) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_same(a[i], b[i], key)) return false;
      }
      return true;
    }
    if (a is num && b is num) {
      if (key == 'remainingMs') return (a - b).abs() < _remainingMsTolerance;
      return a == b;
    }
    return a == b;
  }

  /// How far apart two computed countdowns may be and still count as the same
  /// moment. The widget freezes a task's remaining time when you tap it; Dart
  /// recomputes it a moment later, so a difference of a few seconds means
  /// nothing and [_same] lets the update through rather than resaving it.
  static const _remainingMsTolerance = 10000;

  /// Returns [fresh] with the countdown the widget is already drawing kept
  /// intact, so the payload written here differs from the stored one only
  /// where something really happened.
  ///
  /// `remainingMs` is frozen twice: by Kotlin the instant you tap, and by Dart
  /// a moment later once the save finishes. The two numbers therefore always
  /// differ by however long that took, while rendering to the very same text.
  /// Writing the newer one anyway made the row signature disagree with what
  /// was on screen, the provider read that as a changed row and re-bound a list
  /// that looked unchanged — the flash a couple of seconds after a tap.
  ///
  /// This deliberately has no time window: on a slow device the save can take
  /// longer than any fixed one, so the rule is instead "keep the widget's
  /// value unless the due date or the tick state itself changed" — a re-tick or
  /// an edited due date changes one of those, and then the freshly computed
  /// value wins.
  static Object? _adoptStored(Object? stored, Object? fresh) {
    if (fresh is Map && stored is Map) {
      final out = <String, dynamic>{};
      fresh.forEach((k, v) {
        out[k] = stored.containsKey(k) ? _adoptStored(stored[k], v) : v;
      });
      if (out['remainingMs'] is num && stored['remainingMs'] is num) {
        final sameDue = stored['dueMs'] == out['dueMs'];
        final sameTick = stored['isDone'] == out['isDone'];
        if (sameDue && sameTick) out['remainingMs'] = stored['remainingMs'];
      }
      return out;
    }
    if (fresh is List && stored is List && fresh.length == stored.length) {
      return [
        for (var i = 0; i < fresh.length; i++)
          _adoptStored(stored[i], fresh[i]),
      ];
    }
    return fresh;
  }

  // ---------- public API ----------

  /// Pins [note] to one specific widget.
  static Future<void> pinNote(int widgetId, String uid, Note note) async {
    await HomeWidget.saveWidgetData<String>(
      _payloadKey(widgetId),
      jsonEncode(_buildPayload(uid, note)),
    );
    final ids = await widgetIds();
    if (!ids.contains(widgetId)) {
      ids.add(widgetId);
      await _saveIds(ids);
    }
    // This widget is deliberately NOT flagged as a content-only update.
    // Pinning is the one request that may arrive when the launcher is holding
    // nothing of ours at all (fresh placement, or an APK replacement), and
    // flagging it used to make the provider compare against its own stored
    // signatures and skip — so pinning the note that was already pinned drew
    // nothing, and the widget stayed on its "no notes pinned" default. Only
    // the other widgets are flagged, so they are left alone.
    await _requestContentUpdate(ids.where((id) => id != widgetId).toList());
  }

  /// Rewrites every widget currently showing this exact note. Used by the
  /// background (widget tap) handler. CHANGED: skips widgets that already show
  /// exactly this, so a tap doesn't cause a pointless redraw.
  static Future<void> refreshNote(String uid, Note note) async {
    final touched = <int>[];
    final fresh = _normalized(_buildPayload(uid, note));
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p == null || p['uid'] != uid || p['noteId'] != note.id) continue;
      if (_same(p, fresh)) continue; // already up to date
      await HomeWidget.saveWidgetData<String>(
        _payloadKey(id),
        // Written as the widget already shows it, so the only difference the
        // provider sees is the one that actually happened. See [_adoptStored].
        jsonEncode(_adoptStored(p, fresh)),
      );
      touched.add(id);
    }
    if (touched.isNotEmpty) {
      // The interesting case only: something about this note differs from what
      // the widget holds, so a redraw is going out. NotesWidgetProvider logs
      // whether it re-binds or skips, which is the actual flash decision.
      debugPrint('🔁 widget refresh: content update for $touched');
      await _requestContentUpdate(touched);
    }
  }

  /// Call after local notes reload (HomeScreen._refreshLocalNotes already does).
  /// Refreshes each widget pinned to a note of [uid]; blanks it if the note is
  /// gone. CHANGED: skips widgets that are already up to date, and never blanks
  /// a widget just because the list came back empty (that usually means the
  /// list failed to load, not that the note was deleted).
  static Future<void> syncIfNeeded(String? uid, List<Note> currentNotes) async {
    if (uid == null) return;
    final touched = <int>[];
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p == null || p['uid'] != uid) continue;
      final matches = currentNotes.where((n) => n.id == p['noteId']);
      if (matches.isEmpty) {
        if (currentNotes.isEmpty) continue;
        await HomeWidget.saveWidgetData<String>(_payloadKey(id), '');
        touched.add(id);
      } else {
        final fresh = _normalized(_buildPayload(uid, matches.first));
        if (_same(p, fresh)) continue; // already up to date
        await HomeWidget.saveWidgetData<String>(
          _payloadKey(id),
          jsonEncode(fresh),
        );
        touched.add(id);
      }
    }
    if (touched.isNotEmpty) {
      await _requestContentUpdate(touched);
    }
  }

  /// Blanks every widget showing a note from [uid] (used on sign-out).
  static Future<void> clearForUid(String uid) async {
    final touched = <int>[];
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p != null && p['uid'] == uid) {
        await HomeWidget.saveWidgetData<String>(_payloadKey(id), '');
        touched.add(id);
      }
    }
    if (touched.isNotEmpty) {
      await _requestContentUpdate(touched);
    }
  }

  /// For the in-app "which widget?" picker.
  static Future<List<({int id, String title})>> widgetSummaries() async {
    final result = <({int id, String title})>[];
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      result.add((id: id, title: (p?['title'] as String?) ?? '(empty)'));
    }
    return result;
  }

}
