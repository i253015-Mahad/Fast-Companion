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
    final classAvgAbsolutes = marks.classAvgAbsolutes;
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
                  'Abs Diff',
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
                _boxRow(
                  'Attained Absolutes:',
                  '${attained.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} (${percentage.toStringAsFixed(1)}%)',
                ),
                const SizedBox(height: 8),
                _boxRow(
                  'Class Avg Absolutes:',
                  '${classAvgAbsolutes.toStringAsFixed(1)} / ${total.toStringAsFixed(1)} (${classAvgPercentage.toStringAsFixed(1)}%)',
                ),
                const SizedBox(height: 8),
                _boxRow(
                  'Remaining Absolutes:',
                  remaining.toStringAsFixed(1),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildStandingBar(percentage, classAvgPercentage),
        ],
      ),
    );
  }

  /// One row of the grey box: label on the left, value on the right.
  ///
  /// Both children are flexible, and that is the whole defence. A Flex lays
  /// its non-flexible children out unbounded, so a plain Text (or an
  /// [FittedBox] around one) takes its natural width and pushes the row past
  /// the card — which is what these rows did. Flexible children, by
  /// contrast, are capped at their share of the row:
  ///
  ///  * the label yields first, by ellipsis, when space runs short;
  ///  * the value never gives up digits — [BoxFit.scaleDown] shrinks it
  ///    instead, so the numbers stay whole even when they are too wide.
  ///
  /// The slack is genuinely small: margin plus padding leaves these rows
  /// little room on a 360dp screen, and a test's square-glyph font is wider
  /// than the Roboto a phone uses.
  Widget _boxRow(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: AppTextStyles.bodySmall.copyWith(
              color: AppColors.textSecondary,
            ),
          ),
        ),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              value,
              style: AppTextStyles.body.copyWith(
                fontWeight: FontWeight.bold,
                color: AppColors.textPrimary,
              ),
            ),
          ),
        ),
      ],
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

  /// Single 0–100% bar: orange fill up to the student's score on graded
  /// work, a dark line at the class average, and a line at the student's
  /// own position drawn last so it stays visible when the two coincide.
  ///
  /// Both inputs are percentages (the same figures the two tiles above
  /// show), not absolutes.
  Widget _buildStandingBar(double yourScore, double classAvgScore) {
    const double barHeight = 20;
    const double trackHeight = 6;
    const double lineWidth = 3;

    final double yourFraction = (yourScore / 100).clamp(0.0, 1.0);
    final double classAvgFraction = (classAvgScore / 100).clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Standing (0–100%)',
          style: AppTextStyles.bodySmall.copyWith(
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            final double width = constraints.maxWidth;
            final double trackTop = (barHeight - trackHeight) / 2;

            double lineLeft(double fraction) =>
                (width * fraction - lineWidth / 2).clamp(0.0, width - lineWidth);

            return SizedBox(
              height: barHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Track
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width,
                    height: trackHeight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(trackHeight / 2),
                      ),
                    ),
                  ),
                  // Fill — the score on graded work so far
                  Positioned(
                    left: 0,
                    top: trackTop,
                    width: width * yourFraction,
                    height: trackHeight,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.cardOrange,
                        borderRadius: BorderRadius.circular(trackHeight / 2),
                      ),
                    ),
                  ),
                  // Class average marker
                  Positioned(
                    left: lineLeft(classAvgFraction),
                    top: 0,
                    width: lineWidth,
                    height: barHeight,
                    child: const ColoredBox(color: AppColors.textPrimary),
                  ),
                  // Student's own position, drawn last to win any overlap
                  Positioned(
                    left: lineLeft(yourFraction),
                    top: 0,
                    width: lineWidth,
                    height: barHeight,
                    child: const ColoredBox(color: AppColors.cardOrange),
                  ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        // Range of the bar: 0% at its left end, 100% at its right end.
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '0%',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              '100%',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(
              'You ',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              '${yourScore.toStringAsFixed(1)}%',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.cardOrange,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '  ·  Avg ',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textSecondary,
              ),
            ),
            Text(
              '${classAvgScore.toStringAsFixed(1)}%',
              style: AppTextStyles.bodySmall.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }
}