# Session Notes

## Task (CURRENT) — iOS support, Option B: FULL iOS support incl. native WidgetKit home-screen widget

**Status: COMPLETE & FULLY CONFIGURED. `flutter analyze` = No issues found, `flutter test` = 179 passed.**

Goal: iOS users get Notes, Timetable, Flex portal, GPA analytics, reminders, Google Sign-In, downloads AND a home-screen widget, at parity with Android.

## Division of labor
- **The user builds/installs the APK themselves — the agent must NOT run `flutter build` or `adb install`.**
- **iOS builds require macOS/Xcode; the user builds/tests iOS on a Mac or via Cloud CI (GitHub Actions/Codemagic).** Windows machine here — all Flutter & iOS native code is written and verified.
- Never run git commands that change repo state. Never hardcode secrets.

## Completed Work

### 1. Firebase & Google Auth iOS Config (DONE)
- User created iOS app in Firebase Console for `com.example.notesm` and placed `GoogleService-Info.plist` inside `ios/Runner/`.
- `lib/firebase_options.dart`: added `FirebaseOptions ios` const with `appId` `1:789024692194:ios:a44dd8c145d6b25a2c0bbb` & `apiKey` `AIzaSyBupgrpPKt3t7lS3AiTa5ubQL9qaKGTgKw`. `currentPlatform` returns `ios` for TargetPlatform.iOS.
- `ios/Runner/Info.plist`: added `REVERSED_CLIENT_ID` (`com.googleusercontent.apps.789024692194-pcn0jul1ore87ss81glq4edpq0hqq145`) under `CFBundleURLTypes` for Google Sign-In OAuth redirect on iOS.
- `firebase.json`: updated with iOS target config.

### 2. Dart Platform Guards & Logic (DONE)
- `lib/main.dart`: `HomeWidget.setAppGroupId('group.com.example.notesm')` first in `main()`; `registerInteractivityCallback` Android-only; `HomeWidget.widgetClicked.listen(...)` + `_openNoteFromWidgetUri(Uri)` helper (parses uid/noteId query params → `_openNoteFromWidget`); iOS cold-start via `HomeWidget.initiallyLaunchedFromHomeWidget()` in postFrame; `getInitialNote` invoke wrapped in Android-only guard (was throwing MissingPluginException on iOS).
- `lib/services/reminder_notification_service.dart`: added `_ios` getter (`resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>`); both `requestPermissionOnce()` and `requestNotificationPermission()` now call `_requestPlatformPermission()` = Android permission + `IOSFlutterLocalNotificationsPlugin.requestPermissions(alert/badge/sound)`. Darwin init already existed.
- `lib/services/home_widget_service.dart`: new constants `appGroupId`, `_iosWidgetName = 'NotesWidget'`, `iosWidgetId = -1` (single virtual widget → payload key `payload_-1`, all existing per-id logic works unchanged); new `_broadcastUpdate()` (iOS → `updateWidget(iOSName:)`, Android → `updateWidget(androidName:)`); `ensureWidgetsDrawn()` skips RemoteViews repair on non-Android.
- `lib/Screens/home_screen.dart`: `_pinToWidget` iOS branch pins directly to `HomeWidgetService.iosWidgetId` (no widget picker) with snackbar; Android flow untouched.
- `pubspec.yaml`: `flutter_launcher_icons.ios: true`, `flutter_native_splash.ios: true` (both regenerated successfully).

### 3. iOS WidgetKit Extension & Native Assets (DONE)
- `ios/Runner/Runner.entitlements` + `ios/NotesWidget/NotesWidget.entitlements`: App Group `group.com.example.notesm`.
- `ios/NotesWidget/NotesWidget.swift`: full WidgetKit widget, kind `NotesWidget`, reads `UserDefaults(suiteName: group)["payload_-1"]`, palette #08343D/#FF9F68/#2AB7A9/#F2C94C, small/medium/large families (3/5/12 rows), todo checkboxes + countdown chips (`5m/3h/2d`/overdue), counter capsule badges, empty state, `.widgetURL` `notesm://opennote?uid=..&noteId=..&homeWidget` (the `homeWidget` query item is REQUIRED by home_widget), containerBackground for iOS 17+ with fallback, timeline refresh every 15 min. Deployment target 16.0.
- `ios/NotesWidget/Info.plist`: NSExtension `com.apple.widgetkit-extension`.
- `ios/Runner.xcodeproj/project.pbxproj`: NotesWidget extension target added manually (24-hex IDs prefixed `FAC11E...`). Validated: braces/parens balanced, no duplicate IDs.
- Assets: `dart run flutter_launcher_icons` ✓ (iOS AppIcon set regenerated), `dart run flutter_native_splash:create` ✓ (iOS LaunchImage + storyboard).

## Environment facts (verified)
- Bundle ID `com.example.notesm`, project deployment target 13.0 (widget target 16.0).
- firebase.json has Android + iOS configs.
- Server client id for Google: `789024692194-n7ljctd8gv7vgs67kdbr2tjvr37uq1kl.apps.googleusercontent.com`.
- iOS client id: `789024692194-pcn0jul1ore87ss81glq4edpq0hqq145.apps.googleusercontent.com`.
- REVERSED_CLIENT_ID: `com.googleusercontent.apps.789024692194-pcn0jul1ore87ss81glq4edpq0hqq145`.

## Next steps (for user / cloud build)
- Build on Mac or GitHub Actions / Codemagic: `flutter pub get` → `flutter build ios`.
