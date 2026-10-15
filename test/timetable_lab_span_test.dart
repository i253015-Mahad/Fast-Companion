// Lab spans.
//
// The sheets say how long a class is by merging cells so one class's
// colour runs across several time slots — a three-hour lab is drawn
// across two of them. The parser used to read only the slot the text
// first appears in, so every lab came out looking like a 1h20m
// lecture (COAL Lab SE-C, running to 02:20 on the sheet, showed as
// 11:30-12:50).
//
// A block ends where the last period it covers ends: 11:30 and 01:00
// come out as 11:30-02:20, not 11:30-02:30. The coloured block on the
// sheet stops at the end of the second period; it does not run into
// the one after it.
//
// Two groups: fixtures that always run, and the real sheets when a
// saved copy is present.
import 'dart:io';

import 'package:fast_companion/services/timetable_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Escapes cells into one CSV row the way gviz exports it.
String _csvRow(List<String> cells) => cells
    .map((c) => '"${c.replaceAll('"', '""')}"')
    .join(',');

void main() {
  final svc = TimetableService.instance;

  // ---------------------------------------------------------------------
  // Fixtures. The column layout is the sheets' own: Computing puts four
  // columns per period with a spacer between them (1, 6, 11, 16...),
  // Engineering seventeen (3, 21, 39...), and Management has no spacer
  // at all (3, 12, 21, 30...).
  // ---------------------------------------------------------------------

  group('merged spans', () {
    test('computing: a lab across two periods ends with the second', () {
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
  <td colspan="9">COAL Lab (SE-C)</td><td></td>
  <td colspan="4">COAL (SE-C)</td><td></td>
  <td colspan="4">LA (SE-B)</td>
</tr>
<tr>
  <td>C-604</td>
  <td colspan="4">PF (SE-C)</td><td></td>
  <td colspan="7">FSM</td>
</tr>
</table>''';

      final entries = svc.debugParseComputingHtml(html, 'Wednesday');

      final lab = entries.firstWhere(
        (e) => e.course == 'COAL Lab',
        orElse: () => fail('lab not parsed: $entries'),
      );
      expect(lab.section, 'SE-C');
      expect(lab.isLab, isTrue);
      expect(lab.room, 'C-603');
      // Both periods are covered, so it ends where the second one does.
      expect(lab.startTime, '11:30');
      expect(lab.endTime, '02:20');
    });

    test('computing: a single-period lecture keeps its own end time', () {
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
  <td colspan="9">COAL Lab (SE-C)</td><td></td>
  <td colspan="4">COAL (SE-C)</td><td></td>
  <td colspan="4">LA (SE-B)</td>
</tr>
<tr>
  <td>C-604</td>
  <td colspan="4">PF (SE-C)</td><td></td>
  <td colspan="7">FSM</td>
</tr>
</table>''';

      final entries = svc.debugParseComputingHtml(html, 'Wednesday');

      final theory = entries.firstWhere(
        (e) => e.course == 'COAL',
        orElse: () => fail('theory not parsed: $entries'),
      );
      expect(theory.isLab, isFalse);
      expect(theory.startTime, '02:30');
      expect(theory.endTime, '03:50');

      final pf = entries.firstWhere(
        (e) => e.course == 'PF',
        orElse: () => fail('PF not parsed: $entries'),
      );
      expect(pf.startTime, '08:30');
      expect(pf.endTime, '09:50');

      // Reaching into the next period is not the same as occupying it:
      // this cell is five columns wide and brushes a single column of
      // the period beside it. Reading that as three hours is exactly
      // the bug the other way round.
      final fsm = entries.firstWhere(
        (e) => e.course == 'FSM',
        orElse: () => fail('FSM not parsed: $entries'),
      );
      expect(fsm.startTime, '10:00');
      expect(fsm.endTime, '11:20');
    });

    test('engineering: a lab across two periods ends with the second', () {
      const html = '''
<table>
<tr>
  <td></td><td></td><td>Room</td>
  <td colspan="17">8:30 - 09:50</td><td></td>
  <td colspan="17">09:55 - 11:15</td><td></td>
  <td colspan="17">11:25 - 12:45</td><td></td>
  <td colspan="17">12:50 - 02:10</td>
</tr>
<tr>
  <td rowspan="2">Monday</td><td>Classes</td><td>C-601</td>
  <td colspan="17">PF SE-C</td><td></td>
  <td colspan="17">Calculus SE-A</td>
</tr>
<tr>
  <td>Labs</td><td>Comp-I</td>
  <td colspan="35">Applications of ICT Lab EE-A</td>
</tr>
</table>''';

      final entries = svc.debugParseEngineeringHtml(html);

      final lab = entries.firstWhere(
        (e) => e.course.contains('Applications of ICT'),
        orElse: () => fail('lab not parsed: $entries'),
      );
      expect(lab.day, 'Monday');
      expect(lab.room, 'Comp-I');
      expect(lab.isLab, isTrue);
      expect(lab.startTime, '08:30');
      expect(lab.endTime, '11:15'); // the end of the second period

      final theory = entries.firstWhere(
        (e) => e.course == 'PF',
        orElse: () => fail('PF not parsed: $entries'),
      );
      expect(theory.isLab, isFalse);
      expect(theory.startTime, '08:30');
      expect(theory.endTime, '09:50');
    });

    test('unbalanced brackets in a room are closed', () {
      // The computing sheet writes this room with no closing bracket.
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
  <td>Margala 4 (C-212</td>
  <td colspan="4">COAL (SE-C)</td><td></td>
  <td colspan="4">LA (SE-B)</td>
</tr>
</table>''';

      final entries = svc.debugParseComputingHtml(html, 'Wednesday');

      expect(entries, isNotEmpty);
      expect(entries.first.room, 'Margala 4 (C-212)');
    });

    test('a stray closing bracket is dropped', () {
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
  <td>C-603)</td>
  <td colspan="4">COAL (SE-C)</td>
</tr>
</table>''';

      final entries = svc.debugParseComputingHtml(html, 'Wednesday');

      expect(entries, isNotEmpty);
      expect(entries.first.room, 'C-603');
    });

    test('management: a course code with no space before its name', () {
      // The sheet writes `LG2009Data Analysis for Business -II Lab` with
      // no space at all, and requiring one dropped the whole cell — the
      // lab never appeared anywhere on the timetable.
      List<String> row(int length) => List.filled(length, '');

      final header = row(51);
      header[2] = 'Room';
      header[3] = '08:30-09:50';
      header[11] = '10:00-11:20';
      header[19] = '11:30-12:50';
      header[27] = '01:00-02:20';
      header[35] = '02:25-03:45';
      header[43] = '03:50-05:10';

      final labRow = row(51);
      labRow[0] = 'Monday';
      labRow[1] = 'Labs';
      labRow[2] = 'KK-I';
      labRow[19] = 'LG2009Data Analysis for Business -II Lab';
      labRow[26] = 'AF03A';
      labRow[27] = 'LG2009Data Analysis for Business -II Lab';
      labRow[34] = 'AF03A';

      // A separator standing in for the space must not survive as a
      // stray leading hyphen on the name.
      final sepRow = row(51);
      sepRow[1] = 'Classes';
      sepRow[2] = 'A-01';
      sepRow[3] = 'AF5007-Advanced Financial Management';
      sepRow[10] = 'AF05A';

      // Two codes in one cell belong to the code, not the name.
      final pairRow = row(51);
      pairRow[1] = 'Classes';
      pairRow[2] = 'A-02';
      pairRow[11] = 'SS1022/SS1021 U-Holy Quran-I&II';
      pairRow[18] = 'AF07A';

      final entries = svc.debugParseManagementCsv(
        '${_csvRow(header)}\n${_csvRow(labRow)}\n${_csvRow(sepRow)}\n'
        '${_csvRow(pairRow)}\n',
      );

      final lab = entries.firstWhere(
        (e) => e.course.contains('Data Analysis'),
        orElse: () => fail('glued code not parsed: $entries'),
      );
      expect(lab.course, 'LG2009 Data Analysis for Business -II Lab');
      expect(lab.isLab, isTrue, reason: 'the joined pair is still a lab');

      final separated = entries.firstWhere(
        (e) => e.course.contains('Advanced Financial'),
        orElse: () => fail('separator course not parsed: $entries'),
      );
      expect(
        separated.course,
        'AF5007 Advanced Financial Management',
        reason: 'the leading separator is dropped, not spaced',
      );

      final paired = entries.firstWhere(
        (e) => e.course.contains('Holy Quran'),
        orElse: () => fail('paired code not parsed: $entries'),
      );
      expect(paired.course, 'SS1022/SS1021 U-Holy Quran-I&II');
    });

    test('management: a lab written into two periods becomes one entry', () {
      List<String> row(int length) => List.filled(length, '');

      final header = row(51);
      header[2] = 'Room';
      header[3] = '08:30-09:50';
      header[11] = '10:00-11:20';
      header[19] = '11:30-12:50';
      header[27] = '01:00-02:20';
      header[35] = '02:25-03:45';
      header[43] = '03:50-05:10';

      final labRow = row(51);
      labRow[0] = 'Monday';
      labRow[1] = 'Labs';
      labRow[2] = 'A-01';
      // The sheet writes the same lab into the period and the one after
      // it, section code and all.
      labRow[19] = 'LG2009 Data Analysis Lab';
      labRow[26] = 'AF03A';
      labRow[27] = 'LG2009 Data Analysis Lab';
      labRow[34] = 'AF03A';

      // The same repetition for a lecture is two sessions, not one long
      // one, and stays as the sheet drew it.
      final lectureRow = row(51);
      lectureRow[0] = '';
      lectureRow[1] = 'Classes';
      lectureRow[2] = 'A-02';
      lectureRow[3] = 'AF1002 Finacial Accounting';
      lectureRow[10] = 'AF03A';
      lectureRow[12] = 'AF1002 Finacial Accounting';
      lectureRow[19] = 'AF03A';

      final entries = svc.debugParseManagementCsv(
        '${_csvRow(header)}\n${_csvRow(labRow)}\n${_csvRow(lectureRow)}\n',
      );

      final labs = entries
          .where((e) => e.course == 'LG2009 Data Analysis Lab')
          .toList();
      expect(labs, hasLength(1), reason: 'the two periods must be joined');
      expect(labs.single.isLab, isTrue);
      expect(labs.single.startTime, '11:30');
      expect(labs.single.endTime, '02:20'); // the end of the second period

      final lectures = entries
          .where((e) => e.course == 'AF1002 Finacial Accounting')
          .toList();
      expect(
        lectures,
        hasLength(2),
        reason: 'a repeated lecture is two sessions, not one block',
      );
      expect(lectures.first.startTime, '08:30');
      expect(lectures.first.endTime, '09:50');
      expect(lectures.last.startTime, '10:00');
      expect(lectures.last.endTime, '11:20');
    });
  });

  // ---------------------------------------------------------------------
  // The real sheets, when a copy is on this machine. These are the data
  // that produced the report: COAL Lab SE-C, Wednesday, Margala 4.
  // ---------------------------------------------------------------------

  group('real sheets', () {
    final dir = '${Platform.environment['TEMP']}\\opencode';
    File f(String name) => File('$dir\\$name');
    bool has(String name) => f(name).existsSync();

    test('computing: COAL Lab (SE-C) runs both periods', () {
      final entries = svc.debugParseComputingHtml(
        f('ct_Wednesday.html').readAsStringSync(),
        'Wednesday',
      );
      final lab = entries.firstWhere(
        (e) => e.course == 'COAL Lab' && e.section == 'SE-C',
        orElse: () => fail('COAL Lab (SE-C) not found'),
      );
      expect(lab.startTime, '11:30');
      expect(lab.endTime, '02:20');
      expect(lab.isLab, isTrue);
      expect(lab.room, contains('Margala'));
    }, skip: !has('ct_Wednesday.html'));

    test('computing: a theory lecture keeps its single period', () {
      final entries = svc.debugParseComputingHtml(
        f('ct_Tuesday.html').readAsStringSync(),
        'Tuesday',
      );
      final theory = entries.firstWhere(
        (e) => e.course == 'COAL' && e.section == 'SE-C',
        orElse: () => fail('COAL theory (SE-C) not found'),
      );
      expect(theory.isLab, isFalse);
      expect(theory.startTime, '08:30');
      expect(theory.endTime, '09:50');
    }, skip: !has('ct_Tuesday.html'));

    test('computing: labs are two periods, lectures are not', () {
      const days = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
      ];
      final labs = <(String, String)>[];
      final others = <(String, String)>[];
      for (final d in days) {
        if (!has('ct_$d.html')) continue;
        for (final e in svc.debugParseComputingHtml(
          f('ct_$d.html').readAsStringSync(),
          d,
        )) {
          (e.isLab ? labs : others).add((e.startTime, e.endTime));
        }
      }
      expect(labs, isNotEmpty);

      // Every two-period lab must end where its last period ends, and
      // every one-period entry must match its own period.
      const twoPeriods = {
        '08:30 - 11:20',
        '10:00 - 12:50',
        '11:30 - 02:20',
        '02:30 - 05:15',
        '03:55 - 06:40',
        '05:20 - 08:05',
      };
      final odd = labs
          .where((t) => !twoPeriods.contains('${t.$1} - ${t.$2}'))
          .toList();
      // The sheet does contain a handful of single-period lab blocks
      // (a lab exam, a room-tagged class) and cells carrying a typed-in
      // time; those are read straight off the sheet and are correct.
      expect(
        odd.length,
        lessThan(labs.length ~/ 4),
        reason: 'too many labs not on a three-hour block: $odd',
      );
      expect(
        others.where((t) => t.$2 == '09:50' || t.$2 == '11:20').length,
        greaterThan(100),
        reason: 'single-period lectures should be untouched',
      );
    }, skip: !has('ct_Wednesday.html'));

    test('computing csv fallback: lab extends over the blank period', () {
      final entries = svc.debugParseComputingCsv(
        f('ct_wed.csv').readAsStringSync(),
        'Wednesday',
      );
      final lab = entries.firstWhere(
        (e) => e.course == 'COAL Lab' && e.section == 'SE-C',
        orElse: () => fail('COAL Lab (SE-C) not found in CSV'),
      );
      expect(lab.startTime, '11:30');
      expect(lab.endTime, '02:20');
    }, skip: !has('ct_wed.csv'));

    test('engineering: every lab spans two periods', () {
      final entries = svc.debugParseEngineeringHtml(
        f('sheet_eng.html').readAsStringSync(),
      );
      final labs = entries.where((e) => e.isLab).toList();
      expect(labs, isNotEmpty);
      expect(
        labs.map((e) => '${e.startTime} - ${e.endTime}').toSet(),
        everyElement(
          anyOf(
            '08:30 - 11:15',
            '09:55 - 12:45',
            '11:25 - 02:10',
            '12:50 - 03:40',
            '02:20 - 05:05',
          ),
        ),
      );
    }, skip: !has('sheet_eng.html'));

    test('no entry anywhere carries an unbalanced bracket', () {
      bool bad(String s) {
        var depth = 0;
        for (final r in s.split('')) {
          if (r == '(') depth++;
          if (r == ')') depth--;
          if (depth < 0) return true;
        }
        return depth != 0;
      }

      final offenders = <String>[];
      for (final e in svc.debugParseComputingHtml(
        f('ct_Wednesday.html').readAsStringSync(),
        'Wednesday',
      )) {
        for (final v in [e.course, e.room, e.section]) {
          if (bad(v)) offenders.add(v);
        }
      }
      for (final e in svc.debugParseEngineeringHtml(
        f('sheet_eng.html').readAsStringSync(),
      )) {
        for (final v in [e.course, e.room, e.section]) {
          if (bad(v)) offenders.add(v);
        }
      }
      for (final e in svc.debugParseManagementCsv(
        f('sheet_mgmt.csv').readAsStringSync(),
      )) {
        for (final v in [e.course, e.room, e.section]) {
          if (bad(v)) offenders.add(v);
        }
      }
      expect(offenders, isEmpty);
    }, skip: !has('ct_Wednesday.html'));

    test('management: labs are joined into one two-period block', () {
      final entries = svc.debugParseManagementCsv(
        f('sheet_mgmt.csv').readAsStringSync(),
      );
      final labs = entries.where((e) => e.isLab).toList();
      expect(labs, isNotEmpty);
      for (final e in labs) {
        if (!const {
          '08:30 - 11:20',
          '11:30 - 02:20',
          '02:25 - 05:10',
        }.contains('${e.startTime} - ${e.endTime}')) {
          // ignore: avoid_print
          print('ODD ${e.day} | ${e.course} | ${e.section} | ${e.room} | '
              '${e.startTime} - ${e.endTime}');
        }
      }
      expect(
        labs.map((e) => '${e.startTime} - ${e.endTime}').toSet(),
        everyElement(
          anyOf('08:30 - 11:20', '11:30 - 02:20', '02:25 - 05:10'),
        ),
      );
    }, skip: !has('sheet_mgmt.csv'));
  });
}
