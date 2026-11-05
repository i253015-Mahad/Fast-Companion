# FAST-Companion

A Flutter companion app for university students. It combines four daily tools in one place — **notes**, a **class timetable**, **campus wayfinding** (rooms + faculty directory), and a live view of the university's **FLEX student portal** (attendance, marks, downloads) — plus home-screen widgets and reminder notifications.

- **Package name:** `fast_companion` (bundle ID `com.example.notesm`)
- **Platforms:** Android and iOS. Web/PWA is intentionally **not** supported (key plugins such as `home_widget` and `flutter_inappwebview` have no web implementation).
- **Stack:** Flutter/Dart (`sdk: ^3.12.1`), Firebase (Core, Auth, Realtime Database), Google Sign-In.

---

## Features

### Notes (home tab)
Four note types, all creatable from the speed-dial button on the Notes tab:

| Type | Screen | Purpose |
|---|---|---|
| Text Note | `edit_note_screen.dart` | Plain rich-title text notes |
| To-Do List | `todo_screen.dart` | Checkbox lists |
| Counter List | `counter_screen.dart` | Tap-to-increment counters |
| Timed Task | `timed_task_screen.dart` | Countdown / deadline tasks |

- Notes are created, edited, starred (pinned to the top) and deleted from the home grid.
- **Note history** (`note_history.dart`) keeps previous versions; **note preview** (`note_preview.dart`) shows content without opening the editor.
- Long-press a note card to **pin it to a home-screen widget**.
- Notes sync to Firebase Realtime Database per account (`database_service.dart`) and are cached locally in SharedPreferences (`local_storage_service.dart`) so they work offline.

### Timetable
`timetable_screen.dart` + `timetable_service.dart` render the class schedule from bundled CSV data (`csv_reader.dart`), including lab spans, per-section schedules and room overrides (covered by dedicated tests).

### Rooms & Wayfinding
`wayfinding_screen.dart` hosts a two-in-one tab: a **room-occupancy list** (`rooms_screen.dart`, `room_occupancy.dart`) and a **faculty directory** (`teachers_screen.dart`, `faculty_member.dart`, `faculty_directory_service.dart`) behind a swipe shifter. Both halves stay mounted so neither loses scroll position. Data comes from bundled CSV assets.

### FLEX portal
`flex_screen.dart` embeds the university's FLEX student portal:

- The portal sits behind **Cloudflare Turnstile**, which a plain HTTP client cannot solve, so the student signs in inside a WebView and `flex_session_service.dart` **adopts the resulting session cookie**. The app never sees, stores or transmits the password — only the cookie the university's own site issued.
- The copied cookie lets later stages fetch portal pages directly in Dart (fast, parseable). If it stops working, the WebView remains the fallback — the screen always renders the live site, not only the parsed view.
- Known limitation (measured, not guessed): the portal serves about **five requests per session** and then refuses the sixth; the session is never rotated. The service is built around that budget.
- `flex_attendance_service.dart` parses attendance; `flex_marks_enhancer_service.dart` + `flex_marks_analytics.dart` (`flex_marks_model.dart`) present marks with analytics; admit-card / fee-challan downloads use the system "Save as" picker via `flutter_file_dialog` (no storage permission needed).

### Home-screen widgets
- **Android:** `home_widget` package — `home_widget_service.dart` writes note data for the widget; `widget_config_main.dart` (configuration entry point) and `widget_background_main.dart` (background tap actions, e.g. ticking a checkbox from the widget) are compiled into the app via dedicated `@pragma('vm:entry-point')` entry points in `main.dart`.
- **iOS:** native WidgetKit extension `ios/NotesWidget` (App Group `group.com.example.notesm`), kind `NotesWidget`, deployment target 16.0.
- Tapping a widget note routes through a MethodChannel into the correct editor screen (todo/counter/timed/text) via `rootNavigatorKey`, restoring account sessions first on cold start.

### Reminders & notifications
`reminder_notification_service.dart` schedules local notifications (`flutter_local_notifications` + `timezone`). Notification taps are dispatched centrally by `_dispatchNotificationTap` in `main.dart`: `uid|noteId` payloads open the matching note.

### Accounts & auth
- **Multi-account Google Sign-In** — `multi_account_auth_service.dart` keeps several signed-in accounts, persists them in SharedPreferences, and restores their sessions on cold start (needed before any widget-initiated edit can save).
- Firebase Auth + Realtime Database hold synced data (`firebase_options.dart` is the FlutterFire config).

---

## Project structure

```
lib/
├── main.dart                     # App entry + widget entry points + notification routing
├── firebase_options.dart         # Firebase configuration (FlutterFire-generated)
├── app_signals.dart              # App-wide ValueNotifiers (e.g. home refresh signal)
├── widget_config_main.dart       # Home-widget configuration screen entry point
├── widget_background_main.dart   # Home-widget background/tap action entry point
├── Screens/                      # All UI screens (note: capital "S" folder)
│   ├── home_screen.dart          # Shell: auth, notes grid, speed dial, bottom nav
│   ├── flex_screen.dart          # FLEX portal WebView
│   ├── timetable_screen.dart     # Class schedule
│   ├── rooms_screen.dart         # Room occupancy
│   ├── teachers_screen.dart      # Faculty directory
│   ├── wayfinding_screen.dart    # Tab hosting rooms + faculty
│   ├── edit_note_screen.dart     # Text notes
│   ├── todo_screen.dart          # To-do lists
│   ├── counter_screen.dart       # Counter lists
│   └── timed_task_screen.dart    # Timed tasks
├── models/                       # note, timetable_entry, room_occupancy,
│                                 # faculty_member, flex_marks_model
├── services/                     # All business/data logic (see table below)
├── widgets/                      # Reusable UI: note_card, attendance_ring,
│                                 # account_avatar, flex_marks_analytics, …
├── theme/                        # app_colors.dart, app_text_styles.dart
└── utils/                        # color_extensions.dart

assets/images/                    # App icon + logo (also used by splash screen)
test/                             # Widget & unit tests (179 tests)
ios/NotesWidget/                  # Native iOS home-screen widget
android/                          # Android project (allowBackup="false")
```

### Services (business logic lives here, not in screens)

| Service | Responsibility |
|---|---|
| `database_service.dart` | Firebase Realtime Database read/write for notes |
| `multi_account_auth_service.dart` | Multi-account Google Sign-In + session restore |
| `local_storage_service.dart` | SharedPreferences cache (accounts, notes) |
| `flex_session_service.dart` | FLEX portal WebView session & cookie adoption |
| `flex_attendance_service.dart` | Attendance parsing |
| `flex_marks_enhancer_service.dart` | Marks parsing/enrichment |
| `faculty_directory_service.dart` | Faculty data loading |
| `timetable_service.dart` | Timetable loading (CSV → entries) |
| `csv_reader.dart` | CSV parsing helper |
| `home_widget_service.dart` | Home-widget data sync (Android + iOS) |
| `reminder_notification_service.dart` | Local notification scheduling |
| `note_history.dart` | Note version history |
| `note_preview.dart` | Note preview generation |
| `profile_photo_cache.dart` | Offline avatar caching (`path_provider`) |

---

## Getting started

### Prerequisites
- Flutter SDK with Dart `^3.12.1` (`flutter --version`)
- For Android: Android Studio / SDK + a device or emulator
- For iOS: macOS with Xcode (this project is developed on Windows, so iOS builds require a Mac or cloud CI)
- A Firebase project with Auth (Google provider) and Realtime Database enabled

### Setup

```bash
flutter pub get        # install dependencies
flutter analyze        # static checks — expect "No issues found"
flutter test           # run the test suite (179 tests)
flutter run            # run on a connected device/emulator
```

### Firebase & Google Sign-In
- `lib/firebase_options.dart` is checked in with the FlutterFire-generated config. Those API keys are **public by design** — they are protected by package-name/SHA-1 restrictions in the Firebase/Google Cloud consoles, not by secrecy. Do not replace them with placeholders (that breaks Firebase init).
- Android needs the app's SHA-1 registered in the Firebase console for Google Sign-In to work.
- **Never hardcode new secrets** (passwords, tokens, private keys) anywhere in the repo.

### Building

```bash
flutter build apk      # Android APK (release)
flutter build ios      # iOS — requires macOS/Xcode
```

> Web builds (`flutter run -d chrome`) will not work: plugins used by this app have no web implementation and `firebase_options.dart` throws on `kIsWeb`. This is by design.

---

## Testing & code quality

```bash
flutter analyze   # lint (flutter_lints) — keep at 0 issues
flutter test      # 179 tests: timetable, rooms, faculty, notes, widgets, …
```

Run both after any change and fix anything you introduced before declaring a task done. Do not modify unrelated files just to quiet pre-existing warnings.

---

## Repository documentation

| File | Purpose |
|---|---|
| `README.md` | This file — what the app is and how to work on it |
| `PROJECT_MAP.md` | File-by-file navigation aid (entry points, screens, services, routing rules) |
| `SESSION_NOTES.md` | Progress log between coding sessions — read it before continuing prior work |
| `AGENTS.md` | Rules for AI coding agents working in this repo |

**Before changing navigation or a feature**, trace routes from `main.dart` / `home_screen.dart` and inspect the involved screen + service — filenames alone don't fully describe behavior.

---

## Conventions worth knowing

- **Screens vs. services:** UI lives in `lib/Screens/`; anything touching data, Firebase, the portal or storage belongs in `lib/services/`.
- **Reuse first:** check for existing models/services/widgets/theme before creating new ones; keep changes focused rather than rewriting files.
- **Branding:** brand color `#083C2E` (dark green) drives the splash screen, adaptive icon background and theme (`lib/theme/app_colors.dart`).
- **Android backup is disabled** (`android:allowBackup="false"`) to protect the FLEX session cookie, notes and saved accounts from backup extraction — keep it that way.
- **Firebase structure is off-limits** without explicit permission; same for `firebase_options.dart`.
