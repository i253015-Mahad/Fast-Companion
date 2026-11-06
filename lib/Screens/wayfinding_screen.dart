// lib/Screens/wayfinding_screen.dart

import 'package:flutter/material.dart';

import '../models/tutorial_actions.dart';
import '../models/tutorial_content.dart';
import '../models/tutorial_titles.dart';
import '../services/tutorial_service.dart';
import '../theme/app_colors.dart';
import '../widgets/tutorial_overlay.dart';
import '../widgets/tutorial_targets.dart';
import 'rooms_screen.dart';
import 'teachers_screen.dart';

/// The one tab that answers "where is X?" two ways.
///
/// Rooms and teachers are the same question from opposite ends: a
/// student asking where a free lab is and a student asking where Dr X
/// sits are both trying to get to a place. This screen holds both and a
/// control that slides between them, rather than spending a second
/// slot of the bottom bar on a distinction nobody has to make before
/// they know which answer they want.
///
/// The two halves stay **mounted permanently** and cross-fade, rather
/// than being swapped in and out. Swapping would unmount the outgoing
/// screen and throw away its state — the selected day, the selected
/// block, the list already downloaded — so flipping to teachers and
/// back would land you on Monday in block A whatever you had chosen. A
/// permanent [Stack] keeps both, which is the same bargain the bottom
/// bar's [IndexedStack] already makes.
class WayfindingScreen extends StatefulWidget {
  const WayfindingScreen({super.key, required this.active});

  /// Whether this tab is the one on screen, and so whether either half
  /// should be doing anything at all.
  final bool active;

  @override
  State<WayfindingScreen> createState() => _WayfindingScreenState();
}

class _WayfindingScreenState extends State<WayfindingScreen> {
  static const _fade = Duration(milliseconds: 200);

  /// Which half is in front.
  bool _showTeachers = false;

  /// Rooms tutorial state. Owned here (not in HomeScreen) so it can
  /// keep running across the Rooms → Teachers switch: the controller
  /// holds the step index, the two wait steps are advanced by the
  /// shifter tap and the card-expand tap below.
  bool _tutorialLoaded = false;
  bool _tutorialPending = false;
  final TutorialController _tutorialController = TutorialController();

  @override
  void initState() {
    super.initState();
    _loadTutorialStatus();
  }

  Future<void> _loadTutorialStatus() async {
    final pending = !await TutorialService.instance.hasSeenRoomsTutorial();
    if (!mounted) return;
    setState(() {
      _tutorialLoaded = true;
      _tutorialPending = pending;
    });
  }

  /// Advances past the wait step whose [targetId] matches, but only if
  /// the tutorial is actually sitting on it — a stray trigger after
  /// Skip/Done must not jump a finished walkthrough.
  void _advancePastWait(String targetId) {
    if (!_tutorialPending) return;
    final steps = TutorialContent.roomsTutorialSteps;
    final waitIndex = steps
        .indexWhere((s) => s.waitForTrigger && s.targetId == targetId);
    if (waitIndex < 0) return;
    if (_tutorialController.index == waitIndex) {
      _tutorialController.goTo(waitIndex + 1);
    }
  }

  Future<void> _completeTutorial() async {
    await TutorialService.instance.markRoomsTutorialAsSeen();
    if (mounted) setState(() => _tutorialPending = false);
  }

  @override
  Widget build(BuildContext context) {
    // Only while this tab is on screen; unmounting on tab switch is
    // safe because the step index lives in the controller.
    final tutorial = widget.active && _tutorialLoaded && _tutorialPending
        ? TutorialOverlay(
            title: TutorialTitles.rooms,
            steps: TutorialContent.roomsTutorialSteps,
            skipText: TutorialActions.skip,
            controller: _tutorialController,
            onSkip: _completeTutorial,
            onDone: _completeTutorial,
          )
        : null;

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildShells(),
        if (tutorial != null)
          Positioned.fill(
            child: SafeArea(child: tutorial),
          ),
      ],
    );
  }

  Widget _buildShells() {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _shifter(),
          const SizedBox(height: 12),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Both stay in the tree. IgnorePointer rather than
                // Offstage or a conditional so the hidden half keeps its
                // scroll position, its expanded card and its filters.
                IgnorePointer(
                  ignoring: _showTeachers,
                  child: AnimatedOpacity(
                    opacity: _showTeachers ? 0 : 1,
                    duration: _fade,
                    curve: Curves.easeOut,
                    child: RoomsScreen(active: widget.active && !_showTeachers),
                  ),
                ),
                IgnorePointer(
                  ignoring: !_showTeachers,
                  child: AnimatedOpacity(
                    opacity: _showTeachers ? 1 : 0,
                    duration: _fade,
                    curve: Curves.easeOut,
                    child: TeachersScreen(
                      active: widget.active && _showTeachers,
                      onCardExpanded: () => _advancePastWait('teachersCard'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Two halves of one pill, with a marker that slides between them.
  ///
  /// Built from a [Stack] rather than an [AnimatedPositioned] or a
  /// segmented button, because the app's language is rounded containers
  /// on a dark bar and Material's own segmented control paints a
  /// surface-tint layer that fights it — the same reason the pills
  /// everywhere else are not [ChoiceChip]s.
  Widget _shifter() {
    return Container(
      key: TutorialTargets.resolve('roomsShifter'),
      height: 46,
      decoration: BoxDecoration(
        color: AppColors.navBar,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white24),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: AnimatedAlign(
              alignment: _showTeachers
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              duration: _fade,
              curve: Curves.easeOut,
              child: FractionallySizedBox(
                widthFactor: 0.5,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _showTeachers
                        ? AppColors.cardOrange
                        : AppColors.cardGreen,
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
          Row(
            children: [
              _segment('Rooms', selected: !_showTeachers, onTap: () {
                if (!_showTeachers) return;
                setState(() => _showTeachers = false);
              }),
              _segment('Teachers', selected: _showTeachers, onTap: () {
                if (_showTeachers) return;
                setState(() => _showTeachers = true);
                // Hands the tutorial over from the shifter step to the
                // faculty-directory steps.
                _advancePastWait('roomsShifter');
              }),
            ],
          ),
        ],
      ),
    );
  }

  Widget _segment(
    String label, {
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.textDark : Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
