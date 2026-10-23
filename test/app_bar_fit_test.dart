// test/app_bar_fit_test.dart
//
// What the undo and redo buttons are allowed to cost the screen's title.
//
// These bars were already full before them: a back button, a title that is a
// phrase rather than a word, and a save tick. On the 360dp-wide phone this
// app is used on the title has about 280dp to work with, and "Timed Tasks
// Track" and "Edit Counter List" each need roughly 170 of that in Roboto —
// so the two new buttons have about 110dp of slack to spend before the
// titles start losing characters off the end.
//
// A pair of IconButtons spends 96 of it, which is close enough to call it a
// regression waiting to happen. The buttons in NoteHistoryActions are 32dp
// ink wells rather than IconButtons for exactly this reason — an IconButton
// in an app bar is floored at 48dp, and constraints, padding and
// minimumSize all measure as having no effect on that.
//
// Note that flutter_test draws with a square-glyph font much wider than the
// Roboto the phone uses (the same caveat test/note_row_alignment_test.dart
// records), so a title here is about twice its real width. This test
// therefore asserts what the buttons *cost*, measured against a bar that has
// only the save tick — a difference, which the font cannot skew — rather
// than whether the title fits, which the font would misreport entirely.

import 'package:fast_companion/services/note_history.dart';
import 'package:fast_companion/widgets/note_history_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// How much width the bar leaves the title.
Future<double> _titleRoom(WidgetTester tester, {required bool withHistory}) async {
  const title = 'Timed Tasks Track';
  final history = NoteHistory(initial: 'a');
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(title, style: TextStyle(color: Colors.white)),
          actions: [
            if (withHistory)
              NoteHistoryActions(
                history: history,
                onUndo: () => history.undo(),
                onRedo: () => history.redo(),
              ),
            IconButton(
              icon: const Icon(Icons.check, size: 28),
              onPressed: () {},
            ),
          ],
        ),
        body: const SizedBox(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final room = tester.getRect(find.text(title)).width;
  history.dispose();
  await tester.pumpWidget(const SizedBox());
  return room;
}

void main() {
  testWidgets('undo and redo leave the title its room', (tester) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final alone = await _titleRoom(tester, withHistory: false);
    final withButtons = await _titleRoom(tester, withHistory: true);
    final cost = alone - withButtons;

    expect(
      cost,
      lessThanOrEqualTo(64),
      reason: 'the two history buttons took ${cost.toStringAsFixed(0)}dp off '
          'the title. Only about 110dp of the bar is spare, so a pair of '
          '48dp IconButtons — which cost 96 — leaves the longest titles '
          'hanging on. Keep them at 32dp, or find the room somewhere else.',
    );
  });
}
