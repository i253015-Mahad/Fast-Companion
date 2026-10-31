// lib/widget_background_main.dart
//
// This runs in a HEADLESS Flutter engine — no UI, no visible app — spun up
// briefly by Android when someone taps a checkbox or +/- button on the
// widget. It's wired up via home_widget's interactivity callback
// (HomeWidget.registerInteractivityCallback in main.dart).
//
// SPEED: the widget already shows the tapped change instantly (the Kotlin
// provider applies it before this code even starts). This code's job is the
// slow part: saving to Firebase and the local cache, then writing the REAL
// value back to the widget.
//
// The actual counter/todo value is always sourced from a Firebase
// transaction (see runTransaction calls below), which reads whatever the
// server's true current value is at write time.

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

import 'firebase_options.dart';
import 'models/note.dart';
import 'services/local_storage_service.dart';
import 'services/multi_account_auth_service.dart';
import 'services/home_widget_service.dart';
import 'services/note_preview.dart';
import 'services/reminder_notification_service.dart';

// Must match PENDING_TAPS_KEY in NotesWidgetProvider.kt.
const String _kPendingTaps = 'pending_taps';

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

// NEW: taps are handled ONE AT A TIME. Two taps used to run at once, each
// reading the same saved notes and each saving over the other's change.
Future<void> _tapQueue = Future<void>.value();

/// Called from the tiny `widgetBackgroundCallback()` wrapper that must live
/// in main.dart itself — same rule as the widget configuration entry point.
Future<void> runWidgetBackgroundAction(Uri? uri) {
  final run = _tapQueue.then((_) => _handleTap(uri));
  _tapQueue = run.catchError((_) {});
  return run;
}

/// NEW: writes the real note value back to the widget — but only when no
/// other tap is still waiting. Otherwise a quick series of taps (+ + +) would
/// bounce back to a half-finished value between taps. The last tap in the
/// series does the final refresh.
Future<void> _refreshWidgetIfIdle(String uid, Note note) async {
  final pending = await HomeWidget.getWidgetData<int>(_kPendingTaps) ?? 0;
  // This tap itself still counts as 1 until _finishTap() runs.
  if (pending > 1) {
    debugPrint(
      '⏭️ widget background: $pending taps pending, skipping widget refresh',
    );
    return;
  }
  await HomeWidgetService.refreshNote(uid, note);
}

/// NEW: tells the widget side that this tap is finished.
Future<void> _finishTap() async {
  final pending = await HomeWidget.getWidgetData<int>(_kPendingTaps) ?? 0;
  await HomeWidget.saveWidgetData<int>(
    _kPendingTaps,
    pending > 0 ? pending - 1 : 0,
  );
}

Future<void> _handleTap(Uri? uri) async {
  debugPrint('🔘 widget background action fired: $uri');

  // Kept so that if anything goes wrong we can put the widget back to the
  // real saved value (the Kotlin side already showed the tap optimistically).
  String? revertUid;
  Note? revertNote;

  try {
    if (uri == null) {
      debugPrint('⚠️ widget background: uri was null, aborting');
      return;
    }

    final uid = uri.queryParameters['uid'];
    final noteId = uri.queryParameters['noteId'];
    if (uid == null || uid.isEmpty || noteId == null || noteId.isEmpty) {
      debugPrint('⚠️ widget background: missing uid/noteId in $uri, aborting');
      return;
    }

    await _ensureFirebase();

    final accounts = await LocalStorageService.loadAccounts();
    // A cold headless engine can be slow to rehydrate auth.
    await MultiAccountAuthService.instance.restoreSessions(
      accounts,
      authTimeout: const Duration(seconds: 8),
    );

    // A widget tap is the other moment we're provably alive after an overnight
    // force-stop — an explicit broadcast is the one thing that still reaches a
    // stopped package — so ship any queued gap report. After restoreSessions
    // rather than before it: a report that needs the signed-in fallback path
    // would otherwise fail here every time and wait for the next app launch.
    // Not awaited: telemetry must never slow a tap down.
    HomeWidgetService.flushGapQueue();
    final gotSession = MultiAccountAuthService.instance.sessionFor(uid) != null;
    debugPrint('🔎 widget background: session for $uid restored? $gotSession');

    final notes = await LocalStorageService.loadNotes(uid);
    final idx = notes.indexWhere((n) => n.id == noteId);
    if (idx == -1) {
      debugPrint(
        '⚠️ widget background: note $noteId not found for uid $uid, aborting',
      );
      return;
    }
    final note = notes[idx];
    revertUid = uid;
    revertNote = note;

    final session = MultiAccountAuthService.instance.sessionFor(uid);

    if (uri.host == 'toggletodo') {
      final index = int.tryParse(uri.queryParameters['index'] ?? '') ?? -1;
      if (index < 0 || index >= note.todoList.length) {
        debugPrint('⚠️ widget background: todo index $index out of range, aborting');
        await _refreshWidgetIfIdle(uid, note); // undo the instant change
        return;
      }

      if (session == null) {
        debugPrint(
          '⚠️ widget background: no live session for $uid, aborting todo toggle',
        );
        await _refreshWidgetIfIdle(uid, note); // undo the instant change
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
          debugPrint(
            '✅ widget background: todo transaction committed, isDone=$resultDone',
          );
        } else {
          debugPrint(
            '⚠️ widget background: todo transaction not committed, using local fallback',
          );
        }
      } catch (e) {
        debugPrint(
          '⚠️ widget background: todo transaction failed, using local fallback: $e',
        );
      }

      // Mirror what TimedTaskScreen does when an item is ticked — freeze the
      // remaining time; clear it when un-ticked.
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
      // CHANGED: the widget is refreshed BEFORE the slower cloud "body" update.
      await _refreshWidgetIfIdle(uid, updatedNote);
      debugPrint('✅ widget background: toggled todo $index on note $noteId');

      // Keeps the cloud copy's preview body and frozen countdown in step with
      // the in-app screens. A null value deletes the key (un-ticking).
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
        debugPrint('⚠️ widget background: body/remaining update failed: $e');
      }

      // Reminders follow the note — the same call DatabaseService.updateNote
      // makes after an in-app save. This path writes the local cache itself,
      // so without it nothing cancels the checked-off task's scheduled
      // milestones and they keep firing. Its own try, deliberately: an
      // exception here must not reach the revert path above, which would put
      // the widget back to unchecked while the server says checked.
      try {
        await ReminderNotificationService.syncNote(uid, noteId);
      } catch (e) {
        debugPrint('⚠️ widget background: reminder sync failed: $e');
      }
    } else if (uri.host == 'adjustcounter') {
      final index = int.tryParse(uri.queryParameters['index'] ?? '') ?? -1;
      final delta = int.tryParse(uri.queryParameters['delta'] ?? '0') ?? 0;
      if (index < 0 || index >= note.counterList.length) {
        debugPrint(
          '⚠️ widget background: counter index $index out of range, aborting',
        );
        await _refreshWidgetIfIdle(uid, note); // undo the instant change
        return;
      }

      if (session == null) {
        debugPrint(
          '⚠️ widget background: no live session for $uid, aborting counter adjust',
        );
        await _refreshWidgetIfIdle(uid, note); // undo the instant change
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
      // No clamp at 0, to match the in-app counter screen.
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
          debugPrint(
            '✅ widget background: counter transaction committed, new value $resultCount',
          );
        } else {
          debugPrint(
            '⚠️ widget background: counter transaction not committed, using local fallback',
          );
        }
      } catch (e) {
        debugPrint(
          '⚠️ widget background: counter transaction failed, using local fallback: $e',
        );
      }

      final updatedCounterList = List<CounterItem>.from(note.counterList);
      updatedCounterList[index] = CounterItem(
        label: old.label,
        count: resultCount,
      );

      final newBody = NotePreview.counter(updatedCounterList);

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
      // CHANGED: the widget is refreshed BEFORE the slower cloud "body" update.
      await _refreshWidgetIfIdle(uid, updatedNote);
      debugPrint(
        '✅ widget background: adjusted counter $index by $delta on note $noteId',
      );

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
        debugPrint('⚠️ widget background: body update failed: $e');
      }
    } else {
      debugPrint('⚠️ widget background: unrecognized action host "${uri.host}"');
    }
  } catch (e, st) {
    debugPrint('❌ widget background action FAILED: $e');
    debugPrint(st.toString());
    // Put the widget back to the last real saved value.
    if (revertUid != null && revertNote != null) {
      try {
        await _refreshWidgetIfIdle(revertUid, revertNote);
      } catch (_) {}
    }
  } finally {
    await _finishTap();
  }
}
