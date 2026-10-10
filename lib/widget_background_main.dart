// lib/widget_background_main.dart
//
// This runs in a HEADLESS Flutter engine — no UI, no visible app — spun up
// briefly by Android when someone taps a checkbox or +/- button on the
// widget. It's wired up via home_widget's interactivity callback
// (HomeWidget.registerInteractivityCallback in main.dart).
//
// The actual counter/todo value is always sourced from a Firebase
// transaction (see runTransaction calls below), which reads whatever the
// server's true current value is at write time. This is what makes the
// widget's writes immune to any local-cache staleness.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

import 'firebase_options.dart';
import 'models/note.dart';
import 'services/local_storage_service.dart';
import 'services/multi_account_auth_service.dart';
import 'services/home_widget_service.dart';
import 'services/note_preview.dart'; // NEW (Fix 6)

Future<void> _ensureFirebase() async {
  // If this headless engine shares the app's process with an already-
  // running main engine, calling initializeApp() again throws "duplicate
  // app". This guard avoids that.
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  }
}

/// Called from the tiny `widgetBackgroundCallback()` wrapper that must live
/// in main.dart itself — same rule as the widget configuration entry point.
Future<void> runWidgetBackgroundAction(Uri? uri) async {
  print('🔘 widget background action fired: $uri');
  try {
    if (uri == null) {
      print('⚠️ widget background: uri was null, aborting');
      return;
    }

    final uid = uri.queryParameters['uid'];
    final noteId = uri.queryParameters['noteId'];
    if (uid == null || uid.isEmpty || noteId == null || noteId.isEmpty) {
      print('⚠️ widget background: missing uid/noteId in $uri, aborting');
      return;
    }

    await _ensureFirebase();

    final accounts = await LocalStorageService.loadAccounts();
    // CHANGED (Fix 3c): a cold headless engine can be slow to rehydrate auth.
    await MultiAccountAuthService.instance.restoreSessions(
      accounts,
      authTimeout: const Duration(seconds: 8),
    );
    final gotSession = MultiAccountAuthService.instance.sessionFor(uid) != null;
    print('🔎 widget background: session for $uid restored? $gotSession');

    final notes = await LocalStorageService.loadNotes(uid);
    final idx = notes.indexWhere((n) => n.id == noteId);
    if (idx == -1) {
      print(
        '⚠️ widget background: note $noteId not found for uid $uid, aborting',
      );
      return;
    }
    final note = notes[idx];

    final session = MultiAccountAuthService.instance.sessionFor(uid);

    if (uri.host == 'toggletodo') {
      final index = int.tryParse(uri.queryParameters['index'] ?? '') ?? -1;
      if (index < 0 || index >= note.todoList.length) {
        print('⚠️ widget background: todo index $index out of range, aborting');
        return;
      }

      if (session == null) {
        print(
          '⚠️ widget background: no live session for $uid, aborting todo toggle',
        );
        return;
      }

      // Transaction: reads the SERVER's true current isDone at write time
      // and flips it atomically, so it can't be reverted by a stale local
      // snapshot.
      final doneRef = session.database
          .ref()
          .child('users')
          .child(uid)
          .child('notes')
          .child(noteId)
          .child('todoList')
          .child('$index')
          .child('isDone');

      final old = note.todoList[index];
      bool resultDone = !old.isDone; // fallback if the transaction fails
      try {
        final result = await doneRef
            .runTransaction((Object? currentData) {
              final current = currentData == true;
              return Transaction.success(!current);
            })
            .timeout(const Duration(seconds: 15));
        if (result.committed) {
          resultDone = result.snapshot.value == true;
          print(
            '✅ widget background: todo transaction committed, isDone=$resultDone',
          );
        } else {
          print(
            '⚠️ widget background: todo transaction not committed, using local fallback',
          );
        }
      } catch (e) {
        print(
          '⚠️ widget background: todo transaction failed, using local fallback: $e',
        );
      }

      // NEW (Fix 6): mirror what TimedTaskScreen does when an item is
      // ticked — freeze the remaining time; clear it when un-ticked.
      Duration? remaining;
      if (resultDone && old.dueDateTime != null) {
        final diff = old.dueDateTime!.difference(DateTime.now());
        remaining = diff.isNegative ? Duration.zero : diff;
      }

      final updatedTodoList = List<TodoItem>.from(note.todoList);
      updatedTodoList[index] = TodoItem(
        text: old.text,
        isDone: resultDone,
        dueDateTime: old.dueDateTime,
        remainingDuration: remaining,
      );

      final newBody = note.type == 'timed'
          ? NotePreview.timed(updatedTodoList)
          : NotePreview.todo(updatedTodoList);

      // One multi-path update keeps the cloud copy in step with the in-app
      // screens. A null value deletes the key (what we want when un-ticking).
      try {
        await session.database
            .ref()
            .child('users')
            .child(uid)
            .child('notes')
            .child(noteId)
            .update({
              'body': newBody,
              'todoList/$index/remainingDurationMs': remaining?.inMilliseconds,
            })
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        print('⚠️ widget background: body/remaining update failed: $e');
      }

      final updatedNote = Note(
        id: note.id,
        title: note.title,
        body: newBody,
        isStarred: note.isStarred,
        type: note.type,
        todoList: updatedTodoList,
        counterList: note.counterList,
      );

      notes[idx] = updatedNote;
      await LocalStorageService.saveNotes(uid, notes);
      // CHANGED (Fix 4d): refresh every widget showing this note.
      await HomeWidgetService.refreshNote(uid, updatedNote);
      print('✅ widget background: toggled todo $index on note $noteId');
    } else if (uri.host == 'adjustcounter') {
      final index = int.tryParse(uri.queryParameters['index'] ?? '') ?? -1;
      final delta = int.tryParse(uri.queryParameters['delta'] ?? '0') ?? 0;
      if (index < 0 || index >= note.counterList.length) {
        print(
          '⚠️ widget background: counter index $index out of range, aborting',
        );
        return;
      }

      if (session == null) {
        print(
          '⚠️ widget background: no live session for $uid, aborting counter adjust',
        );
        return;
      }

      // Same idea as toggletodo: a transaction always adjusts whatever the
      // server's true current count is.
      final countRef = session.database
          .ref()
          .child('users')
          .child(uid)
          .child('notes')
          .child(noteId)
          .child('counterList')
          .child('$index')
          .child('count');

      final old = note.counterList[index];
      // CHANGED (Fix 10): no clamp at 0, to match the in-app counter screen.
      int resultCount = old.count + delta; // fallback

      try {
        final result = await countRef
            .runTransaction((Object? currentData) {
              final current = (currentData as num?)?.toInt() ?? 0;
              return Transaction.success(current + delta);
            })
            .timeout(const Duration(seconds: 15));
        if (result.committed && result.snapshot.value != null) {
          resultCount = (result.snapshot.value as num).toInt();
          print(
            '✅ widget background: counter transaction committed, new value $resultCount',
          );
        } else {
          print(
            '⚠️ widget background: counter transaction not committed, using local fallback',
          );
        }
      } catch (e) {
        print(
          '⚠️ widget background: counter transaction failed, using local fallback: $e',
        );
      }

      final updatedCounterList = List<CounterItem>.from(note.counterList);
      updatedCounterList[index] = CounterItem(
        label: old.label,
        count: resultCount,
      );

      // NEW (Fix 6): keep the preview body in step, as the app screen does.
      final newBody = NotePreview.counter(updatedCounterList);
      try {
        await session.database
            .ref()
            .child('users')
            .child(uid)
            .child('notes')
            .child(noteId)
            .update({'body': newBody})
            .timeout(const Duration(seconds: 15));
      } catch (e) {
        print('⚠️ widget background: body update failed: $e');
      }

      final updatedNote = Note(
        id: note.id,
        title: note.title,
        body: newBody,
        isStarred: note.isStarred,
        type: note.type,
        todoList: note.todoList,
        counterList: updatedCounterList,
      );

      notes[idx] = updatedNote;
      await LocalStorageService.saveNotes(uid, notes);
      // CHANGED (Fix 4d): refresh every widget showing this note.
      await HomeWidgetService.refreshNote(uid, updatedNote);
      print(
        '✅ widget background: adjusted counter $index by $delta on note $noteId',
      );
    } else {
      print('⚠️ widget background: unrecognized action host "${uri.host}"');
    }
  } catch (e, st) {
    print('❌ widget background action FAILED: $e');
    print(st);
  }
}
