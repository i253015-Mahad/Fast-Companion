// test/note_row_alignment_test.dart
//
// Two things about a note row are measured here, because both are decided by
// the field's InputDecoration rather than by the row around it, and neither
// is obvious from reading either one.
//
// 1. Alignment. The label has to sit on the same centre line as every other
//    control in its row: the checkbox and the countdown in a timed task, the
//    row number and the +/- buttons in a counter. That holds for a label on
//    one line and for one that wraps to several. The hint still there before
//    anything is typed is measured whether or not it is showing, so a hint
//    wide enough to wrap makes the field taller than the text actually in it
//    - and the text stays at the top of that box. A short label then reads
//    as sitting high beside the checkbox, which is what prompted this test.
//
// 2. Spacing. A counter needs a good fraction of a line of clear space
//    around it - far more than a line box leaves between its own lines - or a
//    label on two or more lines runs into the counter below it and the rows
//    stop reading as separate things. Nothing else groups these rows: no
//    rule, no stripe, only how far apart they are.
//
// The decorations the fields use are exported by the screens, and the
// counter rows here are the screen's own [CounterRowItem], so what is
// measured is what ships rather than a copy that could drift from it.
//
// The window is the DS BD3 Pro: 1080x2412 at density 3.0 -> 360x804 logical.
// Note that flutter_test draws with a square-glyph font, which is wider than
// the Roboto the phone uses, so the label column comes out narrower here than
// on the device. That makes this a harsher case than the real one, which is
// the point: it still has to line up.
import 'package:fast_companion/Screens/counter_screen.dart';
import 'package:fast_companion/Screens/timed_task_screen.dart';
import 'package:fast_companion/models/note.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// The measured boxes of one note row.
typedef RowGeometry = ({
  Rect glyphs, // where the label's text actually is
  Rect leading, // the checkbox, or the "1." number
  Rect other, // the countdown, or the +/- controls
});

/// The label's text is on the same centre line as the rest of the row, to
/// within a fifth of a pixel.
bool isAligned(RowGeometry g) =>
    (g.glyphs.center.dy - g.leading.center.dy).abs() < 0.2 &&
    (g.glyphs.center.dy - g.other.center.dy).abs() < 0.2;

String describe(RowGeometry g) =>
    'glyphs ${g.glyphs.center.dy} vs leading ${g.leading.center.dy} '
    'vs ${g.other.center.dy}';

/// Runs [body] against the phone this app is used on.
void deviceTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await body(tester);
  });
}

const _heading = TextField(
  decoration: InputDecoration(
    hintText: 'Note Heading',
    border: InputBorder.none,
  ),
);

/// A timed-task row, laid out as `_buildTimedRow` lays it out. The screen's
/// own builder is private and the screen itself cannot be pumped (it reaches
/// for Firebase in a field initializer and runs a ticker), so this mirrors
/// it - which is why the decoration it uses is imported rather than repeated.
Future<RowGeometry> pumpTimedRow(
  WidgetTester tester, {
  required String label,
  required String countdown,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              _heading,
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: ListView(
                  children: [
                    ListTile(
                      key: const Key('tile'),
                      contentPadding: EdgeInsets.zero,
                      leading: const Checkbox(value: false, onChanged: null),
                      title: TextFormField(
                        initialValue: label,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        decoration: kTimedTaskLabelDecoration,
                      ),
                      trailing: KeyedSubtree(
                        key: const Key('trail'),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 6),
                              child: Text(
                                countdown,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const IconButton(
                                icon: Icon(Icons.close, size: 18),
                                onPressed: null),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final title = find.byType(TextFormField);
  final geometry = (
    glyphs: tester.getRect(
        find.descendant(of: title, matching: find.byType(EditableText))),
    leading: tester.getRect(find.byType(Checkbox)),
    other: tester.getRect(find.descendant(
        of: find.byKey(const Key('trail')), matching: find.byType(Text))),
  );
  await tester.pumpWidget(const SizedBox());
  return geometry;
}

/// The counter screen's real row widget, in the screen's real list.
Future<void> pumpCounters(WidgetTester tester, List<String> labels) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              const TextField(
                decoration: InputDecoration(
                  hintText: 'Counter Title',
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: labels.length,
                  itemBuilder: (context, index) => CounterRowItem(
                    key: Key('r$index'),
                    item: CounterItem(label: labels[index]),
                    rowNumber: index + 1,
                    focusNode: FocusNode(),
                    onChanged: () {},
                    onNextRowRequested: () {},
                    onDeleteRequested: () {},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Row [row] of a list built by [pumpCounters].
RowGeometry counterGeometry(WidgetTester tester, int row) {
  final rowKey = find.byKey(Key('r$row'));
  final labelField = find.descendant(
    of: rowKey,
    matching: find.byWidgetPredicate(
        (w) => w is TextField && w.decoration == kCounterLabelDecoration),
  );
  return (
    glyphs: tester.getRect(
        find.descendant(of: labelField, matching: find.byType(EditableText))),
    leading: tester.getRect(
        find.descendant(of: rowKey, matching: find.byType(Text)).first),
    other: tester.getRect(
        find.descendant(of: rowKey, matching: find.byIcon(Icons.add_circle_outline))),
  );
}

/// The counter's own Row, which sits inside the widget's padding, so the
/// distance between two of them is the empty space between two counters.
Rect counterRowBox(WidgetTester tester, int row) => tester.getRect(
    find.descendant(of: find.byKey(Key('r$row')), matching: find.byType(Row)).first);

/// The pitch between two consecutive lines of row [row]'s label: how far the
/// second line's box sits below the first's. Line boxes touch, so this is the
/// scale a reader is judging "too close" against when a label wraps.
double labelLinePitch(WidgetTester tester, int row, String label) {
  final labelField = find.descendant(
    of: find.byKey(Key('r$row')),
    matching: find.byWidgetPredicate(
        (w) => w is TextField && w.decoration == kCounterLabelDecoration),
  );
  final editable = _findEditable(tester.renderObject(labelField));
  expect(editable, isNotNull, reason: 'the label has to have a paragraph');
  final boxes = editable!.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: label.length));

  // One box per run, not per line, so take the first two distinct tops.
  final tops = <double>[];
  for (final b in boxes) {
    if (!tops.contains(b.top)) tops.add(b.top);
    if (tops.length == 2) break;
  }
  expect(tops.length, 2,
      reason: 'the label has to wrap, or there is nothing to compare');
  return tops[1] - tops[0];
}

RenderEditable? _findEditable(RenderObject root) {
  if (root is RenderEditable) return root;
  RenderEditable? found;
  root.visitChildren((child) => found ??= _findEditable(child));
  return found;
}

void main() {
  group('timed task row', () {
    deviceTest('a one-line label sits on the countdown and checkbox line',
        (tester) async {
      final g = await pumpTimedRow(
        tester,
        label: 'HW',
        countdown: '2d 23h left',
      );
      // The label really is on one line, so this is about what it says.
      expect(g.glyphs.height, lessThan(40));
      expect(isAligned(g), isTrue, reason: describe(g));
    });

    deviceTest('a label that wraps stays centred', (tester) async {
      final g = await pumpTimedRow(
        tester,
        label: 'line one\nline two\nline three',
        countdown: '2d 23h left',
      );
      expect(g.glyphs.height, greaterThan(40));
      expect(isAligned(g), isTrue, reason: describe(g));
    });

    deviceTest('an undated task, whose "tap to set date" is the widest '
        'countdown it can show', (tester) async {
      final g = await pumpTimedRow(
        tester,
        label: 'HW',
        countdown: 'tap to set date',
      );
      expect(isAligned(g), isTrue, reason: describe(g));
    });
  });

  group('counter row', () {
    deviceTest('a one-line label sits on the number and buttons line',
        (tester) async {
      await pumpCounters(tester, ['Read']);
      final g = counterGeometry(tester, 0);
      expect(g.glyphs.height, lessThan(40));
      expect(isAligned(g), isTrue, reason: describe(g));
    });

    deviceTest('a label that wraps stays centred', (tester) async {
      await pumpCounters(tester, ['line one\nline two\nline three']);
      final g = counterGeometry(tester, 0);
      expect(g.glyphs.height, greaterThan(40));
      expect(isAligned(g), isTrue, reason: describe(g));
    });
  });

  group('counter rows apart', () {
    deviceTest('counters are further apart than the lines of one label',
        (tester) async {
      const wrapped = 'line one\nline two\nline three';
      await pumpCounters(tester, [wrapped, 'Read']);

      final betweenCounters =
          counterRowBox(tester, 1).top - counterRowBox(tester, 0).bottom;
      final pitch = labelLinePitch(tester, 0, wrapped);

      expect(
        betweenCounters,
        greaterThan(pitch * 0.5),
        reason: 'the space between two counters ($betweenCounters) has to be '
            'a good fraction of a line ($pitch), or a label that wraps reads '
            'straight into the counter below it and the rows stop reading as '
            'separate rows',
      );
    });
  });
}
