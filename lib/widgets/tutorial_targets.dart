// lib/widgets/tutorial_targets.dart
import 'package:flutter/widgets.dart';

/// Named [GlobalKey]s for the widgets the tutorial can spotlight.
///
/// Each key is attached (via `key:`) to exactly one widget in the app;
/// tutorial steps reference them by the string id used as the map key
/// here. Resolution happens at runtime in `TutorialOverlay`, because a
/// [GlobalKey] cannot live inside a `const` content list.
///
/// Keys are harmless when no tutorial is showing — attaching one does not
/// change widget behavior.
class TutorialTargets {
  TutorialTargets._();

  static final Map<String, GlobalKey> _targets = <String, GlobalKey>{
    // Notes tab (home_screen.dart)
    'notesFab': GlobalKey(debugLabel: 'tutorial.notesFab'),
    'notesSearch': GlobalKey(debugLabel: 'tutorial.notesSearch'),
    'notesAvatar': GlobalKey(debugLabel: 'tutorial.notesAvatar'),
    'notesGrid': GlobalKey(debugLabel: 'tutorial.notesGrid'),
    // First card in the grid that renders (only one grid branch ever
    // carries this key, so it stays unique).
    'notesFirstCard': GlobalKey(debugLabel: 'tutorial.notesFirstCard'),

    // Timetable tab (timetable_screen.dart)
    'timetableSchoolPills': GlobalKey(debugLabel: 'tutorial.timetableSchoolPills'),
    'timetableFilters': GlobalKey(debugLabel: 'tutorial.timetableFilters'),
    'timetableDayTabs': GlobalKey(debugLabel: 'tutorial.timetableDayTabs'),
    'timetableList': GlobalKey(debugLabel: 'tutorial.timetableList'),

    // Rooms → Teachers (wayfinding_screen.dart / rooms_screen.dart)
    'roomsFilters': GlobalKey(debugLabel: 'tutorial.roomsFilters'),
    'roomsShifter': GlobalKey(debugLabel: 'tutorial.roomsShifter'),
    'roomsList': GlobalKey(debugLabel: 'tutorial.roomsList'),
    'teachersOffice': GlobalKey(debugLabel: 'tutorial.teachersOffice'),
    'teachersCard': GlobalKey(debugLabel: 'tutorial.teachersCard'),
    // Keyed inside the `if (open)` branch — only one card can be
    // expanded at a time, so this id never has two mounted widgets.
    'teachersActions': GlobalKey(debugLabel: 'tutorial.teachersActions'),

    // Flex toolbar (flex_screen.dart)
    'flexBack': GlobalKey(debugLabel: 'tutorial.flexBack'),
    'flexOpen': GlobalKey(debugLabel: 'tutorial.flexOpen'),
    'flexRefresh': GlobalKey(debugLabel: 'tutorial.flexRefresh'),
    'flexAnalytics': GlobalKey(debugLabel: 'tutorial.flexAnalytics'),
    'flexSignOut': GlobalKey(debugLabel: 'tutorial.flexSignOut'),
  };

  /// The key registered for [id], or null when nothing claims that id.
  static GlobalKey? resolve(String id) => _targets[id];

  /// The registered key when it is currently attached to a mounted
  /// widget, otherwise null — a step whose target is absent (FAB while
  /// logged out, hidden Back button) falls back to a centered card.
  static GlobalKey? resolveMounted(String id) {
    final key = _targets[id];
    return (key != null && key.currentContext != null) ? key : null;
  }
}
