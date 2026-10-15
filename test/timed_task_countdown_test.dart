// test/timed_task_countdown_test.dart
//
// The words a countdown is shown in. The home screen widget and the
// timed-task screen count the same task down side by side, so the formatter
// is shared — and the branch it got wrong was the last hour of a multi-day
// countdown, which no screenshot of a busy screen makes obvious.
import 'package:fast_companion/models/note.dart';
import 'package:fast_companion/services/note_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatCountdown', () {
    test('the last hour of a multi-day countdown shows its minutes', () {
      // The bug: a day and a half left read "1d 0h left". `inHours` is a
      // count of the whole hours in the duration, so at a day and a half it
      // is 24 — and 24 % 24 is 0. The hour was still there; only the
      // arithmetic hid it.
      expect(
        formatCountdown(const Duration(days: 1, minutes: 30)),
        '1d 30m left',
      );
      expect(
        formatCountdown(const Duration(days: 3, minutes: 5)),
        '3d 5m left',
      );
      // A day on the nose has no minutes either, and says so plainly rather
      // than claiming a whole hour it does not have.
      expect(formatCountdown(const Duration(days: 1)), '1d 0m left');
    });

    test('a multi-day countdown with hours left still shows the hours', () {
      expect(
        formatCountdown(const Duration(days: 1, hours: 2)),
        '1d 2h left',
      );
      expect(
        formatCountdown(const Duration(days: 2, hours: 23, minutes: 59)),
        '2d 23h left',
      );
    });

    test('countdowns under a day are unchanged', () {
      expect(
        formatCountdown(const Duration(hours: 3, minutes: 45)),
        '3h 45m left',
      );
      expect(
        formatCountdown(const Duration(minutes: 45, seconds: 20)),
        '45m 20s left',
      );
      expect(formatCountdown(const Duration(seconds: 30)), '30s left');
    });

    test('an expired task says so', () {
      expect(formatCountdown(Duration.zero), 'Time expired');
    });
  });

  group('NotePreview.timed', () {
    test('the widget shows the same words as the shared formatter', () {
      // A finished task keeps the duration it had when it was finished, so
      // it can be rendered at a fixed point in the countdown instead of
      // against a wall clock that moves between building and asserting.
      final note = [
        TodoItem(
          text: 'ISE assignment',
          isDone: true,
          remainingDuration: const Duration(days: 1, minutes: 30),
        ),
      ];

      expect(
        NotePreview.timed(note),
        '⏳ ISE assignment (1d 30m left)',
      );
    });
  });
}
