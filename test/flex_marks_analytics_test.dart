// test/flex_marks_analytics_test.dart
//
// The analytics sheet's course card shows three things that are easy to break
// silently, because none of them is visible as code:
//
// 1. The absolutes are the raw portal sums, never rescaled. The card prints
//    a denominator ("32.0 / 100.0") and a bar drawn 0-100, but a FAST course
//    is out of 100 because its weightages add up to 100 - not because
//    anything is multiplied. Attained, class average and graded weightage
//    have to come out of the model exactly as they went in; the only rule
//    applied is remaining = 100 - the weightage allotted to work already
//    graded, which is what fills the box's third row. So the model is fed
//    weightages summing to 95 and asked to report them raw, and fed
//    weightages summing to 100 and asked to change nothing.
//
// 2. The box reads Attained, then Class Avg, then Remaining, in that order.
//    Three rows of the same shape are indistinguishable at a glance, so the
//    order itself is the assertion rather than just their presence.
//
// 3. The standing bar is two markers on one 0-100% scale: the fill and your
//    line both sit at your score on graded work, the dark line at the class
//    average's score on graded work - the same two figures the tiles above
//    show - and yours is drawn last so that a student sitting exactly on the
//    average still sees their own marker. The 0% and 100% at its ends label
//    that range. The positions are measured against the bar's own measured
//    width, because a hardcoded pixel value would only test the card's
//    padding.
//
// The window is the DS BD3 Pro: 1080x2412 at density 3.0 -> 360x804 logical,
// the same one test/note_row_alignment_test.dart measures against.
import 'package:fast_companion/models/flex_marks_model.dart';
import 'package:fast_companion/theme/app_colors.dart';
import 'package:fast_companion/widgets/flex_marks_analytics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Runs [body] against the phone this app is used on.
void deviceTest(String description, Future<void> Function(WidgetTester) body) {
  testWidgets(description, (tester) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await body(tester);
  });
}

/// Weightages of 10 + 30 + 60 = 100, which is how FAST courses actually add
/// up - so every figure below is both the raw sum and the course total.
///
/// Quiz 1 and Sessional 1 are graded, the Final is not, which leaves 60 of
/// the 100 points still up for grabs.
const FlexCourseMarks courseOn100 = FlexCourseMarks(
  courseCode: 'CS241',
  courseName: 'Object Oriented Programming',
  section: 'Morning',
  items: [
    FlexEvaluationItem(
      name: 'Quiz 1',
      category: 'Quiz',
      weightage: 10,
      obtainedMarks: 8,
      totalMarks: 10,
      averageMarks: 7,
    ),
    FlexEvaluationItem(
      name: 'Sessional 1',
      category: 'Sessional',
      weightage: 30,
      obtainedMarks: 24,
      totalMarks: 30,
      averageMarks: 21,
    ),
    FlexEvaluationItem(
      name: 'Final',
      category: 'Final',
      weightage: 60,
    ),
  ],
);

/// The same course as the portal would report it if its weightages summed
/// to 95 instead of 100.
///
/// Raw figures: attained 8 + 15 = 23, graded weightage 40, class average
/// 7 + 18 = 25 - all reported as they are, with no factor applied. Only
/// remaining is derived: 100 - 40 allotted = 60.
const FlexCourseMarks courseOn95 = FlexCourseMarks(
  courseCode: 'CS241',
  courseName: 'Object Oriented Programming',
  section: 'Morning',
  items: [
    FlexEvaluationItem(
      name: 'Quiz 1',
      category: 'Quiz',
      weightage: 10,
      obtainedMarks: 8,
      totalMarks: 10,
      averageMarks: 7,
    ),
    FlexEvaluationItem(
      name: 'Sessional 1',
      category: 'Sessional',
      weightage: 30,
      obtainedMarks: 15,
      totalMarks: 30,
      averageMarks: 18,
    ),
    FlexEvaluationItem(
      name: 'Final',
      category: 'Final',
      weightage: 55,
    ),
  ],
);

/// Pumps one card the way the sheet shows it: full-bleed in a list, so the
/// card takes the screen width and the bar inside it has a real width to be
/// measured against.
Future<void> pumpCard(
  WidgetTester tester, {
  FlexCourseMarks marks = courseOn100,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          padding: EdgeInsets.zero,
          children: [FlexMarksAnalyticsWidget(marks: marks)],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every string the card prints, in the order they appear down the card.
List<String> textsInCard(WidgetTester tester) => tester
    .widgetList<Text>(
      find.descendant(
        of: find.byType(FlexMarksAnalyticsWidget),
        matching: find.byType(Text),
      ),
    )
    .map((t) => t.data ?? '')
    .toList();

void main() {
  group('absolutes are the raw sums', () {
    test('weightages summing to 100 report their figures directly', () {
      expect(courseOn100.totalWeightage, 100.0);
      expect(courseOn100.attainedAbsolutes, 32.0);
      expect(courseOn100.evaluatedWeightage, 40.0);
      expect(courseOn100.classAvgAbsolutes, 28.0);
      expect(courseOn100.remainingWeightage, 60.0);
      expect(courseOn100.percentage, closeTo(80.0, 1e-9));
      expect(courseOn100.classAvgPercentage, closeTo(70.0, 1e-9));
      expect(courseOn100.diffFromAvg, 4.0);
      expect(courseOn100.letterGrade, 'B+');
    });

    test('weightages summing to 95 are reported raw, not rescaled', () {
      const c = courseOn95;
      // Nothing is multiplied: these are 8 + 15 and 7 + 18 as the portal
      // gave them, whatever the item weightages happen to total.
      expect(c.attainedAbsolutes, 23.0);
      expect(c.evaluatedWeightage, 40.0);
      expect(c.classAvgAbsolutes, 25.0);
      expect(c.totalWeightage, 95.0);
      // Remaining is the one derived figure, and it is always 100 minus the
      // weightage allotted to graded work - here 100 - 40.
      expect(c.remainingWeightage, 60.0);
      expect(
        c.remainingWeightage,
        100.0 - c.evaluatedWeightage,
        reason: 'remaining is defined as 100 minus the allotted weightage',
      );
    });

    test('percentages, Abs Diff and the grade use those raw sums', () {
      expect(courseOn95.percentage, closeTo(57.5, 1e-9));
      expect(courseOn95.classAvgPercentage, closeTo(62.5, 1e-9));
      // 57.5 sits on the D+/C- boundary and the scale grades off the rounded
      // percentage. 23/40 * 100 lands a hair under 57.5 in binary floating
      // point, so it rounds to 57 and reads D+ - the model's own arithmetic,
      // left exactly as it is.
      expect(courseOn95.letterGrade, 'D+');
      expect(
        courseOn95.diffFromAvg,
        closeTo(-2.0, 1e-9),
        reason: 'Abs Diff is the raw gap: 23 attained against 25 average',
      );
    });
  });

  group('course card', () {
    deviceTest('shows the renamed tile and the three box rows in order',
        (tester) async {
      await pumpCard(tester);

      expect(find.text('Abs Diff'), findsOneWidget);
      expect(find.text('+4.0'), findsOneWidget);

      expect(find.text('Attained Absolutes:'), findsOneWidget);
      expect(find.text('32.0 / 100.0 (80.0%)'), findsOneWidget);
      expect(find.text('Class Avg Absolutes:'), findsOneWidget);
      expect(find.text('28.0 / 100.0 (70.0%)'), findsOneWidget);
      expect(find.text('Remaining Absolutes:'), findsOneWidget);
      expect(find.text('60.0'), findsOneWidget);

      final labels = textsInCard(tester);
      final attained = labels.indexOf('Attained Absolutes:');
      final classAvg = labels.indexOf('Class Avg Absolutes:');
      final remaining = labels.indexOf('Remaining Absolutes:');
      expect(attained, greaterThanOrEqualTo(0));
      expect(classAvg, greaterThan(attained),
          reason: 'the class average sits between the other two rows');
      expect(remaining, greaterThan(classAvg));
    });

    deviceTest('draws the fill and both marker lines at their percentages',
        (tester) async {
      await pumpCard(tester);

      expect(find.text('Standing (0–100%)'), findsOneWidget);
      expect(find.text('You '), findsOneWidget);
      expect(find.text('  ·  Avg '), findsOneWidget);
      // The bar repeats the two tile figures, so each shows up twice: once
      // in its tile and once as a marker in the legend.
      expect(find.text('80.0%'), findsNWidgets(2),
          reason: 'Your Score tile and the bar legend');
      expect(find.text('70.0%'), findsNWidgets(2),
          reason: 'Class Avg tile and the bar legend');
      expect(find.text('0%'), findsOneWidget,
          reason: 'left end of the bar is labelled 0%');
      expect(find.text('100%'), findsOneWidget,
          reason: 'right end of the bar is labelled 100%');

      final markers = find.descendant(
        of: find.byType(FlexMarksAnalyticsWidget),
        matching: find.byType(Positioned),
      );
      expect(markers, findsNWidgets(4),
          reason: 'track, fill, class-average line, your line');

      // Stack children paint in order, so index 3 is on top of index 2 -
      // which is the point: your line wins when you sit on the average.
      final avgLine = tester.widget<Positioned>(markers.at(2)).child;
      final yourLine = tester.widget<Positioned>(markers.at(3)).child;
      expect(avgLine, isA<ColoredBox>());
      expect((avgLine as ColoredBox).color, AppColors.textPrimary);
      expect(yourLine, isA<ColoredBox>());
      expect((yourLine as ColoredBox).color, AppColors.cardOrange);

      final track = tester.getRect(markers.at(0));
      final fill = tester.getRect(markers.at(1));
      final avg = tester.getRect(markers.at(2));
      final you = tester.getRect(markers.at(3));

      const lineWidth = 3.0;
      expect(track.width, greaterThan(0));
      expect(you.height, greaterThan(track.height),
          reason: 'the markers overhang the track so they read as lines on it');

      expect(fill.width, closeTo(track.width * 80 / 100, 0.01),
          reason: 'a score of 80.0% fills 80% of the track');
      expect(avg.width, closeTo(lineWidth, 0.01));
      expect(avg.left, closeTo(track.left + track.width * 70 / 100 - lineWidth / 2, 0.01),
          reason: 'class average at 70.0%');
      expect(you.width, closeTo(lineWidth, 0.01));
      expect(you.left, closeTo(track.left + track.width * 80 / 100 - lineWidth / 2, 0.01),
          reason: 'your 80.0%');

      // The range labels mark the bar's own two ends: 0% on its left edge,
      // 100% on its right edge.
      final rangeStart = tester.getRect(find.text('0%'));
      final rangeEnd = tester.getRect(find.text('100%'));
      expect(rangeStart.left, closeTo(track.left, 0.01));
      expect(rangeEnd.right, closeTo(track.right, 0.01));
    });

    deviceTest('keeps both markers on the bar when nothing is graded',
        (tester) async {
      const ungraded = FlexCourseMarks(
        courseCode: 'CS300',
        courseName: 'Theory of Automata',
        section: 'Morning',
        items: [
          FlexEvaluationItem(
            name: 'Final',
            category: 'Final',
            weightage: 100,
          ),
        ],
      );
      await pumpCard(tester, marks: ungraded);

      final markers = find.descendant(
        of: find.byType(FlexMarksAnalyticsWidget),
        matching: find.byType(Positioned),
      );
      expect(markers, findsNWidgets(4));

      final track = tester.getRect(markers.at(0));
      final fill = tester.getRect(markers.at(1));
      final avg = tester.getRect(markers.at(2));
      final you = tester.getRect(markers.at(3));

      expect(fill.width, closeTo(0.0, 0.01));
      // At zero both lines clamp to the left edge rather than falling off
      // it, and yours is the one left showing.
      expect(avg.left, closeTo(track.left, 0.01));
      expect(you.left, closeTo(track.left, 0.01));
    });
  });
}
