// lib/services/note_preview.dart   (NEW FILE, Fix 6a)
import '../models/note.dart';

/// Builds the same preview `body` strings the editor screens save, so a
/// widget tap can keep `body` (used by search) in step with the app.
class NotePreview {
  static String todo(List<TodoItem> items) {
    final saved = items.where((i) => i.text.trim().isNotEmpty).toList();
    if (saved.isEmpty) return 'Empty list';
    return saved.map((i) => "${i.isDone ? '☑' : '☐'} ${i.text}").join('\n');
  }

  static String counter(List<CounterItem> items) {
    final saved = items.where((i) => i.label.trim().isNotEmpty).toList();
    if (saved.isEmpty) return 'No counters added';
    return saved.map((i) => '🔢 ${i.label}: ${i.count}').join('\n');
  }

  static String timed(List<TodoItem> items) {
    final saved = items.where((i) => i.text.trim().isNotEmpty).toList();
    if (saved.isEmpty) return 'No active timed tasks';
    return saved.map((i) => '⏳ ${i.text} (${_countdown(i)})').join('\n');
  }

  static Duration _remaining(TodoItem item) {
    if (item.isDone && item.remainingDuration != null) {
      return item.remainingDuration!;
    }
    if (item.dueDateTime == null) return const Duration(days: 99999);
    final diff = item.dueDateTime!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  static String _countdown(TodoItem item) {
    final d = _remaining(item);
    if (d == Duration.zero) return 'Time expired';
    if (d.inDays >= 1) return '${d.inDays}d ${d.inHours % 24}h left';
    if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m left';
    if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s left';
    return '${d.inSeconds}s left';
  }
}
