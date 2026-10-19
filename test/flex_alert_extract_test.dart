// Phase 3 — from a parsed page to the hashes an alert compares.
//
// The parsers are already tested; what needs testing here is what this
// layer *keeps* from them, and the one rule that matters: a page that
// failed to parse must never look like a page that legitimately emptied.
// The first would fire a notification about nothing; the second would fire
// one claiming every course the student has ever taken had vanished.
import 'dart:io';

import 'package:fast_companion/services/flex_alert_challan.dart';
import 'package:fast_companion/services/flex_alert_extract.dart';
import 'package:fast_companion/services/flex_alert_marks.dart';
import 'package:fast_companion/services/flex_alert_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

final _marks = File('test/fixtures/flex_marks.html');
final _transcript = File('test/fixtures/flex_transcript.html');
final _challan = File('test/fixtures/flex_challan.html');

void main() {
  group('a page that parses', () {
    test('marks hashes one entry per course code', () {
      if (!_marks.existsSync()) {
        markTestSkipped('marks fixture not present');
        return;
      }
      final page = const FlexMarksParser().parse(_marks.readAsStringSync());
      final hashes = marksHashes(page);

      // Grouped by code, so one entry per distinct code rather than per row
      // — the fixture has two courses sharing a code once its digits are
      // collapsed, and both still have to be watched.
      expect(hashes.keys, unorderedEquals(page.courses.map((c) => c.code).toSet()));
      for (final h in hashes.values) {
        expect(h, isNotEmpty);
      }
    });

    test('marks hash moves when a duplicated course changes', () {
      // The fixture's two `SS` courses share a code. Keyed one-to-one the
      // second would overwrite the first, and a mark uploaded to it would
      // never be noticed.
      if (!_marks.existsSync()) {
        markTestSkipped('marks fixture not present');
        return;
      }
      final page = const FlexMarksParser().parse(_marks.readAsStringSync());
      final duplicate = page.courses.firstWhere(
        (c) => page.courses.where((o) => o.code == c.code).length > 1,
        orElse: () => throw TestFailure('fixture should share a code'),
      );

      final rebuilt = FlexMarksPage([
        for (final c in page.courses)
          identical(c, duplicate)
              ? FlexCourseMarks(
                  code: c.code,
                  name: c.name,
                  section: c.section,
                  grandTotal: c.grandTotal,
                  assessments: {
                    for (final e in c.assessments.entries)
                      e.key: Map<String, double>.from(e.value)
                        ..['Obtained Marks'] =
                            (e.value['Obtained Marks'] ?? 0) + 1,
                  },
                )
              : c,
      ]);

      expect(marksHashes(rebuilt)[duplicate.code],
          isNot(marksHashes(page)[duplicate.code]),
          reason: 'the duplicated course must still be watched');
    });

    test('transcript hashes one entry per course code', () {
      if (!_transcript.existsSync()) {
        markTestSkipped('transcript fixture not present');
        return;
      }
      final page =
          const FlexTranscriptParser().parse(_transcript.readAsStringSync());
      final hashes = transcriptHashes(page);

      // Grouped by code: the fixture lists courses taken more than once,
      // and each distinct code is one watched entry.
      expect(hashes.keys,
          unorderedEquals(page.courses.map((c) => c.code).toSet()));
      expect(hashes.length, lessThan(page.courses.length),
          reason: 'the fixture should re-take at least one course');
    });

    test('challan hashes one entry per row, keyed by serial', () {
      if (!_challan.existsSync()) {
        markTestSkipped('challan fixture not present');
        return;
      }
      final page = const FlexChallanParser().parse(_challan.readAsStringSync());
      final hashes = challanHashes(page);

      expect(hashes, hasLength(page.rows.length));
      for (final row in page.rows) {
        expect(hashes.containsKey(row.serial.toString()), isTrue,
            reason: 'a challan with serial ${row.serial} should be keyed');
      }
    });

    test('a re-taken course is one entry that moves with either attempt', () {
      // The transcript lists a re-taken course once per attempt. Grouped by
      // code that is one entry — and it must move when the *second*
      // attempt's grade changes, not only the first, or a resit would
      // never be noticed.
      final twoAttempts = const FlexTranscriptParser().parse('''
        <h5>Fall 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>F</td></tr></table>
        <h5>Spring 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>A</td></tr></table>
      ''');
      final resat = const FlexTranscriptParser().parse('''
        <h5>Fall 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>F</td></tr></table>
        <h5>Spring 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>B</td></tr></table>
      ''');

      final before = transcriptHashes(twoAttempts);
      final after = transcriptHashes(resat);

      expect(before, hasLength(1), reason: 'one course, however many rows');
      expect(after['CS2001'], isNot(before['CS2001']),
          reason: 'a resit changing grade must move the hash');
    });

    test('a page re-sorted but unchanged hashes the same', () {
      // The portal re-sorts its tables between fetches. A re-sort is not a
      // change, and alerting on one would cry wolf every time the portal
      // felt like it.
      final listed = const FlexTranscriptParser().parse('''
        <h5>Fall 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>A</td></tr>
          <tr><td>CS2002</td><td>Discrete Structures</td><td>B</td></tr></table>
      ''');
      final resorted = const FlexTranscriptParser().parse('''
        <h5>Fall 7777</h5>
        <table><tr><th>Code</th><th>Course Name</th><th>Grade</th></tr>
          <tr><td>CS2002</td><td>Discrete Structures</td><td>B</td></tr>
          <tr><td>CS2001</td><td>Data Structures</td><td>A</td></tr></table>
      ''');

      expect(transcriptHashes(resorted), transcriptHashes(listed));
    });
  });

  group('a page that did not parse', () {
    test('marks yields null, not an empty map', () {
      // An empty map reads as "this page now lists no courses", which
      // compares against the stored snapshot as every course having
      // vanished. `null` reads as "this fetch told us nothing".
      expect(extractHashes(FlexAlertSources.marks, '<html></html>'), isNull);
    });

    test('transcript yields null, not an empty map', () {
      expect(extractHashes(FlexAlertSources.grades, ''), isNull);
      expect(extractHashes(FlexAlertSources.grades, '<table></table>'), isNull);
    });

    test('challan yields null, not an empty map', () {
      expect(extractHashes(FlexAlertSources.fees, '<html></html>'), isNull);
    });

    test('a sign-in page yields null for every source', () {
      // The session dying mid-poll returns the portal's login page. It must
      // not read as "every mark vanished", or the student gets a
      // notification claiming they have no courses at all.
      const bounced = '<html><body><div id="m_login">Sign in</div></body></html>';
      for (final source in FlexAlertSources.all) {
        expect(extractHashes(source, bounced), isNull,
            reason: '$source must not treat a bounced session as an empty page');
      }
    });

    test('an unknown source yields null rather than throwing', () {
      expect(extractHashes('somethingElse', '<html></html>'), isNull);
    });
  });
}
