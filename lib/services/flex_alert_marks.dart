// Reads the Flex portal's marks page so the alert system can tell a new or
// changed mark from one it has already seen.
//
// The page is one block per course, headed by the course and then split into
// assessments:
//
//     <h5>CS2001-Data Structures (BSE-3C)</h5>
//     <h5>Assignment</h5>
//     <table class="...">
//       <thead><tr><th>Assignment #</th><th>Weightage</th><th>Obtained Marks</th> ...</tr></thead>
//       <tbody>
//         <tr><td>1</td><td>10</td><td>8</td>   ...</tr>
//         <tr><td>2</td><td>10</td><td>9</td>   ...</tr>
//         <tr><td>Total</td><td>20</td><td>17</td> ...</tr>
//       </tbody>
//     </table>
//
// Two facts about this page decide the whole design.
//
// The course's *grand* total is not in the HTML. It prints into a
// `<div class="collapse" id="CS2001-Grand_Total_Marks">` whose `<tbody>`
// arrives empty; the browser fills it from `ftn_calculateMarks()` after
// load. A parser reading the fetched page therefore never sees a grand
// total, and must not invent one — a guess that disagrees with what the
// portal shows is a wrong mark, and a wrong mark is worse than no mark. So
// the grand total is reported absent, and alerts watch what *is*
// server-rendered: the per-assessment totals, which are real numbers that
// move the moment a mark is uploaded.
//
// Every figure is kept under the header it sat under rather than by column
// position, because the portal renames columns between pages — one assessment
// table says "Standard Deviation" where the summary says "Std Dev". Reading
// by label is what survives that.
//
// Nothing here fetches. The page comes in as a String and leaves as typed
// values, so the parser can be tested against a fixture without a session.
import 'flex_alert_hash.dart';

/// One course's marks as the portal reports them.
///
/// The code is kept as the portal spells it (`CS2001`). [assessments] holds
/// the server-rendered figures, keyed by assessment name — `Assignment`,
/// `Quiz`, `Sessional-I` — which is what an alert watches.
class FlexCourseMarks {
  /// The code the portal puts before the name (`CS2001`).
  final String code;

  /// Full name as the portal writes it (`Data Structures`), without the
  /// section the portal appends in brackets.
  final String name;

  /// The section the portal filed it under (`BSE-3C`), or `''`.
  final String section;

  /// The course's grand total, which is **always absent from the fetched
  /// page** — see the file header. Present so a caller can tell "read and
  /// not there" from "not read", but never populated by this parser, and
  /// never guessed at.
  final double? grandTotal;

  /// Every assessment, keyed by its name, holding its labelled figures.
  ///
  /// Keyed by name rather than kept in a list because a course has at most
  /// one table per assessment, and a name is stable where a position is not.
  final Map<String, Map<String, double>> assessments;

  const FlexCourseMarks({
    required this.code,
    required this.name,
    this.section = '',
    this.grandTotal,
    this.assessments = const {},
  });

  /// The marks an alert watches: the weightage and obtained total of each
  /// assessment, as `"<assessment>|weightage=<w>|obtained=<o>"`, sorted so
  /// the order the portal lists them in cannot read as a change.
  ///
  /// Each entry is a `Map` because an assessment's figures are labelled, but
  /// only two of those labels are marks — the rest (average, min, max, class
  /// statistics) describe the cohort and are not the student's own. So they
  /// are named out explicitly rather than hashed wholesale, which would make
  /// a classmate's better day move this student's hash.
  List<String> get watchedFigures {
    final out = <String>[];
    assessments.forEach((name, columns) {
      final weight = _firstLabelled(columns, const [
        'weightage',
        'total weightage',
        'total marks',
        'grand total marks',
      ]);
      final obtained = _firstLabelled(columns, const [
        'obtained marks',
        'obtained',
        'marks obtained',
      ]);
      out.add('$name|weightage=${_num(weight)}|obtained=${_num(obtained)}');
    });
    return out..sort();
  }

  /// The first of [labels] present in [columns], case-insensitively, or
  /// `null` when the table labelled that figure some other way.
  ///
  /// The portal renames columns between pages — "Std Dev" in one table and
  /// "Standard Deviation" in another — so a lookup by a short list of
  /// accepted spellings is what keeps a label change from reading as a mark
  /// change. An unrecognised label stays absent rather than guessed at: a
  /// wrong figure is worse than no figure.
  static double? _firstLabelled(Map<String, double> columns, List<String> labels) {
    for (final label in labels) {
      for (final e in columns.entries) {
        if (e.key.toLowerCase() == label) return e.value;
      }
    }
    return null;
  }

  /// A value that changes exactly when this course's marks change, for
  /// snapshot comparison.
  ///
  /// The name and section are left out on purpose: a course renamed on the
  /// portal, or refiled under a different section spelling, is the same
  /// marks, and either change alone must not raise an alert.
  ///
  /// [stableHash] rather than `Object.hash`: this value is written into a
  /// snapshot and compared on a later poll, across restarts, so it has to
  /// repeat. `Object.hash` is seeded per process and would report a change
  /// on every fetch.
  ///
  /// Nulls fold in as empty so two courses that both lack a figure hash
  /// alike rather than never matching.
  String get contentHash => stableHash([code, ...watchedFigures]);

  static String _num(double? v) => v == null ? '' : v.toStringAsFixed(4);
}

/// The marks page, read into one [FlexMarksPage]'s courses.
class FlexMarksPage {
  final List<FlexCourseMarks> courses;
  const FlexMarksPage(this.courses);

  /// Every course the page listed, by code.
  Map<String, FlexCourseMarks> byCode() => {
        for (final c in courses) c.code: c,
      };

  /// A value that changes when anything on the page changes, for snapshot
  /// comparison.
  ///
  /// The per-course hashes are sorted before being combined, so a course
  /// being *reordered* on the page cannot read as a mark changing. The
  /// portal lists courses in a fixed order today, but that is a presentation
  /// choice and not a promise.
  String get contentHash {
    final perCourse = courses.map((c) => c.contentHash).toList()..sort();
    return stableHash(perCourse);
  }
}

/// Parses the portal's marks page.
///
/// Regex over the HTML rather than a DOM, matching the rest of the codebase
/// (`FlexAttendanceService`, the timetable): the page is server-rendered and
/// stable in the places relied on here, and adding a parser dependency to
/// read four fields is not worth it.
class FlexMarksParser {
  const FlexMarksParser();

  /// A course heading, which reads `CODE-Name (Section)` as plain text
  /// inside an `<h5>`.
  ///
  /// The code is two letters and three or four digits. The fixture's
  /// sanitized codes keep their shape but collapse their digits (`CS2001`
  /// -> `CS7777`), so the shape is matched, never a literal code.
  ///
  /// Assessment headings are deliberately *not* matched here: those `<h5>`s
  /// wrap a `<button>`, so their inner text never reaches this pattern. That
  /// is the whole distinction between a course and an assessment, and it is
  /// why the two are never confused for one another.
  static final _heading = RegExp(
    r'<h5[^>]*>((?:(?!</h5>)[\s\S])*?)</h5>',
    multiLine: true,
  );

  /// A heading naming an assessment.
  ///
  /// The portal prints these as a `<button>` inside the `<h5>` that toggles
  /// the collapse showing that assessment's table, so the name is the
  /// button's inner text — `<h5><button ...>Assignment</button></h5>` — not
  /// the `<h5>`'s own text. Matching the button is what tells an assessment
  /// from a course: a course heading is plain text and carries a `CODE-`
  /// prefix, and never opens with one of these words.
  static final _assessmentHeading = RegExp(
    r'<button[^>]*data-target="#[A-Z]{2}\d{3,4}-([^"]+)"[^>]*>'
    r'([\s\S]*?)</button>',
    multiLine: true,
    caseSensitive: false,
  );

  /// Reads every course the page lists, each with the assessments under it.
  ///
  /// The grand total is looked for and reported absent — see the file
  /// header. It is not read here because it is never in the fetched page.
  FlexMarksPage parse(String html) {
    // Only plain-text headings count as course boundaries. Assessment
    // headings wrap a <button> inside their <h5>, and _heading matches both
    // kinds — so they are filtered out here rather than in the loop below,
    // because a boundary list that still contained an assessment would cut
    // every course's slice at the first assessment instead of the next
    // course, leaving nothing to read.
    final headings = _heading
        .allMatches(html)
        .where((m) => !m.group(1)!.contains('<'))
        .toList();
    if (headings.isEmpty) return const FlexMarksPage([]);

    final out = <FlexCourseMarks>[];
    for (var i = 0; i < headings.length; i++) {
      final m = headings[i];
      final inner = m.group(1)!.trim();

      final head = RegExp(
        r'^([A-Z]{2}\d{3,4})\s*-\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(inner);
      if (head == null) continue;
      final code = head.group(1)!.toUpperCase();

      // The heading's text is `Name (Section)`; the section is split off
      // rather than left in the name, because two courses that differ only
      // by section (`Lab` beside its lecture) must not read as one.
      final body = head.group(2)!.trim();
      final sectionMatch = RegExp(r'\s*\(([^()]*)\)\s*$').firstMatch(body);
      final name = (sectionMatch == null
              ? body
              : body.substring(0, sectionMatch.start))
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (name.isEmpty) continue;
      final section = sectionMatch?.group(1)?.trim() ?? '';

      // This course's assessments run from here to the next course heading.
      final end = i + 1 < headings.length ? headings[i + 1].start : html.length;
      final segment = html.substring(m.end, end);

      out.add(
        FlexCourseMarks(
          code: code,
          name: name,
          section: section,
          assessments: _readAssessments(segment),
        ),
      );
    }
    return FlexMarksPage(out);
  }

  /// The assessments in one course's slice of the page, keyed by name.
  ///
  /// Each assessment is a heading followed by a table. A heading with no
  /// table after it is skipped rather than reported empty: the portal
  /// prints a heading for an assessment that has no marks yet, and "not
  /// uploaded" and "uploaded as nothing" are different answers to an alert.
  Map<String, Map<String, double>> _readAssessments(String segment) {
    final out = <String, Map<String, double>>{};

    for (final m in _assessmentHeading.allMatches(segment)) {
      // The collapse this button toggles holds that assessment's table, so
      // its id is the only reliable way from a heading to a table. A table
      // merely following the heading in the markup could be any course's —
      // the portal interleaves blocks — and pairing them by position is how
      // one course's marks end up under another's name.
      final target = RegExp(
        r'data-target="#([A-Z]{2}\d{3,4}-[^"]+)"',
        caseSensitive: false,
      ).firstMatch(m.group(0)!);
      if (target == null) continue;
      final id = target.group(1)!;

      final key = _assessmentKey(_text(m.group(2)!));
      if (key == null) continue;

      // The block whose id is this target, up to the next block with one.
      final block = _collapseBlock(segment, id);
      if (block == null) continue;

      final figures = _readTotalRow(block);
      if (figures.isEmpty) continue;
      // Two tables under one heading (`Quiz` twice) keep the first: the
      // portal splits a repeated assessment across tables, and summing
      // them would double-count the weightage an alert watches.
      out.putIfAbsent(key, () => figures);
    }
    return out;
  }

  /// The markup of the collapse block whose id is [id], or `null`.
  ///
  /// Opened at `<div ... id="id" ...>` and walked by depth, since the block
  /// nests the table and a non-greedy match would stop at the first `</div>`
  /// and cut the figures off.
  String? _collapseBlock(String segment, String id) {
    final open = RegExp(
      r'<div[^>]*\bid="' + RegExp.escape(id) + r'"[^>]*>',
      caseSensitive: false,
    ).firstMatch(segment);
    if (open == null) return null;

    var depth = 0;
    for (final m in RegExp(r'<div\b|</div>').allMatches(segment, open.start)) {
      if (m[0] == '</div>') {
        depth--;
        if (depth == 0) return segment.substring(open.start, m.end);
      } else {
        depth++;
      }
    }
    return segment.substring(open.start);
  }

  /// Normalises an assessment name to a key, or `null` when the heading is
  /// not one the parser recognises.
  ///
  /// The portal spells the same assessment several ways (`Sessional-I`
  /// beside `Sessional 1`), and a key that drifted with its spelling would
  /// make an unchanged course look changed on every fetch.
  String? _assessmentKey(String name) {
    final t = name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return null;
    if (t.startsWith('quiz')) return 'Quiz';
    if (t.startsWith('assignment')) return 'Assignment';
    if (t.startsWith('lab')) return 'Lab Work';
    if (t.startsWith('viva')) return 'Viva';
    if (t.startsWith('final')) return 'Final';
    if (t.startsWith('midterm')) return 'Midterm';
    if (t.startsWith('presentation')) return 'Presentation';
    if (t.startsWith('project')) return 'Project';
    if (t.startsWith('term')) return 'Term Paper';
    if (t.startsWith('sessional')) {
      // `Sessional-I`, `Sessional 1`, `Sessional-II` -> the numeral.
      final numeral = RegExp(r'([ivx]+|\d+)').firstMatch(t);
      if (numeral == null) return 'Sessional';
      final n = _romanOrDigit(numeral.group(1)!);
      return n == null ? 'Sessional' : 'Sessional-$n';
    }
    return null;
  }

  /// `i` or `1` as an ordinal digit, or `null` when neither reads.
  String? _romanOrDigit(String raw) {
    final t = raw.trim().toLowerCase();
    final asDigit = int.tryParse(t);
    if (asDigit != null) return asDigit.toString();
    const romans = {'i': 1, 'ii': 2, 'iii': 3, 'iv': 4, 'v': 5};
    final v = romans[t];
    return v?.toString();
  }

  /// The `Total` row of one assessment table, as labelled figures.
  ///
  /// The portal ends each assessment table with a total, so the row is found
  /// by its label rather than assumed to be last — a table could grow a
  /// cohort row after it. Figures are read against the header row above, so
  /// a column added or renamed elsewhere in the table does not shift them.
  Map<String, double> _readTotalRow(String table) {
    final header = RegExp(r'<thead[^>]*>([\s\S]*?)</thead>')
        .firstMatch(table)
        ?.group(1);
    if (header == null) return const {};

    final labels = RegExp(r'<th[^>]*>([\s\S]*?)</th>')
        .allMatches(header)
        .map((m) => _text(m.group(1)!))
        .toList();
    if (labels.isEmpty) return const {};

    // Every body row, to find the one labelled Total. The portal writes that
    // label in the first cell, so the row is matched on its own text.
    final rows = RegExp(r'<tr[^>]*>([\s\S]*?)</tr>')
        .allMatches(table)
        .map((m) => m.group(1)!)
        .where((r) => _text(r).toLowerCase().startsWith('total'))
        .toList();
    if (rows.isEmpty) return const {};

    final values = RegExp(r'<td[^>]*>([\s\S]*?)</td>')
        .allMatches(rows.first)
        .map((m) => _text(m.group(1)!))
        .toList();

    final out = <String, double>{};
    for (var i = 0; i < labels.length && i < values.length; i++) {
      final label = labels[i];
      if (label.isEmpty) continue;
      final n = _number(values[i]);
      if (n != null) out[label] = n;
    }
    return out;
  }

  /// The words inside a tag, entities resolved and spacing collapsed.
  String _text(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// A number as the portal writes it, or `null` when there isn't one — a
  /// dash or an empty cell is "no mark", not zero.
  double? _number(String text) {
    final m = RegExp(r'-?\d+(?:\.\d+)?').firstMatch(text);
    if (m == null) return null;
    return double.tryParse(m.group(0)!);
  }
}
