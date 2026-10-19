// Turns a parsed page into the hashes the snapshot compares.
//
// The parsers know how to read a page; this knows what to keep from it. The
// rule is one hash per *thing an alert can name* — a course for marks and
// grades, a challan for fees — rather than one for the whole page. A
// page-level hash can only say "the marks page differs", which makes a
// notification nobody can act on; per-course hashes say *which* course
// moved, which is the reason a student reads the alert at all.
//
// Nothing here fetches or stores. A page comes in as a String and a map of
// hashes leaves, so the whole path from markup to alert can be tested
// against a fixture without a session, a device or a network.
import 'flex_alert_challan.dart';
import 'flex_alert_hash.dart';
import 'flex_alert_marks.dart';
import 'flex_alert_transcript.dart';

/// The three pages an alert watches, and the name each is filed under in
/// the snapshot.
///
/// Names rather than an enum because they are what the stored snapshot is
/// keyed by, and a name that survives being written to disk and read back
/// is one less thing to keep in step.
abstract final class FlexAlertSources {
  /// StudentMarks — the per-assessment totals a mark upload moves.
  static const String marks = 'marks';

  /// The transcript — the letter grade awarded per course.
  static const String grades = 'grades';

  /// The challan page — what is owed, and what has been paid.
  static const String fees = 'fees';

  /// Every source, in the order an alert lists them.
  static const List<String> all = [marks, grades, fees];
}

/// The marks page as the snapshot wants it: course code to a hash of every
/// row the portal listed under that code.
///
/// Grouped rather than keyed one-to-one, because a code is not unique on
/// this page. The portal lists a re-taken course more than once, and the
/// sanitizer collapses `CS2001` and `CS2002` into one shape, so two
/// genuinely different courses can share a code. Keying one-to-one would
/// drop one of them — and a mark uploaded to a dropped course would never
/// be noticed, which is the exact failure this alert exists to prevent.
///
/// The rows are hashed in the order the page listed them, so the key is
/// stable while the value still moves when any row under it changes.
Map<String, String> marksHashes(FlexMarksPage page) => _grouped(
      page.courses.map((c) => (c.code, c.contentHash)),
    );

/// The transcript as the snapshot wants it: course code to a hash of every
/// row recorded under that code.
///
/// Grouped for the same reason as [marksHashes]: a re-taken course appears
/// once per attempt, so the code is a label for a set of rows rather than a
/// unique key. An improvement on a second attempt moves the hash, which is
/// what a student wants to hear about.
Map<String, String> transcriptHashes(FlexTranscriptPage page) => _grouped(
      page.courses.map((c) => (c.code, c.contentHash)),
    );

/// Hashes every row under its code, in the order they were listed.
///
/// The per-row hashes are combined with [stableHash] rather than summed, so
/// that two pages listing the same rows in a different order hash alike —
/// the portal re-sorts its tables between fetches, and a re-sort is not a
/// change.
Map<String, String> _grouped(Iterable<(String, String)> rows) {
  final byCode = <String, List<String>>{};
  for (final (code, hash) in rows) {
    byCode.putIfAbsent(code, () => []).add(hash);
  }
  return {
    for (final e in byCode.entries)
      e.key: stableHash(e.value..sort()),
  };
}

/// The challan page as the snapshot wants it: challan serial to row hash.
///
/// Keyed by serial rather than by position, because the portal reorders its
/// list between fetches — and a serial that moved is itself a change worth
/// reporting, so it belongs in the key and not hidden from it.
Map<String, String> challanHashes(FlexChallanPage page) => {
      for (var i = 0; i < page.rows.length; i++)
        // A row with no serial still has to be keyed by something stable,
        // so its position stands in — the portal always prints one, and the
        // fallback keeps a malformed row from vanishing out of the
        // comparison entirely.
        (page.rows[i].serial?.toString() ?? '#$i'): page.rows[i].contentHash,
    };

/// Parses [html] and returns the hashes an alert watches, or `null` when
/// the page carried nothing recognisable.
///
/// `null` rather than an empty map, and the difference matters: an empty
/// map would read as "this source now lists no courses", which compares
/// against the stored snapshot as every course having vanished and fires a
/// notification. `null` reads as "this fetch told us nothing", which leaves
/// the stored hashes alone. A page that fails to parse must never look like
/// a page that legitimately emptied.
///
/// [source] is one of [FlexAlertSources]; an unknown name yields `null`
/// rather than throwing, so a caller that misnames a source degrades to
/// silence instead of a crash.
Map<String, String>? extractHashes(String source, String html) {
  switch (source) {
    case FlexAlertSources.marks:
      final page = const FlexMarksParser().parse(html);
      if (page.courses.isEmpty) return null;
      return marksHashes(page);
    case FlexAlertSources.grades:
      final page = const FlexTranscriptParser().parse(html);
      if (page.courses.isEmpty) return null;
      return transcriptHashes(page);
    case FlexAlertSources.fees:
      final page = const FlexChallanParser().parse(html);
      if (page.rows.isEmpty) return null;
      return challanHashes(page);
    default:
      return null;
  }
}
