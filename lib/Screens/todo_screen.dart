// lib/screens/todo_screen.dart
import 'package:flutter/material.dart';
import 'dart:ui';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';
import '../widgets/checked_items_header.dart'; // NEW

class TodoScreen extends StatefulWidget {
  final Note note;

  /// The specific account context this list belongs to.
  final String uid;

  const TodoScreen({super.key, required this.note, required this.uid});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  // NEW: set to true if you'd rather checked items start out visible.
  static const bool _checkedExpandedByDefault = false;

  late TextEditingController _titleController;
  late List<TodoItem> _todoItems;
  final List<FocusNode> _focusNodes = [];
  final _db = DatabaseService();

  // NEW: arrow UP = checked items hidden, arrow DOWN = shown.
  bool _checkedExpanded = _checkedExpandedByDefault;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _todoItems = List.from(widget.note.todoList ?? []);
    if (_todoItems.isEmpty) _todoItems.add(TodoItem(text: ""));
    for (var _ in _todoItems) _focusNodes.add(FocusNode());
    for (final item in _todoItems) _assignRank(item); // NEW
    _regroup(); // NEW
    // The Note object this screen was built with can be stale — e.g. the
    // widget checked off an item after this note was last loaded into
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
      _todoItems = List.from(fresh.todoList);
      if (_todoItems.isEmpty) _todoItems.add(TodoItem(text: ""));
      // Fresh instances, so the old ranks are meaningless now.
      _rank.clear(); // NEW
      _nextRank = 0; // NEW
      for (final item in _todoItems) _assignRank(item); // NEW
      for (final f in _focusNodes) {
        f.dispose();
      }
      _focusNodes
        ..clear()
        ..addAll(List.generate(_todoItems.length, (_) => FocusNode()));
      _regroup(); // NEW
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (var f in _focusNodes) f.dispose();
    super.dispose();
  }

  /// NEW: keeps the list as [unchecked..., checked...], with both groups in
  /// rank order. The ranks are what make ticking reversible: an item that
  /// leaves the unchecked group still knows where it belongs, so unticking
  /// drops it back there instead of at the bottom.
  /// Focus nodes move with their items so they stay lined up.
  /// Call inside setState.
  void _regroup() {
    final nodesOf = <TodoItem, FocusNode>{
      for (var i = 0; i < _todoItems.length; i++) _todoItems[i]: _focusNodes[i],
    };
    int byRank(TodoItem a, TodoItem b) => _rankOf(a).compareTo(_rankOf(b));
    final unchecked = [for (final i in _todoItems) if (!i.isDone) i]
      ..sort(byRank);
    final checked = [for (final i in _todoItems) if (i.isDone) i]
      ..sort(byRank);
    _todoItems = [...unchecked, ...checked];
    _focusNodes
      ..clear()
      ..addAll([for (final item in _todoItems) nodesOf[item]!]);
  }

  /// NEW: the order each item belongs in, so ticking one cannot lose its
  /// place. Assigned once when the item appears and afterwards only handed
  /// from one item to another, never regenerated — that way a rank can never
  /// collide with one some other item is holding.
  /// Keyed by identity: TodoItem has no == override, and the same instances
  /// live for as long as the screen does.
  final Map<TodoItem, int> _rank = {};
  int _nextRank = 0;

  int _rankOf(TodoItem item) => _rank[item] ?? 0;

  /// NEW: gives [item] a rank past every one handed out so far.
  void _assignRank(TodoItem item) => _rank[item] = _nextRank++;

  /// NEW: the user dragged the unchecked tasks into a new order, so their
  /// ranks have to follow. The ranks they already hold are handed back
  /// sorted and dealt out along the new order: every rank stays unique, and
  /// the checked items keep theirs untouched.
  void _ranksToMatchOrder() {
    final ranks = [
      for (final item in _todoItems)
        if (!item.isDone) _rankOf(item),
    ]..sort();
    var next = 0;
    for (final item in _todoItems) {
      if (item.isDone) continue;
      _rank[item] = ranks[next++];
    }
  }

  /// NEW: a checkbox was ticked or unticked, so move the item between groups.
  /// The item keeps its rank throughout, so _regroup puts it straight back
  /// where it was: unticking no longer drops it at the bottom.
  void _onItemDoneChanged(TodoItem item) => setState(_regroup);

  Future<void> _save() async {
    final savedList = _todoItems
        .where((i) => i.text.trim().isNotEmpty)
        .toList();
    final previewBody = savedList.isEmpty
        ? "Empty list"
        : savedList.map((i) => "${i.isDone ? '☑' : '☐'} ${i.text}").join('\n');
    final firebaseTodoList = savedList
        .map((i) => {'text': i.text, 'isDone': i.isDone})
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

  void _createNewItemRow(int currentIndex) {
    setState(() {
      final newItem = TodoItem(text: "");
      _todoItems.insert(currentIndex + 1, newItem);
      _assignRank(newItem); // NEW: any unique rank; the call below fixes the order
      final node = FocusNode();
      _focusNodes.insert(currentIndex + 1, node);
      _ranksToMatchOrder(); // NEW: the row belongs right where it was inserted
      _regroup(); // NEW: a new item is unchecked, so it belongs above the line
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (node.canRequestFocus) node.requestFocus();
      });
    });
  }

  void _removeItemRow(int index) {
    if (_todoItems.length == 1) {
      setState(() {
        _rank.remove(_todoItems[0]); // NEW
        _todoItems[0] = TodoItem(text: "");
        _assignRank(_todoItems[0]); // NEW
      });
      return;
    }
    final wasDone = _todoItems[index].isDone; // NEW
    setState(() {
      _rank.remove(_todoItems[index]); // NEW: nowhere to come back to
      _todoItems.removeAt(index);
      _focusNodes[index].dispose();
      _focusNodes.removeAt(index);
      // CHANGED: only jump to the previous row when the removed item was an
      // unchecked one, so deleting a checked item doesn't pop up the keyboard.
      if (!wasDone && index > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_focusNodes[index - 1].canRequestFocus)
            _focusNodes[index - 1].requestFocus();
        });
      }
    });
  }

  /// NEW: the "⌃ x checked items" header plus (when open) the checked rows.
  /// Shown as the footer of the reorderable list, so it scrolls with it.
  Widget? _buildCheckedSection() {
    final checkedCount = _todoItems.where((i) => i.isDone).length;
    if (checkedCount == 0) return null;
    final firstChecked = _todoItems.length - checkedCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CheckedItemsHeader(
          count: checkedCount,
          expanded: _checkedExpanded,
          onTap: () => setState(() => _checkedExpanded = !_checkedExpanded),
        ),
        if (_checkedExpanded)
          for (var i = firstChecked; i < _todoItems.length; i++)
            TodoRowItem(
              key: ValueKey(_todoItems[i]),
              item: _todoItems[i],
              focusNode: _focusNodes[i],
              onNextRowRequested: () => _createNewItemRow(i),
              onDeleteRequested: () => _removeItemRow(i),
              onDoneChanged: _onItemDoneChanged,
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // NEW: only unchecked items go in the reorderable part.
    final uncheckedCount = _todoItems.where((i) => !i.isDone).length;

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
            "Edit To-Do List",
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
                  hintText: "List Title",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: uncheckedCount, // CHANGED (was _todoItems.length)
                  itemBuilder: (context, index) {
                    final item = _todoItems[index];
                    return TodoRowItem(
                      key: ValueKey(item),
                      item: item,
                      focusNode: _focusNodes[index],
                      onNextRowRequested: () => _createNewItemRow(index),
                      onDeleteRequested: () => _removeItemRow(index),
                      onDoneChanged: _onItemDoneChanged, // NEW
                    );
                  },
                  footer: _buildCheckedSection(), // NEW
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
                      final item = _todoItems.removeAt(oldIndex);
                      _todoItems.insert(newIndex, item);
                      final node = _focusNodes.removeAt(oldIndex);
                      _focusNodes.insert(newIndex, node);
                      _ranksToMatchOrder(); // NEW: the drag is the new order
                    });
                  },
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

class TodoRowItem extends StatefulWidget {
  final TodoItem item;
  final FocusNode focusNode;
  final VoidCallback onNextRowRequested;
  final VoidCallback onDeleteRequested;

  /// NEW: called after the checkbox is ticked or unticked, with the item that
  /// changed, so the screen can move it above/below the "checked items" line.
  final ValueChanged<TodoItem> onDoneChanged;

  const TodoRowItem({
    super.key,
    required this.item,
    required this.focusNode,
    required this.onNextRowRequested,
    required this.onDeleteRequested,
    required this.onDoneChanged,
  });

  @override
  State<TodoRowItem> createState() => _TodoRowItemState();
}

class _TodoRowItemState extends State<TodoRowItem> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isLineFocused = widget.focusNode.hasFocus;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        value: widget.item.isDone,
        activeColor: AppColors.cardGreen,
        onChanged: (value) {
          setState(() => widget.item.isDone = value ?? false);
          widget.onDoneChanged(widget.item); // NEW
        },
      ),
      title: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: widget.item.isDone ? 0.38 : (isLineFocused ? 1.0 : 0.75),
        child: TextField(
          controller: _controller,
          focusNode: widget.focusNode,
          style: TextStyle(
            color: Colors.white,
            decoration: widget.item.isDone ? TextDecoration.lineThrough : null,
          ),
          textInputAction: TextInputAction.next,
          maxLines: null,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: "List item",
            hintStyle: TextStyle(color: Colors.white24),
            border: InputBorder.none,
          ),
          onChanged: (text) => widget.item.text = text,
          onSubmitted: (_) => widget.onNextRowRequested(),
        ),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.close, color: Colors.white38),
        onPressed: widget.onDeleteRequested,
      ),
    );
  }
}
