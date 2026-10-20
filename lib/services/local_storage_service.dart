import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';

class LocalStorageService {
  static const String _notesKeyPrefix = 'local_notes_';
  static const String _accountsKey = 'saved_accounts';

  static String _notesKey(String uid) => '$_notesKeyPrefix$uid';

  // ================= NOTES =================

  static Future<void> saveNotes(String uid, List<Note> notes) async {
    final prefs = await SharedPreferences.getInstance();

    final encoded = notes.map((note) => jsonEncode(note.toJson())).toList();

    await prefs.setStringList(_notesKey(uid), encoded);
  }

  static Future<List<Note>> loadNotes(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final raw = prefs.getStringList(_notesKey(uid));

      if (raw == null || raw.isEmpty) {
        return [];
      }

      return raw
          .map((e) => Note.fromJson(Map<String, dynamic>.from(jsonDecode(e))))
          .toList();
    } catch (e) {
      debugPrint("Local cache read failed: $e");
      return [];
    }
  }

  static Future<void> upsertNote(String uid, Note note) async {
    final notes = await loadNotes(uid);

    final index = notes.indexWhere((n) => n.id == note.id);

    if (index == -1) {
      notes.add(note);
    } else {
      notes[index] = note;
    }

    await saveNotes(uid, notes);
  }

  static Future<void> deleteNote(String uid, String noteId) async {
    final notes = await loadNotes(uid);

    notes.removeWhere((n) => n.id == noteId);

    await saveNotes(uid, notes);
  }

  // ================= ACCOUNTS =================

  static Future<void> saveAccounts(List<Map<String, String>> accounts) async {
    final prefs = await SharedPreferences.getInstance();

    final encoded = accounts.map((e) => jsonEncode(e)).toList();

    await prefs.setStringList(_accountsKey, encoded);
  }

  static Future<List<Map<String, String>>> loadAccounts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();

      final raw = prefs.getStringList(_accountsKey);

      if (raw == null || raw.isEmpty) {
        return [];
      }

      return raw.map((e) => Map<String, String>.from(jsonDecode(e))).toList();
    } catch (e) {
      debugPrint("Account cache read failed: $e");
      return [];
    }
  }

  // ================= ACTIVE ACCOUNT =================

  static const String _activeUidKey = 'active_account_uid';

  /// Which account the app should open on.
  ///
  /// The account pool is an ordered list of everyone who has signed in,
  /// not a record of who is being used, so without this the app reopens
  /// on whichever account happened to be added first — usually not the
  /// one that was on screen last.
  static Future<void> saveActiveUid(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activeUidKey, uid);
    } catch (e) {
      debugPrint("Active account save failed: $e");
    }
  }

  static Future<String?> loadActiveUid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final uid = prefs.getString(_activeUidKey);
      return (uid == null || uid.isEmpty) ? null : uid;
    } catch (e) {
      debugPrint("Active account read failed: $e");
      return null;
    }
  }

  /// Dropped when the account it names signs out, so the next launch
  /// falls back to another account rather than one that is gone.
  static Future<void> clearActiveUid() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_activeUidKey);
    } catch (e) {
      debugPrint("Active account clear failed: $e");
    }
  }
}
