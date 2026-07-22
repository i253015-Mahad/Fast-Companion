// lib/screens/edit_note_screen.dart

import 'package:flutter/material.dart';

import '../models/note.dart';
import '../theme/app_colors.dart';
import '../services/database_service.dart';

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

  @override
  void initState() {
    super.initState();

    _titleController = TextEditingController(text: widget.note.title);

    _bodyController = TextEditingController(text: widget.note.body);
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

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
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
