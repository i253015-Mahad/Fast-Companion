// lib/widget_config_main.dart
//
// This is a SEPARATE Dart entry point from your normal main(). It only ever
// runs inside NotesWidgetConfigureActivity (native side), which Android
// launches automatically the instant the user drops the widget on their
// home screen — never from inside the main app.
//
// Flow: Firebase init -> restore account sessions -> if >1 account, ask
// which one -> show that account's notes -> user taps one -> save it as
// the pinned note -> tell the native activity we're done (so it can
// setResult(RESULT_OK) and finish, letting Android actually place the
// widget). Backing out at any point leaves the result as CANCELED
// (set natively) and Android discards the widget placement — same as Keep.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'theme/app_colors.dart';
import 'models/note.dart';
import 'services/local_storage_service.dart';
import 'services/multi_account_auth_service.dart';
import 'services/home_widget_service.dart';

const MethodChannel _configChannel = MethodChannel('notes_widget_configure');

// Called from the tiny `widgetConfigureMain()` wrapper that must live in
// main.dart itself (see instructions) — Flutter's entrypoint mechanism
// only resolves top-level functions that live in the root library
// (lib/main.dart), not ones imported from elsewhere.
void runWidgetConfigureApp() {
  runApp(const WidgetConfigureApp());
}

class WidgetConfigureApp extends StatelessWidget {
  const WidgetConfigureApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _WidgetConfigureFlow(),
    );
  }
}

enum _Step { loading, pickAccount, pickNote, error }

class _WidgetConfigureFlow extends StatefulWidget {
  const _WidgetConfigureFlow();

  @override
  State<_WidgetConfigureFlow> createState() => _WidgetConfigureFlowState();
}

class _WidgetConfigureFlowState extends State<_WidgetConfigureFlow> {
  _Step _step = _Step.loading;
  List<Map<String, String>> _accounts = [];
  String? _selectedUid;
  List<Note> _notes = [];
  String _error = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      final accounts = await LocalStorageService.loadAccounts();
      await MultiAccountAuthService.instance.restoreSessions(accounts);

      if (!mounted) return;

      if (accounts.isEmpty) {
        setState(() {
          _error = "No signed-in accounts found.\nOpen the app and sign in first.";
          _step = _Step.error;
        });
        return;
      }

      if (accounts.length == 1) {
        await _selectAccount(accounts.first['uid']!);
      } else {
        setState(() {
          _accounts = accounts;
          _step = _Step.pickAccount;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = "Couldn't load your accounts:\n$e";
          _step = _Step.error;
        });
      }
    }
  }

  Future<void> _selectAccount(String uid) async {
    final notes = await LocalStorageService.loadNotes(uid);
    if (!mounted) return;
    setState(() {
      _selectedUid = uid;
      _notes = notes.reversed.toList();
      _step = _Step.pickNote;
    });
  }

  Future<void> _selectNote(Note note) async {
    await HomeWidgetService.pinNote(_selectedUid!, note);
    // Signal the native Activity to finish with RESULT_OK. Android then
    // actually places the widget and immediately calls the provider's
    // onUpdate for it, which reads the data we just saved.
    await _configChannel.invokeMethod('configComplete');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    switch (_step) {
      case _Step.loading:
        return const Center(
          child: CircularProgressIndicator(color: AppColors.cardOrange),
        );

      case _Step.error:
        return Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(
              _error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        );

      case _Step.pickAccount:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                "Choose an account",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _accounts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final acc = _accounts[index];
                  final photoUrl = acc['photoUrl'] ?? '';
                  return Material(
                    color: AppColors.navBar,
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      leading: CircleAvatar(
                        backgroundColor: AppColors.cardOrange,
                        backgroundImage:
                            photoUrl.isNotEmpty ? NetworkImage(photoUrl) : null,
                        child: photoUrl.isEmpty
                            ? Text(
                                (acc['name'] ?? '?').isNotEmpty
                                    ? acc['name']![0].toUpperCase()
                                    : '?',
                                style: const TextStyle(color: Colors.white),
                              )
                            : null,
                      ),
                      title: Text(
                        acc['name'] ?? 'Google User',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        acc['email'] ?? '',
                        style: const TextStyle(color: Colors.white60),
                      ),
                      onTap: () => _selectAccount(acc['uid']!),
                    ),
                  );
                },
              ),
            ),
          ],
        );

      case _Step.pickNote:
        if (_notes.isEmpty) {
          return const Center(
            child: Text(
              "No notes in this account yet.",
              style: TextStyle(color: Colors.white30),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Text(
                "Choose a note",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _notes.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final note = _notes[index];
                  return Material(
                    color: AppColors.navBar,
                    borderRadius: BorderRadius.circular(16),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      title: Text(
                        note.title.isEmpty ? "Untitled" : note.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(
                        note.body.isEmpty ? "No content" : note.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60),
                      ),
                      trailing: const Icon(
                        Icons.push_pin_outlined,
                        color: AppColors.cardOrange,
                      ),
                      onTap: () => _selectNote(note),
                    ),
                  );
                },
              ),
            ),
          ],
        );
    }
  }
}
