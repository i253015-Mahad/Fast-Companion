// lib/widget_config_main.dart
//
// This is a SEPARATE Dart entry point from your normal main(). It only ever
// runs inside NotesWidgetConfigureActivity (native side), which Android
// launches automatically the instant the user drops the widget on their
// home screen — never from inside the main app.
//
// Flow: Firebase init -> restore account sessions -> if >1 account, ask
// which one -> show that account's notes -> user taps one -> save it as
// the pinned note FOR THIS WIDGET ID -> tell the native activity we're done
// (so it can setResult(RESULT_OK) and finish, letting Android actually place
// the widget). Backing out at any point leaves the result as CANCELED
// (set natively) and Android discards the widget placement.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';

import 'firebase_options.dart';
import 'theme/app_colors.dart';
import 'models/note.dart';
import 'services/local_storage_service.dart';
import 'services/multi_account_auth_service.dart';
import 'services/home_widget_service.dart';
import 'widgets/account_avatar.dart';

const MethodChannel _configChannel = MethodChannel('notes_widget_configure');

// Called from the tiny `widgetConfigureMain()` wrapper that must live in
// main.dart itself — Flutter's entrypoint mechanism only resolves top-level
// functions that live in the root library (lib/main.dart).
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
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
      final accounts = await LocalStorageService.loadAccounts();
      await MultiAccountAuthService.instance.restoreSessions(accounts);

      if (!mounted) return;

      if (accounts.isEmpty) {
        setState(() {
          _error =
              "No signed-in accounts found.\nOpen the app and sign in first.";
          _step = _Step.error;
        });
        return;
      }

      // Always keep the list: the note screen's back button needs to know
      // whether going back means "show accounts" or "cancel setup".
      _accounts = accounts;

      if (accounts.length == 1) {
        await _selectAccount(accounts.first['uid']!);
      } else {
        setState(() {
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

  // Back navigation on the "Choose a note" screen.
  //
  // Multiple accounts -> return to the account list.
  // Single account    -> there's nowhere to go back to, so end the whole
  // setup instead (native side discards the widget placement).
  Future<void> _handleNoteBack() async {
    if (_accounts.length > 1) {
      _goBackToAccounts();
    } else {
      await _configChannel.invokeMethod('configCancel');
    }
  }

  void _goBackToAccounts() {
    setState(() {
      _step = _Step.pickAccount;
      _selectedUid = null;
      _notes = [];
    });
  }

  // CHANGED (Fix 4c): pin to THIS widget's id instead of one global slot.
  Future<void> _selectNote(Note note) async {
    final widgetId = await _configChannel.invokeMethod<int>('getWidgetId');
    if (widgetId == null || widgetId == 0) {
      // 0 == AppWidgetManager.INVALID_APPWIDGET_ID
      if (!mounted) return;
      setState(() {
        _error = "Couldn't identify this widget.\nRemove it and try again.";
        _step = _Step.error;
      });
      return;
    }
    await HomeWidgetService.pinNote(widgetId, _selectedUid!, note);
    // Signal the native Activity to finish with RESULT_OK. Android then
    // actually places the widget.
    await _configChannel.invokeMethod('configComplete');
  }

  @override
  Widget build(BuildContext context) {
    // Intercept system back ONLY on the note screen: elsewhere the default
    // behavior (finish with RESULT_CANCELED, widget not placed) is wanted.
    final interceptBack = _step == _Step.pickNote;
    return PopScope(
      canPop: !interceptBack,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleNoteBack();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: SafeArea(child: _buildBody()),
      ),
    );
  }

  /// "Choose a note" header with a back button at the top left.
  ///
  /// Back returns to the account list, or cancels the widget setup when
  /// only one account is signed in (see [_handleNoteBack]).
  Widget _buildNoteHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 20, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleNoteBack,
          ),
          const SizedBox(width: 4),
          const Text(
            "Choose a note",
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
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
                separatorBuilder: (_, _) => const SizedBox(height: 10),
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
                      leading: AccountAvatar(
                        photoUrl: photoUrl,
                        backgroundColor: AppColors.cardOrange,
                        fallback: Text(
                          (acc['name'] ?? '?').isNotEmpty
                              ? acc['name']![0].toUpperCase()
                              : '?',
                          style: const TextStyle(color: Colors.white),
                        ),
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildNoteHeader(),
              const Expanded(
                child: Center(
                  child: Text(
                    "No notes in this account yet.",
                    style: TextStyle(color: Colors.white30),
                  ),
                ),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildNoteHeader(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: _notes.length,
                separatorBuilder: (_, _) => const SizedBox(height: 10),
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
