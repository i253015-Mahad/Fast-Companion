// lib/services/note_history.dart
//
// Undo/redo for one note while it is being edited.
//
// Snapshots, not inverse operations. `Note` already serializes itself, so a
// state is a string and undo is a decode — where inverting "typed a word,
// deleted a row, dragged two others, ticked a third" by hand is the part that
// quietly loses an item. A snapshot cannot drift from the thing it came from.
//
// The history lives only as long as the screen that opened it. It is not
// written anywhere: a student who closes a note expects the note to be as they
// left it, not to reopen it holding an undo stack from last Tuesday.

import 'dart:async';

import 'package:flutter/foundation.dart';

/// The undo and redo stacks for a single note being edited.
///
/// A [ChangeNotifier] so the buttons can show whether they are usable without
/// dragging the whole screen through a rebuild on every keystroke.
class NoteHistory extends ChangeNotifier {
  NoteHistory({
    required String initial,
    this.limit = 80,
    this.burst = const Duration(milliseconds: 700),
  }) : _current = initial;

  /// How many steps back a student can walk. Bounded because the stack holds
  /// serialized notes and a list kept without limit is a leak that only shows
  /// up on the longest editing session.
  final int limit;

  /// How long after the last keystroke a run of typing counts as one step.
  ///
  /// Without this, undo on a word would walk back letter by letter — the
  /// behaviour that makes people stop using undo altogether.
  final Duration burst;

  /// The state the screen is on now.
  ///
  /// Kept here rather than read back off the screen because typing calls
  /// [record] faster than a run of keystrokes is worth stacking: within an
  /// open burst only this advances, so undo lands on the start of the run and
  /// redo comes back to its end, not to a letter halfway through.
  String _current;

  final List<String> _undo = [];
  final List<String> _redo = [];

  bool _burstOpen = false;
  Timer? _timer;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Call AFTER a change, with the state it produced.
  ///
  /// [discrete] marks a change that is a step in its own right — a row added,
  /// a row deleted, a row dragged, a box ticked. It closes any run of typing
  /// first, so deleting a row right after typing its name is two undo steps
  /// and not one lump.
  void record(String after, {bool discrete = false}) {
    if (discrete) _closeBurst();

    if (_burstOpen) {
      // Mid-run: the stack already holds the state this run started from, so
      // pushing again would bury the real undo point under a dozen near
      // copies. The current state still moves, so redo can come back here.
      if (after != _current) _current = after;
      _restartBurst();
      notifyListeners();
      return;
    }

    if (after == _current) return;

    _undo.add(_current);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    _current = after;

    _burstOpen = true;
    _restartBurst();
    notifyListeners();
  }

  /// Drops every step and starts again from [state].
  ///
  /// For when a screen swaps in fresh contents underneath the history. The
  /// counter and todo screens re-read their note from disk as they open; a
  /// history still holding the pre-refresh state would send the first undo
  /// back to content the student never saw on this screen.
  void rebase(String state) {
    _undo.clear();
    _redo.clear();
    _current = state;
    _closeBurst();
    notifyListeners();
  }

  /// Goes back one step, returning the state to restore — or `null`.
  String? undo() {
    if (_undo.isEmpty) return null;
    _closeBurst();
    _redo.add(_current);
    _current = _undo.removeLast();
    notifyListeners();
    return _current;
  }

  /// Returns one step forward, or `null` when nothing was undone.
  String? redo() {
    if (_redo.isEmpty) return null;
    _closeBurst();
    _undo.add(_current);
    _current = _redo.removeLast();
    notifyListeners();
    return _current;
  }

  void _restartBurst() {
    _timer?.cancel();
    _timer = Timer(burst, _closeBurst);
  }

  void _closeBurst() {
    _timer?.cancel();
    _timer = null;
    _burstOpen = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
