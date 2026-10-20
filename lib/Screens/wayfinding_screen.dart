// lib/Screens/wayfinding_screen.dart

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
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

  /// The block last asked for by a teacher's office card, handed down to
  /// the rooms half. Stays set so returning to Rooms later lands on the
  /// corridor you were last pointed at.
  String _block = '';

  /// Flips to the rooms half and selects [block].
  ///
  /// Filtering a list that is already loaded is a setState and never a
  /// fetch, so this is instant.
  void _showRoomsIn(String block) {
    setState(() {
      _block = block;
      _showTeachers = false;
    });
  }

  @override
  Widget build(BuildContext context) {
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
                    child: RoomsScreen(
                      active: widget.active && !_showTeachers,
                      requestedBlock: _block.isEmpty ? null : _block,
                    ),
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
                      onShowBlock: _showRoomsIn,
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
