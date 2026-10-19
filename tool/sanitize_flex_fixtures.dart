// Turns the portal markup pulled off the phone into fixtures the parser
// tests can commit.
//
// The dumps carry the student's name, roll number, fee balance and marks,
// so they cannot go into the repository as they are. This rewrites them by
// *pattern* rather than by listing values: it recognises the shapes the
// portal uses — a name in the topbar, an amount under an Amount column, a
// grade under a Grade column — and replaces what it finds with a
// placeholder of the same shape. A fixture still parses exactly like the
// page it came from while saying nothing about the student.
//
// The real values never leave this process. Every string it replaces is
// held in memory for one purpose afterwards: re-reading the written
// fixtures to prove none of them survived. A leftover fails the run rather
// than waiting to be noticed in review.
//
//   dart run tool/sanitize_flex_fixtures.dart [--src <dir>] [--out <dir>]
//
// Defaults: src = %TEMP%/opencode/flex_dump, out = test/fixtures.
import 'dart:io';

/// What a redacted value becomes.
///
/// Digits become `7` at the same length and grade letters become `B`, so
/// `"18.5"` is still `"77.7"` and `"A+"` is still `"B+"`. The format a
/// parser has to cope with survives; the answer does not.
const _digitFill = '7';
const _gradeFill = 'B';
const _nameFill = '[redacted]';

/// Marks the digits that belong to a word — `SE1001` is a course code and
/// is left exactly as the portal wrote it, while `206500` beside it is not.
const _guard = '\u0001';

/// Columns whose values are the student's own data, matched against the
/// table's own `<th>` text. Written against labels the portal controls
/// rather than column positions that could shift under us.
final _sensitiveColumn = RegExp(
  r'amount|obtained|marks|score|total|average|std|deviation|'
  r'weightage|points|gpa|cgpa|balance|dues|fee|minimum|maximum|'
  r'\bmin\b|\bmax\b',
  caseSensitive: false,
);

/// Columns holding the portal's calendar rather than the student's data.
/// The table rule leaves them alone entirely: rewriting `14` in
/// `14-Aug-2026` would destroy the day, and a fee parser has to read due
/// dates. The year is four digits and does still meet the general sweep
/// below, so a fixture date comes out as `14-Aug-7777` — still a date,
/// still the same day and month, and no closer to the real one.
final _dateColumn = RegExp(
  r'\bdate\b|generated|session|semester|\bsem\b|time|due',
  caseSensitive: false,
);

/// Columns holding a letter grade, where the value is alphabetic and a
/// digit rule would pass straight over it.
final _gradeColumn = RegExp(r'\bgrade\b', caseSensitive: false);

/// `CGPA:3.42`, `Cr. Ernd:110` — summary figures printed as a label and a
/// number with no table round them, so no column rule sees them, and too
/// few digits for the general sweep. Only a number that *ends* its text
/// node counts: `Due: 14-Aug-2026` has a dash after the first number and
/// is a date, and `Step 1:` has the colon in the wrong place.
final _labeledNumber = RegExp(
  r'>(\s*[A-Za-z][A-Za-z.\s]{0,16}:\s*)(\d[\d.]*)(?=\s*<)',
  multiLine: true,
);

/// Dashboard portlets whose contents are the student's record rather than
/// anything the alerts read: roll number, CNIC, address, family. Written
/// as titles because the fields inside are the portal's to add to — the
/// whole block goes instead of playing catch-up with each new one.
const _privatePortlets = {
  'University Information',
  'Personal Information',
  'Contact Information',
  'Family Information',
};

void main(List<String> args) {
  final temp = Platform.environment['TEMP'] ??
      Platform.environment['TMPDIR'] ??
      Directory.systemTemp.path;
  final src = _arg(args, '--src') ??
      '$temp${Platform.pathSeparator}opencode${Platform.pathSeparator}flex_dump';
  final out =
      _arg(args, '--out') ?? 'test${Platform.pathSeparator}fixtures';

  final source = Directory(src);
  if (!source.existsSync()) {
    stderr.writeln('No dumps at $src — run the page dump on the phone first.');
    exitCode = 2;
    return;
  }

  // Stable names: the routes carry a `dump=` token that rotates every
  // session, so naming fixtures after them would churn on every run.
  const wanted = <String, String>{
    '00_home.html': 'flex_home.html',
    '01_student_studentmarks_semid_20263.html': 'flex_marks.html',
    '02_student_transcript_dump_6sk6fbxlt_2feklpggbzf5rg_3d_3d.html':
        'flex_transcript.html',
    '03_student_challan_dump_6sk6fbxlt_2feklpggbzf5rg_3d_3d.html':
        'flex_challan.html',
  };

  Directory(out).createSync(recursive: true);

  var wrote = 0;
  for (final entry in wanted.entries) {
    final file =
        File('${source.path}${Platform.pathSeparator}${entry.key}');
    if (!file.existsSync()) {
      stderr.writeln('missing ${entry.key} — skipping');
      continue;
    }

    final raw = file.readAsStringSync();
    final found = <String>{};
    final html = _sanitize(raw, found);
    File('$out${Platform.pathSeparator}${entry.value}')
        .writeAsStringSync(html);

    // Everything this rewrote must be gone from what was written. Checked
    // against the words a reader sees, not against attributes: `semid=20263`
    // is a semester and a course code is a course, and both are entitled to
    // keep their digits.
    final survivors = _survivors(found, _textOf(html), _textOf(raw));
    if (survivors.isNotEmpty) {
      stderr.writeln('${entry.value}: ${survivors.length} redacted value(s) '
          'still present — refusing to commit it.');
      for (final s in survivors.take(5)) {
        // The name is already `[redacted]` in this markup, so there is
        // nothing of it left to mask here.
        stderr.writeln('   ${_where(html, s, '')}');
      }
      exitCode = 1;
      return;
    }

    wrote++;
    stdout.writeln('${entry.value}  <- ${entry.key}  '
        '(${found.length} values redacted, all verified gone)');
  }

  if (wrote == 0) {
    stderr.writeln('Nothing to write — no dumps matched.');
    exitCode = 2;
  }
}

/// One file's worth of redaction. [found] collects every original so it can
/// be checked for afterwards.
String _sanitize(String html, Set<String> found) {
  var out = html;

  // The student's name, in the topbar of every portal page. Take it from
  // there and strike it *everywhere* — the dashboard also prints it in a
  // profile card, and a rule written per occurrence would have to be
  // rewritten each time the portal finds a new place for it.
  final nameMatch =
      RegExp(r'<span class="m-link">([^<]*)</span>', multiLine: true)
          .firstMatch(out);
  final name = nameMatch?.group(1)?.trim() ?? '';
  if (name.length >= 3) {
    found.add(name);
    out = out.replaceAll(name, _nameFill);
  }

  // The dashboard prints the student's record — roll number, CNIC,
  // address, family — in portlets of its own. None of it is read later,
  // and a rule per field would be chasing a portal that adds fields, so
  // the text of those portlets goes wholesale and the markup stays.
  out = _redactPortlets(out, found);

  // The marks page prints each course's grand total under an element named
  // after that course, outside any table, so no column rule ever sees it.
  out = out.replaceAllMapped(
    RegExp(r'(id="[^"]*Grand[ _]Total[ _]Marks[^"]*"[^>]*>)([^<]*)(<)'),
    (m) => '${m[1]}${_redactDigits(m[2]!, 1, found)}${m[3]}',
  );

  // Tables: read their own headers, then redact by what the labels say.
  out = out.replaceAllMapped(
    RegExp(r'<table\b[^>]*>.*?</table>', multiLine: true, dotAll: true),
    (m) => _table(m[0]!, found),
  );

  // The transcript prints the roll number as `22I-1234`, and the sweep at
  // the end only sees half of it: the trailing digits meet the four-digit
  // minimum, but the admission-year prefix does not. Matching the shape
  // whole closes that. Dates slip past it — `14-Aug-2026` has lowercase
  // letters where the pattern wants an ending — and course codes never
  // reach it, since they put their letters first.
  out = out.replaceAllMapped(
    RegExp(r'\b\d{1,3}[A-Z]{1,2}-\d{2,6}\b'),
    (m) {
      found.add(m[0]!);
      return _redactDigits(m[0]!, 1, found);
    },
  );

  // `CGPA:3.42` and `Cr. Ernd:110` — a label and a number, with no column
  // heading to sit under and too few digits for the sweep below.
  out = out.replaceAllMapped(
    _labeledNumber,
    (m) => '>${m[1]}${_redactDigits(m[2]!, 1, found)}',
  );

  // Whatever else the portal prints as a number — a balance in a card, a
  // roll number in the header. Four digits or more, and never digits glued
  // to a word, so course codes come through untouched.
  return _redactDigits(out, 4, found);
}

/// Redacts every text node inside the named portlets, walking each one by
/// div depth so nested panels are included and the next portlet is not.
String _redactPortlets(String html, Set<String> found) {
  final starts = RegExp(r'<div\b[^>]*\bclass="[^"]*\bm-portlet\b[^"]*"')
      .allMatches(html)
      .toList();

  // Back to front: taking text out shortens the document, and earlier
  // offsets must stay valid while later ones are rewritten.
  for (var i = starts.length - 1; i >= 0; i--) {
    final from = starts[i].start;
    final title = RegExp(
      r'<h3 class="m-portlet__head-text"[^>]*>(.*?)</h3>',
      multiLine: true,
      dotAll: true,
    ).firstMatch(html.substring(from, from + 4000));
    if (title == null) continue;
    final heading = _textOf(title[1]!).replaceAll(RegExp(r'\s+'), ' ').trim();
    if (!_privatePortlets.contains(heading)) continue;

    final end = _portletEnd(html, from);
    final block = html.substring(from, end).replaceAllMapped(
          RegExp(r'>([^<]+)<'),
          (m) {
            final value = m[1]!.trim();
            // The name may already be a placeholder from the rule above;
            // booking it as an original would fail its own check.
            if (value.isEmpty || value == _nameFill) return m[0]!;
            // Only values that look like data are worth checking for
            // elsewhere. A short word such as `Gender` is a label, and if
            // the portal repeats it outside these portlets that is not a
            // leak — but booking it would fail the run anyway.
            if (value.contains(RegExp(r'\d')) || value.length >= 13) {
              found.add(value);
            }
            return '>[redacted]<';
          },
        );
    html = html.substring(0, from) + block + html.substring(end);
  }

  return html;
}

/// Where the portlet opened at [from] closes — counted by div depth, since
/// a non-greedy match would stop at the first nested `</div>`.
int _portletEnd(String html, int from) {
  var depth = 0;
  for (final m in RegExp(r'<div\b|</div>').allMatches(html, from)) {
    if (m[0] == '</div>') {
      depth--;
      if (depth == 0) return m.end;
    } else {
      depth++;
    }
  }
  return html.length;
}

/// Redacts a table row by row, so each cell is read against the `<th>` in
/// its own column.
String _table(String table, Set<String> found) {
  final head = RegExp(r'<th\b[^>]*>(.*?)</th>', multiLine: true, dotAll: true)
      .allMatches(table)
      .map((m) => _textOf(m[1]!))
      .toList();

  return table.replaceAllMapped(
    RegExp(r'<tr\b[^>]*>.*?</tr>', multiLine: true, dotAll: true),
    (row) {
      var column = -1;
      return row[0]!.replaceAllMapped(
        RegExp(r'(<td\b[^>]*>)(.*?)(</td>)', multiLine: true, dotAll: true),
        (cell) {
          column++;
          final header = column < head.length ? head[column] : '';
          if (_dateColumn.hasMatch(header)) return cell[0]!;

          var value = cell[2]!;
          if (_sensitiveColumn.hasMatch(header)) {
            value = _redactDigits(value, 1, found);
          }
          if (_gradeColumn.hasMatch(header)) {
            value = _redactLetters(value, found);
          }
          return '${cell[1]}$value${cell[3]}';
        },
      );
    },
  );
}

/// Replaces every digit run of at least [min] digits with the same number of
/// fill digits. Digits attached to a word are shielded first, which is what
/// keeps course codes intact while the amount beside them is rewritten.
String _redactDigits(String input, int min, Set<String> found) {
  final buf = StringBuffer();
  var last = 0;
  for (final m in RegExp(r'[A-Za-z]+[0-9]+').allMatches(input)) {
    buf
      ..write(input.substring(last, m.start))
      ..write(_guard)
      ..write(m[0])
      ..write(_guard);
    last = m.end;
  }
  buf.write(input.substring(last));

  final out = buf.toString().replaceAllMapped(
        RegExp('\\d{$min,}'),
        (m) {
          found.add(m[0]!);
          return _digitFill * m[0]!.length;
        },
      );
  return out.replaceAll(_guard, '');
}

/// Replaces the letters in a grade cell, keeping the punctuation a parser
/// reads alongside them: `A+` becomes `B+`, `I` becomes `B`.
String _redactLetters(String input, Set<String> found) {
  if (!RegExp(r'[A-Za-z]').hasMatch(input)) return input;
  found.add(input.trim());
  return input.replaceAllMapped(RegExp(r'[A-Za-z]'), (_) => _gradeFill);
}

/// The words a page actually shows, with tags and scripts stripped — the
/// surface a redaction check has to be clean on.
String _textOf(String html) {
  final withoutScript = html.replaceAll(
    RegExp(r'<(script|style)\b[^>]*>.*?</\1>', multiLine: true, dotAll: true),
    '',
  );
  return withoutScript.replaceAll(RegExp(r'<[^>]*>'), ' ');
}

/// What, if anything, got through.
///
/// Two kinds have to be told apart. A real leftover is a string the page
/// had and the fixture still has — that is a rule missing. But the passes
/// overlap: the global one walks over digits the table pass has already
/// rewritten, meets the placeholder it left behind and books *that* as an
/// original. A run of the fill digit is only a leak if the untouched page
/// also carried that exact string, which is also the one value this tool
/// cannot redact — `77777` and a placeholder of `77777` are the same bytes.
List<String> _survivors(Set<String> found, String written, String original) {
  final out = <String>{};

  for (final s in found) {
    if (s.length < 4 || _isFill(s)) continue;
    if (written.contains(s)) out.add(s);
  }

  final fill = RegExp('${RegExp.escape(_digitFill)}{4,}');
  for (final m in fill.allMatches(written)) {
    final before = m.start > 0 ? written[m.start - 1] : null;
    final after = m.end < written.length ? written[m.end] : null;
    // `SE7777` is a course code: shielded from redaction by design, so its
    // digits are not a value that was ever meant to change.
    if (before != null && _isLetter(before)) continue;
    if (after != null && _isLetter(after)) continue;
    if (original.contains(m[0]!)) out.add(m[0]!);
  }

  return out.toList();
}

bool _isFill(String s) =>
    RegExp('^${RegExp.escape(_digitFill)}+\$').hasMatch(s);

bool _isLetter(String c) =>
    (c.codeUnitAt(0) >= 65 && c.codeUnitAt(0) <= 90) ||
    (c.codeUnitAt(0) >= 97 && c.codeUnitAt(0) <= 122);

/// Where a leftover sits, described structurally: the element around it,
/// a window of context with **every digit masked**, and the shape of the
/// text. Enough to see which rule is missing without letting a value out.
String _where(String html, String value, String name) {
  final i = html.indexOf(value);
  if (i < 0) return 'not visible in the markup';

  final tags = RegExp(r'<([A-Za-z0-9]+)((?:[^>"]|"[^"]*")*)>')
      .allMatches(html.substring(0, i))
      .toList();
  final Match? tag = tags.isEmpty ? null : tags.last;
  final attrs = tag?.group(2) ?? '';
  final id = RegExp(r'\bid="([^"]*)"').firstMatch(attrs)?.group(1);
  final cls = RegExp(r'\bclass="([^"]*)"').firstMatch(attrs)?.group(1);
  final digits = RegExp(r'\d').allMatches(value).length;
  final letters = RegExp(r'[A-Za-z]').allMatches(value).length;

  return '<${tag?.group(1) ?? '?'}'
      '${id == null ? '' : ' id=$id'}'
      '${cls == null ? '' : ' class=${_clip(cls, 44)}'}>  '
      '${value.length} chars, $digits digits, $letters letters\n'
      '      ${_maskedContext(html, value, name, i)}';
}

/// The surroundings of a leftover with every digit replaced by `#` and the
/// student's name replaced too — `semid=«V»` and `Roll No «V»` are very
/// different problems, and only one of them needs a rule.
String _maskedContext(String html, String value, String name, int at) {
  final from = at > 90 ? at - 90 : 0;
  final to = (at + value.length + 70).clamp(0, html.length);
  var ctx = html.substring(from, to).replaceAll(value, '«V»');
  if (name.isNotEmpty) ctx = ctx.replaceAll(name, '[name]');
  ctx = ctx.replaceAll(RegExp(r'\d'), '#');
  return ctx.replaceAll(RegExp(r'\s+'), ' ').trim();
}

String _clip(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';

String? _arg(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}
