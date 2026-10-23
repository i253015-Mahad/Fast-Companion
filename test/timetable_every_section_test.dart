// Classes filed for every section.
//
// The October 23 lab exams were written onto the Computing sheet as
// `AI (SE Lab Exam) October 23` and `COAL Lab (CY) Mid Exam` — a
// parenthetical saying who the class is for, but not in the `DEPT-SEC`
// form the parser reads a section out of. They therefore arrived with no
// section at all, and `filterBy` read "no section" as "matches no
// section": the exams were invisible behind every pill on the row and
// only turned up once the filter was cleared. A student walked into an
// exam the app never showed them.
//
// A cell that names no section is not aimed at nobody — it is aimed at
// everybody. [TimetableEntry.isForEverySection] says so and `filterBy`
// honours it.
import 'package:fast_companion/models/timetable_entry.dart';
import 'package:fast_companion/services/timetable_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final svc = TimetableService.instance;

  /// The Computing Friday grid as the sheet published the exam day: exam
  /// cells written for the school at large, beside ordinary sectioned
  /// classes in the room next door.
  const html = '''
<table>
<tr>
  <td>Room/ Time</td>
  <td colspan="4">08:30-09:50</td><td></td>
  <td colspan="4">10:00-11:20</td><td></td>
  <td colspan="4">11:30-12:50</td><td></td>
  <td colspan="4">01:00-02:20</td><td></td>
  <td colspan="4">02:30-03:50</td><td></td>
  <td colspan="4">03:55-05:15</td>
</tr>
<tr>
  <td>C-603</td>
  <td colspan="9"></td><td></td>
  <td colspan="9">AI (SE Lab Exam) October 23</td><td></td>
  <td colspan="4">COAL Lab (CY) Mid Exam</td><td></td>
  <td colspan="4">Intro to DS Lab (DS) Mid Exam</td>
</tr>
<tr>
  <td>C-604</td>
  <td colspan="4">PF (SE-A)</td><td></td>
  <td colspan="5"></td>
  <td colspan="9">COAL Lab (SE-C)</td><td></td>
  <td colspan="5"></td>
  <td colspan="4">LA (SE-A1)</td>
</tr>
</table>''';

  // The parenthetical is dropped from the course name, so the exams read
  // as `AI October 23`, `COAL Lab Mid Exam`, `Intro to DS Lab Mid Exam`.
  const exams = ['AI October 23', 'COAL Lab Mid Exam', 'Intro to DS Lab Mid Exam'];

  group('an exam filed for the whole school', () {
    late List<TimetableEntry> entries;

    setUp(() {
      entries = svc.debugParseComputingHtml(html, 'Friday');
    });

    test('parses with no section of its own', () {
      final exam = entries.firstWhere(
        (e) => e.course == 'AI October 23',
        orElse: () => fail('exam lab not parsed: $entries'),
      );
      expect(exam.section, isEmpty);
      expect(exam.isForEverySection, isTrue);
      // Carrying no section is not the same as being a placeholder: the
      // screen drops those before a student ever sees them, and a real
      // class must not be dropped along with them.
      expect(exam.isPlaceholder, isFalse);
    });

    test('survives every section pill', () {
      for (final pill in ['SE-A', 'SE-C', 'AI-A', 'CY-A', 'DS-A']) {
        final shown =
            TimetableService.filterBy(entries, section: pill)
                .map((e) => e.course)
                .toList();
        expect(
          shown,
          containsAll(exams),
          reason: 'an exam filed for the whole school vanished behind $pill',
        );
      }
    });

    test('a sectioned class still stays behind its own pill', () {
      final seA =
          TimetableService.filterBy(entries, section: 'SE-A')
              .map((e) => e.course)
              .toList();
      expect(seA, contains('PF'), reason: 'SE-A keeps its own lecture');
      // A lab group folds into its parent pill...
      expect(seA, contains('LA'), reason: 'SE-A1 folds into SE-A');
      // ...but another section's class does not follow it in.
      expect(
        seA,
        isNot(contains('COAL Lab')),
        reason: 'a sectioned class must not leak into a neighbour',
      );
    });

    test('is unchanged when no filter is set', () {
      expect(
        TimetableService.filterBy(entries).map((e) => e.course),
        containsAll([...exams, 'PF', 'COAL Lab']),
      );
    });
  });

  group('TimetableEntry.isForEverySection', () {
    test('is false for a class filed under one section', () {
      const entry = TimetableEntry(
        day: 'Friday',
        startTime: '11:30',
        endTime: '02:20',
        course: 'COAL Lab',
        section: 'SE-C',
      );
      expect(entry.isForEverySection, isFalse);
    });

    test('is true when the cell names no section', () {
      const entry = TimetableEntry(
        day: 'Friday',
        startTime: '11:30',
        endTime: '02:20',
        course: 'AI October 23',
      );
      expect(entry.isForEverySection, isTrue);
    });
  });
}
