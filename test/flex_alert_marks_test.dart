// Phase 1 — the marks parser against the sanitized fixture.
//
// The fixture is a real marks page with every value replaced by a same-shape
// placeholder, so these assertions are about *structure*: that the parser
// finds the courses, reads the per-assessment totals, and produces hashes
// that move when a mark moves. The specific figures are placeholders and are
// not asserted as themselves.
//
// One assertion is about absence rather than structure: the grand total is
// not in the fetched HTML at all — the browser fills it after load — so the
// parser must report it absent rather than invent one. That is the difference
// between "we don't know" and "we guessed", and a guessed mark is worse than
// none.
import 'dart:io';

import 'package:fast_companion/services/flex_alert_marks.dart';
import 'package:flutter_test/flutter_test.dart';

final _fixture = File('test/fixtures/flex_marks.html');

void main() {
  late FlexMarksPage page;

  setUpAll(() {
    if (!_fixture.existsSync()) {
      markTestSkipped('marks fixture not present');
      return;
    }
    page = const FlexMarksParser().parse(_fixture.readAsStringSync());
  });

  test('reads every course the page lists', () {
    // The fixture is one semester: eight courses, each under its own heading.
    expect(page.courses, hasLength(8));
    // The sanitizer keeps a code's shape but collapses its digits, so match
    // on the codes as they actually spell in the fixture.
    for (final c in page.courses) {
      expect(RegExp(r'^[A-Z]{2}\d{3,4}$').hasMatch(c.code), isTrue,
          reason: '${c.code} should look like a course code');
    }
  });

  test('keeps two courses that share a code apart', () {
    // The sanitizer collapses a code's digits, so the two `SS2xxx` courses
    // in the fixture both read `SS7777`. They are still two courses with
    // two different names, and merging them would drop one — so the list
    // carries both even though a code is no longer unique here.
    final shared = page.courses.where((c) => c.code == 'SS7777');
    expect(shared, hasLength(2),
        reason: 'two distinct courses collapsed to one code must stay two');
    expect(
      shared.map((c) => c.name).toSet(),
      hasLength(2),
      reason: 'they should still be told apart by name',
    );
  });

  test('pairs each code with its name and section, not its neighbour', () {
    final courses = page.courses;
    for (final c in courses) {
      expect(c.name, isNotEmpty, reason: '${c.code} should have a name');
      expect(c.name, isNot(contains('(')),
          reason: '${c.code} name should not carry the section bracket');
      expect(c.section, isNotEmpty,
          reason: '${c.code} should carry the portal\'s section');
    }
    // A lecture and its lab are separate courses, not one wearing a name.
    final lecture = courses.where((c) => !c.name.toLowerCase().contains('lab'));
    final lab = courses.where((c) => c.name.toLowerCase().contains('lab'));
    expect(lecture, isNotEmpty);
    expect(lab, isNotEmpty);
  });

  test('reads the per-assessment totals, which is what alerts watch', () {
    for (final c in page.courses) {
      expect(c.assessments, isNotEmpty,
          reason: '${c.code} should have at least one assessment');
      for (final entry in c.assessments.entries) {
        expect(entry.value, isNotEmpty,
            reason: '${c.code}/${entry.key} should carry labelled figures');
      }
    }
    // A lecture carries its assignments, quizzes and sessionals; a lab
    // carries lab work. The fixture has both, so both are read.
    final lecture = page.courses
        .firstWhere((c) => !c.name.toLowerCase().contains('lab'));
    expect(lecture.assessments.keys, containsAll(['Assignment', 'Quiz']));
    final lab =
        page.courses.firstWhere((c) => c.name.toLowerCase().contains('lab'));
    expect(lab.assessments.keys, contains('Lab Work'));
  });

  test('reports the grand total as absent, never guessed', () {
    for (final c in page.courses) {
      expect(c.grandTotal, isNull,
          reason: '${c.code} grand total is filled by the browser, so the '
              'fetched page cannot carry it and the parser must not invent it');
    }
  });

  test('reads the obtained total of an assessment that has one', () {
    // Every assessment table ends in a Total row, so at least one course's
    // most common assessment should carry both figures.
    final withObtained = page.courses
        .expand((c) => c.watchedFigures)
        .where((f) => !f.endsWith('obtained='));
    expect(withObtained, isNotEmpty,
        reason: 'a Total row should yield an obtained figure');
  });

  test('hash is a fixed value, not one that moves with the process', () {
    // The snapshot is written now and compared on a later poll, after the
    // app has restarted. `Object.hash` is seeded per process and would
    // return a different number here on every run, so this page would read
    // as changed on every fetch and the alert would be useless.
    //
    // This number is what the current code produces, and it is meant to
    // break: if it changes, the hash algorithm changed, and every phone
    // holding a snapshot will see one spurious alert on the next poll. That
    // is worth knowing before shipping — re-baseline deliberately rather
    // than by accident.
    expect(page.contentHash, '6054333133821526423');
  });

  test('hash is non-negative, so it stores as a plain number', () {
    // Dart's int is signed, so a hash that used all 64 bits would print
    // negative and need signing-aware storage for no benefit.
    expect(int.parse(page.contentHash), greaterThanOrEqualTo(0));
  });

  test('hashes a course without its name or section', () {
    for (final c in page.courses) {
      final renamed = FlexCourseMarks(
        code: c.code,
        name: 'A Completely Different Name',
        section: 'ZZ-9Z',
        grandTotal: c.grandTotal,
        assessments: c.assessments,
      );
      expect(renamed.contentHash, c.contentHash,
          reason: 'renaming ${c.code} or refiled it is not a mark change');
    }
  });

  test('hash moves when an assessment total moves', () {
    final c = page.courses.first;
    final key = c.assessments.keys.first;
    final moved = Map<String, Map<String, double>>.from(c.assessments);
    moved[key] = Map<String, double>.from(c.assessments[key]!)
      ..['Obtained Marks'] = (c.assessments[key]!['Obtained Marks'] ?? 0) + 1.5;

    final remarked = FlexCourseMarks(
      code: c.code,
      name: c.name,
      section: c.section,
      assessments: moved,
    );
    expect(remarked.contentHash, isNot(c.contentHash),
        reason: 'a mark going up must move the hash');
  });

  test('two parses of the same page agree', () {
    final again = const FlexMarksParser().parse(_fixture.readAsStringSync());
    expect(again.contentHash, page.contentHash);
    expect(again.courses.map((c) => c.contentHash).toList(),
        page.courses.map((c) => c.contentHash).toList());
  });
}
