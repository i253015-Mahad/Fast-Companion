// test/timed_task_order_test.dart
//
// The rule that decides what order timed tasks are shown in, pinned here
// because the screen applies it once a second while the countdown runs —
// a rule that is subtly wrong only shows up as rows that move on their
// own, which is hard to spot in a screenshot and easy to reintroduce.
import 'package:fast_companion/Screens/timed_task_screen.dart';
import 'package:fast_companion/models/note.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sorts [list] exactly as the screen does on every tick: against the
/// clock it is handed, with each task's current position as the tie-break.
List<TodoItem> _onePass(List<TodoItem> list, DateTime now) {
  final rows = [
    for (var i = 0; i < list.length; i++) (item: list[i], position: i),
  ];
  rows.sort(
    (a, b) => compareTimedTasks(a.item, b.item, now, a.position, b.position),
  );
  return [for (final row in rows) row.item];
}

List<String> _textsOf(List<TodoItem> list) => [
  for (final item in list) item.text,
];

void main() {
  final due = DateTime(2026, 10, 20, 9, 0);

  group('compareTimedTasks', () {
    test('tasks sharing a due date hold their order across many ticks', () {
      // This is the bug the fix is for: two tasks with the same due date
      // used to swap places on every pass, forever, because each one was
      // measured against its own reading of the clock. 50 passes with
      // real, moving wall-clock time reproduces what the screen's 1s
      // ticker does.
      var list = [
        TodoItem(text: 'first', dueDateTime: due),
        TodoItem(text: 'second', dueDateTime: due),
        TodoItem(text: 'third', dueDateTime: due),
      ];

      for (var pass = 0; pass < 50; pass++) {
        list = _onePass(list, DateTime.now());
        expect(_textsOf(list), [
          'first',
          'second',
          'third',
        ], reason: 'pass $pass reordered tasks that share a due date');
      }
    });

    test('undated tasks are stable too', () {
      var list = [
        TodoItem(text: 'a'),
        TodoItem(text: 'b'),
        TodoItem(text: 'c'),
      ];

      for (var pass = 0; pass < 50; pass++) {
        list = _onePass(list, DateTime.now());
        expect(_textsOf(list), ['a', 'b', 'c'], reason: 'pass $pass');
      }
    });

    test('overdue tasks are stable rather than piling onto one another', () {
      final past = DateTime(2026, 1, 1);
      var list = [
        TodoItem(text: 'old one', dueDateTime: past),
        TodoItem(text: 'old two', dueDateTime: past),
      ];

      for (var pass = 0; pass < 50; pass++) {
        list = _onePass(list, DateTime.now());
        expect(_textsOf(list), ['old one', 'old two'], reason: 'pass $pass');
      }
    });

    test('unchecked comes before checked', () {
      final list = [
        TodoItem(text: 'done', isDone: true, dueDateTime: due),
        TodoItem(text: 'todo', dueDateTime: due),
      ];

      expect(_textsOf(_onePass(list, DateTime.now())), ['todo', 'done']);
    });

    test('most urgent comes first', () {
      final list = [
        TodoItem(text: 'later', dueDateTime: due.add(const Duration(days: 3))),
        TodoItem(text: 'sooner', dueDateTime: due),
      ];

      expect(_textsOf(_onePass(list, DateTime.now())), ['sooner', 'later']);
    });

    test('tasks with no date sort last', () {
      final list = [
        TodoItem(text: 'someday'),
        TodoItem(text: 'nowish', dueDateTime: due),
      ];

      expect(_textsOf(_onePass(list, DateTime.now())), ['nowish', 'someday']);
    });

    test('a finished task keeps the figure it was finished with', () {
      final done = TodoItem(
        text: 'done',
        isDone: true,
        remainingDuration: const Duration(hours: 3),
      );

      expect(remainingFor(done, DateTime.now()), const Duration(hours: 3));
    });

    test('an unfinished task counts down against the clock it was given', () {
      final now = DateTime(2026, 10, 14, 12, 0);
      final item = TodoItem(
        text: 'soon',
        dueDateTime: now.add(const Duration(minutes: 10)),
      );

      expect(
        remainingFor(item, now),
        const Duration(minutes: 10),
        reason:
            'must not read its own clock, or two equal tasks tie-break '
            'against two different times',
      );
    });
  });
}
