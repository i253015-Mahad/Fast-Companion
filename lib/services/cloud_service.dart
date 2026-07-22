// lib/services/cloud_service.dart
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../models/note.dart';

class CloudService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  static bool _isGoogleSignInInitialized = false;

  static Future<void> _ensureInitialized() async {
    if (!_isGoogleSignInInitialized) {
      await _googleSignIn.initialize();
      _isGoogleSignInInitialized = true;
    }
  }

  static Future<User?> signInWithGoogle() async {
    try {
      await _ensureInitialized();

      final GoogleSignInAccount googleUser = await _googleSignIn.authenticate();

      final List<String> scopes = ['email', 'profile'];
      final clientAuth = await googleUser.authorizationClient.authorizeScopes(
        scopes,
      );

      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: clientAuth.accessToken,
        idToken: googleUser.authentication.idToken,
      );

      final UserCredential userCredential = await _auth.signInWithCredential(
        credential,
      );
      return userCredential.user;
    } catch (e) {
      print("Error during Google Sign In: $e");
      return null;
    }
  }

  static Future<void> signOut() async {
    await _ensureInitialized();
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  static String? get currentUid => _auth.currentUser?.uid;

  static Future<void> saveNoteToCloud(Note note) async {
    final uid = currentUid;
    if (uid == null) return;

    await _db
        .child('users')
        .child(uid)
        .child('notes')
        .child(note.id)
        .set(note.toJson());
  }

  static Future<void> deleteNoteFromCloud(String noteId) async {
    final uid = currentUid;
    if (uid == null) return;

    await _db.child('users').child(uid).child('notes').child(noteId).remove();
  }

  static Future<List<Note>> fetchNotesFromCloud() async {
    final uid = currentUid;
    if (uid == null) return [];

    try {
      final DataSnapshot snapshot = await _db
          .child('users')
          .child(uid)
          .child('notes')
          .get();

      if (!snapshot.exists) return [];

      final Map<dynamic, dynamic> rawNotes =
          snapshot.value as Map<dynamic, dynamic>;
      List<Note> loadedNotes = [];

      rawNotes.forEach((key, value) {
        final Map<String, dynamic> noteMap = Map<String, dynamic>.from(
          value as Map,
        );
        loadedNotes.add(Note.fromJson(noteMap));
      });

      return loadedNotes;
    } catch (e) {
      print("Error fetching cloud data: $e");
      return [];
    }
  }
}
