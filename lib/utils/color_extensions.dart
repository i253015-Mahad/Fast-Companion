import 'package:flutter/material.dart';

// Helper extension for evaluating CSS-style class names to colors
extension ColorClassExtension on String {
  Color get color {
    switch (this) {
      case 'fast-companion-percentage-excellent':
        return Colors.green.shade700;
      case 'fast-companion-percentage-good':
        return Colors.amber.shade700;
      case 'fast-companion-percentage-poor':
        return Colors.red.shade700;
      case 'fast-companion-diff-positive':
        return Colors.green.shade600;
      case 'fast-companion-diff-negative':
        return Colors.red.shade600;
      default:
        return Colors.grey.shade700;
    }
  }
}


