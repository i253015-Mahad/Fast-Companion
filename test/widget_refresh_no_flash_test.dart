// The widget re-binds its list whenever the provider decides the rows changed,
// and on the launcher this runs on a re-bind blanks the list for a frame. That
// is the "flashes 2-3 seconds after I press a button" bug, so these two tests
// pin what stops it:
//
//   1. a save whose result already matches what the widget shows broadcasts
//      nothing at all;
//   2. a save that does broadcast must not rewrite the countdown the widget is
//      already drawing — the rows it hands back have to be the rows on screen,
//      which is what lets NotesWidgetProvider skip the re-bind.

import 'dart:convert';

import 'package:fast_companion/models/note.dart';
import 'package:fast_companion/services/home_widget_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('home_widget');
  const uid = 'u1';
  const noteId = 'n1';

  final store = <String, Object?>{};
  var broadcasts = 0;

  setUp(() {
    store.clear();
    broadcasts = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          switch (call.method) {
            case 'getWidgetData':
              return store[args['id']];
            case 'saveWidgetData':
              store[args['id']! as String] = args['data'];
              return true;
            case 'updateWidget':
              broadcasts++;
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  // A fixed due date keeps the arithmetic below independent of the wall clock.
  final dueMs = DateTime(2026, 10, 20).millisecondsSinceEpoch;
  final tappedAt = DateTime(2026, 10, 15, 12, 0, 0);
  final savedAt = tappedAt.add(const Duration(seconds: 4));
  final muchLaterAt = tappedAt.add(const Duration(seconds: 25));

  int frozenAt(DateTime when) => dueMs - when.millisecondsSinceEpoch;

  Map<String, dynamic> payloadOnWidget({
    required int remainingMs,
    required String body,
  }) => {
    'uid': uid,
    'noteId': noteId,
    'type': 'timed',
    'title': 'DS assignment 3',
    'body': body,
    'todoList': [
      {
        'text': 'DS assignment 3',
        'isDone': true,
        'dueMs': dueMs,
        'remainingMs': remainingMs,
      },
    ],
    'counterList': [],
  };

  /// What Dart recomputes after the widget tap has been saved.
  Note noteAfterSave({required int remainingMs, required String body}) => Note(
    id: noteId,
    title: 'DS assignment 3',
    body: body,
    type: 'timed',
    todoList: [
      TodoItem(
        text: 'DS assignment 3',
        isDone: true,
        dueDateTime: DateTime.fromMillisecondsSinceEpoch(dueMs),
        remainingDuration: Duration(milliseconds: remainingMs),
      ),
    ],
  );

  void seed(Map<String, dynamic> payload) {
    store['widget_ids'] = '7';
    store['payload_7'] = jsonEncode(payload);
  }

  test('a save that matches the widget requests no redraw at all', () async {
    final onWidget = payloadOnWidget(
      remainingMs: frozenAt(tappedAt),
      body: 'preview before',
    );
    seed(onWidget);

    await HomeWidgetService.refreshNote(
      uid,
      noteAfterSave(remainingMs: frozenAt(savedAt), body: 'preview after'),
    );

    expect(
      broadcasts,
      0,
      reason:
          'the widget already shows this value — broadcasting would re-bind it '
          'for nothing, which is a flash',
    );
    expect(
      store['payload_7'],
      jsonEncode(onWidget),
      reason: 'nothing changed, so nothing should have been written',
    );
  });

  test('a save that does broadcast keeps the countdown on screen', () async {
    final onWidget = payloadOnWidget(
      remainingMs: frozenAt(tappedAt),
      body: 'preview before',
    );
    seed(onWidget);

    // The save took longer than _remainingMsTolerance, so _same() sees a real
    // difference and an update does go out. The rows it carries still have to
    // be the rows already on screen, or the provider re-binds them and the
    // launcher blanks the list for a frame.
    await HomeWidgetService.refreshNote(
      uid,
      noteAfterSave(remainingMs: frozenAt(muchLaterAt), body: 'preview after'),
    );

    expect(broadcasts, 1);

    final written = jsonDecode(store['payload_7']! as String) as Map<String, dynamic>;
    final row = (written['todoList'] as List).first as Map<String, dynamic>;

    expect(
      row['remainingMs'],
      frozenAt(tappedAt),
      reason:
          'the widget is still drawing the value frozen at tap time; writing a '
          'differently-seconds number would look like a new row',
    );
    expect(row['isDone'], isTrue);
    expect(row['dueMs'], dueMs);
    expect(
      written['body'],
      'preview after',
      reason: 'the body is not part of the row signature, so it should update',
    );
  });

  // A widget's RemoteViews live only inside the launcher, and replacing the
  // APK makes it drop them and fall back to the layout's "no notes pinned"
  // default. Both of these requests can arrive exactly then, so neither is
  // allowed to be answered by comparing against our own stored signatures.
  test('pinning always asks the provider to draw, never to skip', () async {
    final pinned = noteAfterSave(
      remainingMs: frozenAt(tappedAt),
      body: 'preview after',
    );
    seed(payloadOnWidget(remainingMs: frozenAt(tappedAt), body: 'preview before'));

    await HomeWidgetService.pinNote(7, uid, pinned);

    expect(broadcasts, 1, reason: 'pinning has to reach the provider');
    expect(
      store['soft_update_7'],
      isNull,
      reason:
          'flagging the pinned widget as content-only lets the provider decide '
          'the frame is unchanged and draw nothing — which is how the widget '
          'got stuck on "no notes pinned"',
    );
  });

  test('the launch self-check reaches the provider as a check, not a redraw', () async {
    seed(payloadOnWidget(remainingMs: frozenAt(tappedAt), body: 'preview before'));

    await HomeWidgetService.ensureWidgetsDrawn();

    expect(broadcasts, 1);
    expect(store['verify_7'], isNotNull);
    expect(
      store['soft_update_7'],
      isNull,
      reason: 'the self-check says "look", not "redraw"',
    );
  });

  test('the launch self-check asks for nothing when no widget is known', () async {
    await HomeWidgetService.ensureWidgetsDrawn();

    expect(broadcasts, 0);
  });
}