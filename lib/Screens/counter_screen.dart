// lib/screens/counter_screen.dart
import 'package:flutter/material.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';

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

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note.title);
    _counterItems = List.from(widget.note.counterList ?? []);
    if (_counterItems.isEmpty) _counterItems.add(CounterItem(label: ""));
    for (var _ in _counterItems) _focusNodes.add(FocusNode());
    // The Note object this screen was built with can be stale — e.g. the
    // widget adjusted a count after this note was last loaded into
    // whatever list handed it to us. _save() overwrites the whole
    // counterList on close, so without this, that stale snapshot would
    // silently wipe out any newer widget-driven changes. This re-fetch is
    // near-instant (local disk), so it resolves before the user has
    // usually even started reading the screen.
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
      _counterItems = List.from(fresh.counterList);
      if (_counterItems.isEmpty) _counterItems.add(CounterItem(label: ""));
      for (final f in _focusNodes) {
        f.dispose();
      }
      _focusNodes
        ..clear()
        ..addAll(List.generate(_counterItems.length, (_) => FocusNode()));
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    for (var f in _focusNodes) f.dispose();
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
    await _db.updateNote(widget.note.id, {
      'title': _titleController.text.trim(),
      'body': previewBody,
      'counterList': firebaseCounterList,
    }, customUid: widget.uid, awaitRemote: true);
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
  }

  void _removeCounterRow(int index) {
    if (_counterItems.length == 1) {
      setState(() => _counterItems[0] = CounterItem(label: "", count: 0));
      return;
    }
    setState(() {
      _counterItems.removeAt(index);
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
            "Edit Counter List",
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
                  hintText: "Counter Title",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: _counterItems.length,
                  itemBuilder: (context, index) {
                    return CounterRowItem(
                      key: ValueKey(_counterItems[index]),
                      item: _counterItems[index],
                      rowNumber: index + 1,
                      focusNode: _focusNodes[index],
                      onNextRowRequested: () => _createNewCounterRow(index),
                      onDeleteRequested: () => _removeCounterRow(index),
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

  const CounterRowItem({
    super.key,
    required this.item,
    required this.rowNumber,
    required this.focusNode,
    required this.onNextRowRequested,
    required this.onDeleteRequested,
  });

  @override
  State<CounterRowItem> createState() => _CounterRowItemState();
}

class _CounterRowItemState extends State<CounterRowItem> {
  late AppColors colors;
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.item.label);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
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
              controller: _controller,
              focusNode: widget.focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 18),
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                hintText: "Add counter feature...",
                hintStyle: TextStyle(color: Colors.white24),
                border: InputBorder.none,
              ),
              onChanged: (text) => widget.item.label = text,
              onSubmitted: (_) => widget.onNextRowRequested(),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(
                  Icons.remove_circle_outline,
                  color: Colors.white60,
                ),
                onPressed: () => setState(() => widget.item.count--),
              ),
              SizedBox(
                width: 40,
                child: Center(
                  child: Text(
                    '${widget.item.count}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.add_circle_outline,
                  color: AppColors.cardGreen,
                ),
                onPressed: () => setState(() => widget.item.count++),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white38, size: 20),
            onPressed: widget.onDeleteRequested,
          ),
        ],
      ),
    );
  }
}
