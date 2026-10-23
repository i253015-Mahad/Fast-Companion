// Undo and redo for an open note.
//
// The two rules that make this usable rather than infuriating: a run of
// typing is ONE step (undoing a word letter by letter is why people stop
// using undo), and a structural change never folds into the typing around it.

import 'package:fast_companion/services/note_history.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Short enough to keep the suite quick, long enough to be unambiguous
  // against a machine that occasionally stalls.
  const burst = Duration(milliseconds: 25);
  Future<void> settle() => Future<void>.delayed(burst * 4);

  NoteHistory open(String initial, {int limit = 80}) =>
      NoteHistory(initial: initial, burst: burst, limit: limit);

  group('a single step', () {
    test('records forward and walks back once', () {
      final h = open('a');
      h.record('b');
      expect(h.canUndo, isTrue);
      expect(h.undo(), 'a');
      expect(h.canUndo, isFalse);
      expect(h.undo(), isNull);
    });

    test('redo returns what undo took away', () {
      final h = open('a');
      h.record('b');
      h.undo();
      expect(h.canRedo, isTrue);
      expect(h.redo(), 'b');
      expect(h.canRedo, isFalse);
      expect(h.redo(), isNull);
    });

    test('a new change after an undo throws the redo away', () {
      final h = open('a');
      h.record('b');
      h.undo();
      h.record('c');
      expect(h.canRedo, isFalse, reason: 'c is a new branch, not a redo');
      expect(h.undo(), 'a');
    });

    test('recording the same state is not a step', () {
      final h = open('a');
      h.record('a');
      expect(h.canUndo, isFalse);
    });
  });

  group('typing', () {
    test('a run of keystrokes collapses into one step', () async {
      final h = open('a');
      h.record('ab');
      h.record('abc');
      h.record('abcd');
      await settle();

      // One undo leaves the whole word, not one letter of it.
      expect(h.undo(), 'a');
      expect(h.canUndo, isFalse);
    });

    test('redo comes back to the end of the run', () async {
      final h = open('a');
      h.record('ab');
      h.record('abc');
      await settle();

      h.undo();
      expect(h.redo(), 'abc');
    });

    test('quiet between runs separates them again', () async {
      final h = open('a');
      h.record('b');
      await settle();
      h.record('c');

      expect(h.undo(), 'b');
      expect(h.undo(), 'a');
    });
  });

  group('structural changes', () {
    test('discrete steps cut a typing run short', () async {
      final h = open('a');
      h.record('typed', discrete: false);
      // A row deleted straight after typing its name is its own step, so the
      // text it was typed into can still be undone to separately.
      h.record('deleted', discrete: true);

      expect(h.undo(), 'typed');
      expect(h.undo(), 'a');
    });

    test('a discrete step lands even inside a run', () async {
      final h = open('a');
      h.record('b');
      h.record('c'); // still inside the burst
      h.record('d', discrete: true);

      expect(h.undo(), 'c');
      expect(h.undo(), 'a');
    });
  });

  group('bounded', () {
    test('the stack never grows past its limit', () async {
      final h = open('a', limit: 3);
      for (final s in ['b', 'c', 'd', 'e']) {
        h.record(s);
        await settle();
      }

      var steps = 0;
      while (h.undo() != null) {
        steps++;
      }
      expect(steps, 3, reason: 'limit 3 means exactly three steps back');
    });
  });

  group('rebase', () {
    test('starts again from fresh contents, with nothing behind it', () async {
      final h = open('a');
      h.record('b');
      await settle();

      // The screen re-read its note from disk and now shows something else.
      h.rebase('fresh');

      expect(
        h.canUndo,
        isFalse,
        reason: 'those steps belong to contents the student is no longer '
            'looking at, so an undo would be a jump to a note they never '
            'saw on this screen',
      );
      expect(h.canRedo, isFalse);

      h.record('fresh2');
      await settle();
      expect(h.undo(), 'fresh');
    });

    test('closes a run of typing, so the swap is not folded into it', () async {
      final h = open('a');
      h.record('typing'); // burst still open
      h.rebase('fresh');
      h.record('after');

      expect(h.undo(), 'fresh');
    });
  });

  group('notifies', () {
    test('buttons hear about record, undo and redo', () {
      final h = open('a');
      var calls = 0;
      h.addListener(() => calls++);

      h.record('b');
      h.undo();
      h.redo();
      expect(calls, 3);
    });

    test('a no-op change leaves the buttons alone', () {
      final h = open('a');
      var calls = 0;
      h.addListener(() => calls++);

      h.record('a');
      expect(calls, 0);
    });

    test('a timer left open is cancelled on dispose', () async {
      final h = open('a');
      h.record('b');
      // Disposing mid-burst must not leave a pending timer to trip a
      // strict test environment when the note is closed.
      h.dispose();
      await settle();
    });
  });
}
