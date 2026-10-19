// Phase 1 — the transcript parser against the sanitized fixture.
//
// The fixture is a real transcript with every value replaced by a same-shape
// placeholder, so these assertions are about *structure*: that the parser
// finds the courses, files each row under the term that preceded it, reads
// the letter grade from the Grade column, and produces hashes that move when
// a grade moves. The specific figures are placeholders and are not asserted
// as themselves.
//
// The transcript is where grades come from. `/Student/GradeReport` refuses
// the session on its own account, so the letter a student wants an alert
// about is read here, which makes this parser the one that has to be right
// about which grade belongs to which course.
import 'dart:io';

import 'package:fast_companion/services/flex_alert_transcript.dart';
import 'package:flutter_test/flutter_test.dart';

final _fixture = File('test/fixtures/flex_transcript.html');

void main() {
  late FlexTranscriptPage page;

  setUpAll(() {
    if (!_fixture.existsSync()) {
      markTestSkipped('transcript fixture not present');
      return;
    }
    page = const FlexTranscriptParser().parse(_fixture.readAsStringSync());
  });

  test('reads every course row the transcript lists', () {
    // The fixture is three semesters: 9, 10 and 8 rows.
    expect(page.courses, hasLength(27));
    for (final c in page.courses) {
      expect(RegExp(r'^[A-Z]{2}\d{3,4}$').hasMatch(c.code), isTrue,
          reason: '${c.code} should look like a course code');
      expect(c.name, isNotEmpty,
          reason: '${c.code} should carry the portal\'s course name');
    }
  });

  test('files each row under the term heading that preceded it', () {
    // The three tables sit under three headings, so the rows come out as
    // three runs — never a table filed under the wrong heading, and never a
    // row with no term at all.
    final runs = <String>[];
    for (final c in page.courses) {
      expect(c.term, isNotEmpty,
          reason: '${c.code} should sit under a term heading');
      if (runs.isEmpty || runs.last != c.term) runs.add(c.term);
    }
    expect(runs, hasLength(3),
        reason: 'three tables should read as three consecutive runs, '
            'got $runs');
  });

  test('reads a letter grade from the Grade column', () {
    for (final c in page.courses) {
      expect(c.grade, isNotNull,
          reason: '${c.code} should have a grade on the transcript');
      expect(
        RegExp(r'^[ABC][+-]?$|^F$|^I$|^W$').hasMatch(c.grade!),
        isTrue,
        reason: '${c.code} grade "${c.grade}" should be a letter grade',
      );
    }
  });

  test('reads credit hours as a number, not as text', () {
    for (final c in page.courses) {
      expect(c.creditHours, isNotNull,
          reason: '${c.code} should carry credit hours');
      expect(c.creditHours!, greaterThan(0));
    }
  });

  test('keeps a re-taken course\'s latest row', () {
    // A course taken twice appears twice, and the transcript's last row for
    // a code is the one that counts — so `byCode()` returns one entry per
    // distinct course even though the page lists more rows than that.
    final distinct = page.courses.map((c) => c.code).toSet();
    expect(distinct.length, lessThan(page.courses.length),
        reason: 'the fixture should re-take at least one course');
    expect(page.byCode().keys, unorderedEquals(distinct));
    for (final entry in page.byCode().entries) {
      expect(entry.value.grade, isNotNull,
          reason: '${entry.key} should keep a grade after collapsing');
    }
  });

  test('hash is a fixed value, not one that moves with the process', () {
    // The snapshot is written now and compared on a later poll, after the
    // app has restarted. `Object.hash` is seeded per process and would
    // return a different number on every run, so a grade would look new on
    // every fetch and the alert would be worthless.
    //
    // This number is what the current code produces, and it is meant to
    // break: if it changes, the hash algorithm changed, and every phone
    // holding a snapshot sees one spurious alert on the next poll.
    expect(page.contentHash, '4643466684441503709');
  });

  test('hash moves when a grade moves', () {
    final c = page.courses.first;
    final remarked = FlexCourseGrade(
      code: c.code,
      name: c.name,
      grade: c.grade == 'B+' ? 'A' : 'B+',
      points: c.points,
      creditHours: c.creditHours,
      term: c.term,
    );
    expect(remarked.contentHash, isNot(c.contentHash),
        reason: 'a grade going up must move the hash');
  });

  test('hashes a course without its name or term', () {
    // A rename, or a row refiled under another heading, is the same grade —
    // and must not raise an alert on its own.
    for (final c in page.courses.take(5)) {
      final renamed = FlexCourseGrade(
        code: c.code,
        name: 'A Completely Different Name',
        grade: c.grade,
        points: c.points,
        creditHours: c.creditHours,
        term: 'Term 7777',
      );
      expect(renamed.contentHash, c.contentHash,
          reason: 'renaming ${c.code} or re-filing it is not a grade change');
    }
  });

  test('two parses of the same page agree', () {
    final again = const FlexTranscriptParser().parse(_fixture.readAsStringSync());
    expect(again.contentHash, page.contentHash);
    expect(again.courses.map((c) => c.contentHash).toList(),
        page.courses.map((c) => c.contentHash).toList());
  });
}
