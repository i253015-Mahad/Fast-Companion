// test/keyboard_next_focus_test.dart
//
// Why pressing "next" blinked the keyboard out and back when it added a row.
//
// The reaction to TextInputAction.next is decided in EditableText's
// _finalizeEditing. With no onEditingComplete of ours, the default is
// FocusNode.nextFocus(): focus jumps to whatever focusable happens to follow
// the field — in a note row that is the row's own count box, or its delete
// button — and only after that does onSubmitted run, build the new row, and
// focus it a frame later. Two hops, with the keyboard dropping and
// reconnecting in between, which is what the eye reads as a blink.
//
// Supplying onEditingComplete replaces that entire default branch and still
// calls onSubmitted afterwards, so what is left is a single transfer.
//
// What is measured here is therefore the number of focus hops and where they
// land. flutter_test has no IME to assert against, but the keyboard follows
// focus, so a focus trace is the behaviour under test.
//
// The screens themselves cannot be pumped: each reaches for Firebase in a
// field initializer, and the timed screen additionally runs a ticker that
// pumpAndSettle would never settle against. So the screens' own row widgets
// are pumped in a harness that mirrors each screen's create-row-and-focus-it
// method — the arrangement test/note_row_alignment_test.dart already uses,
// for the same reason.

import 'package:fast_companion/Screens/counter_screen.dart';
import 'package:fast_companion/Screens/todo_screen.dart';
import 'package:fast_companion/models/note.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where focus sat before "next" was pressed, immediately after it, and once
/// the row it created had been built.
typedef FocusTrace = ({FocusNode? before, FocusNode? during, FocusNode? after});

/// Runs [body] against the phone this app is used on.
void deviceTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await body(tester);
  });
}

/// Presses the keyboard's "next" key on [labelField] and reports where focus
/// went.
///
/// The middle reading is taken before a single frame is drawn, so it sees
/// whatever the framework did on its own — which is exactly the hop this
/// whole file is about.
Future<FocusTrace> pressNext(WidgetTester tester, Finder labelField) async {
  await tester.showKeyboard(labelField);
  final before = FocusManager.instance.primaryFocus;

  await tester.testTextInput.receiveAction(TextInputAction.next);
  final during = FocusManager.instance.primaryFocus;

  await tester.pumpAndSettle();
  final after = FocusManager.instance.primaryFocus;

  return (before: before, during: during, after: after);
}

/// The one rule the fix exists to satisfy.
void expectSingleHop(FocusTrace t, {required String what}) {
  expect(
    t.during,
    same(t.before),
    reason: '$what: focus moved before the new row even existed, so the '
        'framework did a nextFocus() of its own and the keyboard dropped '
        'and came back on the way to the new row',
  );
  expect(t.after, isNotNull, reason: '$what: focus has to end up somewhere');
  expect(
    t.after,
    isNot(same(t.before)),
    reason: '$what: focus must reach the row that was just created',
  );
}

// ---------------------------------------------------------------------------
// Counter
// ---------------------------------------------------------------------------

/// The label fields of a counter, in row order.
final _counterLabels = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration == kCounterLabelDecoration);

/// The counter screen, minus the Firebase: the same rows, and the same
/// _createNewCounterRow.
class CounterHarness extends StatefulWidget {
  const CounterHarness({super.key});

  @override
  State<CounterHarness> createState() => _CounterHarnessState();
}

class _CounterHarnessState extends State<CounterHarness> {
  final List<CounterItem> items = [
    CounterItem(label: 'first'),
    CounterItem(label: 'second'),
  ];
  final List<FocusNode> nodes = [FocusNode(), FocusNode()];

  @override
  void dispose() {
    for (final n in nodes) {
      n.dispose();
    }
    super.dispose();
  }

  // Mirrors CounterScreen._createNewCounterRow.
  void createNewCounterRow(int currentIndex) {
    setState(() {
      items.insert(currentIndex + 1, CounterItem(label: "", count: 0));
      final node = FocusNode();
      nodes.insert(currentIndex + 1, node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (node.canRequestFocus) node.requestFocus();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
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
                itemCount: items.length,
                itemBuilder: (context, index) => CounterRowItem(
                  key: ValueKey(items[index]),
                  item: items[index],
                  rowNumber: index + 1,
                  focusNode: nodes[index],
                  onChanged: () {},
                  onNextRowRequested: () => createNewCounterRow(index),
                  onDeleteRequested: () {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Todo
// ---------------------------------------------------------------------------

/// The item fields of a list, in row order.
final _todoItems = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.hintText == 'List item');

/// The todo screen, minus the Firebase: the same rows, and the same
/// _createNewItemRow.
class TodoHarness extends StatefulWidget {
  const TodoHarness({super.key});

  @override
  State<TodoHarness> createState() => _TodoHarnessState();
}

class _TodoHarnessState extends State<TodoHarness> {
  final List<TodoItem> items = [
    TodoItem(text: 'first'),
    TodoItem(text: 'second'),
  ];
  final List<FocusNode> nodes = [FocusNode(), FocusNode()];

  @override
  void dispose() {
    for (final n in nodes) {
      n.dispose();
    }
    super.dispose();
  }

  // Mirrors TodoScreen._createNewItemRow. The screen additionally keeps a
  // rank per item so that ticking a box can put a row back where it came
  // from; that decides which side of the "checked items" line a row sits on
  // and has no bearing on focus, so it is left out.
  void createNewItemRow(int currentIndex) {
    setState(() {
      items.insert(currentIndex + 1, TodoItem(text: ""));
      final node = FocusNode();
      nodes.insert(currentIndex + 1, node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (node.canRequestFocus) node.requestFocus();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const TextField(
              decoration: InputDecoration(
                hintText: 'List Title',
                border: InputBorder.none,
              ),
            ),
            const Divider(color: Colors.white24, thickness: 1),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, index) => TodoRowItem(
                  key: ValueKey(items[index]),
                  item: items[index],
                  focusNode: nodes[index],
                  onChanged: () {},
                  onNextRowRequested: () => createNewItemRow(index),
                  onDeleteRequested: () {},
                  onDoneChanged: (_) {},
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  group('counter', () {
    deviceTest('"next" hands focus straight to the row it just added',
        (tester) async {
      await tester.pumpWidget(const CounterHarness());
      await tester.pumpAndSettle();

      final t = await pressNext(tester, _counterLabels.first);

      expectSingleHop(t, what: 'counter');

      final labels = tester.widgetList<TextField>(_counterLabels).toList();
      expect(labels, hasLength(3), reason: 'a row has to have been added');
      expect(
        labels[1].focusNode,
        same(t.after),
        reason: 'the added row is the second one, and it is the new row\'s '
            'label — not a count box and not a button — that has to take the '
            'focus the keyboard stays open for',
      );
    });
  });

  group('todo', () {
    deviceTest('"next" hands focus straight to the row it just added',
        (tester) async {
      await tester.pumpWidget(const TodoHarness());
      await tester.pumpAndSettle();

      final t = await pressNext(tester, _todoItems.first);

      expectSingleHop(t, what: 'todo');

      final items = tester.widgetList<TextField>(_todoItems).toList();
      expect(items, hasLength(3), reason: 'a row has to have been added');
      expect(
        items[1].focusNode,
        same(t.after),
        reason: 'the added row is the second one, and it is the new row\'s '
            'field that has to take the focus the keyboard stays open for',
      );
    });
  });
}
