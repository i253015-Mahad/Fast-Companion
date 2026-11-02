import 'package:flutter/material.dart';
import 'app_colors.dart';

class AppTextStyles {
  static const title = TextStyle(
    fontSize: 34,
    fontWeight: FontWeight.bold,
    color: AppColors.textLight,
  );

  static const cardTitle = TextStyle(
    fontSize: 18,
    fontWeight: FontWeight.bold,
    color: AppColors.textDark,
  );

  static const cardBody = TextStyle(
    fontSize: 14,
    color: AppColors.textDark,
  );

  // Body copy for overlays and sheets — same size as [cardBody], kept as
  // its own name because the marks analytics calls for "body" semantics.
  static const body = TextStyle(
    fontSize: 14,
    color: AppColors.textDark,
  );

  static const bodySmall = TextStyle(
    fontSize: 12,
    color: AppColors.textDark,
  );
}