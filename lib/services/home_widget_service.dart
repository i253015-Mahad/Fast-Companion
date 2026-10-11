// lib/services/home_widget_service.dart
import 'dart:convert';
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
      for (final k in a.keys) {
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
      if (key == 'remainingMs') return (a - b).abs() < 10000;
      return a == b;
    }
    return a == b;
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
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }

  /// Rewrites every widget currently showing this exact note. Used by the
  /// background (widget tap) handler. CHANGED: skips widgets that already show
  /// exactly this, so a tap doesn't cause a pointless redraw.
  static Future<void> refreshNote(String uid, Note note) async {
    var touched = false;
    final fresh = _normalized(_buildPayload(uid, note));
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p == null || p['uid'] != uid || p['noteId'] != note.id) continue;
      if (_same(p, fresh)) continue; // already up to date
      await HomeWidget.saveWidgetData<String>(
        _payloadKey(id),
        jsonEncode(fresh),
      );
      touched = true;
    }
    if (touched) {
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    }
  }

  /// Call after local notes reload (HomeScreen._refreshLocalNotes already does).
  /// Refreshes each widget pinned to a note of [uid]; blanks it if the note is
  /// gone. CHANGED: skips widgets that are already up to date, and never blanks
  /// a widget just because the list came back empty (that usually means the
  /// list failed to load, not that the note was deleted).
  static Future<void> syncIfNeeded(String? uid, List<Note> currentNotes) async {
    if (uid == null) return;
    var touched = false;
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p == null || p['uid'] != uid) continue;
      final matches = currentNotes.where((n) => n.id == p['noteId']);
      if (matches.isEmpty) {
        if (currentNotes.isEmpty) continue;
        await HomeWidget.saveWidgetData<String>(_payloadKey(id), '');
        touched = true;
      } else {
        final fresh = _normalized(_buildPayload(uid, matches.first));
        if (_same(p, fresh)) continue; // already up to date
        await HomeWidget.saveWidgetData<String>(
          _payloadKey(id),
          jsonEncode(fresh),
        );
        touched = true;
      }
    }
    if (touched) {
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    }
  }

  /// Blanks every widget showing a note from [uid] (used on sign-out).
  static Future<void> clearForUid(String uid) async {
    var touched = false;
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p != null && p['uid'] == uid) {
        await HomeWidget.saveWidgetData<String>(_payloadKey(id), '');
        touched = true;
      }
    }
    if (touched) {
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
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

  /// One-time cleanup: forgets every stored widget. Not called anywhere.
  static Future<void> clearAllWidgets() async {
    for (final id in await widgetIds()) {
      await HomeWidget.saveWidgetData<String>(_payloadKey(id), null);
    }
    await HomeWidget.saveWidgetData<String>(_kIds, '');
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }
}
