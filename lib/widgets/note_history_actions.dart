// lib/widgets/note_history_actions.dart

import 'package:flutter/material.dart';

import '../services/note_history.dart';

/// The undo and redo buttons a note's app bar shows.
///
/// Lives behind a [ListenableBuilder] on the history rather than a rebuild of
/// the whole screen, because the history is what decides whether these are
/// usable and typing changes it on every keystroke — dragging a full list of
/// rows through a rebuild per letter to re-light two icons is not a trade
/// worth making.
///
/// [onUndo] and [onRedo] are callbacks rather than calls into the history
/// itself: the history can say *which* state to go back to, but only the
/// screen knows how to put that state back into its fields and rows.
class NoteHistoryActions extends StatelessWidget {
  const NoteHistoryActions({
    super.key,
    required this.history,
    required this.onUndo,
    required this.onRedo,
  });

  final NoteHistory history;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: history,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _HistoryButton(
              icon: Icons.undo,
              tooltip: 'Undo',
              enabled: history.canUndo,
              onPressed: onUndo,
            ),
            _HistoryButton(
              icon: Icons.redo,
              tooltip: 'Redo',
              enabled: history.canRedo,
              onPressed: onRedo,
            ),
          ],
        );
      },
    );
  }
}

/// One of the two buttons.
///
/// Not an [IconButton], which measures this: an IconButton in an app bar is
/// never narrower than 48dp, and setting constraints, padding or a style's
/// minimumSize does not move it (all measured at 48 on this Flutter version).
/// Two of them cost the title 96dp of the 280 it had, and on the 360dp-wide
/// phone this app is used on "Timed Tasks Track" and "Edit Counter List" both
/// need about 170 in Roboto — a few characters from clipping. A 32dp box with
/// an ink well over it costs 32 less, and is still a 48dp-tall strip to hit.
class _HistoryButton extends StatelessWidget {
  const _HistoryButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 48,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: enabled ? onPressed : null,
          child: Icon(
            icon,
            size: 22,
            // Mere grey would be invisible against this app's near-black bar;
            // the disabled state still has to read as a button that is off
            // rather than as nothing at all.
            color: enabled ? Colors.white : Colors.white30,
          ),
        ),
      ),
    );
  }
}
