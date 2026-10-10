// lib/services/home_widget_service.dart
import 'dart:convert';
import 'package:home_widget/home_widget.dart';
import '../models/note.dart';

/// Bridges a chosen Note to the Android home screen widget.
///
/// Unlike the earlier text-preview version, this saves the note's actual
/// STRUCTURED data (todoList / counterList as JSON), not a flattened
/// string — that's what lets the widget show a real checkbox/counter row
/// per item and know which item index was tapped when it reports back.
class HomeWidgetService {
  // Must match the class name of the AppWidgetProvider on the Android side
  // (NotesWidgetProvider.kt).
  static const String _androidWidgetName = 'NotesWidgetProvider';

  static const _kPayload = 'pinned_payload';
  // Kept for isPinned()/back-compat checks — cheap to read without
  // decoding the whole JSON payload.
  static const _kUid = 'pinned_uid';
  static const _kNoteId = 'pinned_note_id';

  /// Pins `note` (belonging to `uid`) to the widget.
  static Future<void> pinNote(String uid, Note note) async {
    final payload = {
      'uid': uid,
      'noteId': note.id,
      'type': note.type,
      'title': note.title.isEmpty ? 'Untitled' : note.title,
      'body': note.body.isEmpty ? 'No content' : note.body,
      'todoList': note.todoList
          .map(
            (t) => {
              'text': t.text,
              'isDone': t.isDone,
              'meta': _formatMeta(t),
            },
          )
          .toList(),
      'counterList': note.counterList
          .map((c) => {'label': c.label, 'count': c.count})
          .toList(),
    };
    await HomeWidget.saveWidgetData<String>(_kPayload, jsonEncode(payload));
    await HomeWidget.saveWidgetData<String>(_kUid, uid);
    await HomeWidget.saveWidgetData<String>(_kNoteId, note.id);
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }

  /// Call this after local notes are reloaded (edit, delete, star, sync —
  /// anywhere `_localNotes` refreshes). Keeps the widget's structured data
  /// in sync with the real note; clears it to a friendly message if the
  /// pinned note was deleted.
  static Future<void> syncIfNeeded(String? uid, List<Note> currentNotes) async {
    if (uid == null) return;
    final pinnedUid = await HomeWidget.getWidgetData<String>(_kUid);
    final pinnedId = await HomeWidget.getWidgetData<String>(_kNoteId);
    if (pinnedUid != uid || pinnedId == null) return;

    final matches = currentNotes.where((n) => n.id == pinnedId);
    if (matches.isEmpty) {
      await HomeWidget.saveWidgetData<String>(_kPayload, '');
      await HomeWidget.updateWidget(androidName: _androidWidgetName);
    } else {
      await pinNote(uid, matches.first);
    }
  }

  static Future<bool> isPinned(String uid, String noteId) async {
    final pinnedUid = await HomeWidget.getWidgetData<String>(_kUid);
    final pinnedId = await HomeWidget.getWidgetData<String>(_kNoteId);
    return pinnedUid == uid && pinnedId == noteId;
  }

  // NOTE: this is computed at the moment the widget data is saved (pin,
  // edit, sync) — Android widgets don't get a free per-minute tick, so a
  // "Due in 2h" line will read stale until the next refresh (app opened,
  // note edited, or the widget resized). A live countdown would need a
  // periodic update, which isn't set up here.
  static String? _formatMeta(TodoItem t) {
    if (t.dueDateTime != null) {
      final diff = t.dueDateTime!.difference(DateTime.now());
      if (diff.isNegative) {
        return 'Overdue by ${_formatDuration(diff.abs())}';
      }
      return 'Due in ${_formatDuration(diff)}';
    }
    if (t.remainingDuration != null) {
      return '${_formatDuration(t.remainingDuration!)} left';
    }
    return null;
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }
}
