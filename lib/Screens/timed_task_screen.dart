// lib/screens/timed_task_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';

class TimedTaskScreen extends StatefulWidget {
  final Note note;

  /// Target context for cloud file storage syncing routines.
  final String uid;

  const TimedTaskScreen({super.key, required this.note, required this.uid});

  @override
  State<TimedTaskScreen> createState() => _TimedTaskScreenState();
}

class _TimedTaskScreenState extends State<TimedTaskScreen> {
  late TextEditingController _titleController;
  late List<TodoItem> _timedItems;
  final List<FocusNode> _focusNodes = [];
  Timer? _tickerTimer;
  final _db = DatabaseService();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _timedItems = List.from(widget.note.todoList ?? []);
    if (_timedItems.isEmpty) {
      _timedItems.add(
        TodoItem(
          text: "",
          dueDateTime: DateTime.now().add(const Duration(days: 2)),
        ),
      );
    }
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
      if (_timedItems.isEmpty) {
        _timedItems.add(
          TodoItem(
            text: "",
            dueDateTime: DateTime.now().add(const Duration(days: 2)),
          ),
        );
      }
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
              .map((i) => "⏳ ${i.text} (${_parseCountdown(i)})")
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
    await _db.updateNote(widget.note.id, {
      'title': _titleController.text.trim(),
      'body': previewBody,
      'todoList': firebaseTodoList,
    }, customUid: widget.uid, awaitRemote: true);
  }

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

  Future<void> _createNewItemRow(int currentIndex) async {
    final DateTime? chosenDateTime = await _pickDateTime(context);
    if (chosenDateTime == null) return;
    setState(() {
      _timedItems.insert(
        currentIndex + 1,
        TodoItem(text: "", dueDateTime: chosenDateTime),
      );
      _focusNodes.insert(currentIndex + 1, FocusNode());
      _sortTasksByUrgency();
    });
  }

  void _removeItemRow(int index) {
    if (_timedItems.length == 1) {
      setState(
        () => _timedItems[0] = TodoItem(
          text: "",
          dueDateTime: DateTime.now().add(const Duration(hours: 1)),
        ),
      );
      return;
    }
    setState(() {
      _timedItems.removeAt(index);
      _focusNodes[index].dispose();
      _focusNodes.removeAt(index);
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
              Expanded(
                child: ListView.builder(
                  itemCount: _timedItems.length,
                  itemBuilder: (context, index) {
                    final item = _timedItems[index];
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
                              final diff = item.dueDateTime!.difference(
                                DateTime.now(),
                              );
                              item.remainingDuration = diff.isNegative
                                  ? Duration.zero
                                  : diff;
                            } else {
                              item.remainingDuration = null;
                            }
                            _sortTasksByUrgency();
                          });
                        },
                      ),
                      title: TextFormField(
                        focusNode: _focusNodes.length > index
                            ? _focusNodes[index]
                            : null,
                        initialValue: item.text,
                        style: TextStyle(
                          color: item.isDone ? Colors.white38 : Colors.white,
                          decoration: item.isDone
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: "Add timed task...",
                          hintStyle: TextStyle(color: Colors.white24),
                          border: InputBorder.none,
                        ),
                        onChanged: (text) => item.text = text,
                        onFieldSubmitted: (_) => _createNewItemRow(index),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _parseCountdown(item),
                            style: TextStyle(
                              color: item.isDone
                                  ? Colors.white24
                                  : (_parseCountdown(item).contains('s left') ||
                                            _parseCountdown(
                                              item,
                                            ).contains('m left')
                                        ? AppColors.cardOrange
                                        : Colors.white60),
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white38,
                              size: 18,
                            ),
                            onPressed: () => _removeItemRow(index),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton(
          backgroundColor: AppColors.cardOrange,
          child: const Icon(Icons.add, color: Colors.white),
          onPressed: () => _createNewItemRow(_timedItems.length - 1),
        ),
      ),
    );
  }
}
