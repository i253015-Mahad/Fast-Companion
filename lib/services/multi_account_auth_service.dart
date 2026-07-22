// lib/services/multi_account_auth_service.dart
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:google_sign_in/google_sign_in.dart';

const String kRtdbUrl =
    "https://fast-companion-default-rtdb.asia-southeast1.firebasedatabase.app";

/// Everything needed to talk to Firebase AS a specific account.
class AccountSession {
  final FirebaseApp app;
  final FirebaseAuth auth;
  final FirebaseDatabase database;
  final String uid;
  final String email;
  final String name;
  final String photoUrl;

  AccountSession({
    required this.app,
    required this.auth,
    required this.database,
    required this.uid,
    required this.email,
    required this.name,
    required this.photoUrl,
  });
}

/// Keeps one live, authenticated FirebaseApp per Google account so that
/// switching accounts is instant (no re-auth, no sign-out/sign-in dance,
/// no losing the other accounts' sessions).
///
/// Each account gets its own secondary FirebaseApp named after its uid.
/// That app has its own FirebaseAuth (own persisted session) and its own
/// FirebaseDatabase instance (whose requests carry that account's auth
/// token) — so RTDB security rules see the right `auth.uid` for every
/// account, all the time.
class MultiAccountAuthService {
  MultiAccountAuthService._internal();
  static final MultiAccountAuthService instance =
      MultiAccountAuthService._internal();

  final Map<String, AccountSession> _sessions = {};

  Map<String, AccountSession> get sessions => Map.unmodifiable(_sessions);

  AccountSession? sessionFor(String? uid) =>
      uid == null ? null : _sessions[uid];

  bool get hasAnySession => _sessions.isNotEmpty;

  /// Call once on startup with whatever accounts you have cached locally
  /// (e.g. from LocalStorageService.loadAccounts()). Re-creates each
  /// account's secondary FirebaseApp and waits briefly for its persisted
  /// Auth session to rehydrate, so switching is instant from cold start too.
  Future<void> restoreSessions(List<Map<String, String>> savedAccounts) async {
    for (final acc in savedAccounts) {
      final uid = acc['uid'];
      if (uid == null || uid.isEmpty || _sessions.containsKey(uid)) continue;
      try {
        final app = await _appForUid(uid);
        final auth = FirebaseAuth.instanceFor(app: app);
        final user = auth.currentUser ??
            await auth.authStateChanges().first.timeout(
                  const Duration(seconds: 3),
                  onTimeout: () => auth.currentUser,
                );
        if (user != null) {
          _register(app, auth, user, fallback: acc);
        }
      } catch (_) {
        // Couldn't rehydrate this one (e.g. token revoked) — it just won't
        // appear in `sessions`, and the UI can prompt the user to re-add it.
      }
    }
  }

  Future<FirebaseApp> _appForUid(String uid) async {
    final existing = Firebase.apps.where((a) => a.name == uid);
    if (existing.isNotEmpty) return existing.first;
    return Firebase.initializeApp(name: uid, options: Firebase.app().options);
  }

  void _register(
    FirebaseApp app,
    FirebaseAuth auth,
    User user, {
    Map<String, String>? fallback,
  }) {
    _sessions[user.uid] = AccountSession(
      app: app,
      auth: auth,
      database: FirebaseDatabase.instanceFor(app: app, databaseURL: kRtdbUrl),
      uid: user.uid,
      email: user.email ?? fallback?['email'] ?? '',
      name: user.displayName ?? fallback?['name'] ?? 'Google User',
      photoUrl: user.photoURL ?? fallback?['photoUrl'] ?? '',
    );
  }

  /// Runs the Google + Firebase sign-in flow and gives the resulting
  /// account its own permanent, dedicated FirebaseApp/session. If that
  /// account is already registered, just hands back its existing session
  /// (no duplicate apps).
  Future<AccountSession?> addAccount() async {
    await GoogleSignIn.instance.signOut();
    final GoogleSignInAccount pickedUser =
        await GoogleSignIn.instance.authenticate();
    final GoogleSignInAuthentication googleAuth =
        await pickedUser.authentication;
    final clientAuth = await pickedUser.authorizationClient
        .authorizeScopes(['email', 'profile']);
    final AuthCredential credential = GoogleAuthProvider.credential(
      idToken: googleAuth.idToken,
      accessToken: clientAuth.accessToken,
    );

    // We don't know the uid until we sign in, so use a throwaway app first.
    final tempApp = await Firebase.initializeApp(
      name: 'pending_${DateTime.now().microsecondsSinceEpoch}',
      options: Firebase.app().options,
    );
    final tempAuth = FirebaseAuth.instanceFor(app: tempApp);
    final userCred = await tempAuth.signInWithCredential(credential);
    final user = userCred.user;
    if (user == null) {
      await tempApp.delete();
      return null;
    }

    // Already have this account signed in elsewhere? Reuse it.
    if (_sessions.containsKey(user.uid)) {
      await tempApp.delete();
      return _sessions[user.uid];
    }

    // Move the session onto a permanent app named after the uid, so it can
    // be found and restored the same way on the next app launch.
    final permanentApp = await _appForUid(user.uid);
    final permanentAuth = FirebaseAuth.instanceFor(app: permanentApp);
    await permanentAuth.signInWithCredential(credential);
    await tempApp.delete();

    _register(permanentApp, permanentAuth, permanentAuth.currentUser!);
    return _sessions[user.uid];
  }

  /// Instant — synchronous, no network call. Just returns the already-live
  /// session for this account (or null if it was never added/restored).
  AccountSession? switchTo(String uid) => _sessions[uid];

  Future<void> signOut(String uid) async {
    final session = _sessions.remove(uid);
    if (session != null) {
      await session.auth.signOut();
      if (session.app.name != Firebase.app().name) {
        await session.app.delete();
      }
    }
  }
}
