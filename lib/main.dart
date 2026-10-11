// lib/main.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/home_screen.dart';
import 'screens/todo_screen.dart';
import 'screens/counter_screen.dart';
import 'screens/timed_task_screen.dart';
import 'screens/edit_note_screen.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:home_widget/home_widget.dart';

import 'models/note.dart';
import 'services/local_storage_service.dart';
import 'services/multi_account_auth_service.dart'; // NEW (Fix 3b)
import 'services/reminder_notification_service.dart';
import 'app_signals.dart';

// Required so the widget-configuration entry point (used by
// NotesWidgetConfigureActivity) and the background-action entry point
// (used when tapping checkboxes/counters on the widget) actually get
// compiled into the app.
// ignore: unused_import
import 'widget_config_main.dart';
// ignore: unused_import
import 'widget_background_main.dart';

// Lets us push a screen from the widget's "open note" MethodChannel
// handler, which fires outside any normal BuildContext.
final rootNavigatorKey = GlobalKey<NavigatorState>();

@pragma('vm:entry-point')
void widgetConfigureMain() {
  WidgetsFlutterBinding.ensureInitialized();
  runWidgetConfigureApp();
}

// CHANGED (Fix 2): returns the Future so the plugin can await the work.
@pragma('vm:entry-point')
Future<void> widgetBackgroundCallback(Uri? uri) async {
  await runWidgetBackgroundAction(uri);
}

const _openNoteChannel = MethodChannel('notes_widget_open_note');

// NEW (Fix 3b): this is the body of the old setMethodCallHandler, moved into
// its own function so it can be called from two places: when the app is
// already running (Android pushes "openNote") and on a cold start (we pull
// "getInitialNote" below).
Future<void> _openNoteFromWidget(Map<String, dynamic> args) async {
  final uid = args['uid'] as String?;
  final noteId = args['noteId'] as String?;
  if (uid == null || noteId == null) return;

  // NEW: on a cold start HomeScreen is restoring sessions in parallel. Make
  // sure this account's session exists before an editor can save.
  // (Safe to call twice, see Fix 3c.)
  await MultiAccountAuthService.instance.restoreSessions(
    await LocalStorageService.loadAccounts(),
  );

  final notes = await LocalStorageService.loadNotes(uid);
  Note? note;
  for (final n in notes) {
    if (n.id == noteId) {
      note = n;
      break;
    }
  }
  if (note == null) return;

  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;

  Widget screen;
  switch (note.type) {
    case 'todo':
      screen = TodoScreen(note: note, uid: uid);
      break;
    case 'counter':
      screen = CounterScreen(note: note, uid: uid);
      break;
    case 'timed':
      screen = TimedTaskScreen(note: note, uid: uid);
      break;
    default:
      screen = EditNoteScreen(note: note, uid: uid);
  }
  // Clears any previous note screen still on the stack — otherwise
  // repeatedly tapping the widget's edit button stacks a new screen on
  // top of an old one, and going "back" into a stale earlier instance
  // could re-save outdated data over a newer edit.
  nav.popUntil((route) => route.isFirst);
  await nav.push(MaterialPageRoute(builder: (_) => screen));
  // HomeScreen doesn't know this edit happened (it bypassed the normal
  // openAndEditNote flow), so nudge it to refresh — otherwise the save
  // succeeds but the app appears to still show the old data.
  homeRefreshSignal.value++;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await GoogleSignIn.instance.initialize(
    serverClientId:
        "789024692194-n7ljctd8gv7vgs67kdbr2tjvr37uq1kl.apps.googleusercontent.com",
  );

  await HomeWidget.registerInteractivityCallback(widgetBackgroundCallback);

  // Reminder notifications carry a `uid|noteId` payload; tapping one opens
  // that timed note through the same path as the widget's edit button.
  // (Cold starts launched *by* the tap are handled below via launch details.)
  ReminderNotificationService.onNotificationTap = (payload) {
    final parts = payload.split('|');
    if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
      _openNoteFromWidget({'uid': parts[0], 'noteId': parts[1]});
    }
  };

  // Handles the widget's "edit" (pencil) button while the app is already
  // running. CHANGED (Fix 3b): the handler now just calls the function above.
  _openNoteChannel.setMethodCallHandler((call) async {
    if (call.method != 'openNote') return;
    await _openNoteFromWidget(Map<String, dynamic>.from(call.arguments as Map));
  });

  runApp(const MyApp());

  // NEW (Fix 3b): cold start. If the app was launched by the widget's edit
  // button, MainActivity holds the request until we ask for it here.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    // Timed-task reminders: schedule everything first (local, fast), then
    // ask for the Android 13+ notification permission — at most once.
    await ReminderNotificationService.syncAll();
    await ReminderNotificationService.requestPermissionOnce();

    // Or cold start launched by TAPPING a reminder notification — open that
    // note instead of the widget's pending edit request.
    final launch = await ReminderNotificationService.launchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      final parts = (launch.notificationResponse?.payload ?? '').split('|');
      if (parts.length == 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        await _openNoteFromWidget({'uid': parts[0], 'noteId': parts[1]});
      }
      return;
    }

    final initial = await _openNoteChannel.invokeMethod<Map<dynamic, dynamic>>(
      'getInitialNote',
    );
    if (initial != null) {
      await _openNoteFromWidget(Map<String, dynamic>.from(initial));
    }
  });
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      debugShowCheckedModeBanner: false,
      home: const HomeScreen(),
    );
  }
}
