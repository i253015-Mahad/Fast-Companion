// lib/services/tutorial_service.dart
import 'package:shared_preferences/shared_preferences.dart';

/// Tracks which tutorials users have seen to avoid re-showing them.
class TutorialService {
  static final TutorialService _instance = TutorialService._internal();
  static TutorialService get instance => _instance;

  TutorialService._internal();

  // Pref keys for tutorial completion tracking
  static const String _notesTutorialKey = 'has_seen_notes_tutorial';
  static const String _noteActionsTutorialKey =
      'has_seen_note_actions_tutorial';
  static const String _timetableTutorialKey = 'has_seen_timetable_tutorial';
  static const String _roomsTutorialKey = 'has_seen_rooms_tutorial';
  static const String _flexMarksTutorialKey = 'has_seen_flex_marks_tutorial';

  /// Check if a specific tutorial has been completed
  Future<bool> hasSeenTutorial(String tutorialKey) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(tutorialKey) ?? false;
  }

  /// Mark a tutorial as seen
  Future<void> markTutorialAsSeen(String tutorialKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(tutorialKey, true);
  }

  /// Reset all tutorials (useful for testing)
  Future<void> resetAllTutorials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_notesTutorialKey);
    await prefs.remove(_noteActionsTutorialKey);
    await prefs.remove(_timetableTutorialKey);
    await prefs.remove(_roomsTutorialKey);
    await prefs.remove(_flexMarksTutorialKey);
  }

  // Convenience methods

  /// Notes tab welcome tutorial
  Future<bool> hasSeenNotesTutorial() => hasSeenTutorial(_notesTutorialKey);
  Future<void> markNotesTutorialAsSeen() => markTutorialAsSeen(_notesTutorialKey);

  /// First-note actions tutorial (star / hold / delete)
  Future<bool> hasSeenNoteActionsTutorial() =>
      hasSeenTutorial(_noteActionsTutorialKey);
  Future<void> markNoteActionsTutorialAsSeen() =>
      markTutorialAsSeen(_noteActionsTutorialKey);

  /// Timetable tab tutorial
  Future<bool> hasSeenTimetableTutorial() => hasSeenTutorial(_timetableTutorialKey);
  Future<void> markTimetableTutorialAsSeen() => markTutorialAsSeen(_timetableTutorialKey);

  /// Rooms tab tutorial
  Future<bool> hasSeenRoomsTutorial() => hasSeenTutorial(_roomsTutorialKey);
  Future<void> markRoomsTutorialAsSeen() => markTutorialAsSeen(_roomsTutorialKey);

  /// Flex marks page tutorial
  Future<bool> hasSeenFlexMarksTutorial() => hasSeenTutorial(_flexMarksTutorialKey);
  Future<void> markFlexMarksTutorialAsSeen() => markTutorialAsSeen(_flexMarksTutorialKey);
}