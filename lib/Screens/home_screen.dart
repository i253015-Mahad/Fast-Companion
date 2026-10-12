// lib/screens/home_screen.dart
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../widgets/note_card.dart';
import '../models/note.dart';
import 'edit_note_screen.dart';
import 'todo_screen.dart';
import 'counter_screen.dart';
import 'timed_task_screen.dart';
import 'timetable_screen.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:fast_companion/services/database_service.dart';
import 'package:fast_companion/services/local_storage_service.dart';
import 'package:fast_companion/services/multi_account_auth_service.dart';
import 'package:fast_companion/services/home_widget_service.dart';
import 'package:fast_companion/services/reminder_notification_service.dart';
import '../app_signals.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final DatabaseService _dbService = DatabaseService();
  final MultiAccountAuthService _authService = MultiAccountAuthService.instance;
  final List<Map<String, String>> _accountPool = [];
  bool _isUserLoggedIn = false;
  String? _userProfileUrl;
  String? _activeNotesUid;
  List<Note> _localNotes = [];
  bool _isMenuOpen = false;
  final TextEditingController searchController = TextEditingController();
  String searchQuery = "";

  // Bottom nav: 0 = Notes, 1 = Timetable, 2 = Flex (placeholder).
  // Held in an IndexedStack so the Notes state (search text, scroll,
  // loaded notes) survives a round trip to another tab.
  int _navIndex = 0;

  // Live vertical drag distance (px) on the account avatar, for the
  // swipe-up/down-to-switch-account gesture. Negative = swiping up.
  double _avatarDragOffset = 0;
  // True while the finger is down: makes the return animation instant
  // during the drag and springy once released.
  bool _isAvatarDragging = false;
  // Blocks a second swipe while a switch is still activating a session.
  bool _isSwitchingAccount = false;
  // Photo layered over the avatar (the account a swipe would land on, or
  // the one being switched to), and its target opacity. Layering keeps the
  // avatar from flashing the old account back mid-switch, and lets the
  // preview fade out smoothly when a swipe is released too early.
  String? _previewPhoto;
  double _previewOpacity = 0;
  // Distance the finger must travel before a swipe counts as a switch.
  static const double _avatarSwitchThreshold = 30;
  // How far the avatar can be dragged before it stops following the finger.
  // Kept modest so it doesn't slide off the top of the header.
  static const double _avatarDragClamp = 50;
  // Snap-back / cross-fade duration — kept short so switching feels snappy.
  static const Duration _avatarSnapDuration = Duration(milliseconds: 140);

  final List<Color> cardColors = [
    AppColors.cardOrange,
    AppColors.cardGreen,
    AppColors.cardYellow,
    AppColors.cardCream,
  ];

  // The FirebaseDatabase instance authenticated as whichever account is
  // currently active. Every direct RTDB write in this screen should go
  // through this, NOT FirebaseDatabase.instance, or it'll be writing with
  // the wrong (or no) account's auth token.
  FirebaseDatabase get _activeDatabase =>
      _authService.sessionFor(_activeNotesUid)?.database ??
      FirebaseDatabase.instanceFor(
        app: FirebaseDatabase.instance.app,
        databaseURL: kRtdbUrl,
      );

  void _showAccountSwitcherSheet(BuildContext context) {
    final scaffoldContext = context;

    final activeAccount = _accountPool.firstWhere(
      (acc) => acc['uid'] == _activeNotesUid,
      orElse: () => {
        'uid': _activeNotesUid ?? '',
        'email': 'No Email',
        'name': 'No Name',
        'photoUrl': '',
      },
    );
    final activePhotoUrl = activeAccount['photoUrl'] ?? '';

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          backgroundColor: AppColors.navBar,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            "Google Account",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 35,
                backgroundColor: AppColors.cardOrange,
                backgroundImage: activePhotoUrl.isNotEmpty
                    ? NetworkImage(activePhotoUrl)
                    : null,
                child: activePhotoUrl.isEmpty
                    ? Text(
                        activeAccount['name']!.isNotEmpty
                            ? activeAccount['name']![0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      )
                    : null,
              ),
              const SizedBox(height: 15),
              Text(
                activeAccount['name'] ?? "No Name",
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  fontSize: 18,
                ),
              ),
              Text(
                activeAccount['email'] ?? "No Email",
                style: const TextStyle(color: Colors.white60, fontSize: 14),
              ),
              const SizedBox(height: 15),
              const Divider(color: Colors.white24),

              if (_accountPool.any((acc) => acc['uid'] != _activeNotesUid)) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Column(
                      children: _accountPool
                          .where((acc) => acc['uid'] != _activeNotesUid)
                          .map((account) {
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundImage: account['photoUrl']!.isNotEmpty
                                    ? NetworkImage(account['photoUrl']!)
                                    : null,
                                child: account['photoUrl']!.isEmpty
                                    ? Text(
                                        account['name']![0].toUpperCase(),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                        ),
                                      )
                                    : null,
                              ),
                              title: Text(
                                account['name']!,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              subtitle: Text(
                                account['email']!,
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 12,
                                ),
                              ),
                              // INSTANT switch: no network call, no Google
                              // picker. The account's session is already
                              // live — we just point the UI at it.
                              onTap: () {
                                Navigator.pop(context);
                                _switchToUid(account['uid']!, scaffoldContext);
                              },
                            );
                          })
                          .toList(),
                    ),
                  ),
                ),
                const Divider(color: Colors.white24),
              ],

              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.person_add_alt_1_rounded,
                  color: AppColors.cardOrange,
                ),
                title: const Text(
                  "Add another account",
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                subtitle: const Text(
                  "Sign in with a different Google ID",
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  try {
                    final session = await _authService.addAccount();
                    if (session == null || !mounted) return;
                    await _activateSession(session);
                    ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                      SnackBar(
                        content: Text("Switched to: ${session.email}"),
                        backgroundColor: AppColors.cardOrange,
                      ),
                    );
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(scaffoldContext).showSnackBar(
                        SnackBar(content: Text("Could not add account: $e")),
                      );
                    }
                  }
                },
              ),
              const Divider(color: Colors.white24),

              // Timed-task reminders on/off (see _ReminderToggleTile below).
              const _ReminderToggleTile(),
              const Divider(color: Colors.white24),

              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.logout, color: Colors.redAccent),
                title: const Text(
                  "Sign Out",
                  style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                onTap: () async {
                  final signedOutUid = _activeNotesUid;
                  if (signedOutUid != null) {
                    await _authService.signOut(signedOutUid);
                    _accountPool.removeWhere(
                      (acc) => acc['uid'] == signedOutUid,
                    );
                    await LocalStorageService.saveAccounts(_accountPool);
                    await HomeWidgetService.clearForUid(signedOutUid);
                  }

                  if (!mounted) return;

                  // If another account is still signed in, drop into it
                  // instead of logging the user out of the app entirely.
                  final remaining = _accountPool.isNotEmpty
                      ? _accountPool.first['uid']
                      : null;
                  final nextSession = _authService.sessionFor(remaining);

                  if (nextSession != null) {
                    await _activateSession(nextSession);
                  } else {
                    setState(() {
                      _isUserLoggedIn = false;
                      _userProfileUrl = null;
                      _activeNotesUid = null;
                      _localNotes = [];
                      _isMenuOpen = false;
                    });
                  }
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Instant switch to an already-live session.
  Future<void> _switchToUid(String uid, BuildContext scaffoldContext) async {
    final session = _authService.switchTo(uid);
    if (session == null) {
      ScaffoldMessenger.of(scaffoldContext).showSnackBar(
        const SnackBar(
          content: Text("That account's session expired — please re-add it."),
        ),
      );
      return;
    }
    await _activateSession(session);
  }

  /// The account a vertical swipe would land on: next when swiping up,
  /// previous when swiping down, wrapping around the pool. Null unless
  /// there's more than one signed-in account to move between.
  Map<String, String>? _neighborAccount({required bool swipeUp}) {
    if (!_isUserLoggedIn || _accountPool.length < 2) return null;
    final current = _accountPool.indexWhere(
      (acc) => acc['uid'] == _activeNotesUid,
    );
    if (current < 0) return null;
    final step = swipeUp ? 1 : -1;
    final next = (current + step + _accountPool.length) % _accountPool.length;
    return _accountPool[next];
  }

  /// Called whenever the drag moves: keeps `_previewPhoto` pointed at the
  /// account the swipe would land on and fades it in as the finger travels.
  void _updateAvatarPreview() {
    final neighbor = _neighborAccount(swipeUp: _avatarDragOffset < 0);
    _previewPhoto = neighbor == null ? null : (neighbor['photoUrl'] ?? '');
    _previewOpacity = _avatarDragOffset == 0
        ? 0
        : (_avatarDragOffset.abs() / _avatarDragClamp).clamp(0.0, 1.0);
  }

  /// The avatar itself; [photoUrl] of '' or null falls back to the generic
  /// account icon.
  Widget _buildAccountCircle(String? photoUrl) {
    final hasPhoto = photoUrl != null && photoUrl.isNotEmpty;
    return CircleAvatar(
      radius: 18,
      backgroundColor: Colors.white12,
      backgroundImage: hasPhoto ? NetworkImage(photoUrl) : null,
      child: hasPhoto
          ? null
          : const Icon(
              Icons.account_circle_outlined,
              color: Colors.white70,
              size: 24,
            ),
    );
  }

  /// Fades are done: drop the preview layer once it's fully transparent
  /// (and no new drag/switch has claimed it).
  void _onPreviewFadeComplete() {
    if (!mounted) return;
    if (_previewOpacity == 0 && !_isAvatarDragging && !_isSwitchingAccount) {
      setState(() => _previewPhoto = null);
    }
  }

  void _onAvatarDragStart(DragStartDetails details) {
    if (_isSwitchingAccount) return;
    _isAvatarDragging = true;
    setState(() {
      _avatarDragOffset = 0;
      _previewOpacity = 0;
    });
  }

  void _onAvatarDragUpdate(DragUpdateDetails details) {
    if (_isSwitchingAccount) return;
    final delta = details.primaryDelta;
    if (delta == null) return;
    setState(() {
      _avatarDragOffset = (_avatarDragOffset + delta)
          .clamp(-_avatarDragClamp, _avatarDragClamp)
          .toDouble();
      _updateAvatarPreview();
    });
  }

  void _onAvatarDragEnd(DragEndDetails details) async {
    _isAvatarDragging = false;
    final offset = _avatarDragOffset;

    // Not far enough (or nowhere to go) — snap back and fade the preview.
    final target = offset.abs() >= _avatarSwitchThreshold
        ? _neighborAccount(swipeUp: offset < 0)
        : null;
    if (target == null || target['uid'] == null) {
      // Snap back; keep the preview layer so it can fade out smoothly.
      setState(() {
        _avatarDragOffset = 0;
        _previewOpacity = 0;
      });
      return;
    }

    // Snap the avatar home but hold the target's photo at full opacity, so
    // the switch lands on it without ever flashing the old account back.
    _isSwitchingAccount = true;
    setState(() {
      _avatarDragOffset = 0;
      _previewPhoto = target['photoUrl'] ?? '';
      _previewOpacity = 1;
    });
    try {
      await _switchToUid(target['uid']!, context);
    } finally {
      _isSwitchingAccount = false;
      // The base avatar now shows the new account (or the old one, if the
      // switch failed), so fade the overlay out rather than popping it.
      if (mounted) {
        setState(() => _previewOpacity = 0);
      } else {
        _previewPhoto = null;
        _previewOpacity = 0;
      }
    }
  }

  /// Points the whole screen's state at a given account session and loads
  /// its notes (cached instantly, then refreshed from Firebase).
  Future<void> _activateSession(AccountSession session) async {
    _addToAccountPool({
      'uid': session.uid,
      'email': session.email,
      'name': session.name,
      'photoUrl': session.photoUrl,
    });
    final cached = await LocalStorageService.loadNotes(session.uid);
    if (!mounted) return;
    setState(() {
      _isUserLoggedIn = true;
      _userProfileUrl = session.photoUrl;
      _activeNotesUid = session.uid;
      _localNotes = cached;
    });
    _syncFromFirebaseAndRefresh(session.uid);
  }

  void openAndEditNote(Note note) async {
    FocusManager.instance.primaryFocus?.unfocus();

    final dynamic screenToOpen;
    final String activeUid = _activeNotesUid ?? _dbService.uid;

    if (note.type == 'todo') {
      screenToOpen = TodoScreen(note: note, uid: activeUid);
    } else if (note.type == 'counter') {
      screenToOpen = CounterScreen(note: note, uid: activeUid);
    } else if (note.type == 'timed') {
      screenToOpen = TimedTaskScreen(note: note, uid: activeUid);
    } else {
      screenToOpen = EditNoteScreen(note: note, uid: activeUid);
    }

    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => screenToOpen),
    );

    FocusManager.instance.primaryFocus?.unfocus();

    if (mounted) {
      await _refreshLocalNotes();
    }
  }

  @override
  void initState() {
    super.initState();
    _initState();
    homeRefreshSignal.addListener(_handleExternalRefreshSignal);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    homeRefreshSignal.removeListener(_handleExternalRefreshSignal);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Catches changes made via the widget's checkbox/counter taps — those
    // run in a separate headless engine with no shared memory with this
    // one, so homeRefreshSignal can't reach across. Refreshing whenever the
    // app comes back to the foreground covers it generally, since that's
    // also when a widget-driven change would have happened.
    if (state == AppLifecycleState.resumed && _activeNotesUid != null) {
      _refreshLocalNotes();
    }
  }

  void _handleExternalRefreshSignal() {
    if (mounted) _refreshLocalNotes();
  }

  Future<void> _initState() async {
    final saved = await LocalStorageService.loadAccounts();
    if (mounted && saved.isNotEmpty) {
      setState(() => _accountPool.addAll(saved));
    }

    // Re-create a live session for every previously signed-in account so
    // switching is instant from the moment the app opens.
    await _authService.restoreSessions(_accountPool);

    // Prefer whichever account was active in the legacy single-session
    // default FirebaseApp (covers users updating from the old version);
    // otherwise fall back to the first restored session.
    final legacyUid = FirebaseAuth.instance.currentUser?.uid;
    final startupSession =
        _authService.sessionFor(legacyUid) ??
        (_authService.sessions.isNotEmpty
            ? _authService.sessions.values.first
            : null);

    if (startupSession != null && mounted) {
      await _activateSession(startupSession);
    }
  }

  Future<void> _syncFromFirebaseAndRefresh(String uid) async {
    await _dbService.syncFromFirebase(customUid: uid);
    if (mounted && _activeNotesUid == uid) {
      await _refreshLocalNotes();
    }
  }

  Future<void> _refreshLocalNotes() async {
    if (!mounted) return;
    final refreshed = await LocalStorageService.loadNotes(
      _activeNotesUid ?? '',
    );
    if (mounted) setState(() => _localNotes = refreshed);
    // Keeps the home screen widget's content up to date with zero extra
    // wiring in EditNoteScreen/TodoScreen/etc — this fires after every
    // edit, delete, and star toggle since they all call _refreshLocalNotes.
    HomeWidgetService.syncIfNeeded(_activeNotesUid, refreshed);
  }

  void _addToAccountPool(Map<String, String> account) {
    final exists = _accountPool.any((a) => a['uid'] == account['uid']);
    if (!exists) {
      _accountPool.add(account);
      LocalStorageService.saveAccounts(_accountPool);
    }
  }

  /// Long-press a note card to pin it to a home screen widget.
  Future<void> _pinToWidget(Note note) async {
    final uid = _activeNotesUid;
    if (uid == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final widgets = await HomeWidgetService.widgetSummaries();
    if (!mounted) return;
    if (widgets.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          backgroundColor: AppColors.cardOrange,
          content: Text(
            'Add the Notes widget to your home screen first.',
            style: TextStyle(color: Colors.black87),
          ),
        ),
      );
      return;
    }

    final int? targetId = widgets.length == 1
        ? widgets.first.id
        : await showDialog<int>(
            context: context,
            builder: (ctx) => SimpleDialog(
              backgroundColor: AppColors.navBar,
              title: const Text(
                'Show on which widget?',
                style: TextStyle(color: Colors.white),
              ),
              children: [
                for (final w in widgets)
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, w.id),
                    child: Text(
                      'Currently: ${w.title}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
              ],
            ),
          );
    if (targetId == null) return;

    await HomeWidgetService.pinNote(targetId, uid, note);
    messenger.showSnackBar(
      SnackBar(
        backgroundColor: AppColors.cardOrange,
        content: Text(
          '"${note.title.isEmpty ? 'Untitled' : note.title}" pinned to widget',
          style: const TextStyle(color: Colors.black87),
        ),
      ),
    );
  }

  Widget _buildNotesGrid(List<Note> listToRender, int colorOffset) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: listToRender.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 15,
        mainAxisSpacing: 15,
        childAspectRatio: 0.8,
      ),
      itemBuilder: (context, index) {
        Note note = listToRender[index];

        return NoteCard(
          note: note,
          color: cardColors[(index + colorOffset) % cardColors.length],
          onDelete: () async {
            await _dbService.deleteNote(note.id, customUid: _activeNotesUid);
            if (mounted) {
              await _refreshLocalNotes();
            }
          },
          onStarToggled: () async {
            await _dbService.toggleStarStatus(
              note.id,
              note.isStarred,
              customUid: _activeNotesUid,
            );
            if (mounted) {
              await _refreshLocalNotes();
            }
          },
          onPin: () => _pinToWidget(note),
          onTap: () {
            openAndEditNote(note);
          },
        );
      },
    );
  }

  void _showNewTimedTaskDialog() {
    final titleController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.navBar,
          title: const Text(
            "New Timed Note",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: titleController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: "Enter Note Heading",
              labelStyle: TextStyle(color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            TextButton(
              onPressed: () async {
                String enteredTitle = titleController.text.trim();
                if (enteredTitle.isEmpty) enteredTitle = "Untitled Timed Note";
                Navigator.pop(context);

                final targetUid = _activeNotesUid ?? _dbService.uid;

                final newNoteRef = _activeDatabase
                    .ref()
                    .child('users')
                    .child(targetUid)
                    .child('notes')
                    .push();

                final String newId = newNoteRef.key!;

                final newNote = Note(
                  id: newId,
                  title: enteredTitle,
                  body: '',
                  isStarred: false,
                  type: 'timed',
                  todoList: [],
                  counterList: [],
                );

                await LocalStorageService.upsertNote(targetUid, newNote);
                if (mounted) {
                  await _refreshLocalNotes();
                }

                newNoteRef
                    .set({
                      'id': newId,
                      'title': enteredTitle,
                      'body': '',
                      'isStarred': false,
                      'type': 'timed',
                      'timestamp': ServerValue.timestamp,
                    })
                    .catchError((e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Saved locally, but cloud sync failed: $e",
                            ),
                          ),
                        );
                      }
                    });

                if (mounted) {
                  openAndEditNote(newNote);
                }
              },
              child: const Text(
                "Create",
                style: TextStyle(
                  color: AppColors.cardOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showNewCounterDialog() {
    final titleController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.navBar,
          title: const Text(
            "New Counter List",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: titleController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: "Enter Title",
              labelStyle: TextStyle(color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            TextButton(
              onPressed: () async {
                String enteredTitle = titleController.text.trim();
                if (enteredTitle.isEmpty) enteredTitle = "Untitled Counters";
                Navigator.pop(context);

                final targetUid = _activeNotesUid ?? _dbService.uid;

                final newNoteRef = _activeDatabase
                    .ref()
                    .child('users')
                    .child(targetUid)
                    .child('notes')
                    .push();

                final String newId = newNoteRef.key!;

                final newNote = Note(
                  id: newId,
                  title: enteredTitle,
                  body: '',
                  isStarred: false,
                  type: 'counter',
                  todoList: [],
                  counterList: [],
                );

                await LocalStorageService.upsertNote(targetUid, newNote);
                if (mounted) {
                  await _refreshLocalNotes();
                }

                newNoteRef
                    .set({
                      'id': newId,
                      'title': enteredTitle,
                      'body': '',
                      'isStarred': false,
                      'type': 'counter',
                      'timestamp': ServerValue.timestamp,
                    })
                    .catchError((e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Saved locally, but cloud sync failed: $e",
                            ),
                          ),
                        );
                      }
                    });

                if (mounted) {
                  openAndEditNote(newNote);
                }
              },
              child: const Text(
                "Create",
                style: TextStyle(
                  color: AppColors.cardOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showNewTodoDialog() {
    final titleController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.navBar,
          title: const Text(
            "New To-Do List",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: titleController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: "Enter List Title",
              labelStyle: TextStyle(color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            TextButton(
              onPressed: () async {
                String enteredTitle = titleController.text.trim();
                if (enteredTitle.isEmpty) enteredTitle = "Untitled List";
                Navigator.pop(context);

                final targetUid = _activeNotesUid ?? _dbService.uid;

                final newNoteRef = _activeDatabase
                    .ref()
                    .child('users')
                    .child(targetUid)
                    .child('notes')
                    .push();

                final String newId = newNoteRef.key!;

                final newNote = Note(
                  id: newId,
                  title: enteredTitle,
                  body: '',
                  isStarred: false,
                  type: 'todo',
                  todoList: [],
                  counterList: [],
                );

                await LocalStorageService.upsertNote(targetUid, newNote);
                if (mounted) {
                  await _refreshLocalNotes();
                }

                newNoteRef
                    .set({
                      'id': newId,
                      'title': enteredTitle,
                      'body': '',
                      'isStarred': false,
                      'type': 'todo',
                      'timestamp': ServerValue.timestamp,
                    })
                    .catchError((e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Saved locally, but cloud sync failed: $e",
                            ),
                          ),
                        );
                      }
                    });

                if (mounted) {
                  openAndEditNote(newNote);
                }
              },
              child: const Text(
                "Create",
                style: TextStyle(
                  color: AppColors.cardOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showNewTextNoteDialog() {
    final titleController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.navBar,
          title: const Text(
            "New Text Note",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: TextField(
            controller: titleController,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
              labelText: "Enter Title",
              labelStyle: TextStyle(color: Colors.white70),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "Cancel",
                style: TextStyle(color: Colors.white60),
              ),
            ),
            TextButton(
              onPressed: () async {
                String enteredTitle = titleController.text.trim();
                if (enteredTitle.isEmpty) enteredTitle = "Untitled";
                Navigator.pop(context);

                final targetUid = _activeNotesUid ?? _dbService.uid;

                final newNoteRef = _activeDatabase
                    .ref()
                    .child('users')
                    .child(targetUid)
                    .child('notes')
                    .push();

                final String newId = newNoteRef.key!;

                final newNote = Note(
                  id: newId,
                  title: enteredTitle,
                  body: '',
                  isStarred: false,
                  type: 'text',
                  todoList: [],
                  counterList: [],
                );

                await LocalStorageService.upsertNote(targetUid, newNote);
                if (mounted) {
                  await _refreshLocalNotes();
                }

                newNoteRef
                    .set({
                      'id': newId,
                      'title': enteredTitle,
                      'body': '',
                      'isStarred': false,
                      'type': 'text',
                      'timestamp': ServerValue.timestamp,
                    })
                    .catchError((e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              "Saved locally, but cloud sync failed: $e",
                            ),
                          ),
                        );
                      }
                    });

                if (mounted) {
                  openAndEditNote(newNote);
                }
              },
              child: const Text(
                "Create",
                style: TextStyle(
                  color: AppColors.cardOrange,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// The empty-state bulb: an outlined bulb with rays fanned around its
  /// top so it reads as "switched on".
  Widget _buildLitBulb() {
    const rayColor = AppColors.cardOrange;
    const rayLength = 12.0;
    const rayThickness = 3.0;
    // Distance from the bulb's center to each ray's center.
    const orbit = 40.0;
    const box = 100.0;
    const center = box / 2;
    // Degrees in screen space (y grows downward): rays fan across the
    // top half of the bulb — left, up-left, up, up-right, right.
    const angles = [180.0, -135.0, -90.0, -45.0, 0.0];

    return SizedBox(
      width: box,
      height: box,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(
            Icons.lightbulb_outline_rounded,
            size: 60,
            color: rayColor,
          ),
          for (final deg in angles)
            Positioned(
              left:
                  center +
                  orbit * math.cos(deg * math.pi / 180) -
                  rayLength / 2,
              top:
                  center +
                  orbit * math.sin(deg * math.pi / 180) -
                  rayThickness / 2,
              // Rotating a horizontal bar by `deg` aligns it with the
              // radius it sits on.
              child: Transform.rotate(
                angle: deg * math.pi / 180,
                child: Container(
                  width: rayLength,
                  height: rayThickness,
                  decoration: const BoxDecoration(
                    color: rayColor,
                    borderRadius: BorderRadius.all(Radius.circular(1.5)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: IndexedStack(
          index: _navIndex,
          children: [
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text("Notes", style: AppTextStyles.title),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          if (_isUserLoggedIn) {
                            _showAccountSwitcherSheet(context);
                          }
                        },
                        // Swipe up = next account, down = previous one (wraps
                        // around). Only meaningful with 2+ signed-in accounts.
                        onVerticalDragStart: _onAvatarDragStart,
                        onVerticalDragUpdate: _onAvatarDragUpdate,
                        onVerticalDragEnd: _onAvatarDragEnd,
                        onVerticalDragCancel: () {
                          if (_isSwitchingAccount || !_isAvatarDragging) return;
                          _isAvatarDragging = false;
                          setState(() {
                            _avatarDragOffset = 0;
                            _previewOpacity = 0;
                          });
                        },
                        // Padding enlarges the touch target beyond the 36px
                        // circle so the swipe is easy to perform.
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 6,
                          ),
                          child: AnimatedSlide(
                            offset: Offset(0, _avatarDragOffset / 36),
                            duration: _isAvatarDragging
                                ? Duration.zero
                                : _avatarSnapDuration,
                            curve: Curves.easeOutBack,
                            child: AnimatedScale(
                              scale:
                                  1.0 -
                                  ((_avatarDragOffset.abs() / _avatarDragClamp)
                                          .clamp(0.0, 1.0) *
                                      0.15),
                              duration: _isAvatarDragging
                                  ? Duration.zero
                                  : _avatarSnapDuration,
                              curve: Curves.easeOut,
                              child: SizedBox(
                                width: 36,
                                height: 36,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    _buildAccountCircle(
                                      _isUserLoggedIn ? _userProfileUrl : null,
                                    ),
                                    // The account a swipe would land on, fading
                                    // in as you drag (held at full opacity for
                                    // the duration of an actual switch).
                                    if (_previewPhoto != null)
                                      AnimatedOpacity(
                                        opacity: _previewOpacity,
                                        duration: _isAvatarDragging
                                            ? Duration.zero
                                            : _avatarSnapDuration,
                                        curve: Curves.easeOut,
                                        onEnd: _onPreviewFadeComplete,
                                        child: _buildAccountCircle(
                                          _previewPhoto,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    controller: searchController,
                    onChanged: (value) {
                      setState(() {
                        searchQuery = value.toLowerCase();
                      });
                    },
                    decoration: InputDecoration(
                      hintText: "Find your thoughts...",
                      hintStyle: const TextStyle(color: Colors.white70),
                      filled: true,
                      fillColor: Colors.black12,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: !_isUserLoggedIn
                        ? Center(
                            child: Container(
                              padding: const EdgeInsets.all(24),
                              decoration: BoxDecoration(
                                color: AppColors.navBar,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.cloud_queue_rounded,
                                    size: 56,
                                    color: AppColors.cardOrange,
                                  ),
                                  const SizedBox(height: 16),
                                  const Text(
                                    "Sync Notes Across Devices",
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  ElevatedButton.icon(
                                    icon: const Icon(
                                      Icons.login_rounded,
                                      color: Colors.blueAccent,
                                    ),
                                    label: const Text("Sign in with Google"),
                                    onPressed: () async {
                                      try {
                                        final session = await _authService
                                            .addAccount();
                                        if (session == null || !mounted) return;
                                        await _activateSession(session);
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              "Welcome: ${session.email}",
                                            ),
                                          ),
                                        );
                                      } catch (e) {
                                        if (!mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              "Google Connection Failed: $e",
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Builder(
                            builder: (context) {
                              List<Note> displayNotes = _localNotes;
                              if (searchQuery.isNotEmpty) {
                                displayNotes = displayNotes.where((note) {
                                  return note.title.toLowerCase().contains(
                                        searchQuery,
                                      ) ||
                                      note.body.toLowerCase().contains(
                                        searchQuery,
                                      );
                                }).toList();
                              }

                              if (displayNotes.isEmpty) {
                                // A search that matched nothing isn't the same
                                // as an account with no notes — say so.
                                if (searchQuery.isNotEmpty) {
                                  return Center(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.search_off_rounded,
                                          size: 56,
                                          color: Colors.white38,
                                        ),
                                        const SizedBox(height: 12),
                                        Text(
                                          'No notes match "$searchQuery"',
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        const Text(
                                          "Try a different search term.",
                                          style: TextStyle(
                                            color: Colors.white38,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                // Sits a little above center so it doesn't feel
                                // like it's sinking to the bottom of the screen.
                                return Align(
                                  alignment: const Alignment(0, -0.25),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _buildLitBulb(),
                                      const SizedBox(height: 4),
                                      const Text(
                                        "Add a note and get Creative!",
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

                              final reversedNotes = displayNotes.reversed
                                  .toList();
                              final starredNotes = reversedNotes
                                  .where((n) => n.isStarred)
                                  .toList();
                              final otherNotes = reversedNotes
                                  .where((n) => !n.isStarred)
                                  .toList();

                              if (starredNotes.isEmpty) {
                                return ListView(
                                  padding: EdgeInsets.zero,
                                  children: [
                                    _buildNotesGrid(reversedNotes, 0),
                                    const SizedBox(height: 20),
                                  ],
                                );
                              }

                              return ListView(
                                padding: EdgeInsets.zero,
                                children: [
                                  const Padding(
                                    padding: EdgeInsets.only(
                                      bottom: 10,
                                      left: 4,
                                    ),
                                    child: Text(
                                      "STARRED",
                                      style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                  _buildNotesGrid(starredNotes, 0),
                                  const SizedBox(height: 25),
                                  const Padding(
                                    padding: EdgeInsets.only(
                                      bottom: 10,
                                      left: 4,
                                    ),
                                    child: Text(
                                      "OTHER",
                                      style: TextStyle(
                                        color: Colors.white60,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 1.5,
                                      ),
                                    ),
                                  ),
                                  _buildNotesGrid(
                                    otherNotes,
                                    starredNotes.length,
                                  ),
                                  const SizedBox(height: 20),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            const TimetableScreen(),
            _buildFlexPlaceholder(),
          ],
        ),
      ),

      // The note-creation speed dial only makes sense on the Notes tab
      // (and only when signed in).
      floatingActionButton: (!_isUserLoggedIn || _navIndex != 0)
          ? null
          : Stack(
              alignment: Alignment.bottomRight,
              children: [
                if (_isMenuOpen)
                  GestureDetector(
                    onTap: () => setState(() => _isMenuOpen = false),
                    child: Container(
                      width: MediaQuery.of(context).size.width,
                      height: MediaQuery.of(context).size.height,
                      color: Colors.black.withOpacity(0.6),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 80.0, right: 4.0),
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 200),
                    opacity: _isMenuOpen ? 1.0 : 0.0,
                    child: IgnorePointer(
                      ignoring: !_isMenuOpen,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _buildSpeedDialItem(
                            label: "Timed Tasks",
                            icon: Icons.hourglass_top_rounded,
                            iconColor: Colors.deepPurpleAccent,
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              _showNewTimedTaskDialog();
                            },
                          ),
                          const SizedBox(height: 12),
                          _buildSpeedDialItem(
                            label: "Counter List",
                            icon: Icons.add_circle_rounded,
                            iconColor: Colors.lightBlue,
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              _showNewCounterDialog();
                            },
                          ),
                          const SizedBox(height: 12),
                          _buildSpeedDialItem(
                            label: "To-Do List",
                            icon: Icons.check_box_rounded,
                            iconColor: AppColors.cardGreen,
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              _showNewTodoDialog();
                            },
                          ),
                          const SizedBox(height: 12),
                          _buildSpeedDialItem(
                            label: "Text Note",
                            icon: Icons.description_rounded,
                            iconColor: Colors.amber,
                            onTap: () {
                              setState(() => _isMenuOpen = false);
                              _showNewTextNoteDialog();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => _isMenuOpen = !_isMenuOpen),
                  child: AnimatedRotation(
                    turns: _isMenuOpen ? 0.125 : 0.0,
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: _isMenuOpen
                            ? Colors.white
                            : AppColors.cardOrange,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.add,
                        color: _isMenuOpen
                            ? AppColors.background
                            : Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),

      bottomNavigationBar: BottomAppBar(
        color: AppColors.navBar,
        shape: const CircularNotchedRectangle(),
        notchMargin: 8.0,
        child: SizedBox(
          height: 60,
          child: Row(
            children: [
              Expanded(
                child: _buildNavTab(
                  index: 0,
                  icon: Icons.notes_rounded,
                  label: "Notes",
                ),
              ),
              Expanded(
                child: _buildNavTab(
                  index: 1,
                  icon: Icons.edit_calendar_rounded,
                  label: "Timetable",
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildNavTab(
                  index: 2,
                  icon: Icons.school_rounded,
                  label: "Flex",
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One bottom-nav tab. The active tab gets the orange accent; inactive
  /// tabs are dimmed. Switching away from Notes closes the speed dial so
  /// it isn't left open behind the next tab.
  Widget _buildNavTab({
    required int index,
    required IconData icon,
    required String label,
  }) {
    final active = _navIndex == index;
    final color = active ? AppColors.cardOrange : Colors.white38;

    return InkWell(
      onTap: () {
        if (_navIndex == index) return;
        setState(() {
          _navIndex = index;
          _isMenuOpen = false;
        });
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Placeholder for the not-yet-built Flex tab.
  Widget _buildFlexPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.school_rounded, size: 56, color: Colors.lightBlueAccent),
          SizedBox(height: 16),
          Text(
            "Flex is coming soon!",
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

  Widget _buildSpeedDialItem({
    required String label,
    required IconData icon,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.navBar,
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: iconColor.withOpacity(0.25), width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: 20),
            const SizedBox(width: 12),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Self-contained row for the Google Account dialog: toggles every
/// timed-task reminder on/off and surfaces the exact-timing status.
class _ReminderToggleTile extends StatefulWidget {
  const _ReminderToggleTile();

  @override
  State<_ReminderToggleTile> createState() => _ReminderToggleTileState();
}

class _ReminderToggleTileState extends State<_ReminderToggleTile> {
  bool _enabled = true;
  bool _exactAvailable = true;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final enabled = await ReminderNotificationService.isEnabled();
    final exact = await ReminderNotificationService.canScheduleExact();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _exactAvailable = exact;
      _loaded = true;
    });
  }

  Future<void> _setEnabled(bool value) async {
    // Flip immediately — rescheduling a whole account can take a moment.
    setState(() => _enabled = value);

    if (value) {
      // (Re-)ask for the Android 13+ notification permission; if it was
      // already denied, Android just re-denies and the user has to allow
      // it in system settings.
      await ReminderNotificationService.requestNotificationPermission();
      await ReminderNotificationService.setEnabled(true);
    } else {
      await ReminderNotificationService.setEnabled(false);
    }

    final exact = await ReminderNotificationService.canScheduleExact();
    if (!mounted) return;
    setState(() => _exactAvailable = exact);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.cardOrange,
            ),
          ),
        ),
      );
    }

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      value: _enabled,
      activeThumbColor: AppColors.cardOrange,
      title: const Text(
        "Task reminders",
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
      ),
      subtitle: (_enabled && !_exactAvailable)
          ? GestureDetector(
              onTap: () => ReminderNotificationService.openExactAlarmSettings(),
              child: const Text(
                "Exact timing off — tap to enable in system settings",
                style: TextStyle(color: AppColors.cardOrange, fontSize: 11),
              ),
            )
          : Text(
              _enabled
                  ? "Alerts 3d / 1d / 2h / 1h / 30m / 10m / 5m before deadlines"
                  : "Reminders are turned off",
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
      onChanged: _setEnabled,
    );
  }
}
