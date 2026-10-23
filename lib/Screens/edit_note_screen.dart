// lib/screens/edit_note_screen.dart

import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';
import '../services/note_history.dart';
import '../widgets/note_history_actions.dart';

class EditNoteScreen extends StatefulWidget {
  final Note note;

  /// The account whose notes are being edited.
  /// This is passed from HomeScreen so we NEVER depend on
  /// FirebaseAuth.currentUser after switching accounts.
  final String uid;

  const EditNoteScreen({super.key, required this.note, required this.uid});

  @override
  State<EditNoteScreen> createState() => _EditNoteScreenState();
}

class _EditNoteScreenState extends State<EditNoteScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;

  final DatabaseService _db = DatabaseService();

  bool _isSaving = false;

  /// Undo and redo for this note, held only while the note is open.
  late final NoteHistory _history;

  /// True while an undo or redo is putting text back into the fields.
  ///
  /// Setting a controller's text goes through the same path a keystroke does,
  /// so it would be recorded as a fresh change — undoing a step and then
  /// undoing again would land back on the step just undone rather than on the
  /// one before it.
  bool _restoring = false;

  @override
  void initState() {
    super.initState();

    _titleController = TextEditingController(text: widget.note.title);

    _bodyController = TextEditingController(text: widget.note.body);

    _history = NoteHistory(initial: _state());
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    _history.dispose();
    super.dispose();
  }

  /// Both fields as one string, which is what a step of the history is.
  String _state() =>
      jsonEncode({'title': _titleController.text, 'body': _bodyController.text});

  /// Puts a step back into the fields.
  void _apply(String state) {
    final map = jsonDecode(state) as Map<String, dynamic>;
    _titleController.text = map['title'] as String;
    _bodyController.text = map['body'] as String;
  }

  /// Called from every field's onChanged, which fires on a keystroke and on
  /// [NoteHistory] alike. The burst the history keeps open is what turns a
  /// word into one step rather than one per letter.
  void _record() {
    if (_restoring) return;
    _history.record(_state());
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

  Future<void> _save() async {
    if (_isSaving) return;

    _isSaving = true;

    try {
      await _db.updateNote(widget.note.id, {
        'title': _titleController.text.trim(),
        'body': _bodyController.text,
      }, customUid: widget.uid);
    } finally {
      _isSaving = false;
    }
  }

  Future<void> _finishEditing() async {
    await _save();

    if (!mounted) return;

    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;

        await _finishEditing();
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
          title: const Text("Edit Note", style: TextStyle(color: Colors.white)),
          actions: [
            NoteHistoryActions(
              history: _history,
              onUndo: _undo,
              onRedo: _redo,
            ),
            IconButton(
              icon: const Icon(Icons.check, size: 28),
              onPressed: _finishEditing,
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
                  hintText: "Title",
                  hintStyle: TextStyle(color: Colors.white38),
                  border: InputBorder.none,
                ),
                onChanged: (_) => _record(),
              ),
              const Divider(color: Colors.white24, thickness: 1),
              Expanded(
                child: TextField(
                  controller: _bodyController,
                  maxLines: null,
                  style: const TextStyle(color: Colors.white, fontSize: 18),
                  decoration: const InputDecoration(
                    hintText: "Start typing...",
                    hintStyle: TextStyle(color: Colors.white38),
                    border: InputBorder.none,
                  ),
                  onChanged: (_) => _record(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
