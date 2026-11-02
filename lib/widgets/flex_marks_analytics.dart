import 'package:flutter/material.dart';

import '../models/flex_marks_model.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/color_extensions.dart';

class FlexMarksAnalyticsWidget extends StatelessWidget {
  final FlexCourseMarks marks;

  const FlexMarksAnalyticsWidget({
    super.key,
    required this.marks,
  });

  @override
  Widget build(BuildContext context) {
    final percentage = marks.percentage;
    final classAvgPercentage = marks.classAvgPercentage;
    final diff = marks.diffFromAvg;
    final attained = marks.attainedAbsolutes;
    final total = marks.totalWeightage;
    // Still earnable this semester: the 100-point course scale minus
    // whatever has already been graded — upcoming and unannounced work
    // included, marks already lost on graded work not.
    final remaining = marks.remainingWeightage;

    final String percentageClass;
    if (percentage >= 85) {
      percentageClass = 'fast-companion-percentage-excellent';
    } else if (percentage >= 70) {
      percentageClass = 'fast-companion-percentage-good';
    } else {
      percentageClass = 'fast-companion-percentage-poor';
    }

    final gradeBadge = marks.letterGrade;
    final gradeColor = gradeBadge == null
        ? AppColors.textSecondary
        : gradeBadge == 'F'
            ? AppColors.error
            : gradeBadge.startsWith('D')
                ? AppColors.error
                : gradeBadge.startsWith('C')
                    ? AppColors.cardOrange
                    : AppColors.cardGreen;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.cardOrange.withValues(alpha: 0.1), Colors.white],
        ),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  marks.courseName,
                  style: AppTextStyles.title.copyWith(color: AppColors.textPrimary),
                ),
              ),
              // Grade badge as a rounded circle with letter
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: gradeColor.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: gradeColor, width: 2),
                ),
                child: Center(
                  child: Text(
                    gradeBadge ?? '–',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: gradeColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildMetricCard(
                  'Your Score',
                  '${percentage.toStringAsFixed(1)}%',
                  percentageClass,
                  Icons.person,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Class Avg',
                  '${classAvgPercentage.toStringAsFixed(1)}%',
                  '',
                  Icons.people,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildMetricCard(
                  'Diff from Avg',
                  diff >= 0
                      ? '+${diff.toStringAsFixed(1)}'
                      : diff.toStringAsFixed(1),
                  diff >= 0 ? 'fast-companion-diff-positive' : 'fast-companion-diff-negative',
                  Icons.trending_up,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Attained Absolutes:',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      '${attained.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} (${percentage.toStringAsFixed(1)}%)',
                      style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Remaining Absolutes:',
                      style: AppTextStyles.bodySmall.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                    Text(
                      remaining.toStringAsFixed(1),
                      style: AppTextStyles.body.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildProgressBar('Your Progress', percentage / 100, AppColors.cardOrange),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildProgressBar(
                  'Class Gap',
                  ((percentage - classAvgPercentage).clamp(-100, 100) + 100) / 200,
                  diff >= 0 ? AppColors.success : AppColors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard(
    String label,
    String value,
    String valueClass,
    IconData icon,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: AppColors.cardOrange, size: 20),
          const SizedBox(height: 8),
          Text(
            value,
            style: AppTextStyles.title.copyWith(
              fontSize: 20,
              color: valueClass.isEmpty ? AppColors.textPrimary : valueClass.color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildProgressBar(String label, double value, Color color) {
    final displayValue = (value * 100).toInt();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              '$displayValue%',
              style: AppTextStyles.bodySmall.copyWith(
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(
          value: value,
          backgroundColor: Colors.grey.shade200,
          valueColor: AlwaysStoppedAnimation<Color>(color),
          minHeight: 6,
          borderRadius: BorderRadius.circular(3),
        ),
      ],
    );
  }
}