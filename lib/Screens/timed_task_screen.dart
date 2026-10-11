// lib/screens/timed_task_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';
import '../widgets/checked_items_header.dart'; // NEW

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
    _timedItems = List.from(widget.note.todoList ?? []);
    // No auto-created rows: an empty note stays empty until the user adds a
    // task themselves (see the add button / "next" flow).
    for (var _ in _timedItems) _focusNodes.add(FocusNode());
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
    for (var f in _focusNodes) f.dispose();
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
  void _sortTasksByUrgency() {
    _timedItems.sort((a, b) {
      if (a.isDone && !b.isDone) return 1;
      if (!a.isDone && b.isDone) return -1;
      return _getRemainingDuration(a).compareTo(_getRemainingDuration(b));
    });
  }

  Duration _getRemainingDuration(TodoItem item) {
    if (item.isDone && item.remainingDuration != null)
      return item.remainingDuration!;
    if (item.dueDateTime == null) return const Duration(days: 99999);
    final diff = item.dueDateTime!.difference(DateTime.now());
    return diff.isNegative ? Duration.zero : diff;
  }

  /// Inserts a new EMPTY row (no date yet) after [item] — or at the end when
  /// [item] is null — and focuses its label field. No dialogs: the due date
  /// is asked for later, when the label is submitted (see [_onLabelSubmitted]).
  void _createNewItemRow({TodoItem? after}) {
    final node = FocusNode();
    setState(() {
      final insertAt = after == null ? _timedItems.length : _timedItems.indexOf(after) + 1;
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
    final difference = _getRemainingDuration(item);
    if (difference == Duration.zero) return "Time expired";
    final days = difference.inDays;
    final hours = difference.inHours;
    final minutes = difference.inMinutes;
    if (days >= 1) return "${days}d ${hours % 24}h left";
    if (hours >= 1) return "${hours}h ${minutes % 60}m left";
    if (minutes >= 1) return "${minutes}m ${difference.inSeconds % 60}s left";
    return "${difference.inSeconds}s left";
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
        decoration: const InputDecoration(
          hintText: "Add timed task...",
          hintStyle: TextStyle(color: Colors.white24),
          border: InputBorder.none,
        ),
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
