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

  static String _countdown(TodoItem item) =>
      formatCountdown(_remaining(item));
}

/// How much of a countdown is left, in the words the home screen widget and
/// the timed-task screen both show.
///
/// It lives in one place because those two have to agree: a task the widget
/// calls "1d 30m left" cannot be a task the screen calls "1d 0h left".
///
/// [d] is the time remaining, never a due date — the callers take that
/// reading themselves.
String formatCountdown(Duration d) {
  if (d == Duration.zero) return 'Time expired';

  if (d.inDays >= 1) {
    final hours = d.inHours % 24;
    // The last hour of a multi-day countdown holds no whole hour, so the
    // hours figure read zero and "1d 0h left" threw that hour away entirely.
    // The minutes are still there, so show those instead.
    if (hours == 0) return '${d.inDays}d ${d.inMinutes % 60}m left';
    return '${d.inDays}d ${hours}h left';
  }
  if (d.inHours >= 1) return '${d.inHours}h ${d.inMinutes % 60}m left';
  if (d.inMinutes >= 1) return '${d.inMinutes}m ${d.inSeconds % 60}s left';
  return '${d.inSeconds}s left';
}
