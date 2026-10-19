// TEMPORARY — Phase 0 diagnostic. Runs the dump's link scanner against the
// real dashboard HTML pulled off the phone, to tell a regex miss from a
// failed fetch. Delete with the rest of the dump tooling.
import 'dart:io';

import 'package:fast_companion/services/flex_page_dump.dart';
import 'package:flutter_test/flutter_test.dart';

const _home = r'C:\Users\mahad\AppData\Local\Temp\opencode\flex_dump\00_home.html';

void main() {
  test('link scan over the real dashboard', () {
    final file = File(_home);
    if (!file.existsSync()) {
      markTestSkipped('dashboard dump not present');
      return;
    }

    final links = FlexPageDump.interestingLinks(file.readAsStringSync());

    // The dashboard advertises these and the dump is meant to fetch them.
    expect(links.any((l) => l.contains('StudentMarks')), isTrue);
    expect(links.any((l) => l.contains('Challan')), isTrue);
    expect(
      links.any((l) => l.toLowerCase().contains('gradereport')),
      isTrue,
      reason: 'Grade Report has to be found - it is the grades page',
    );
    expect(
      links.any((l) => l.toLowerCase().contains('consolidated')),
      isTrue,
      reason: 'Fee Details has to be found - it is the consolidated fees page',
    );

    // A session is worth five requests, so what leads the queue is the
    // whole value of the run. The pages the parsers have never seen go
    // first; fees follows now that its markup is already on disk.
    final ordered = FlexPageDump.ordered(links);
    expect(
      ordered.take(3).any((l) => l.contains('StudentMarks')),
      isTrue,
      reason: 'marks take the first slot',
    );
    expect(
      ordered.take(3).any((l) => l.toLowerCase().contains('transcript')),
      isTrue,
      reason: 'the transcript carries grades and sits second',
    );
    expect(
      ordered.take(3).any((l) => l.toLowerCase().contains('challan')),
      isTrue,
      reason: 'fees take the third',
    );

    // GradeReport has been refused from both positions it was tried
    // from while pages behind it still came back, so it is that page
    // and not the session. Two attempts are spent on it either way —
    // they must not be spent at the front.
    final gradeIndex = ordered.indexWhere(
      (l) => l.toLowerCase().contains('gradereport'),
    );
    if (gradeIndex >= 0) {
      expect(
        gradeIndex,
        greaterThanOrEqualTo(3),
        reason: 'GradeReport must not spend a front slot',
      );
    }
  });
}
