// lib/services/database_service.dart
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import '../models/note.dart';
import 'local_storage_service.dart';
import 'multi_account_auth_service.dart';
import 'home_widget_service.dart';
import 'reminder_notification_service.dart';

class DatabaseService {
  // Fallback used only when there's no per-account session for the uid in
  // question (e.g. legacy default-app session, or anonymous/offline use).
  final FirebaseDatabase _defaultDb = FirebaseDatabase.instanceFor(
    app: Firebase.app(),
    databaseURL:
        "https://fast-companion-default-rtdb.asia-southeast1.firebasedatabase.app",
  );

  final FirebaseAuth _defaultAuth = FirebaseAuth.instance;

  String get uid => _defaultAuth.currentUser?.uid ?? "anonymous";

  /// Every RTDB read/write MUST go through this instead of `_defaultDb`
  /// directly. It picks the FirebaseDatabase instance that's actually
  /// authenticated as `targetUid` (from MultiAccountAuthService), so
  /// security rules see the right `auth.uid` no matter which of the
  /// signed-in accounts is being written to.
  FirebaseDatabase _databaseFor(String targetUid) {
    return MultiAccountAuthService.instance.sessionFor(targetUid)?.database ??
        _defaultDb;
  }

  /// Whether `targetUid` currently has a live, authenticated session
  /// (either via MultiAccountAuthService, or as the legacy default-app
  /// user) — used to decide whether it's safe to attempt a Firebase write
  /// at all, vs. staying purely local/offline.
  bool _isSignedIn(String targetUid) {
    final session = MultiAccountAuthService.instance.sessionFor(targetUid);
    if (session != null) return true;
    return _defaultAuth.currentUser?.uid == targetUid;
  }

  Future<String?> addNote(
    String title,
    String body, {
    bool isStarred = false,
    String type = 'text',
    String? customUid,
  }) async {
    final targetUid = customUid ?? uid;

    final localKey =
        'local_${DateTime.now().millisecondsSinceEpoch}_$targetUid';

    final localNote = Note(
      id: localKey,
      title: title,
      body: body,
      isStarred: isStarred,
      type: type,
      todoList: [],
      counterList: [],
    );
    await LocalStorageService.upsertNote(targetUid, localNote);

    if (!_isSignedIn(targetUid)) {
      debugPrint("ℹ️ Offline mode: note saved locally with id $localKey");
      return localKey;
    }

    final newNoteRef = _databaseFor(
      targetUid,
    ).ref().child('users').child(targetUid).child('notes').push();

    // Do NOT await this. When offline, Firebase queues the write locally
    // but its Future only completes once the server acknowledges it —
    // which can hang indefinitely until reconnect. Awaiting it here would
    // freeze whatever UI is waiting on addNote() (e.g. a "Create" button).
    newNoteRef
        .set({
          'id': newNoteRef.key,
          'title': title,
          'body': body,
          'isStarred': isStarred,
          'type': type,
          'timestamp': ServerValue.timestamp,
        })
        .timeout(const Duration(seconds: 15))
        .then((_) async {
          await LocalStorageService.deleteNote(targetUid, localKey);
          final realNote = Note(
            id: newNoteRef.key!,
            title: title,
            body: body,
            isStarred: isStarred,
            type: type,
            todoList: [],
            counterList: [],
          );
          await LocalStorageService.upsertNote(targetUid, realNote);
          debugPrint("✅ SAVE SUCCESS: Note id ${newNoteRef.key}");
        })
        .catchError((e) {
          debugPrint("⚠️ Firebase write failed/queued, kept local copy: $e");
        });

    // Local storage currently holds the note under `localKey` — the swap to
    // the real Firebase id happens in the background above once the write
    // succeeds, so we return `localKey` since that's what's actually there
    // right now (avoids callers looking up an id that doesn't exist yet).
    return localKey;
  }

  Future<List<Note>> getLocalNotes({String? customUid}) async {
    final activeUid = customUid ?? uid;
    return LocalStorageService.loadNotes(activeUid);
  }

  Future<void> syncFromFirebase({String? customUid}) async {
    final activeUid = customUid ?? uid;
    if (!_isSignedIn(activeUid)) return;

    // Right after a fresh sign-in, FirebaseAuth has the token but the
    // Realtime Database connection can take a moment to attach it — a read
    // in that gap gets rejected by security rules even though the user
    // really is signed in. Retrying a few times, a little further apart
    // each time, covers that window without retrying forever.
    const maxAttempts = 4;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final snapshot = await _databaseFor(activeUid)
            .ref()
            .child('users')
            .child(activeUid)
            .child('notes')
            .get(); // no orderByChild — avoids requiring a ".indexOn" rule
        if (!snapshot.exists || snapshot.value == null) return;
        final raw = snapshot.value;
        final List<MapEntry<num, Note>> fetchedWithTime = [];
        void parse(dynamic key, dynamic value) {
          if (value == null) return;
          final m = Map<String, dynamic>.from(value as Map);
          List<TodoItem> todoList = [];
          if (m['todoList'] is List) {
            todoList = (m['todoList'] as List).where((i) => i != null).map((i) {
              final t = Map<String, dynamic>.from(i as Map);
              return TodoItem(
                text: t['text'] ?? '',
                isDone: t['isDone'] ?? false,
                dueDateTime: t['dueDateTime'] != null
                    ? DateTime.tryParse(t['dueDateTime'])
                    : null,
                remainingDuration: t['remainingDurationMs'] != null
                    ? Duration(milliseconds: t['remainingDurationMs'])
                    : null,
              );
            }).toList();
          }
          List<CounterItem> counterList = [];
          if (m['counterList'] is List) {
            counterList = (m['counterList'] as List)
                .where((i) => i != null)
                .map((i) {
                  final c = Map<String, dynamic>.from(i as Map);
                  return CounterItem(
                    label: c['label'] ?? '',
                    count: c['count'] ?? 0,
                  );
                })
                .toList();
          }
          final ts = m['timestamp'];
          fetchedWithTime.add(
            MapEntry(
              ts is num ? ts : 0,
              Note(
                id: key.toString(),
                title: m['title'] ?? '',
                body: m['body'] ?? '',
                isStarred: m['isStarred'] ?? false,
                type: m['type'] ?? 'text',
                todoList: todoList,
                counterList: counterList,
              ),
            ),
          );
        }

        if (raw is Map) {
          raw.forEach(parse);
        } else if (raw is List) {
          for (int i = 0; i < raw.length; i++) {
            parse(i, raw[i]);
          }
        }
        fetchedWithTime.sort((a, b) => a.key.compareTo(b.key));
        final fetched = fetchedWithTime.map((e) => e.value).toList();
        await LocalStorageService.saveNotes(activeUid, fetched);
        // Fresh data from the cloud (possibly edited on another device) —
        // bring the scheduled reminders in line with it. Not awaited; the
        // fetch itself already succeeded.
        ReminderNotificationService.syncAll().catchError((e) {
          debugPrint('⚠️ reminder sync after cloud fetch failed: $e');
        });
        return; // success — stop retrying
      } catch (e) {
        debugPrint('⚠️ syncFromFirebase attempt $attempt failed: $e');
        if (attempt == maxAttempts) return;
        await Future.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  Future<void> updateNote(
    String noteId,
    Map<String, dynamic> updatedData, {
    String? customUid,
    // Interactive app screens should leave this false (default) — see the
    // comment below on why the remote write isn't awaited there. The
    // widget's background handler (widget_background_main.dart) sets this
    // true instead: there's no UI to freeze in a headless engine, and
    // Android can kill that engine right after this function returns —
    // so the write needs to actually finish, not just be issued, before
    // we hand control back.
    bool awaitRemote = false,
  }) async {
    final targetUid = customUid ?? uid;

    final localNotes = await LocalStorageService.loadNotes(targetUid);
    final idx = localNotes.indexWhere((n) => n.id == noteId);
    if (idx >= 0) {
      final old = localNotes[idx];
      final updated = Note(
        id: old.id,
        title: updatedData['title'] ?? old.title,
        body: updatedData['body'] ?? old.body,
        type: old.type,
        isStarred: updatedData['isStarred'] ?? old.isStarred,
        todoList: updatedData.containsKey('todoList')
            ? _parseTodoList(updatedData['todoList'])
            : old.todoList,
        counterList: updatedData.containsKey('counterList')
            ? _parseCounterList(updatedData['counterList'])
            : old.counterList,
      );
      localNotes[idx] = updated;
      await LocalStorageService.saveNotes(targetUid, localNotes);
      try {
        await HomeWidgetService.refreshNote(targetUid, updated);
      } catch (e) {
        debugPrint('⚠️ widget refresh after save failed: $e');
      }
      // Reminders follow the note: re-sync this note's scheduled
      // notifications after every save (new task, new deadline, item
      // checked off, note renamed...). Not awaited — scheduling is quick
      // but must never delay the save itself.
      ReminderNotificationService.syncNote(
        targetUid,
        noteId,
      ).catchError((e) {
        debugPrint('⚠️ reminder sync failed: $e');
      });
    }

    final remoteWrite = _databaseFor(targetUid)
        .ref()
        .child('users')
        .child(targetUid)
        .child('notes')
        .child(noteId)
        .update(updatedData)
        .timeout(const Duration(seconds: 15));

    if (awaitRemote) {
      try {
        await remoteWrite;
        debugPrint("✅ DATABASE UPDATE SUCCESS for note: $noteId");
      } catch (e) {
        debugPrint("⚠️ Firebase update failed (awaited), local cache updated: $e");
      }
    } else {
      // Not awaited — offline, this Future won't resolve until reconnect,
      // which would freeze whatever called updateNote() (tick marks, the
      // back button, counter taps) until the connection came back.
      remoteWrite
          .then((_) => debugPrint("✅ DATABASE UPDATE SUCCESS for note: $noteId"))
          .catchError((e) {
            debugPrint("⚠️ Firebase update failed/queued, local cache updated: $e");
          });
    }
  }

  Future<void> toggleStarStatus(
    String noteId,
    bool currentStatus, {
    String? customUid,
  }) async {
    final targetUid = customUid ?? uid;
    final newStatus = !currentStatus;

    final localNotes = await LocalStorageService.loadNotes(targetUid);
    final idx = localNotes.indexWhere((n) => n.id == noteId);
    if (idx >= 0) {
      final old = localNotes[idx];
      localNotes[idx] = Note(
        id: old.id,
        title: old.title,
        body: old.body,
        type: old.type,
        isStarred: newStatus,
        todoList: old.todoList,
        counterList: old.counterList,
      );
      await LocalStorageService.saveNotes(targetUid, localNotes);
    }

    // Not awaited — see updateNote() above. This is what was making the
    // star icon appear stuck offline: the caller awaits this method, then
    // refreshes the UI, so a hung remote write here delayed the whole
    // refresh until reconnect even though the local star was already saved.
    _databaseFor(targetUid)
        .ref()
        .child('users')
        .child(targetUid)
        .child('notes')
        .child(noteId)
        .update({'isStarred': newStatus})
        .timeout(const Duration(seconds: 15))
        .catchError((e) {
          debugPrint(
            "⚠️ Firebase star toggle failed/queued, local cache updated: $e",
          );
        });
  }

  Future<void> deleteNote(String noteId, {String? customUid}) async {
    final targetUid = customUid ?? uid;

    await LocalStorageService.deleteNote(targetUid, noteId);

    // Its reminders are meaningless without the note — drop them right away.
    ReminderNotificationService.cancelNote(
      targetUid,
      noteId,
    ).catchError((e) {
      debugPrint('⚠️ reminder cancel failed: $e');
    });

    // Not awaited — same reasoning as above. The note is already gone
    // locally at this point; the remote delete just catches up whenever
    // the connection comes back.
    _databaseFor(targetUid)
        .ref()
        .child('users')
        .child(targetUid)
        .child('notes')
        .child(noteId)
        .remove()
        .timeout(const Duration(seconds: 15))
        .catchError((e) {
          debugPrint(
            "⚠️ Firebase delete failed/queued, removed from local cache: $e",
          );
        });
  }

  List<TodoItem> _parseTodoList(dynamic raw) {
    if (raw == null || raw is! List) return [];
    return raw.map((item) {
      final m = Map<String, dynamic>.from(item as Map);
      return TodoItem(
        text: m['text'] ?? '',
        isDone: m['isDone'] ?? false,
        dueDateTime: m['dueDateTime'] != null
            ? DateTime.tryParse(m['dueDateTime'])
            : null,
        remainingDuration: m['remainingDurationMs'] != null
            ? Duration(milliseconds: m['remainingDurationMs'])
            : null,
      );
    }).toList();
  }

  List<CounterItem> _parseCounterList(dynamic raw) {
    if (raw == null || raw is! List) return [];
    return raw.map((item) {
      final m = Map<String, dynamic>.from(item as Map);
      return CounterItem(label: m['label'] ?? '', count: m['count'] ?? 0);
    }).toList();
  }
}
