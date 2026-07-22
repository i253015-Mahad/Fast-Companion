// lib/screens/todo_screen.dart
import 'package:flutter/material.dart';
import 'dart:ui';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';

class TodoScreen extends StatefulWidget {
  final Note note;

  /// The specific account context this list belongs to.
  final String uid;

  const TodoScreen({super.key, required this.note, required this.uid});

  @override
  State<TodoScreen> createState() => _TodoScreenState();
}

class _TodoScreenState extends State<TodoScreen> {
  late TextEditingController _titleController;
  late List<TodoItem> _todoItems;
  final List<FocusNode> _focusNodes = [];
  final _db = DatabaseService();

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _todoItems = List.from(widget.note.todoList ?? []);
    if (_todoItems.isEmpty) _todoItems.add(TodoItem(text: ""));
    for (var _ in _todoItems) _focusNodes.add(FocusNode());
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (var f in _focusNodes) f.dispose();
    super.dispose();
  }

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
    await _db.updateNote(widget.note.id, {
      'title': _titleController.text.trim(),
      'body': previewBody,
      'todoList': firebaseTodoList,
    }, customUid: widget.uid);
  }

  void _createNewItemRow(int currentIndex) {
    setState(() {
      final newItem = TodoItem(text: "");
      _todoItems.insert(currentIndex + 1, newItem);
      final node = FocusNode();
      _focusNodes.insert(currentIndex + 1, node);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (node.canRequestFocus) node.requestFocus();
      });
    });
  }

  void _removeItemRow(int index) {
    if (_todoItems.length == 1) {
      setState(() => _todoItems[0] = TodoItem(text: ""));
      return;
    }
    setState(() {
      _todoItems.removeAt(index);
      _focusNodes[index].dispose();
      _focusNodes.removeAt(index);
      if (index > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_focusNodes[index - 1].canRequestFocus)
            _focusNodes[index - 1].requestFocus();
        });
      }
    });
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
                  itemCount: _todoItems.length,
                  itemBuilder: (context, index) {
                    final item = _todoItems[index];
                    return TodoRowItem(
                      key: ValueKey(item),
                      item: item,
                      focusNode: _focusNodes[index],
                      onNextRowRequested: () => _createNewItemRow(index),
                      onDeleteRequested: () => _removeItemRow(index),
                    );
                  },
                  onReorderItem: (oldIndex, newIndex) {
                    setState(() {
                      final item = _todoItems.removeAt(oldIndex);
                      _todoItems.insert(newIndex, item);
                      final node = _focusNodes.removeAt(oldIndex);
                      _focusNodes.insert(newIndex, node);
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

  const TodoRowItem({
    super.key,
    required this.item,
    required this.focusNode,
    required this.onNextRowRequested,
    required this.onDeleteRequested,
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
        onChanged: (value) =>
            setState(() => widget.item.isDone = value ?? false),
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
