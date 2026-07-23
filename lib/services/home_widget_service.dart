// lib/services/home_widget_service.dart
import 'package:home_widget/home_widget.dart';
import '../models/note.dart';

/// Bridges a chosen Note to the Android home screen widget.
///
/// Data flows one-way: app -> shared native storage -> widget. The widget
/// itself is read-only (tapping it just opens the app); all the "which
/// note, what content" logic lives here.
class HomeWidgetService {
  // Must match the class name of the AppWidgetProvider on the Android side
  // (NotesWidgetProvider.kt).
  static const String _androidWidgetName = 'NotesWidgetProvider';

  static const _kUid = 'pinned_uid';
  static const _kNoteId = 'pinned_note_id';
  static const _kTitle = 'pinned_title';
  static const _kBody = 'pinned_body';

  /// Pins `note` (belonging to `uid`) to the widget.
  static Future<void> pinNote(String uid, Note note) async {
    await HomeWidget.saveWidgetData<String>(_kUid, uid);
    await HomeWidget.saveWidgetData<String>(_kNoteId, note.id);
    await HomeWidget.saveWidgetData<String>(
      _kTitle,
      note.title.isEmpty ? 'Untitled' : note.title,
    );
    await HomeWidget.saveWidgetData<String>(_kBody, _previewFor(note));
    await HomeWidget.updateWidget(androidName: _androidWidgetName);
  }

  /// Call this after local notes are reloaded (edit, delete, star, sync —
  /// anywhere `_localNotes` refreshes). If the currently pinned note is in
  /// the list, the widget is refreshed with its latest content. If it's
  /// gone (deleted), the widget shows a friendly "removed" message instead
  /// of stale content.
  static Future<void> syncIfNeeded(String? uid, List<Note> currentNotes) async {
    if (uid == null) return;
    final pinnedUid = await HomeWidget.getWidgetData<String>(_kUid);
    final pinnedId = await HomeWidget.getWidgetData<String>(_kNoteId);
    if (pinnedUid != uid || pinnedId == null) return;

    final matches = currentNotes.where((n) => n.id == pinnedId);
    if (matches.isEmpty) {
      await HomeWidget.saveWidgetData<String>(_kTitle, 'Note removed');
      await HomeWidget.saveWidgetData<String>(
        _kBody,
        'Pin another note from the app.',
      );
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

  static String _previewFor(Note note) {
    switch (note.type) {
      case 'todo':
        if (note.todoList.isEmpty) return 'No items yet';
        return note.todoList
            .take(10)
            .map((t) => (t.isDone ? '☑ ' : '☐ ') + t.text)
            .join('\n');
      case 'counter':
        if (note.counterList.isEmpty) return 'No counters yet';
        return note.counterList
            .take(10)
            .map((c) => '${c.label}: ${c.count}')
            .join('\n');
      default:
        return note.body.isEmpty ? 'No content' : note.body;
    }
  }
}
