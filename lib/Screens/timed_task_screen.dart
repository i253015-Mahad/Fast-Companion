// lib/screens/timed_task_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';
import '../services/note_preview.dart';
import '../widgets/checked_items_header.dart'; // NEW

/// How the label field of a timed-task row is decorated.
///
/// Public so `test/note_row_alignment_test.dart` can measure the exact
/// decoration this screen uses instead of a copy that could drift from it.
const kTimedTaskLabelDecoration = InputDecoration(
  hintText: "Add timed task...",
  hintStyle: TextStyle(color: Colors.white24),
  border: InputBorder.none,
  // The hint exists only until something is typed, but the decorator sizes
  // the whole field to it anyway. On a phone "Add timed task..." is wider
  // than the column left between the checkbox and the countdown, so it
  // wrapped to two lines, made the field two lines tall, and left a
  // one-line label sitting at the top of that box: visibly higher than the
  // checkbox and the countdown beside it. Capping the hint at one line keeps
  // the field the height of its own text, which is what lines the label up
  // again. The to-do screen needs no such cap, because its hint is short and
  // its column (nothing but an X beside it) is wide.
  hintMaxLines: 1,
);

class TimedTaskScreen extends StatefulWidget {
  final Note note;

  /// Target context for cloud file storage syncing routines.
  final String uid;

  const TimedTaskScreen({super.key, required this.note, required this.uid});

  @override
  State<TimedTaskScreen> createState() => _TimedTaskScreenState();
}

class _TimedTaskScreenState extends State<TimedTaskScreen> {
  // NEW: set to true if you'd rather checked items start out visible.
  static const bool _checkedExpandedByDefault = false;

  late TextEditingController _titleController;
  late List<TodoItem> _timedItems;
  final List<FocusNode> _focusNodes = [];
  Timer? _tickerTimer;
  final _db = DatabaseService();

  // NEW: arrow UP = checked items hidden, arrow DOWN = shown.
  bool _checkedExpanded = _checkedExpandedByDefault;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _timedItems = List.from(widget.note.todoList);
    // No auto-created rows: an empty note stays empty until the user adds a
    // task themselves (see the add button / "next" flow).
    for (var _ in _timedItems) {
      _focusNodes.add(FocusNode());
    }
    _sortTasksByUrgency();
    _tickerTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _sortTasksByUrgency());
    });
    // The Note object this screen was built with can be stale — e.g. the
    // widget checked off a task after this note was last loaded into
    // whatever list handed it to us. _save() overwrites the whole
    // todoList on close, so without this, that stale snapshot would
    // silently wipe out any newer widget-driven changes.
    _loadFreshData();
  }

  Future<void> _loadFreshData() async {
    final notes = await LocalStorageService.loadNotes(widget.uid);
    Note? fresh;
    for (final n in notes) {
      if (n.id == widget.note.id) {
        fresh = n;
        break;
      }
    }
    if (fresh == null || !mounted) return;

    setState(() {
      _titleController.text = fresh!.title;
      _timedItems = List.from(fresh.todoList);
      for (final f in _focusNodes) {
        f.dispose();
      }
      _focusNodes
        ..clear()
        ..addAll(List.generate(_timedItems.length, (_) => FocusNode()));
      _sortTasksByUrgency();
    });
  }

  @override
  void dispose() {
    _tickerTimer?.cancel();
    _titleController.dispose();
    for (var f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    final savedList = _timedItems
        .where((i) => i.text.trim().isNotEmpty)
        .toList();
    final previewBody = savedList.isEmpty
        ? "No active timed tasks"
        : savedList
              .map(
                (i) =>
                    "⏳ ${i.text} (${i.dueDateTime == null ? "no date" : _parseCountdown(i)})",
              )
              .join('\n');
    final firebaseTodoList = savedList
        .map(
          (i) => {
            'text': i.text,
            'isDone': i.isDone,
            'dueDateTime': i.dueDateTime?.toIso8601String(),
            'remainingDurationMs': i.remainingDuration?.inMilliseconds,
          },
        )
        .toList();
    await _db.updateNote(
      widget.note.id,
      {
        'title': _titleController.text.trim(),
        'body': previewBody,
        'todoList': firebaseTodoList,
      },
      customUid: widget.uid,
      awaitRemote: true,
    );
  }

  // Unchecked tasks first (most urgent first), then checked tasks. That
  // ordering is what the "checked items" header below relies on.
  //
  // `now` is taken once for the whole pass, and it has to be. Taking it
  // per task — as this used to — means two tasks sharing a due date are
  // measured against two different clocks, microseconds apart, so each
  // one comes out slightly less urgent than the other depending on which
  // side of the comparison it landed. Every pass then disagrees with the
  // one before it about which came first, and with a ticker calling this
  // once a second the two rows swap places forever.
  //
  // Tasks that still compare equal are held in the order they were
  // already in, because List.sort is not stable — without that, two
  // undated tasks would trade places on every pass too.
  void _sortTasksByUrgency() {
    final now = DateTime.now();
    final rows = [
      for (var i = 0; i < _timedItems.length; i++)
        (
          item: _timedItems[i],
          node: i < _focusNodes.length ? _focusNodes[i] : null,
          position: i,
        ),
    ];

    rows.sort(
      (a, b) => compareTimedTasks(a.item, b.item, now, a.position, b.position),
    );

    _timedItems = [for (final row in rows) row.item];
    // The focus nodes ride along with the task they belong to. They are
    // looked up by index while building, so reordering the tasks and
    // leaving the nodes behind would hand "next" on the keyboard to a
    // different row than the one being typed in.
    _focusNodes
      ..clear()
      ..addAll([
        for (final row in rows)
          if (row.node != null) row.node!,
      ]);
  }

  /// What the countdown reads. See [remainingFor], which sorts against a
  /// clock it was handed rather than reading its own.
  Duration _getRemainingDuration(TodoItem item) =>
      remainingFor(item, DateTime.now());

  /// Inserts a new EMPTY row (no date yet) after [item] — or at the end when
  /// [item] is null — and focuses its label field. No dialogs: the due date
  /// is asked for later, when the label is submitted (see [_onLabelSubmitted]).
  void _createNewItemRow({TodoItem? after}) {
    final node = FocusNode();
    setState(() {
      final insertAt = after == null
          ? _timedItems.length
          : _timedItems.indexOf(after) + 1;
      _timedItems.insert(insertAt, TodoItem(text: "", dueDateTime: null));
      _focusNodes.insert(insertAt, node);
    });
    // Focus after the new row actually exists on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) node.requestFocus();
    });
  }

  /// Label field submitted ("next" on the keyboard or a new row):
  ///  - labelled, no date yet -> ask for the date, attach it, done;
  ///  - already has a date   -> start the next task (new empty row);
  ///  - still empty          -> nothing.
  Future<void> _onLabelSubmitted(TodoItem item) async {
    if (item.text.trim().isEmpty) return;
    if (item.dueDateTime != null) {
      _createNewItemRow(after: item);
      return;
    }
    final picked = await _pickDateTime(context);
    if (!mounted) return;
    if (picked == null) {
      // Cancelled the date picker: go back to asking for the label. If the
      // label is empty too (user went back again), discard the row.
      if (item.text.trim().isEmpty) {
        _removeItemRow(item);
      } else {
        final i = _timedItems.indexOf(item);
        if (i >= 0 && _focusNodes.length > i) _focusNodes[i].requestFocus();
      }
      return;
    }
    setState(() => item.dueDateTime = picked);
  }

  /// Tap on a row's countdown / "tap to set date" text: change its due date.
  /// Uses the item itself, not an index — the 1s ticker re-sorts the list
  /// under us, which would make a stale index point at the wrong task.
  Future<void> _editDueDate(TodoItem item) async {
    final picked = await _pickDateTime(context);
    if (picked == null || !mounted) return;
    setState(() => item.dueDateTime = picked);
  }

  /// Same as before, except removing the LAST row leaves the list empty —
  /// rows only exist when the user adds one.
  void _removeItemRow(TodoItem item) {
    final index = _timedItems.indexOf(item);
    if (index < 0) return;
    setState(() {
      _timedItems.removeAt(index);
      if (_focusNodes.length > index) {
        _focusNodes[index].dispose();
        _focusNodes.removeAt(index);
      }
    });
  }

  Future<DateTime?> _pickDateTime(BuildContext context) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (date == null) return null;
    // The date dialog has just been dismissed, and the time picker below
    // needs a context that outlived it.
    if (!context.mounted) return null;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (time == null) return null;
    return DateTime(date.year, date.month, date.day, time.hour, time.minute);
  }

  String _parseCountdown(TodoItem item) {
    if (item.dueDateTime == null && item.remainingDuration == null) {
      return "tap to set date";
    }
    // Shared with the home screen widget, which counts the same task down
    // alongside it.
    return formatCountdown(_getRemainingDuration(item));
  }

  /// One task row. This is the same ListTile that used to live inline in the
  /// ListView; [index] is the item's position in _timedItems.
  Widget _buildTimedRow(TodoItem item, int index) {
    return ListTile(
      key: ValueKey(item),
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: item.isDone,
        activeColor: AppColors.cardGreen,
        onChanged: (value) {
          setState(() {
            item.isDone = value ?? false;
            if (item.isDone && item.dueDateTime != null) {
              final diff = item.dueDateTime!.difference(DateTime.now());
              item.remainingDuration = diff.isNegative ? Duration.zero : diff;
            } else {
              item.remainingDuration = null;
            }
            // Re-sorting moves the task above/below the "checked items" line.
            _sortTasksByUrgency();
          });
        },
      ),
      title: TextFormField(
        focusNode: _focusNodes.length > index ? _focusNodes[index] : null,
        initialValue: item.text,
        style: TextStyle(
          color: item.isDone ? Colors.white38 : Colors.white,
          decoration: item.isDone ? TextDecoration.lineThrough : null,
        ),
        textInputAction: TextInputAction.next,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        decoration: kTimedTaskLabelDecoration,
        onChanged: (text) => item.text = text,
        onFieldSubmitted: (_) => _onLabelSubmitted(item),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Countdown is tappable: opens the date picker to set/change the
          // due date. Undated rows show "tap to set date".
          InkWell(
            onTap: () => _editDueDate(item),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Text(
                _parseCountdown(item),
                style: TextStyle(
                  color: item.isDone
                      ? Colors.white24
                      : (_parseCountdown(item) == "tap to set date"
                            ? Colors.white38
                            : (_parseCountdown(item).contains('s left') ||
                                      _parseCountdown(item).contains('m left')
                                  ? AppColors.cardOrange
                                  : Colors.white60)),
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontStyle: _parseCountdown(item) == "tap to set date"
                      ? FontStyle.italic
                      : FontStyle.normal,
                ),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 18),
            onPressed: () => _removeItemRow(item),
          ),
        ],
      ),
    );
  }

  /// NEW: unchecked tasks, then the "⌃ x checked items" header, then (only
  /// when open) the checked tasks. _timedItems is always sorted with unchecked
  /// tasks first, so the first [uncheckedCount] entries are the unchecked ones.
  Widget _buildTimedList() {
    // Nothing added yet: a friendly hint instead of a blank void. Rows only
    // exist when the user adds one (no auto-created default row).
    if (_timedItems.isEmpty) {
      return const Center(
        child: Text(
          "Tap + to add a task",
          style: TextStyle(color: Colors.white24, fontSize: 15),
        ),
      );
    }
    final checkedCount = _timedItems.where((i) => i.isDone).length;
    final uncheckedCount = _timedItems.length - checkedCount;
    final hasHeader = checkedCount > 0;
    final shownChecked = (hasHeader && _checkedExpanded) ? checkedCount : 0;
    final itemCount = uncheckedCount + (hasHeader ? 1 : 0) + shownChecked;

    return ListView.builder(
      itemCount: itemCount,
      itemBuilder: (context, displayIndex) {
        if (hasHeader && displayIndex == uncheckedCount) {
          return CheckedItemsHeader(
            count: checkedCount,
            expanded: _checkedExpanded,
            onTap: () => setState(() => _checkedExpanded = !_checkedExpanded),
          );
        }
        // Rows after the header are shifted by one, so subtract it.
        final index = displayIndex < uncheckedCount
            ? displayIndex
            : displayIndex - 1;
        return _buildTimedRow(_timedItems[index], index);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        await _save();
        if (context.mounted) Navigator.pop(context, true);
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text(
            "Timed Tasks Track",
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.check, size: 28),
              onPressed: () async {
                await _save();
                if (context.mounted) Navigator.pop(context, true);
              },
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              TextField(
                controller: _titleController,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
                decoration: const InputDecoration(
                  hintText: "Note Heading",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(child: _buildTimedList()), // CHANGED
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: AppColors.cardOrange,
          child: const Icon(Icons.add, color: Colors.white),
          onPressed: () => _createNewItemRow(),
        ),
      ),
    );
  }
}

/// Where [a] goes relative to [b]: unchecked before checked, most urgent
/// first, and tasks that are equal in both hold the order they were
/// already in via [positionOfA]/[positionOfB].
///
/// [now] is a parameter rather than something this reads off the wall
/// clock, and that is the whole point. The screen re-sorts once a second
/// while the countdown runs, and a comparator that took its own reading
/// would measure [a] and [b] against two different clocks — microseconds
/// apart, but far enough that two tasks sharing a due date each come out
/// the more urgent of the two depending on which side of the comparison
/// they landed on. Every pass would then disagree with the one before
/// it, and the two rows would trade places forever.
///
/// The position tie-break matters for the same reason at a smaller
/// scale: `List.sort` is not stable, so without it two tasks that
/// genuinely tie (both undated, both overdue) would be free to shuffle
/// on every pass.
@visibleForTesting
int compareTimedTasks(
  TodoItem a,
  TodoItem b,
  DateTime now,
  int positionOfA,
  int positionOfB,
) {
  if (a.isDone != b.isDone) return a.isDone ? 1 : -1;
  final cmp = remainingFor(a, now).compareTo(remainingFor(b, now));
  if (cmp != 0) return cmp;
  return positionOfA.compareTo(positionOfB);
}

/// What is left on [item] as of [now]: [Duration.zero] once it has run
/// out, and a large stand-in for a task with no date at all so those
/// sort last. A finished task keeps the frozen figure it was finished
/// with rather than counting against the clock it no longer obeys.
@visibleForTesting
Duration remainingFor(TodoItem item, DateTime now) {
  if (item.isDone && item.remainingDuration != null) {
    return item.remainingDuration!;
  }
  if (item.dueDateTime == null) return const Duration(days: 99999);
  final diff = item.dueDateTime!.difference(now);
  return diff.isNegative ? Duration.zero : diff;
}
