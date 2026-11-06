# Session Notes

## Task (CURRENT) — Analytics sheet: "Abs Diff" rename, Class Avg row, single standing bar (now percentage-based)

**Status: DONE (verified). Next: user builds & installs the APK.**

**User's requests (verbatim):** *"in the first row (your score stays as it is, class average stays as it is, abs diff claculation stays as is, just change the name from "Diff from Avg" to "Abs Diff") in the box (Attained absolutes as is, after attainded abs, show class avg abs, and finally the remaining abs as is) and finally the bars (make it a single bar of 100 abs with a verticle line on it showing avg abs, and another showing where we stand)"*, then a correction: *"you got it all wrong, you have changed the attained abs which I told you not to change and because of that the class avg abs is also wrong. Put those back as they were. And in the bar write 0 on the left and 100 on the right below the bar to show the range. I said that in your calculation of remaining abs, you need to do 100 - alloted abs and that was it"*, then: *"Everything is perfect now!! Just one change which is in the final bar. instead of showing abs, show the percentage, the rest remains exactly the same"* — when asked which percentage, the user chose **"Score on graded work (80.0% / 70.0%)"**, not course completion.

**IMPORTANT — a normalisation was added and then fully reverted.** An earlier round applied a `100/Σweightage` factor to the absolutes; the user rejected it. The model is back to its **original raw getters** — do not reintroduce scaling.

**Files changed:**
- `lib/models/flex_marks_model.dart` — reverted to raw sums; only rule is `remainingWeightage = 100.0 - evaluatedWeightage` (`< 0` guard kept). `_rawTotalWeightage` / `_normalisationFactor` deleted. `totalWeightage` = Σ item weightage (always 100 for real FAST courses). `attainedAbsolutes` / `classAvgAbsolutes` / `evaluatedWeightage` are plain folds with **no factor**. `percentage` / `classAvgPercentage` / `diffFromAvg` / `letterGrade` / `gradePoint` untouched.
- `lib/widgets/flex_marks_analytics.dart` — the UI changes below + overflow hardening.
- `test/flex_marks_analytics_test.dart` — **new**, 6 tests, retargeted to raw semantics.

**Widget (`flex_marks_analytics.dart`):**
1. Tile label `'Diff from Avg'` → **`'Abs Diff'`** (value/sign/colors unchanged).
2. Grey box = three rows via `_boxRow(label, value)`, in order: `Attained Absolutes: 32.0 / 100.0 (80.0%)` → `Class Avg Absolutes: 28.0 / 100.0 (70.0%)` (new) → `Remaining Absolutes: 60.0`.
3. Both progress bars + `_buildProgressBar` **deleted**; `_buildStandingBar(percentage, classAvgPercentage)` — **percentage, not absolutes** (call site line ~160; both locals already in `build()`): header **`Standing (0–100%)`**, grey 6px track, orange fill to your score (80% of track), dark (`textPrimary`) 3px line at the class avg score (70%), orange 3px line at your position **drawn last** (wins on overlap), lines span 20px and overhang the track, then a `SpaceBetween` row of **`0%` (left end) and `100%` (right end)**, then legend **`You 80.0%  ·  Avg 70.0%`** — the same figures as the two tiles. `LayoutBuilder` + `Stack` + `Positioned`; fractions clamped `0..1`, left clamped `[0, w-3]`. Params renamed `yourScore`/`classAvgScore`. **Untouched:** box rows, three tiles, `Abs Diff`, grade badge, Semester GPA, `attained`/`classAvgAbsolutes`/`total`/`remaining` locals.

**Overflow fix (keep):** grey-box rows overflowed because `RenderFlex` lays **non-flexible** children out **unbounded** — a plain `Text` (or an `FittedBox` around one) takes natural width and blows past the Row, and a `Flexible` label alone can't help when the *value* is the wide part. Fix in `_boxRow`: **both** children `Flexible`; label ellipsizes, value wrapped in `FittedBox(fit: scaleDown)`. Layout only — moves no numbers.

**Tests (6):** model — raw-100 figures exact; raw-95 reported **raw** (attained 23, evaluated 40, classAvg 25, total 95) with `remaining == 100 - evaluated == 60`; percentages/diff/grade from raw sums (`diffFromAvg == -2.0`; grade reads `D+` because 57.5 sits on the D+/C- boundary and `23/40*100` lands a hair under 57.5 in binary — the model's own arithmetic, deliberately unchanged). Widget (DS BD3 Pro 1080x2412@3.0): `Abs Diff`+`+4.0`, three box rows **in order** with exact strings, bar header `Standing (0–100%)`, **`0%` and `100%` each present with `0%.left == track.left` and `100%.right == track.right`**, legend figures `'80.0%'`/`'70.0%'` asserted as **`findsNWidgets(2)`** (tile + legend each — exact `'32.0'`/`'28.0'` strings no longer exist anywhere on the card, so those finds were dropped), the 4 `Positioned` children measured against the track's width (`fill == 80%`, avg at `70% - 1.5`, you at `80% - 1.5`, colors `textPrimary`/`cardOrange`, you-line last), ungraded course keeps both markers at the left edge (0%).

**Verification:**
- ✅ `dart analyze lib test` — No issues found (`flutter analyze` timed out at 180s earlier; use `dart analyze`).
- ✅ `flutter test` — **191/191 passing**.
- `dart format` NOT run (project-wide non-compliance, per AGENTS.md).

**Files:** `lib/models/flex_marks_model.dart`, `lib/widgets/flex_marks_analytics.dart`, `test/flex_marks_analytics_test.dart`, `SESSION_NOTES.md`. No pubspec/Firebase changes.

**Known issue deliberately deferred (user: "Leave it for later"):** `FlexCourseMarks.letterGrade` never checks whether anything is graded → a course with **zero graded items** yields `percentage 0` → `'F'` → `gradePoint 0.0`, and `computeSemesterGpa` only skips `null` → such a course drags the Semester GPA header down. Fix would be `letterGrade` returning null when `evaluatedWeightage == 0`. Not addressed.

**Manual test cues:** Flex → Marks → chart icon → per course: `Abs Diff` tile; box rows Attained / Class Avg / Remaining (raw absolutes); one bar on a **0%–100%** scale with **`0%` under its left end, `100%` under its right**, fill = Your Score %, dark line = Class Avg %, legend `You 80.0% · Avg 70.0%`; `Semester GPA` unchanged.

---

## Task (PREVIOUS) — First-login Welcome snackbar color + reminder toggle shows OS permission truth

**Status: DONE (verified). Next: user builds & installs the APK.**

**Two user-reported bugs:**

1. **First-login "Welcome" snackbar had the default (grey) background.** The first sign-in path (Sync Notes card → "Sign in with Google") showed `SnackBar(content: Text("Welcome: …"))` with no `backgroundColor`, while later logins ("Add another account" in the switcher) set `AppColors.cardOrange`. No global snackBarTheme exists, so the first path just never got the color.
2. **Reminder toggle lied after the user denied the notification prompt.** The tile read only the in-app pref (`reminders_enabled`, default true) and never checked the OS permission → toggle showed ON while Android was dropping every notification. Android shows the system prompt at most twice per install (startup `requestPermissionOnce` + first toggle-on); after that it silently auto-denies, so the old code did nothing and left the switch ON with no explanation.

**Fixes:**
- **`lib/Screens/home_screen.dart` (done):**
  - Welcome snackbar gains `backgroundColor: AppColors.cardOrange` (matches "Switched to" exactly).
  - `_ReminderToggleTileState` rewritten: adds `WidgetsBindingObserver` (`didChangeAppLifecycleState(resumed)` → `_load()`, observer added/removed in initState/dispose). State split: `_pref` (in-app intent, kept even while blocked so a settings grant restores ON) + `_allowed` (real OS permission) + `bool get _enabled => _pref && _allowed` (what the switch shows).
  - `_load()` reads pref + `notificationsEnabled()` + exact-alarm status. `_setEnabled(true)` requests permission, then **re-reads** `notificationsEnabled()` (Android may silently auto-deny) and sets `_allowed` from reality; persists via existing `setEnabled(value)`.
  - Subtitle priority: `!_allowed` → tappable "Notifications blocked — tap to open system settings" (`openNotificationSettings()`), else exact-alarm hint, else normal text — same GestureDetector pattern as the exact-alarm line.
  - **Follow-up 1 (user feedback):** tapping the toggle itself while blocked did nothing (prompt budget spent → request was a silent no-op) → toggle-on now opens system settings when still `!allowed` after the request.
  - **Follow-up 2 (user feedback):** that auto-open wrongly fired even when the user had just DENIED the second system prompt — settings must only open on a later toggle. Fix is a **timing heuristic** in `_setEnabled`: `Stopwatch` around `requestNotificationPermission()`; the plugin's Android future completes only from `onRequestPermissionsResult` (verified in source, line 2058–2066), i.e. after a real dialog is answered (always > `_silentRequestCeilingMs = 400`), while a spent-budget silent re-denial returns in milliseconds. So settings auto-open only when `!allowed && elapsed < 400ms`. A pref-flag approach was tried first (helpers added, then removed — grep confirms zero references). Plugin source: `flutter_local_notifications-22.3.3`.
- **`lib/services/reminder_notification_service.dart` (done):** two new helpers — `notificationsEnabled()` (Android: `areNotificationsEnabled()`; iOS: `checkPermissions().isEnabled || isProvisionalEnabled`; null → true, i.e. platforms without the concept behave as before) and `openNotificationSettings()` (wraps `_plugin.openAppNotificationSettings()` — available in installed flutter_local_notifications 22.3.x on both platforms).

**Behavior preserved (user-confirmed good):** when permission is granted, toggle off→on does NOT re-prompt (system has nothing to ask) and reminders schedule/show normally — unchanged.

**Verification:**
- ✅ `flutter analyze` — No issues found.
- ✅ `flutter test` — **185/185 passing**.
- `dart format` NOT run (project-wide non-compliance, per AGENTS.md).

**Files:** `lib/Screens/home_screen.dart`, `lib/services/reminder_notification_service.dart`, `SESSION_NOTES.md`. No pubspec changes.

**Manual test cues:** fresh install → deny prompt → toggle must show OFF + blocked subtitle → tap subtitle → system settings → grant → return to app → toggle flips ON. First-login Welcome snackbar should be orange like later "Switched to" ones.

---

## Task (PREVIOUS) — Tutorial fixes round 2 (SnackBar FAB tracker, skip suppression, step-swap index reset)

**Status: DONE (verified). Next: user builds & installs the APK.**

**Three user-reported bugs, one shared class of root cause:**

1. **Bug A — spotlight left pointing at empty space after the login SnackBar.** Login-success SnackBar → Scaffold *raises* the FAB above it (SDK `scaffold.dart:1122-1144`), tutorial measured the raised FAB correctly, then the SnackBar dismissed ~4s later — after the old bounded settle re-checks (300ms/+800ms + 5×800ms polls, exhausted at ~1.1s) — FAB dropped → stale hole.
2. **Bug B — skipping the notes welcome appeared to "advance" instead of stopping.** Skip was correctly wired (`onSkip` → mark seen); but the first-note tutorial became eligible in the *same* rebuild (its trigger fired during welcome via first-note sync), took over the same unkeyed Positioned.fill slot instantly → looked like the step advanced.
3. **Bug C — second notes tutorial opened at "Step 3 of 3".** Welcome finished via 'Got it!' at index 2; first-note tutorial reused the overlay State (same type+position, no key) → inherited `_localIndex = 2`. Same class of bug across tabs (finish notes step 3 → unseen timetable would open at step 3).

**Fixes:**
- **`lib/widgets/tutorial_overlay.dart` (done):**
  - *Tracker replaces bounded settle checks:* fields now `static const _trackInterval = 200ms` + `Timer? _trackTimer` (removed `_settleChecks/_settlePoll/_maxSettlePolls/_settleChecksDone/_settlePollsDone/_settleTimer`). `_startTracking()` (called only from `_resolveCurrentTarget` completion; skipped when targetId null) runs `Timer.periodic(200ms → _trackTarget())`; `_trackTarget` re-resolves with token guard and `setState` **only when rect != _targetGlobal** (static screen = zero rebuilds; late-mount null→rect heals; unmount→null centers). `_resetTracking()` on step change/controller/metrics; cancel in `dispose()` first line.
  - *Step-swap reset:* `didUpdateWidget` steps branch — when `!identical(oldWidget.steps, widget.steps)` → `_localIndex = 0` before reset+resolve, so a different tutorial taking over the slot starts at step 1.
- **`lib/screens/home_screen.dart` (done):** new field `bool _welcomeSkipped = false` (in-memory: skip = leave me alone — first-note tutorial suppressed this session; prefs stays unseen); `_buildCurrentTabTutorial` onSkip closure now `() { if (tabIndex == 0) _welcomeSkipped = true; _completeTutorial(tabIndex); }` (onDone unchanged); `_buildNoteActionsTutorial` null-gate adds `|| _welcomeSkipped`.

**Test:** new 6th case in `test/tutorial_overlay_test.dart` — "a different step list restarts the tutorial at step 1": page to step 2, re-pump host with a different const steps list, assert 'gamma step' + 'Step 1 of 2' visible (not inherited index 1).

**Verification:**
- ✅ `flutter analyze` — No issues found.
- ✅ `flutter test` — **185/185 passing** (184 + 1 new).
- `dart format` NOT run (project-wide non-compliance, per AGENTS.md).

**Files:** `lib/widgets/tutorial_overlay.dart`, `lib/screens/home_screen.dart`, `test/tutorial_overlay_test.dart`, `SESSION_NOTES.md`.

---

## Task (PREVIOUS) — Fix Notes step-1 spotlight pointing at the wrong spot (FAB entrance animation)

**Status: DONE (verified). Next: user builds & installs the APK.**

**Reported (user):** "step 1 in notes tutorial does not point to the + button… the tutorial starts before the button appears… The button is actually roughly 50px down and 20px to the right of the current pointing location."

**Root cause:** `TutorialOverlay` measured its target exactly once (post-frame at mount) and never again. The Notes FAB is wrapped by Scaffold's entrance animation (`_FloatingActionButtonTransition` — `ScaleTransition`+`RotationTransition`, ~200ms easeIn) that transforms about the center of the whole speed-dial `Stack` (tall: hidden menu column), so mid-animation the + button's apparent global rect sits up-left of where it settles. The stale rect kept the hole misplaced for the whole step.

**Fix (`lib/widgets/tutorial_overlay.dart` only):**
- Added `dart:async`; state: `Timer? _settleTimer`, `_settleChecksDone`, `_settlePollsDone` + consts `_settleChecks = [300ms, 800ms]`, `_settlePoll = 800ms`, `_maxSettlePolls = 5`.
- `_resolveCurrentTarget()` now calls `scheduleFrame()` (settle timers fire between frames; `addPostFrameCallback` alone wouldn't run on an idle app) and, after each successful measure, `_scheduleSettleRecheck(rect, targetId)`: null targetId → no tracking; resolved → up to 2 settle re-measures (300ms, +800ms) so animated-into-place targets re-park; unresolved → poll every 800ms up to 5× so late-loading targets (e.g. teachers list) get their hole once mounted.
- `_resetSettleSchedule()` (cancels timer + zeroes budgets) on step change: `_setIndex` local branch, `_onControllerChanged`, `didUpdateWidget` (controller/steps change), `didChangeMetrics`. Timer canceled in `dispose()`. Stale-async token guard unchanged.

**Test:** new 5th case in `test/tutorial_overlay_test.dart` — "the spotlight follows a target that settles into place later": host target moved 100px down without telling the overlay; asserts the card travels the same delta once the settle re-check fires. (First run failed only because the assertion compared against the step-counter *text* rect (~69px inside the card) instead of the card top — fixed to compare deltas.)

**Verification:** ✅ `flutter analyze` — No issues found. ✅ `flutter test` — **184/184 passing** (183 + 1 new).

---

## Task (PREVIOUS) — Tutorial refinements (4 changes: rooms→teachers, notes timing, flex underline fix, flex restructure)

**Status: DONE (verified). Next: user builds & installs the APK.** Approved plan (user: "Everything is perfect now. Implement starting with the md update"):

1. **Rooms → Teachers continuation** — move rooms tutorial ownership from `HomeScreen` into `WayfindingScreen` (embedded overlay, gated `widget.active && !seen`, own `TutorialController`). New 7-step flow: [0] roomsFilters → [1] roomsList tap → [2] roomsList auto-refresh → [3] shifter **waitForTrigger** ("Tap Teachers to continue", advanced by `_segment` onTap callback) → [4] first teacher card office pill (`teachersOffice`, keyed at card index 0 only) → [5] first card **waitForTrigger** ("Tap to expand", advanced via new `onCardExpanded` callback on `TeachersScreen`) → [6] `teachersActions` (key inside `if (open)` — only one card expands at a time) explaining Email/Copy + office pill colors. HomeScreen drops tab 2 from `_loadTutorialState`/`_buildCurrentTabTutorial`/`_completeTutorial`.
2. **Notes timing** — welcome tutorial (case 0) gated on `_isUserLoggedIn` (shows on first visit after login); welcome shrinks to 3 steps (FAB, search, avatar — star/hold step removed). NEW "first note" tutorial: new prefs key `has_seen_note_actions_tutorial`, title 'Your First Note!', 3 steps targeting the first note card (`notesFirstCard`): star=pin to top, hold=pin to home widget, trash=delete. Trigger in `_refreshLocalNotes()` on empty→non-empty when unseen; displayed only when `_navIndex==0` && welcome done (second overlay slot in home Stack). `_buildNotesGrid` gains optional `{Key? firstCardKey}` → index 0 only; passed at the mutually-exclusive call sites (no duplicate GlobalKey; `NoteCard` has `super.key`).
3. **Yellow underline fix** — root cause: flex tutorial in root OverlayEntry has NO Material ancestor → MaterialApp `_errorTextStyle` (monospace + yellow double underline) leaks via `defaultTextStyle.merge`. Fix: wrap `TutorialOverlay.build` top-level in `Material(type: MaterialType.transparency, child: ...)`.
4. **Flex restructure** — new 6-step `flexMarksTutorialSteps`: flexBack → flexOpen → flexRefresh → flexAnalytics (explains sheet contents, doesn't open) → flexSignOut → [5] centered (null targetId) Semester Overview explanation. REMOVE: JS resolver (`_resolveTutorialTarget`, `_parseOverviewRect`, `dart:convert`, flexWebView key), wait machinery (`_tutorialController` field+param, `_reinsertTutorialEntry`, waitIndex advance/retreat in `_showAnalytics`), sheet keys (sheetGpa/sheetCourseCard/sheetBars), revert `progressKey` on `FlexMarksAnalyticsWidget`, drop unused registry ids, add teachers/notes ids. KEEP `_syncTutorialEntry` root-entry hosting + dispose + toolbar keys.

**Files:** tutorial_overlay, tutorial_content, tutorial_titles, tutorial_service, tutorial_targets, home_screen, wayfinding_screen, teachers_screen, flex_screen, flex_marks_analytics, SESSION_NOTES. No new deps. Verify: `flutter analyze` + `flutter test` (183 expected).

**Progress:** session-notes ✅ → implementation ✅ → verification ✅.

**Verification (final):**
- ✅ `flutter analyze` — No issues found (run after main edits and again after tutorial_overlay re-indent).
- ✅ `flutter test` — 183/183 passing (incl. 4 overlay tests + wayfinding/room tests exercising new code paths).
- ✅ Leftover grep clean: removed `flex.overviewCard`/`sheetGpa`/`sheetCourseCard`/`sheetBars`/`flexWebView`/`_reinsertTutorialEntry` only appear nowhere; `hasSeenRoomsTutorial` only in service definition + WayfindingScreen usage.
- ⚠️ `dart format` NOT run: project-wide non-compliance (all touched files fail `--set-exit-if-changed` incl. untouched ones) — avoided churn per AGENTS.md; tutorial_overlay build() body hand-re-indented instead.

---

## Task (PREVIOUS) — Tutorial spotlight: point at features instead of centered box

**Status: DONE (verified).**

Tutorials now dim the screen with a spotlight hole around the exact control being explained (orange glow + arrow from card to hole), instead of a centered box the user has to map to the UI.

### What was built
- `TutorialStep {text, targetId, waitForTrigger}` — null targetId → centered card (old behavior); waitForTrigger → wait step: no Next, taps pass through the hole so the highlighted control stays tappable.
- `lib/widgets/tutorial_targets.dart` — named GlobalKey registry (`TutorialTargets.resolve(id)` / `resolveMounted(id)`; unmounted key → centered fallback).
- `lib/widgets/tutorial_overlay.dart` rewritten: even-odd CustomPaint dimmer + rounded-rect hole + orange arrow; async injectable resolver (default = GlobalKey rect, custom for WebView HTML); card parks below/above the hole (AnimatedPositioned); `TutorialController` keeps step index across host re-mounts; wait-mode uses 4 transparent barrier bars tiling screen-minus-hole; `onWaitAction` fallback button when hole unresolvable; re-resolves on metrics change with stale-async token guard.
- Step flows: Notes (4: FAB, grid, search, avatar), Timetable (5: school pills, filters, day tabs, list, attendance rings), Rooms (4: filter pills, list, shifter, list), Flex (10): [0] JS-scrolls to purple Semester Overview card (`scrollIntoView` + `getBoundingClientRect`, scale/origin-normalized, 3 retries) → [1-5] Back / Open / Refresh / Analytics / Sign out each spotlighted → [6] wait step on Analytics ("tap the highlighted chart button") → [7-9] sheet steps: Semester GPA, first course card, progress bars (advance on sheet open, retreat to wait step if sheet closed early).
- Flex hosting: root-level `OverlayEntry` (`rootOverlay: true`) so the tutorial paints above the bottom-sheet route; re-inserted after sheet push; entry removed in new `dispose()`.
- Keys attached: home_screen (FAB GestureDetector, search TextField, content Expanded, avatar GestureDetector), timetable_screen (school pills, filters via KeyedSubtree, day tabs, list Expanded), rooms_screen (header Column, list Expanded), wayfinding_screen (`_shifter` Container), flex_screen (4 toolbar IconButtons via new `Key? key` on `_action`, analytics Padding, InAppWebView, sheet GPA Container, first course card + `progressKey` on `FlexMarksAnalyticsWidget` progress Row).

### Files created
`lib/widgets/tutorial_targets.dart`, rewritten `lib/widgets/tutorial_overlay.dart`, rewritten `lib/models/tutorial_content.dart` (+ `TutorialStep`), `test/tutorial_overlay_test.dart`

### Files modified
`SESSION_NOTES.md`, `lib/screens/home_screen.dart`, `lib/screens/timetable_screen.dart`, `lib/screens/rooms_screen.dart`, `lib/screens/wayfinding_screen.dart`, `lib/screens/flex_screen.dart`, `lib/widgets/flex_marks_analytics.dart`, `lib/models/tutorial_titles.dart` (flexMarks title → 'Welcome to Flex!')

### Verification
✅ `flutter analyze` — No issues found. ✅ `flutter test` — 183/183 passing (179 existing + 4 new overlay tests: card below target, centered fallback, Next/done paging, wait-step hole tap-through vs outside block).

---

## Task (PREVIOUS) — Add onboarding tutorial system for new users

**Status: DONE (verified).** Step-by-step tutorial overlays shown once per feature for new users.

### What was built
- **Notes / Timetable / Rooms tabs:** each shows its own overlay the first time the tab opens. Overlay = dimmed barrier + centered card (title, "Step i of n", step text, page dots, Skip / Next → Got it!). Bottom nav stays usable.
- **Flex tab:** tutorial appears **only on the Marks page** (URL contains `studentmarks`) and explains the injected purple "Semester Overview" card at the bottom, the orange chart button in the toolbar, the Marks Analytics sheet (Semester GPA, per-course score vs class avg, grade badge, attained vs remaining weightage, progress bars).

### Files created
- `lib/services/tutorial_service.dart` — singleton + SharedPreferences persistence (keys `has_seen_notes_timetable_rooms_flex_marks_tutorial` variants), `hasSeen*/mark*AsSeen()` per feature, `resetAllTutorials()`
- `lib/widgets/tutorial_overlay.dart` — reusable `TutorialOverlay` (ModalBarrier + animated card, internal single-step paging: title, steps, skipText, nextText, doneText, onSkip, onDone)
- `lib/models/tutorial_content.dart` — `TutorialContent` with the 4 step lists (notes/timetable/rooms/flexMarks)
- `lib/models/tutorial_titles.dart` — `TutorialTitles` (Welcome to Notes!/Timetable/Rooms/Marks Analytics!)
- `lib/models/tutorial_actions.dart` — `TutorialActions` (Skip / Next / Got it!)

### Files modified
- `lib/screens/home_screen.dart` — `_seenTutorialTabs` set + `_loadTutorialState()` (fire-and-forget in `_initState()`), `_buildCurrentTabTutorial()` switches on `_navIndex` (0/1/2 only; Flex excluded), single overlay `Positioned.fill` over the IndexedStack in a `Stack`, `_completeTutorial(tabIndex)` marks seen in prefs
- `lib/screens/flex_screen.dart` — `_shouldShowMarksTutorial` + `_loadMarksTutorialStatus()` in initState; `build()` is a Stack where the overlay renders only when `_shouldShowMarksTutorial && _onMarksPage`; `_completeMarksTutorial()` persists and hides

### Verification
✅ `flutter analyze` — No issues found. ✅ `flutter test` — 179/179 passing.

---

## Task (PREVIOUS) — Rewrite README.md

**Status: DONE.** Replaced the default Flutter template in `README.md` with full project documentation: features (notes/timetable/rooms/FLEX portal/widgets/reminders/auth), project structure, services table, setup/run/build commands, testing (179 tests), repo docs (PROJECT_MAP/SESSION_NOTES/AGENTS), and conventions (secrets policy, allowBackup, Firebase config rules). Docs-only change — no code touched, no analyze/test needed. Next: user reviews README; otherwise resume prior backlog.

---

## Task (PREVIOUS) — Revert "Added web compatibility"; web/PWA abandoned

**Status: DONE (verified). Next: user builds & installs; iOS native app is the iOS path.**

### Background & decision
User first tried running on Chrome (`flutter run -d chrome`), hit `MissingPluginException` (home_widget `setAppGroupId`) and `flutter_inappwebview` unavailable errors. Root cause: plugins have no web impl + `firebase_options.dart` throws on `kIsWeb`. User then decided against a PWA: **"because the web app does not give full feature, I will try ios application and now we don't need the web configurations"** → remove web config, restore pre-web build. iOS users get the native app (`e4b1cbc Added ios compatibility` + `ios/NotesWidget`, untouched).

### What was done
- `git revert --no-edit 346a1d8` → commit `029dba1 "Revert \"Added web compatibility\""`.
- Reverted commit removed: `web/` (6 files), `.firebaserc`, `.firebase/` cache, `test/widget_test.dart` (broken counter smoke test), and restored `firebase.json` (original FlutterFire android/ios config — it had been **replaced** by a hosting block), `.metadata`, `pubspec.lock`.
- Verified: `git diff 346a1d8^ HEAD` empty (tree identical to pre-web state); `flutter pub get` OK; `flutter analyze` = No issues; `flutter test` = 179/179 passing.

### Notes
- No `lib/` code was ever changed for web — app logic untouched by the revert.
- `flutter run -d chrome` will never work for this app (by design now); use Android/iOS.
- `firebase.json` hosting block gone — no Firebase Hosting setup remains.

---

## Task (PREVIOUS) — Security pass cleanup: revert safe changes, keep only real fixes

**Status: COMPLETED.**

### Background
The "Pre-deployment security checklist" session (ID `ses_e630c6152ffe0RnrCSNKCPuSX3`) crashed: it hit max context, then OpenCode compaction failed 3× (`Compaction fallback failed: ... 'delete event.tools.compress'`). It left 4 analyzer errors, never ran tests, and broke Firebase with placeholder API keys. Its full history can be read anytime with:
`opencode api get /api/session/ses_e630c6152ffe0RnrCSNKCPuSX3/message`

### Binding user decisions
1. **Guiding principle (user's exact words):** "undo everything which was already safe before and only implement what actually fixes a security issue."
2. Firebase API keys are **public by design** (protected by package/SHA-1 restrictions in Cloud Console) → keep the FlutterFire-generated keys in `lib/firebase_options.dart`; never placeholder them again.
3. Keep the auth guard exactly as-is (user: "already secure, skip it").
4. Behavior-affecting changes (rate limiting, session manager, file validation, Firebase security rules wiring) = **Phase 2 → always ASK the user first**.
5. Division of labor: **user builds/installs the APK** (never `flutter build`/`adb install`); never run git commands that change repo state; never hardcode NEW secrets; never modify Firebase config/database structure without permission.

### Exact resume steps
1. ✅ Update this file (you are here).
2. ✅ Revert the 4 modified files (all were safe before the security pass).
3. ✅ Delete the 5 unwired files created by the failed session.
4. ✅ Scan for REAL security issues only and fix the clear-cut ones (ask before anything ambiguous or Firebase-related).
5. ✅ Run `flutter analyze` (0 issues, clean state).
6. ✅ Run `flutter test` (179 passing).
7. ✅ Update this file with verified end state; tell the user to build & install.

### Why each failed-session change is being undone
| File | Change made | Why it was already safe |
|---|---|---|
| `firebase_options.dart` | API keys → placeholders | Keys are public by design; placeholders broke Firebase init entirely |
| `note.dart` | `toJson()` validation + sanitization, **threw ArgumentError** | Flutter `Text` renders no HTML/JS → no XSS; throws could crash saving existing "Untitled" notes (UI explicitly supports empty titles) |
| `timetable_service.dart` | added `HttpsEnforcement` class + HTTPS checks | every URL already `https://` (verified: zero `http://` matches in `lib/`) |
| `flex_session_service.dart` | duplicate `HttpsEnforcement` | same — also a duplicate-class hazard |
| 5 new service files | validation/rate-limit/session/file/error services | imported nowhere → zero security effect; `session_manager.dart` had 2 analyzer errors |

### Completed earlier — iOS support (Option B): DONE
`flutter analyze` clean, `flutter test` 179 passed. Delivered: Firebase/Google auth iOS config, platform guards in `main.dart`/`reminder_notification_service.dart`/`home_widget_service.dart`, full WidgetKit extension `ios/NotesWidget` (kind `NotesWidget`, App Group `group.com.example.notesm`, deployment target 16.0), launcher icons + native splash regenerated.

### Environment facts (verified)
- Bundle ID `com.example.notesm`; project deployment target 13.0 (widget 16.0).
- Google server client id `789024692194-n7ljctd8gv7vgs67kdbr2tjvr37uq1kl.apps.googleusercontent.com`.
- iOS client id `789024692194-pcn0jul1ore87ss81glq4edpq0hqq145.apps.googleusercontent.com`; REVERSED_CLIENT_ID `com.googleusercontent.apps.789024692194-pcn0jul1ore87ss81glq4edpq0hqq145`.
- iOS builds require macOS/Xcode or cloud CI (this machine is Windows).

### Current state

All security pass cleanup tasks completed:

1. ✅ **Completed:** Reverted 4 modified files from the failed session (all were safe changes).
2. ✅ **Completed:** Deleted 5 unwired service files (validation_service, rate_limiter, session_manager, file_validator, error_handler).
3. ✅ **Completed:** Fixed the one real security issue: `android/app/src/main/AndroidManifest.xml` now has `android:allowBackup="false"` (protects Flex portal session cookie, notes, and saved accounts in SharedPreferences from backup extraction; does NOT affect Firebase sync or app functionality).

**Verification:** `flutter analyze` = No issues found; `flutter test` = 179/179 passing.

**Next:** User builds & installs the APK (agent must never run `flutter build` or `adb install`).

### Task backlog
- [x] Phase 1: Security hardening (stop) – all safe changes undone, 1 real fix applied
- [ ] Phase 2: Ask user before high-risk fixes (rate limiting, session manager, file validation, security rules wiring)
- [ ] Phase 3: Ask user before advanced security (CSRF, audit logging, monitoring)
