// lib/models/tutorial_content.dart

/// One step of a tutorial: the text to show, and — optionally — the id
/// of the widget to spotlight while showing it.
///
/// [targetId] ids are resolved at runtime through
/// `TutorialTargets` (a [GlobalKey] cannot live in a `const` list).
/// A null target — or a target that is not currently mounted (the FAB
/// while signed out, a hidden Back button) — falls back to the classic
/// centered card.
class TutorialStep {
  const TutorialStep(this.text, {this.targetId, this.waitForTrigger = false});

  /// The description shown on the card.
  final String text;

  /// Registry id of the widget to point at, or null to center the card.
  final String? targetId;

  /// A wait step does not offer Next and lets taps through the
  /// spotlight hole so the user can perform the action being taught
  /// (e.g. tap the Faculty shifter or expand a teacher card). The host
  /// advances the tutorial when that trigger happens.
  final bool waitForTrigger;
}

/// The step definitions for each tutorial, one list per feature.
///
/// Titles live in `tutorial_titles.dart` and button labels in
/// `tutorial_actions.dart` — keep those there so each constant has a
/// single home.
class TutorialContent {
  /// Notes tab welcome: what the tab is for and how to get around.
  /// Shown once the user is signed in; the note-actions walkthrough
  /// ([noteActionsTutorialSteps]) covers star/hold/delete separately,
  /// when the first note is created.
  static const List<TutorialStep> notesTutorialSteps = [
    TutorialStep(
      'Tap the + button to create a note — text, '
      'to-do list, counter, or a timed task with reminders.',
      targetId: 'notesFab',
    ),
    TutorialStep(
      'Use the search bar to filter notes instantly by title or content.',
      targetId: 'notesSearch',
    ),
    TutorialStep(
      'Tap your avatar to switch Google accounts — '
      'swipe it up or down to flip between them quickly.',
      targetId: 'notesAvatar',
    ),
  ];

  /// First-note walkthrough: the three actions available on every note
  /// card. Triggered when the note list goes from empty to non-empty.
  static const List<TutorialStep> noteActionsTutorialSteps = [
    TutorialStep(
      'Star a note to pin it to the top of your list.',
      targetId: 'notesFirstCard',
    ),
    TutorialStep(
      'Hold (long-press) a note to show it on your home-screen widget.',
      targetId: 'notesFirstCard',
    ),
    TutorialStep(
      'Tap the trash icon to delete a note.',
      targetId: 'notesFirstCard',
    ),
  ];

  /// Timetable tab: browsing the university timetable.
  static const List<TutorialStep> timetableTutorialSteps = [
    TutorialStep(
      'Pick your school first — Computing, Engineering, or Management.',
      targetId: 'timetableSchoolPills',
    ),
    TutorialStep(
      'Set your department, batch, and section to narrow the timetable '
      'down to your classes.',
      targetId: 'timetableFilters',
    ),
    TutorialStep(
      'Tap a day of the week to jump to that day\'s schedule.',
      targetId: 'timetableDayTabs',
    ),
    TutorialStep(
      'Pull down to refresh. The last fetch is cached, so your '
      'timetable still works offline.',
      targetId: 'timetableList',
    ),
    TutorialStep(
      'The rings on each class of your section show your live attendance once you\'re '
      'signed in to Flex.',
      targetId: 'timetableList',
    ),
  ];

  /// Rooms tab: free rooms by block and day, continuing into the
  /// Faculty directory. The host (WayfindingScreen) advances the two
  /// wait steps when the user switches to Teachers and expands a card.
  static const List<TutorialStep> roomsTutorialSteps = [
    TutorialStep(
      'Choose a day and a block to see which rooms are free at FAST ISB.',
      targetId: 'roomsFilters',
    ),
    TutorialStep(
      'The room block shows its occupancy details for the selected time.',
      targetId: 'roomsList',
    ),
    TutorialStep(
      'Data refreshes automatically when you switch days — everything '
      'stays current without a manual reload.',
      targetId: 'roomsList',
    ),
    TutorialStep(
      'Tap the Teachers tab to continue to the faculty '
      'directory.',
      targetId: 'roomsShifter',
      waitForTrigger: true,
    ),
    TutorialStep(
      'The pill on each card is their office: ',
      targetId: 'teachersOffice',
    ),
    TutorialStep(
      'Tap the teacher to expand their card.',
      targetId: 'teachersCard',
      waitForTrigger: true,
    ),
    TutorialStep(
      'Email opens a ready-to-send message to them directly, and Copy '
      'copies their address so you can paste it anywhere.',
      targetId: 'teachersActions',
    ),
  ];

  /// Flex tutorial on the Marks page: walk every toolbar button, then
  /// a centered recap of the injected Semester Overview card at the
  /// bottom of the page.
  static const List<TutorialStep> flexMarksTutorialSteps = [
    TutorialStep(
      'Back returns to the previous page of the portal, like a browser '
      'back button.',
      targetId: 'flexBack',
    ),
    TutorialStep(
      'Open in browser launches flex in your phone\'s real '
      'browser, where you can use it normally.',
      targetId: 'flexOpen',
    ),
    TutorialStep(
      'Refresh reloads the page — use it if your marks look stale.',
      targetId: 'flexRefresh',
    ),
    TutorialStep(
      'The chart button opens Marks Analytics: your semester GPA and a '
      'per-course breakdown against the class.',
      targetId: 'flexAnalytics',
    ),
    TutorialStep(
      'Sign out leaves this portal account on this device.',
      targetId: 'flexSignOut',
    ),
    TutorialStep(
      'Scroll to the bottom of the Marks page: the purple Semester '
      'Overview card shows your overall score and the class average for '
      'this semester.',
    ),
  ];
}
