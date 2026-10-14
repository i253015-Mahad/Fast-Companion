// lib/services/flex_attendance_service.dart

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timetable_entry.dart';
import 'flex_session_service.dart';

/// One course's attendance as the Flex portal reports it.
class FlexCourseAttendance {
  /// The code the portal puts before the name (`CS2001`).
  final String code;

  /// Full name as the portal writes it (`Data Structures`).
  final String name;

  /// Section the portal filed it under (`BSE-3C`).
  ///
  /// Kept for display and to tell a lecture from its lab, but never used
  /// to pick a timetable section: the portal says `BSE-3C`, the dashboard
  /// says `BSE-253C` and the timetable says `SE-A`, and guessing the
  /// relationship would put a ring on the wrong rows.
  final String section;

  /// Attended percentage, 0-100.
  final double percent;

  const FlexCourseAttendance({
    required this.code,
    required this.name,
    required this.section,
    required this.percent,
  });

  /// Whether the portal filed this as a lab, which is how a course like
  /// `Data St` (matches both) is told apart from `Data St Lab`.
  bool get isLab => RegExp(r'\blab\b', caseSensitive: false).hasMatch(name);

  Map<String, dynamic> toJson() => {
    'code': code,
    'name': name,
    'section': section,
    'percent': percent,
  };

  factory FlexCourseAttendance.fromJson(Map<String, dynamic> json) =>
      FlexCourseAttendance(
        code: json['code'] as String? ?? '',
        name: json['name'] as String? ?? '',
        section: json['section'] as String? ?? '',
        percent: (json['percent'] as num?)?.toDouble() ?? 0,
      );
}

/// The student's own section, resolved against the timetable.
///
/// The portal and the sheet don't share a section vocabulary: the portal
/// files the student under `BSE-3C`, the dashboard under `BSE-253C`, and
/// the timetable writes `SE-C` — on engineering sheets sometimes just
/// `A`. So the gate keeps only what can be checked on both sides: which
/// department, which section letter, and which intake. A ring is painted
/// on a row only when all three hold, because `SE-C` on its own is not
/// the student — the sheet runs an `SE-C` in three different intakes at
/// once (2024 takes Algo, 2026 takes PF, only 2025 takes COAL).
///
/// The portal's digits are read past, never decoded: whether the `3` of
/// `BSE-3C` is a semester or an intake index is not something the page
/// says, and guessing would put rings on another year's classes. The
/// batch is instead settled from the sheet's own course loads, by
/// [FlexAttendanceService].
class FlexSectionGate {
  const FlexSectionGate({
    required this.program,
    required this.letter,
    required this.batch,
    required this.owners,
  });

  /// Timetable department (`SE`), from the portal's section prefix.
  final String program;

  /// Section letter inside that department (`C`).
  final String letter;

  /// Intake year as the sheet writes it (`2025`), or `''` when the
  /// sheet carries no batches — then department and letter are all
  /// there is, and that is still the student's own section.
  final String batch;

  /// Which department owns each `<batch>|<letter>` when the sheet
  /// writes it as a prefixed section. Only unambiguous owners are
  /// recorded, so a letter two departments share is claimed by neither.
  final Map<String, String> owners;

  /// The section as the timetable spells it, for logs rather than for
  /// matching.
  String get label =>
      batch.isEmpty ? '$program-$letter' : '$program-$letter ($batch)';

  /// Whether the row belongs to this student's section, before the
  /// batch is consulted.
  bool claims(TimetableEntry e) {
    final sec = e.sectionGroup;
    // No section, or one that names two sections at once (`FT07A/B`).
    if (sec.isEmpty || sec.contains('/')) return false;

    final tail = RegExp(r'([A-Z])$').firstMatch(sec);
    if (tail == null || tail.group(1) != letter) return false;

    final dept = e.program.isNotEmpty ? e.program : _deptOf(sec);
    if (dept == program) return true;
    if (dept.isNotEmpty) return false;

    // A bare letter with no department of its own belongs to this
    // student only when this department is the one that owns that
    // letter at this batch — the same "fold only where a match exists"
    // rule the engineering section filter applies.
    return owners['${e.batch}|$letter'] == program;
  }

  /// Whether a ring may be painted on the row.
  bool covers(TimetableEntry e) =>
      claims(e) && (batch.isEmpty || e.batch == batch);

  /// The department a section string starts with, for the sheets that
  /// write it without one (`A` beside `EE-A`); '' when nothing of a
  /// department remains.
  static String _deptOf(String section) {
    final cut = section.replaceFirst(RegExp(r'-?\d*[A-Z]$'), '');
    return cut.endsWith('-') ? cut.substring(0, cut.length - 1) : cut;
  }
}

/// Attendance for the signed-in student, read off the portal and matched
/// onto timetable courses so the day's cards can carry a ring.
///
/// The portal is the only place this number exists — there is no public
/// endpoint — so everything here runs behind [FlexSessionService]'s
/// session cookie. No session means no rings, never a guess and never a
/// zero: an absent ring reads as "we don't know", which is the truth.
class FlexAttendanceService {
  FlexAttendanceService._();

  static final FlexAttendanceService instance = FlexAttendanceService._();

  static const String _cachePref = 'flex_attendance_cache';

  /// Bumped whenever the stored shape changes, so a payload written for
  /// an older format is dropped instead of being read as courses it
  /// doesn't hold. The timetable keeps its own cache under the same
  /// arrangement.
  static const int _cacheVersion = 1;

  /// How long a fetch stands before the next one looks for fresh
  /// numbers. Attendance moves once or twice a day, so half an hour of
  /// staleness is invisible; the pull-to-refresh bypasses it anyway.
  static const Duration _ttl = Duration(minutes: 30);

  /// Longest run of words an abbreviation is allowed to stand for. The
  /// portal's longest course name that is abbreviated anywhere on the
  /// sheet is five words (`Computer Organization and Assembly Language`
  /// -> `COAL`), so eight leaves room without letting a two-letter chip
  /// match its way into an unrelated course.
  static const int _maxRun = 8;

  /// Words an abbreviation's initials skip — carrying them would make
  /// `COAL` read `COAAL`.
  static const Set<String> _stopWords = {
    'of',
    'and',
    'the',
    'for',
    'in',
    'on',
    'at',
    'to',
    'a',
    'an',
  };

  List<FlexCourseAttendance> _courses = [];
  DateTime? _fetchedAt;
  bool _loading = false;

  /// The timetable currently on screen.
  ///
  /// The gate can't be settled from the portal alone: which department
  /// and which intake the student is in is only a question the sheet can
  /// answer, because it is the sheet that runs three intakes of `SE-C`
  /// side by side. The screen hands its entries over on each load.
  List<TimetableEntry> _entries = const [];

  FlexSectionGate? _gate;
  bool _gateValid = false;

  /// The portal's courses, empty until something has been fetched or
  /// restored from cache.
  List<FlexCourseAttendance> get courses => _courses;

  /// When [courses] was actually read from the portal, not when it was
  /// restored from the cache.
  DateTime? get fetchedAt => _fetchedAt;

  /// True while a fetch is in flight, so a caller can avoid stacking
  /// another one.
  bool get isLoading => _loading;

  /// True when there is anything to match against.
  bool get hasData => _courses.isNotEmpty;

  /// Hands the sheet's entries over so [gate] can be settled against
  /// them. Called on every timetable load: a new semester, a different
  /// school or a freshly parsed sheet can all move the sections the
  /// student's own is spelled with.
  void setEntries(List<TimetableEntry> entries) {
    _entries = entries;
    _gateValid = false;
  }

  /// The section this student's attendance may be painted onto, or
  /// `null` when it can't be pinned down — in which case no ring is
  /// shown at all, since a ring on another intake's row is a wrong
  /// answer wearing the right colour.
  FlexSectionGate? get gate {
    if (!_gateValid) {
      _gate = _resolveGate();
      _gateValid = true;
    }
    return _gate;
  }

  /// The portal course a timetable card stands for, or `null` — and
  /// `null` as well when the card isn't in the student's own section.
  ///
  /// Keeping the two together is the point: a correct course match on
  /// the wrong section's row would still print that section's
  /// attendance, which is precisely the bug this exists to prevent.
  FlexCourseAttendance? matchEntry(TimetableEntry entry) {
    final g = gate;
    if (g == null || !g.covers(entry)) return null;
    return match(entry.course, isLab: entry.isLab);
  }

  /// Forgets everything read from the portal.
  ///
  /// Only the timetable's own cache-shape guard and this call may
  /// delete the reading — a lapsed session must not, or a student whose
  /// session expires overnight would wake up to no rings at all.
  Future<void> clear() async {
    _courses = [];
    _fetchedAt = null;
    _gate = null;
    _gateValid = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cachePref);
    } catch (e) {
      debugPrint('Flex attendance cache clear failed: $e');
    }
  }

  // ================= READING =================

  /// Paints whatever the last fetch stored, immediately and without a
  /// network round trip. Call before [refresh] so rings show while the
  /// refresh is still running.
  ///
  /// A payload that cannot be vouched for — written for another version
  /// of the format, or not a cache at all — is deleted rather than
  /// skipped: unreadable is the same as absent, and leaving it would
  /// only have it tried again on every load.
  Future<void> loadCached() async {
    if (_courses.isNotEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_cachePref);
      if (raw == null) return;

      final map = jsonDecode(raw) as Map<String, dynamic>;
      final list = (map['v'] as num?)?.toInt() == _cacheVersion
          ? map['courses']
          : null;
      if (list is! List) {
        await prefs.remove(_cachePref);
        return;
      }

      _courses = [
        for (final c in list)
          if (c is Map<String, dynamic>) FlexCourseAttendance.fromJson(c),
      ];
      _gateValid = false;
      final at = (map['fetchedAt'] as num?)?.toInt() ?? 0;
      _fetchedAt = at == 0 ? null : DateTime.fromMillisecondsSinceEpoch(at);
    } catch (e) {
      debugPrint('Flex attendance cache read failed: $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_cachePref);
      } catch (_) {
        // Nothing more to do: the refresh will overwrite it anyway.
      }
    }
  }

  /// Re-reads the portal's attendance page and replaces [courses].
  ///
  /// Silent by design: no session, a lapsed session, an offline device
  /// and an unparsable page all leave the previous numbers (or nothing)
  /// in place. The timetable is useful without this, so it must never
  /// surface an error because of it.
  Future<void> refresh({bool force = false}) async {
    if (_loading) return;
    if (!force &&
        _courses.isNotEmpty &&
        _fetchedAt != null &&
        DateTime.now().difference(_fetchedAt!) < _ttl) {
      return;
    }

    _loading = true;
    try {
      final session = FlexSessionService.instance;
      if (!session.hasSession) await session.restore();

      final path = session.hasSession ? await _attendancePath() : null;
      final html = path == null ? null : await session.getHtml(path);
      final parsed = html == null ? <FlexCourseAttendance>[] : _parse(html);

      // One line rather than silence. "Why are there no rings?" is the
      // only question this ever raises and it can't be answered from
      // the UI, since the whole point is that a failure looks like
      // nothing at all.
      debugPrint(
        'Flex attendance: session=${session.hasSession} path=$path '
        'html=${html?.length} courses=${parsed.length}',
      );
      if (parsed.isEmpty) return;

      _courses = parsed;
      _fetchedAt = DateTime.now();
      _gateValid = false;
      await _writeCache();
    } catch (e) {
      debugPrint('Flex attendance refresh failed: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> _writeCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cachePref,
        jsonEncode({
          'v': _cacheVersion,
          'fetchedAt': _fetchedAt?.millisecondsSinceEpoch ?? 0,
          'courses': [for (final c in _courses) c.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('Flex attendance cache write failed: $e');
    }
  }

  // ================= LOCATING THE PAGE =================

  /// The portal's own attendance link for the current semester.
  ///
  /// The semester id is not something to invent — it changes every term
  /// and a wrong one returns an empty page that would look like "no
  /// attendance". So the dashboard is asked what the link is and that
  /// exact link is followed; when the portal doesn't advertise one, the
  /// fallback is any `semid` it does mention, and failing all that, no
  /// rings.
  Future<String?> _attendancePath() async {
    final home = await FlexSessionService.instance.getHtml('/Home');
    if (home == null) return null;

    final link = RegExp(
      r'href="([^"]*StudentAttendance[^"]*)"',
    ).firstMatch(home);
    if (link != null) {
      var href = link.group(1)!.replaceAll('&amp;', '&');
      if (href.startsWith('http')) {
        final uri = Uri.parse(href);
        final query = uri.query.isEmpty ? '' : '?${uri.query}';
        return '$uri.path$query';
      }
      if (href.startsWith('/')) return href;
      return '/$href';
    }

    final semid = RegExp(r'semid=(\d+)').firstMatch(home);
    if (semid == null) return null;
    return '/Student/StudentAttendance?semid=${semid.group(1)}';
  }

  // ================= PARSING =================

  /// Pulls `(code, name, section, percent)` tuples out of the page.
  ///
  /// The portal lists every registered course as a tab, then under it
  /// writes two `<h5>`s in strict alternation:
  ///
  ///     <h5>CS2001-Data Structures (BSE-3C)</h5>
  ///     <h5>94.00%</h5>
  ///
  /// So the heading is taken as a course and the heading that follows it
  /// as that course's percentage — anything that doesn't come in that
  /// pair shape is skipped rather than mis-read, which would put a
  /// wrong number on a class.
  List<FlexCourseAttendance> _parse(String html) {
    final headings = <String>[];
    for (final m in RegExp(r'<h5[^>]*>([\s\S]*?)</h5>').allMatches(html)) {
      final text = m
          .group(1)!
          .replaceAll(RegExp(r'<[^>]+>'), ' ')
          .replaceAll('&amp;', '&')
          .replaceAll('&nbsp;', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (text.isNotEmpty) headings.add(text);
    }

    final out = <FlexCourseAttendance>[];
    for (var i = 0; i < headings.length; i++) {
      final course = headings[i];
      final percent = i + 1 < headings.length ? headings[i + 1] : null;
      if (percent == null) break;

      final head = RegExp(r'^([A-Z]{2}\d{3,4})\s*-\s*(.+)$').firstMatch(course);
      final value = RegExp(r'^([\d.]+)\s*%$').firstMatch(percent);
      if (head == null || value == null) continue;

      final body = head.group(2)!.trim();
      final section = RegExp(r'\s*\(([^()]*)\)\s*$').firstMatch(body);
      final name = (section == null ? body : body.substring(0, section.start))
          .trim();
      if (name.isEmpty) continue;

      out.add(
        FlexCourseAttendance(
          code: head.group(1)!,
          name: name,
          section: section?.group(1)?.trim() ?? '',
          percent: double.tryParse(value.group(1)!) ?? 0,
        ),
      );
      i++; // the percentage heading belongs to this course
    }
    return out;
  }

  // ================= MATCHING =================

  /// The portal course a timetable card stands for, or `null`.
  ///
  /// The two sides don't share a vocabulary. Management and Engineering
  /// write the code into the timetable (`AF2001 Corporate Accounting`),
  /// which is an exact hit. Computing writes no code at all — its cells
  /// read `Data St (SE-A)`, `COAL Lab (SE-B)` — so the name has to be
  /// matched against the portal's full name using the three ways a
  /// timetable abbreviates:
  ///
  ///  * a head of the word — `data st` for `Data Structures`,
  ///    `pak studies` for `Pakistan Studies`;
  ///  * the initials of a run of words — `COAL` for `Computer
  ///    Organization and Assembly Language`, `LA` for `Linear Algebra`,
  ///    `uhq` for `Understanding of Holy Quran`;
  ///  * both at once — `intro to se` for `Introduction to Software
  ///    Engineering`.
  ///
  /// Every label token has to match in order, and a candidate is only
  /// returned when that leaves nothing better: a lecture is never given
  /// a lab's figure and vice versa. Anything the matcher can't settle
  /// comes back as `null` and the card simply carries no ring.
  FlexCourseAttendance? match(String timetableCourse, {bool isLab = false}) {
    if (_courses.isEmpty) return null;

    final label = _labelTokens(timetableCourse);
    if (label.isEmpty) return null;

    // Management and Engineering spell the course code into the cell.
    final code = RegExp(
      r'^([A-Z]{2}\s?\d{4})\b',
    ).firstMatch(timetableCourse.toUpperCase());
    if (code != null) {
      final key = code.group(1)!.replaceAll(' ', '');
      for (final c in _courses) {
        if (c.code == key) return c;
      }
      // A code that looks right but isn't registered means no ring —
      // falling through to name matching here could match a course with
      // a similar title.
      return null;
    }

    // (course, tokens accounted for, tokens in the name): how much of
    // each portal name the label managed to explain.
    final hits = <(FlexCourseAttendance, int, int)>[];
    for (final c in _courses) {
      final nameTokens = _nameTokens(c.name);
      final consumed = _consume(label, nameTokens);
      if (consumed != null) hits.add((c, consumed, nameTokens.length));
    }
    if (hits.isEmpty) return null;

    // Prefer a label that explains the whole name: `Data St` accounts
    // for all of `Data Structures` but stops short of
    // `Data Structures - Lab`, which settles lecture against lab before
    // the lab flag is even consulted.
    var best = hits.where((h) => h.$2 == h.$3).toList();
    if (best.isEmpty) best = hits;

    // Then the lab flag, so a sheet that writes no "Lab" of its own
    // still lands on the right course.
    final matching = best.where((h) => h.$1.isLab == isLab).toList();
    if (matching.isNotEmpty) return matching.first.$1;

    // One candidate can't be confused with another — take it. Several
    // that disagree about the lab means the label was too short to
    // settle it, so say nothing.
    return best.length == 1 ? best.first.$1 : null;
  }

  /// Splits a timetable cell into comparable tokens, dropping what the
  /// sheet appends to a course but that a course name never contains:
  /// room codes, times, and the reschedule/cancellation marks.
  List<String> _labelTokens(String cell) {
    var s = cell.toLowerCase();
    s = s.replaceAll(RegExp(r'\b[a-z]-\d{3,4}\b'), ' ');
    s = s.replaceAll(RegExp(r'\d{1,2}:\d{2}'), ' ');
    s = s.replaceAll(
      RegExp(r'\b(resch|cancelled|canceled|repeat|room)\b'),
      ' ',
    );
    return _split(s);
  }

  /// Splits a portal course name into tokens. A slash joins two names
  /// (`Understanding of Holy Quran II/Introduction to …`) and must break
  /// the token flow, not disappear into one.
  List<String> _nameTokens(String name) => _split(name);

  List<String> _split(String s) {
    final parts = s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .split(RegExp(r'\s+'));
    return [
      for (final p in parts)
        if (p.isNotEmpty) p,
    ];
  }

  /// How many of [name]'s tokens the label accounts for, or `null` when
  /// it doesn't fit at all.
  ///
  /// Each label token is matched against the next untouched name token:
  /// either it heads that word, or it is the initials of a run starting
  /// there. Tokens are consumed in order, so a label can't be satisfied
  /// by picking words out of a name at random.
  int? _consume(List<String> label, List<String> name) {
    if (label.isEmpty || name.isEmpty) return null;

    var pos = 0;
    for (final token in label) {
      if (pos >= name.length) return null;

      if (name[pos].startsWith(token)) {
        pos++;
        continue;
      }

      final remaining = name.length - pos;
      var advanced = false;
      for (var run = token.length; run <= remaining && run <= _maxRun; run++) {
        if (_initials(name, pos, run) == token) {
          pos += run;
          advanced = true;
          break;
        }
      }
      if (!advanced) return null;
    }
    return pos;
  }

  /// The initials of `name[start .. start+length)`, stopwords skipped so
  /// `Computer Organization and Assembly Language` reads `COAL` rather
  /// than `COAAL`.
  String _initials(List<String> name, int start, int length) {
    final b = StringBuffer();
    for (var i = start; i < start + length && i < name.length; i++) {
      final word = name[i];
      if (_stopWords.contains(word)) continue;
      b.write(word[0]);
    }
    return b.toString();
  }

  // ================= THE STUDENT'S SECTION =================

  /// Settles which timetable rows belong to the signed-in student, or
  /// `null` when that can't be settled from the two sources at hand.
  ///
  /// Fail-closed at every step, because a gate that guesses puts a real
  /// percentage on a class the student does not attend — worse than no
  /// ring at all, which merely reads as "unknown".
  FlexSectionGate? _resolveGate() {
    if (_courses.isEmpty || _entries.isEmpty) return null;

    final portal = _portalSection();
    if (portal == null) return null;

    final parts = _portalSectionParts(portal);
    if (parts == null) {
      debugPrint(
        'Flex attendance: section "$portal" is not shaped like a section '
        'this sheet can be matched to — no rings.',
      );
      return null;
    }
    final (prefix, letter) = parts;

    // The portal writes degrees (`BSE`), the sheet departments (`SE`).
    // The prefix is tried as it stands first, then with one leading
    // degree letter taken off — and never twice, since nothing on a
    // sheet is spelled that way.
    final programs = <String>{
      for (final e in _entries)
        if (e.program.isNotEmpty) e.program,
    };
    String? program = programs.contains(prefix) ? prefix : null;
    if (program == null && prefix.length > 1 && prefix.startsWith('B')) {
      final stripped = prefix.substring(1);
      if (programs.contains(stripped)) program = stripped;
    }
    if (program == null) {
      debugPrint(
        'Flex attendance: section $portal names no department on this '
        'sheet ($programs) — no rings.',
      );
      return null;
    }

    // Which department writes each batch/letter as a prefixed section,
    // so a sheet that spells one section two ways (`EE-A` beside a bare
    // `A`) can still be tied to a single department.
    final owners = <String, Set<String>>{};
    for (final e in _entries) {
      final m = RegExp(r'^([A-Z]+)-([A-Z])$').firstMatch(e.sectionGroup);
      if (m == null) continue;
      owners
          .putIfAbsent('${e.batch}|${m.group(2)}', () => <String>{})
          .add(m.group(1)!);
    }
    final unambiguous = <String, String>{
      for (final e in owners.entries)
        if (e.value.length == 1) e.key: e.value.single,
    };

    final section = FlexSectionGate(
      program: program,
      letter: letter,
      batch: '',
      owners: unambiguous,
    );

    // Which intake is the student's. The intakes don't share course
    // loads, so the sheet answers this itself: on `SE-C`, 2024's rows
    // sit in Algo and 2026's in PF, and only 2025's sit in the courses
    // the portal lists. Tallying the batches of the rows this gate
    // claims *and* whose course matched reads that off the timetable
    // rather than asking anyone — or guessing from the portal's digits.
    final tally = <String, int>{};
    for (final e in _entries) {
      if (e.isPlaceholder || e.batch.isEmpty) continue;
      if (!section.claims(e)) continue;
      if (match(e.course, isLab: e.isLab) == null) continue;
      tally[e.batch] = (tally[e.batch] ?? 0) + 1;
    }

    var batch = '';
    if (tally.isNotEmpty) {
      final ranked = tally.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (ranked.length > 1 && ranked.first.value == ranked[1].value) {
        debugPrint(
          'Flex attendance: intake undecided between $tally — no rings.',
        );
        return null;
      }
      batch = ranked.first.key;
    }

    final gate = FlexSectionGate(
      program: program,
      letter: letter,
      batch: batch,
      owners: unambiguous,
    );
    debugPrint('Flex attendance: section gate ${gate.label}');
    return gate;
  }

  /// The section the portal files the student's courses under —
  /// `BSE-3C` — read across every course it listed.
  ///
  /// One student sits in one section, so the rows that state one have
  /// to agree. Rows stating nothing are simply ignored rather than
  /// counted against; a page whose say splits between two sections,
  /// without one clearly in front, cannot tell us which is theirs, so it
  /// gets no rings.
  String? _portalSection() {
    final counts = <String, int>{};
    for (final c in _courses) {
      final s = c.section.trim();
      if (s.isEmpty) continue;
      counts[s] = (counts[s] ?? 0) + 1;
    }
    if (counts.isEmpty) return null;

    var top = '';
    var seen = 0;
    var total = 0;
    for (final e in counts.entries) {
      total += e.value;
      if (e.value > seen) {
        seen = e.value;
        top = e.key;
      }
    }
    return seen * 2 > total ? top : null;
  }

  /// `BSE-3C` as (degree prefix, section letter), or `null` for a
  /// spelling no part of which can be trusted.
  ///
  /// The digits between the two are read past, never decoded — see
  /// [FlexSectionGate] for why.
  (String, String)? _portalSectionParts(String raw) {
    final m = RegExp(r'^([A-Z]+)-?(\d*)([A-Z])$').firstMatch(raw.trim());
    if (m == null) return null;
    return (m.group(1)!, m.group(3)!);
  }
}
