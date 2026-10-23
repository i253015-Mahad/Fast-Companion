// lib/screens/counter_screen.dart
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';
import '../services/note_history.dart';
import '../widgets/note_history_actions.dart';

/// How the label field of a counter row is decorated.
///
/// Public so `test/note_row_alignment_test.dart` can measure the exact
/// decoration this screen uses instead of a copy that could drift from it.
const kCounterLabelDecoration = InputDecoration(
  hintText: "Add counter feature...",
  hintStyle: TextStyle(color: Colors.white24),
  border: InputBorder.none,
  isDense: true,
  // Two things kept this label off the line drawn by the "1." number and by
  // the +/- controls, which the row centres vertically:
  //   * `top: 25` padded the field on one side only, dropping the label
  //     about 12px below them.
  //   * a hint allowed to wrap reserved its own height below a label shorter
  //     than itself, which lifts the label off the top instead, by about as
  //     much.
  // Zero padding plus a one-line hint makes the field exactly as tall as its
  // text, so number, label and controls all centre together for a one-line
  // label and for a wrapped one alike.
  contentPadding: EdgeInsets.zero,
  hintMaxLines: 1,
);

class CounterScreen extends StatefulWidget {
  final Note note;

  /// The active account identity scope.
  final String uid;

  const CounterScreen({super.key, required this.note, required this.uid});

  @override
  State<CounterScreen> createState() => _CounterScreenState();
}

class _CounterScreenState extends State<CounterScreen> {
  late TextEditingController _titleController;
  late List<CounterItem> _counterItems;
  final List<FocusNode> _focusNodes = [];
  final _db = DatabaseService();

  /// Undo and redo for this note, held only while the note is open.
  late NoteHistory _history;

  /// True while an undo or redo is putting a list back.
  ///
  /// [_apply] builds fresh [CounterItem]s, and their fields feed the rows'
  /// onChanged callbacks, which would otherwise record the step being undone
  /// as a new change — and the next undo would land on the step just undone
  /// rather than on the one before it.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _counterItems = List.from(widget.note.counterList);
    if (_counterItems.isEmpty) _counterItems.add(CounterItem(label: ""));
    for (var _ in _counterItems) {
      _focusNodes.add(FocusNode());
    }
    _history = NoteHistory(initial: _state());
    // The Note object this screen was built with can be stale — e.g. the
    // widget adjusted a count after this note was last loaded into
    // whatever list handed it to us. _save() overwrites the whole
    // counterList on close, so without this, that stale snapshot would
    // silently wipe out any newer widget-driven changes. This re-fetch is
    // near-instant (local disk), so it resolves before the user has
    // usually even started reading the screen.
    _loadFreshData();
  }

  /// Both the title and every counter as one string, which is what a step of
  /// the history is.
  String _state() => jsonEncode({
        'title': _titleController.text,
        'items': _counterItems
            .map((i) => {'label': i.label, 'count': i.count})
            .toList(),
      });

  /// Puts a step back. The items come out as brand new objects, so their
  /// ValueKeys change and the rows rebuild holding the restored text —
  /// no key of theirs needs to carry a version.
  void _apply(String state) {
    final map = jsonDecode(state) as Map<String, dynamic>;
    _titleController.text = map['title'] as String;
    final items = (map['items'] as List)
        .map((e) => CounterItem(
              label: e['label'] as String,
              count: e['count'] as int,
            ))
        .toList();
    _counterItems = items.isEmpty ? [CounterItem(label: "")] : items;
    for (final f in _focusNodes) {
      f.dispose();
    }
    _focusNodes
      ..clear()
      ..addAll(List.generate(_counterItems.length, (_) => FocusNode()));
  }

  /// Called from anywhere the list or the title changes. A run of keystrokes
  /// inside one [NoteHistory.burst] is one step, not one per letter;
  /// [discrete] marks a change that is a step in its own right.
  void _record({bool discrete = false}) {
    if (_restoring) return;
    _history.record(_state(), discrete: discrete);
  }

  void _restore(String? state) {
    if (state == null) return;
    setState(() {
      _restoring = true;
      try {
        _apply(state);
      } finally {
        _restoring = false;
      }
    });
  }

  void _undo() => _restore(_history.undo());

  void _redo() => _restore(_history.redo());

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
      _counterItems = List.from(fresh.counterList);
      if (_counterItems.isEmpty) _counterItems.add(CounterItem(label: ""));
      for (final f in _focusNodes) {
        f.dispose();
      }
      _focusNodes
        ..clear()
        ..addAll(List.generate(_counterItems.length, (_) => FocusNode()));
      // The screen now shows different contents, so the steps that led to
      // the old ones are no longer steps of anything the student can see.
      _history.rebase(_state());
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (var f in _focusNodes) {
      f.dispose();
    }
    _history.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final savedList = _counterItems
        .where((i) => i.label.trim().isNotEmpty)
        .toList();
    final previewBody = savedList.isEmpty
        ? "No counters added"
        : savedList.map((i) => "🔢 ${i.label}: ${i.count}").join('\n');
    final firebaseCounterList = savedList
        .map((i) => {'label': i.label, 'count': i.count})
        .toList();
    await _db.updateNote(
      widget.note.id,
      {
        'title': _titleController.text.trim(),
        'body': previewBody,
        'counterList': firebaseCounterList,
      },
      customUid: widget.uid,
      awaitRemote: true,
    );
  }

  void _createNewCounterRow(int currentIndex) {
    setState(() {
      final newItem = CounterItem(label: "", count: 0);
      _counterItems.insert(currentIndex + 1, newItem);
      final node = FocusNode();
      _focusNodes.insert(currentIndex + 1, node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (node.canRequestFocus) node.requestFocus();
      });
    });
    // Discrete: a row added is a step of its own, and must not fold into
    // whatever was typed just before it.
    _record(discrete: true);
  }

  void _removeCounterRow(int index) {
    if (_counterItems.length == 1) {
      setState(() => _counterItems[0] = CounterItem(label: "", count: 0));
      _record(discrete: true);
      return;
    }
    setState(() {
      _counterItems.removeAt(index);
      _focusNodes[index].dispose();
      _focusNodes.removeAt(index);
      if (index > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_focusNodes[index - 1].canRequestFocus) {
            _focusNodes[index - 1].requestFocus();
          }
        });
      }
    });
    _record(discrete: true);
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
            "Edit Counter List",
            style: TextStyle(color: Colors.white),
          ),
          actions: [
            NoteHistoryActions(
              history: _history,
              onUndo: _undo,
              onRedo: _redo,
            ),
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
                  hintText: "Counter Title",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onChanged: (_) => _record(),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: _counterItems.length,
                  itemBuilder: (context, index) {
                    return CounterRowItem(
                      key: ValueKey(_counterItems[index]),
                      item: _counterItems[index],
                      rowNumber: index + 1,
                      focusNode: _focusNodes[index],
                      // A row reports every edit it makes — its label, its
                      // count, and the two buttons — through this one
                      // callback, because none of them reach the screen any
                      // other way.
                      onChanged: () => _record(),
                      onNextRowRequested: () => _createNewCounterRow(index),
                      onDeleteRequested: () => _removeCounterRow(index),
                    );
                  },
                  // The drag is the new order. The item and the focus node it
                  // owns move together, so a row is still backed by its own
                  // node after it lands somewhere else — and the keyboard
                  // still follows the row it was typed into.
                  //
                  // onReorderItem rather than onReorder: the older callback
                  // passes newIndex unadjusted for a removal below it, and
                  // the caller has to subtract one by hand.
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
                      final item = _counterItems.removeAt(oldIndex);
                      _counterItems.insert(newIndex, item);
                      final node = _focusNodes.removeAt(oldIndex);
                      _focusNodes.insert(newIndex, node);
                    });
                    _record(discrete: true);
                  },
                  // A row lifted clear of the list has to read as lifted. A
                  // hair of scale and a shadow that grows with the drag, on a
                  // transparent Material so the row's own background still
                  // shows through. Same drawing the todo list uses, because
                  // two lists that lift differently look like two apps.
                  proxyDecorator: (child, index, animation) {
                    return AnimatedBuilder(
                      animation: animation,
                      builder: (context, child) {
                        final scale = lerpDouble(1.0, 1.04, animation.value)!;
                        return Transform.scale(
                          scale: scale,
                          child: Material(
                            elevation: lerpDouble(0, 6, animation.value)!,
                            color: Colors.transparent,
                            shadowColor: Colors.black.withValues(alpha: 0.4),
                            child: child,
                          ),
                        );
                      },
                      child: child,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CounterRowItem extends StatefulWidget {
  final CounterItem item;
  final int rowNumber;
  final FocusNode focusNode;
  final VoidCallback onNextRowRequested;
  final VoidCallback onDeleteRequested;

  /// Called after anything this row changes — its label, its count, or a tap
  /// on either button — so the screen can put the change on its undo stack.
  ///
  /// The row owns the fields and the buttons, and the screen owns the
  /// history, so the row has to be the one to say something happened.
  final VoidCallback onChanged;

  const CounterRowItem({
    super.key,
    required this.item,
    required this.rowNumber,
    required this.focusNode,
    required this.onNextRowRequested,
    required this.onDeleteRequested,
    required this.onChanged,
  });

  @override
  State<CounterRowItem> createState() => _CounterRowItemState();
}

class _CounterRowItemState extends State<CounterRowItem> {
  late AppColors colors;
  late TextEditingController _labelController;
  late TextEditingController _countController;

  @override
  void initState() {
    super.initState();
    _labelController = TextEditingController(text: widget.item.label);
    _countController = TextEditingController(
      text: widget.item.count.toString(),
    );
  }

  @override
  void dispose() {
    _labelController.dispose();
    _countController.dispose();
    super.dispose();
  }

  void _updateCount(String value) {
    final parsed = int.tryParse(value);
    if (parsed != null) {
      setState(() => widget.item.count = parsed);
      widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Four pixels each way left only 8px of empty space between two
      // counters, which is about what a wrapped label leaves between its own
      // lines. With a label on two or more lines the rows then ran together:
      // the space *inside* one label looked as big as the space *between*
      // two labels, so the eye had nothing to group them by. Ten each way
      // makes the gap between counters clearly larger than the gap between
      // lines of a single label, which is what tells one counter apart from
      // the next.
      padding: const EdgeInsets.symmetric(vertical: 10.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            "${widget.rowNumber}. ",
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Expanded(
            child: TextField(
              controller: _labelController,
              focusNode: widget.focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 18),

              textInputAction: TextInputAction.next,
              maxLines: null,
              minLines: 1,
              keyboardType: TextInputType.multiline,
              decoration: kCounterLabelDecoration,
              onChanged: (text) {
                widget.item.label = text;
                widget.onChanged();
              },
              // Keyboard "next" must not move focus on its own.
              //
              // The default reaction to TextInputAction.next is
              // FocusNode.nextFocus() (EditableText._finalizeEditing), which
              // flings focus at whatever focusable happens to come next — the
              // count field, the delete button, the row below — and only then
              // does onSubmitted create and focus the row the student asked
              // for. Two competing hops, with the keyboard dropping and
              // reconnecting between them.
              //
              // Supplying onEditingComplete replaces that whole default (it
              // branches on it before any of that runs) and still calls
              // onSubmitted afterwards, leaving one clean transfer to the new
              // row.
              //
              // An empty body is the intent, not an oversight: the only other
              // thing the default did was clearComposing(), and losing focus
              // does that for us anyway (see
              // EditableText._openOrCloseInputConnectionIfNeeded).
              //
              // test/keyboard_next_focus_test.dart fails without this line.
              onEditingComplete: () {},
              onSubmitted: (_) => widget.onNextRowRequested(),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () {
                  setState(() {
                    widget.item.count--;
                    _countController.text = widget.item.count.toString();
                  });
                  widget.onChanged();
                },
                child: const Padding(
                  padding: EdgeInsets.all(4.0),
                  child: Icon(
                    Icons.remove_circle_outline,
                    color: Colors.white60,
                    size: 20,
                  ),
                ),
              ),
              SizedBox(
                width: 50,
                height: 28,
                child: TextField(
                  controller: _countController,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 0),
                    border: InputBorder.none,
                  ),
                  onChanged: _updateCount,
                  // Same reason as the label field: without this, "done"
                  // unfocuses the count box and onSubmitted has to grab focus
                  // back a moment later, so the keyboard blinks out and
                  // returns instead of moving across to the label.
                  onEditingComplete: () {},
                  onSubmitted: (_) => widget.focusNode.requestFocus(),
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    widget.item.count++;
                    _countController.text = widget.item.count.toString();
                  });
                  widget.onChanged();
                },
                child: const Padding(
                  padding: EdgeInsets.all(4.0),
                  child: Icon(
                    Icons.add_circle_outline,
                    color: AppColors.cardGreen,
                    size: 20,
                  ),
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 20),
            onPressed: widget.onDeleteRequested,
          ),
          // A visible grip. These rows have always been reorderable, but only
          // by pressing and holding anywhere on them, which nothing on screen
          // says — so to a student the order just looked fixed.
          //
          // rowNumber is the one-based figure the row prints; the listener
          // wants the zero-based index into the list.
          ReorderableDragStartListener(
            index: widget.rowNumber - 1,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6.0),
              child: Icon(
                Icons.drag_indicator,
                color: Colors.white24,
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
