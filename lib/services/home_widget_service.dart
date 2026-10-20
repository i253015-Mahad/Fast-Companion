// lib/services/home_widget_service.dart
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';
import '../models/note.dart';

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
    final ids = await widgetIds();
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      await HomeWidget.saveWidgetData<int>('$_kVerifyPrefix$id', now);
    }
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
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
