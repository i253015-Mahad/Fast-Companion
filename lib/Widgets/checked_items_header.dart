// lib/widgets/checked_items_header.dart   (NEW FILE)
import 'package:flutter/material.dart';

/// The "⌃ 3 checked items" row that sits between unchecked and checked tasks.
///
/// Arrow UP   = checked items are HIDDEN.
/// Arrow DOWN = checked items are SHOWN.
class CheckedItemsHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onTap;

  const CheckedItemsHeader({
    super.key,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(color: Colors.white24, height: 1, thickness: 1),
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  color: Colors.white70,
                ),
                const SizedBox(width: 8),
                Text(
                  '$count checked item${count == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
