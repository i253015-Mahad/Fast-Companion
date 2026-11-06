// lib/models/flex_marks_model.dart

import 'dart:convert';

/// Represents a single evaluated item (e.g., Quiz 1, Assignment 2, Sessional 1).
class FlexEvaluationItem {
  final String name;
  final String category;
  final double weightage;
  final double? obtainedMarks;
  final double? totalMarks;
  final double? averageMarks;
  final double? minMarks;
  final double? maxMarks;
  final double? stdDev;

  const FlexEvaluationItem({
    required this.name,
    required this.category,
    required this.weightage,
    this.obtainedMarks,
    this.totalMarks,
    this.averageMarks,
    this.minMarks,
    this.maxMarks,
    this.stdDev,
  });

  bool get isGraded =>
      obtainedMarks != null && totalMarks != null && totalMarks! > 0;

  /// Absolute score earned for this specific evaluation item.
  double get attainedAbsolute =>
      isGraded ? (obtainedMarks! / totalMarks!) * weightage : 0.0;

  /// Class average absolute score for this evaluation item.
  double get classAvgAbsolute =>
      isGraded && averageMarks != null && totalMarks != null && totalMarks! > 0
          ? (averageMarks! / totalMarks!) * weightage
          : 0.0;

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'weightage': weightage,
        'obtainedMarks': obtainedMarks,
        'totalMarks': totalMarks,
        'averageMarks': averageMarks,
        'minMarks': minMarks,
        'maxMarks': maxMarks,
        'stdDev': stdDev,
      };

  factory FlexEvaluationItem.fromJson(Map<String, dynamic> json) {
    return FlexEvaluationItem(
      name: json['name'] as String? ?? '',
      category: json['category'] as String? ?? '',
      weightage: (json['weightage'] as num?)?.toDouble() ?? 0.0,
      obtainedMarks: (json['obtainedMarks'] as num?)?.toDouble(),
      totalMarks: (json['totalMarks'] as num?)?.toDouble(),
      averageMarks: (json['averageMarks'] as num?)?.toDouble(),
      minMarks: (json['minMarks'] as num?)?.toDouble(),
      maxMarks: (json['maxMarks'] as num?)?.toDouble(),
      stdDev: (json['stdDev'] as num?)?.toDouble(),
    );
  }
}

/// Holds all evaluation items and calculated metrics for a course.
class FlexCourseMarks {
  final String courseCode;
  final String courseName;
  final String section;
  final List<FlexEvaluationItem> items;

  const FlexCourseMarks({
    required this.courseCode,
    required this.courseName,
    required this.section,
    required this.items,
  });

  /// Total absolutes earned out of items graded so far.
  double get attainedAbsolutes =>
      items.fold(0.0, (sum, item) => sum + item.attainedAbsolute);

  /// Total weightage of items graded so far.
  double get evaluatedWeightage =>
      items.fold(0.0, (sum, item) => sum + (item.isGraded ? item.weightage : 0.0));

  /// Total weightage assigned across all evaluations (graded + unannounced).
  double get totalWeightage =>
      items.fold(0.0, (sum, item) => sum + item.weightage);

  /// Total class average absolutes earned so far.
  double get classAvgAbsolutes =>
      items.fold(0.0, (sum, item) => sum + item.classAvgAbsolute);

  /// Student's efficiency percentage on graded work.
  double get percentage => evaluatedWeightage > 0
      ? (attainedAbsolutes / evaluatedWeightage) * 100.0
      : 0.0;

  /// Class average percentage on graded work.
  double get classAvgPercentage => evaluatedWeightage > 0
      ? (classAvgAbsolutes / evaluatedWeightage) * 100.0
      : 0.0;

  /// Relative delta compared to class average (+ / - absolutes).
  double get diffFromAvg => attainedAbsolutes - classAvgAbsolutes;

  /// Points of the 100-point course scale not yet graded: 100 minus the
  /// weightage allotted to work already graded.
  double get remainingWeightage {
    final rem = 100.0 - evaluatedWeightage;
    return rem < 0 ? 0.0 : rem;
  }

  /// Letter grade based on the FAST standard scale: F <50, D 50–53, D+ 54–57, C- 58–61, C 62–65, C+ 66–69, B- 70–73, B 74–77, B+ 78–81, A- 82–85, A 86–89, A+ 90+.
  String? get letterGrade {
    final rounded = percentage.round();
    if (rounded < 50) return 'F';
    if (rounded >= 50 && rounded <= 53) return 'D';
    if (rounded >= 54 && rounded <= 57) return 'D+';
    if (rounded >= 58 && rounded <= 61) return 'C-';
    if (rounded >= 62 && rounded <= 65) return 'C';
    if (rounded >= 66 && rounded <= 69) return 'C+';
    if (rounded >= 70 && rounded <= 73) return 'B-';
    if (rounded >= 74 && rounded <= 77) return 'B';
    if (rounded >= 78 && rounded <= 81) return 'B+';
    if (rounded >= 82 && rounded <= 85) return 'A-';
    if (rounded >= 86 && rounded <= 89) return 'A';
    if (rounded >= 90) return 'A+';
    return null;
  }

  /// Grade point on the 4.0 scale used by FAST: A+/A 4.0 · A- 3.7 · B+ 3.3 · B 3.0 · B- 2.7 · C+ 2.3 · C 2.0 · C- 1.7 · D+ 1.3 · D 1.0 · F 0.0. Null if nothing graded yet.
  double? get gradePoint {
    final letter = letterGrade;
    if (letter == null) return null;
    switch (letter) {
      case 'A+':
      case 'A':
        return 4.0;
      case 'A-':
        return 3.7;
      case 'B+':
        return 3.3;
      case 'B':
        return 3.0;
      case 'B-':
        return 2.7;
      case 'C+':
        return 2.3;
      case 'C':
        return 2.0;
      case 'C-':
        return 1.7;
      case 'D+':
        return 1.3;
      case 'D':
        return 1.0;
      case 'F':
        return 0.0;
      default:
        return null;
    }
  }

  Map<String, dynamic> toJson() => {
        'courseCode': courseCode,
        'courseName': courseName,
        'section': section,
        'items': items.map((i) => i.toJson()).toList(),
      };

  factory FlexCourseMarks.fromJson(Map<String, dynamic> json) {
    return FlexCourseMarks(
      courseCode: json['courseCode'] as String? ?? '',
      courseName: json['courseName'] as String? ?? '',
      section: json['section'] as String? ?? '',
      items: (json['items'] as List<dynamic>?)
              ?.map((e) => FlexEvaluationItem.fromJson(Map<String, dynamic>.from(e)))
              .toList() ??
          [],
    );
  }

  static String encodeList(List<FlexCourseMarks> list) =>
      jsonEncode(list.map((c) => c.toJson()).toList());

  static List<FlexCourseMarks> decodeList(String jsonStr) {
    if (jsonStr.isEmpty) return [];
    try {
      final List<dynamic> list = jsonDecode(jsonStr);
      return list
          .map((e) => FlexCourseMarks.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }
}
