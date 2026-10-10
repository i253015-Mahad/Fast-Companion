// lib/services/home_widget_service.dart   (REPLACES the old file, Fix 4a)
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
    // side formats them at draw time (Fix 8).
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
  /// background (widget tap) handler.
  static Future<void> refreshNote(String uid, Note note) async {
    var touched = false;
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      if (p != null && p['uid'] == uid && p['noteId'] == note.id) {
        await HomeWidget.saveWidgetData<String>(
          _payloadKey(id),
          jsonEncode(_buildPayload(uid, note)),
        );
        touched = true;
      }
    }
    if (touched) {
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    }
  }

  /// Call after local notes reload (HomeScreen._refreshLocalNotes already does).
  /// Refreshes each widget pinned to a note of [uid]; blanks it if the note is gone.
  static Future<void> syncIfNeeded(String? uid, List<Note> currentNotes) async {
    print('🔄 widget sync: uid=$uid, ${currentNotes.length} notes');
    if (uid == null) return;
    var touched = false;
    final ids = await widgetIds();
    print('🔄 widget sync: widget ids=$ids');
    for (final id in ids) {
      final p = await _readPayload(id);
      print('🔄 widget $id pinned: uid=${p?['uid']} noteId=${p?['noteId']}');
      if (p == null || p['uid'] != uid) continue;
      final matches = currentNotes.where((n) => n.id == p['noteId']);
      await HomeWidget.saveWidgetData<String>(
        _payloadKey(id),
        matches.isEmpty ? '' : jsonEncode(_buildPayload(uid, matches.first)),
      );
      touched = true;
    }
    if (touched) {
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    }
  }

  /// Blanks every widget showing a note from [uid] (used on sign-out, Fix 5).
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

  /// For the in-app "which widget?" picker (Fix 7).
  static Future<List<({int id, String title})>> widgetSummaries() async {
    final result = <({int id, String title})>[];
    for (final id in await widgetIds()) {
      final p = await _readPayload(id);
      result.add((id: id, title: (p?['title'] as String?) ?? '(empty)'));
    }
    return result;
  }
}
