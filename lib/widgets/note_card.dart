// lib/widgets/note_card.dart
import 'package:flutter/material.dart';
import '../theme/app_text_styles.dart';
import '../models/note.dart';
import '../theme/app_colors.dart';

class NoteCard extends StatelessWidget {
  final Color color;
  final Note note;
  final VoidCallback onDelete;
  final VoidCallback onTap;
  final VoidCallback onStarToggled;

  /// NEW (Fix 7a): long-press a card to pin it to a home screen widget.
  final VoidCallback? onPin;

  const NoteCard({
    super.key,
    required this.color,
    required this.note,
    required this.onDelete,
    required this.onTap,
    required this.onStarToggled,
    this.onPin,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onPin, // NEW (Fix 7a)
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ─── NEW UNIFORM HEADER ROW FOR STAR & DELETE ───
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // TOP LEFT: Star Priority Button
                IconButton(
                  icon: Icon(
                    note.isStarred
                        ? Icons.star_rounded
                        : Icons.star_outline_rounded,
                    // Golden amber when selected, subtle dark tint when unselected to match your layout style
                    color: note.isStarred ? Colors.amber : Colors.black45,
                  ),
                  onPressed: onStarToggled, // Passed down from constructor
                ),

                // TOP RIGHT: Your Existing Delete Button
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.black54),
                  onPressed: onDelete,
                ),
              ],
            ),

            // Note Title
            Text(
              note.title.isEmpty ? "Untitled" : note.title,
              style: AppTextStyles.cardTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),

            // Previews Block
            Expanded(child: _buildCardContentBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildCardContentBody() {
    if (note.type == 'todo' || note.type == 'timed') {
      return _buildTodoPreview();
    } else if (note.type == 'counter') {
      return _buildCounterPreview(); // Handle Counter rendering block
    }
    return Text(
      note.body,
      style: AppTextStyles.cardBody,
      overflow: TextOverflow.ellipsis,
      maxLines: 3,
    );
  }

  Widget _buildTodoPreview() {
    final list = note.todoList;
    if (list.isEmpty) {
      return const Text(
        "Empty list",
        style: TextStyle(color: Colors.black38, fontSize: 14),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: list.take(3).map((item) {
        return Row(
          children: [
            Icon(
              item.isDone ? Icons.check_box : Icons.check_box_outline_blank,
              size: 16,
              color: Colors.black54,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                item.text,
                style: TextStyle(
                  fontSize: 13,
                  color: item.isDone
                      ? Colors.black38
                      : AppTextStyles.cardBody.color,
                  decoration: item.isDone ? TextDecoration.lineThrough : null,
                ),
                // A card's height comes from the grid's aspect ratio, so the
                // preview has a fixed budget and cannot grow to meet its
                // content. Letting these wrap meant a long task — or three
                // tasks that each broke onto a second line — ran the preview
                // past the bottom of the card and drew the overflow stripes
                // over it. A preview shows one line and trails off.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: true,
              ),
            ),
          ],
        );
      }).toList(),
    );
  }

  // New layout summary view helper parsing metric increments inside cards
  Widget _buildCounterPreview() {
    final list = note.counterList;
    if (list.isEmpty) {
      return const Text(
        "No counters",
        style: TextStyle(color: Colors.black38, fontSize: 14),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: list.take(3).map((item) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  item.label,
                  style: AppTextStyles.cardBody,
                  // Same fixed budget as the checklist preview above.
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: true,
                ),
              ),
              Text(
                '${item.count}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: AppColors.textDark,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}
