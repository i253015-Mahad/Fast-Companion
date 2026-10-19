// lib/screens/counter_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/local_storage_service.dart';

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
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
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
              onChanged: (text) => widget.item.label = text,
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
                  onSubmitted: (_) => widget.focusNode.requestFocus(),
                ),
              ),
              GestureDetector(
                onTap: () {
                  setState(() {
                    widget.item.count++;
                    _countController.text = widget.item.count.toString();
                  });
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
        ],
      ),
    );
  }
}
