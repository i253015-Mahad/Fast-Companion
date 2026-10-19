// Reads the Flex portal's transcript so the alert system can tell a new or
// changed letter grade from one it has already seen.
//
// The transcript lists every course the student has taken, grouped by
// semester, each row carrying its code, name, credit hours and the grade it
// was awarded:
//
//     <tr>
//       <td>CL1001</td>
//       <td>Introduction to Information and Communication Technology</td>
//       <td>BSE-3C</td>
//       <td class="text-center">3</td>
//       <td class="text-center">B-</td>   <- grade, by position
//       <td class="text-center">2.70</td> <- points
//       <td>Core</td>
//       <td></td>
//     </tr>
//
// Unlike the marks page, this table has no per-cell class names to hang a
// rule on — the grade is simply the fifth cell — so the parser reads it by
// the header row above it, matching "Grade" and "Points" to their columns.
// That keeps working when the portal inserts a column, which it does more
// often than it renames one.
//
// Nothing here fetches. The page comes in as a String and leaves as typed
// values, so the parser can be tested against a fixture without a session.
import 'flex_alert_hash.dart';

/// One course's grade as the transcript records it.
class FlexCourseGrade {
  /// The code the portal puts before the name (`CL1001`).
  final String code;

  /// Full name as the portal writes it.
  final String name;

  /// Letter grade (`B-`), or `null` when the cell was empty — a course
  /// still in progress has no grade yet, and that is not the same as a fail.
  final String? grade;

  /// Grade points, when the transcript prints them beside the letter.
  final double? points;

  /// Credit hours the course carries.
  final double? creditHours;

  /// Which semester this row sat under, as the portal heading spells it
  /// (`Fall 2024`); empty when no heading preceded it.
  final String term;

  const FlexCourseGrade({
    required this.code,
    required this.name,
    this.grade,
    this.points,
    this.creditHours,
    this.term = '',
  });

  /// A value that changes exactly when this course's grade changes, for
  /// snapshot comparison. The name and term are left out: a course renamed
  /// or refiled under another heading is the same grade, and moving alone
  /// must not raise an alert.
  ///
  /// [stableHash] rather than `Object.hash`: this value is written into a
  /// snapshot and compared on a later poll, across restarts, so it has to
  /// repeat. `Object.hash` is seeded per process and would report a change
  /// on every fetch.
  ///
  /// Nulls fold in as empty so two courses that both lack a grade hash
  /// alike rather than never matching.
  String get contentHash => stableHash([
        code,
        grade ?? '',
        points == null ? '' : points!.toStringAsFixed(2),
        creditHours == null ? '' : creditHours!.toStringAsFixed(2),
      ]);
}

/// The transcript, read into one [FlexCourseGrade] per course row.
class FlexTranscriptPage {
  final List<FlexCourseGrade> courses;
  const FlexTranscriptPage(this.courses);

  /// Every course the transcript listed, by code. A course taken twice
  /// (`Repeat` type) keeps its latest row, which is the one a student reads.
  Map<String, FlexCourseGrade> byCode() {
    final out = <String, FlexCourseGrade>{};
    for (final c in courses) {
      out[c.code] = c;
    }
    return out;
  }

  /// A value that changes when any grade on the transcript changes, for
  /// snapshot comparison.
  ///
  /// The per-course hashes are sorted before being combined, so a row being
  /// *reordered* — the portal re-sorts the transcript when a term closes —
  /// cannot read as a grade changing. Only a grade moving is a change.
  String get contentHash {
    final perCourse = courses.map((c) => c.contentHash).toList()..sort();
    return stableHash(perCourse);
  }
}

/// Parses the portal's transcript.
///
/// Regex over the HTML rather than a DOM, matching the rest of the codebase
/// (`FlexAttendanceService`, the timetable): the page is server-rendered and
/// stable in the places relied on here, and adding a parser dependency to
/// read four fields is not worth it.
class FlexTranscriptParser {
  const FlexTranscriptParser();

  /// A semester heading, which the portal prints between the tables.
  static final _term = RegExp(
    r'<(?:h[1-6]|strong|b|span)[^>]*>\s*((?:Fall|Spring|Summer)\s*\d{4})',
    caseSensitive: false,
  );

  /// A table that carries a `Code` header, which is a transcript table. The
  /// closing tag is matched non-greedily: these tables do not nest.
  static final _table = RegExp(
    r'<table[^>]*>[\s\S]*?</table>',
    multiLine: true,
  );

  /// The header labels, in order, from a table's first row.
  static final _headerCells = RegExp(r'<th[^>]*>([\s\S]*?)</th>');

  /// A course row: eight cells, starting with the code.
  static final _dataCells = RegExp(r'<td[^>]*>([\s\S]*?)</td>');

  /// Reads every course the transcript lists.
  FlexTranscriptPage parse(String html) {
    final out = <FlexCourseGrade>[];

    // Term headings and tables are located independently, then walked in
    // document order so each table lands under the heading that preceded
    // it — the same alternation the marks page uses for its courses.
    final terms = [
      for (final m in _term.allMatches(html))
        (m.start, m.group(1)!.replaceAll(RegExp(r'\s+'), ' ').trim()),
    ];
    final tables = _table.allMatches(html).toList();

    var term = '';
    var next = 0;
    for (final table in tables) {
      while (next < terms.length && terms[next].$1 < table.start) {
        term = terms[next].$2;
        next++;
      }
      out.addAll(_readTable(table.group(0)!, term));
    }

    return FlexTranscriptPage(out);
  }

  /// The course rows of one table, read against that table's own headers.
  List<FlexCourseGrade> _readTable(String table, String term) {
    // Which column each label sits in, so the grade is found by name.
    final headers = _headerCells
        .allMatches(table)
        .map((m) => _text(m.group(1)!))
        .where((t) => t.isNotEmpty)
        .toList();
    if (headers.isEmpty) return const [];

    int column(String label) {
      for (var i = 0; i < headers.length; i++) {
        if (headers[i].toLowerCase() == label) return i;
      }
      return -1;
    }

    final codeCol = column('code');
    final nameCol = column('course name');
    final gradeCol = column('grade');
    final pointsCol = column('points');
    final crdCol = column('crdhrs');
    if (codeCol < 0) return const [];

    final out = <FlexCourseGrade>[];
    for (final row in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(table)) {
      final cells = _dataCells
          .allMatches(row.group(1)!)
          .map((m) => _text(m.group(1)!))
          .toList();
      if (cells.isEmpty) continue;

      final code = _code(cells[codeCol]);
      if (code == null) continue;

      out.add(
        FlexCourseGrade(
          code: code,
          name: nameCol >= 0 && nameCol < cells.length ? cells[nameCol] : '',
          grade: gradeCol >= 0 && gradeCol < cells.length
              ? _grade(cells[gradeCol])
              : null,
          points: pointsCol >= 0 && pointsCol < cells.length
              ? _number(cells[pointsCol])
              : null,
          creditHours: crdCol >= 0 && crdCol < cells.length
              ? _number(cells[crdCol])
              : null,
          term: term,
        ),
      );
    }
    return out;
  }

  /// A course code, or `null` when the cell holds something else — the
  /// header row and any stray label are skipped rather than mis-read.
  String? _code(String text) {
    final m = RegExp(r'^([A-Z]{2}\d{3,4})$').firstMatch(text.trim());
    return m?.group(1);
  }

  /// A letter grade (`B-`, `A+`), or `null` when the cell is empty or holds
  /// something that is not a grade — a course still in progress has no
  /// grade yet, and that is not a fail.
  String? _grade(String text) {
    final t = text.trim().toUpperCase();
    if (t.isEmpty) return null;
    final m = RegExp(r'^([ABC][+-]?|F|I|W|D?)$').firstMatch(t);
    return m?.group(1);
  }

  /// The words inside a tag, entities resolved and spacing collapsed.
  String _text(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// A number as the portal writes it, or `null` when there isn't one.
  double? _number(String text) {
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(text);
    if (m == null) return null;
    return double.tryParse(m.group(0)!);
  }
}
