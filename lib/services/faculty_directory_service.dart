// lib/services/faculty_directory_service.dart

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/faculty_member.dart';
import 'csv_reader.dart';

/// One school whose faculty-offices sheet the app knows how to read.
///
/// A list rather than a flag on purpose: a second school is a row here,
/// and the school filter in the directory UI appears by itself the
/// moment there is more than one to choose between.
class FacultySource {
  final String id;
  final String label;

  /// The Google Sheet's own id, from the share link.
  final String sheetId;

  const FacultySource({
    required this.id,
    required this.label,
    required this.sheetId,
  });
}

/// Every faculty-offices sheet the app can read.
///
/// Only Computing publishes one today. Engineering's and Management's
/// office lists are not on a sheet this app can reach, so they are
/// absent rather than present-and-broken.
const List<FacultySource> kFacultySources = [
  FacultySource(
    id: 'computing',
    label: 'School of Computing',
    sheetId: '1HF6g11HUJdnHo9D35fvtCzSxR2fTeu_K',
  ),
];

/// A directory loaded from the schools' faculty-offices sheets.
typedef FacultyDirectory = ({
  List<FacultyMember> members,
  String term,
  DateTime fetchedAt,
  bool fromCache,
});

/// Reads the faculty-offices sheets: who teaches where, and how to reach
/// them.
///
/// Deliberately its own service rather than more methods on
/// `TimetableService`. The two read different documents on different
/// rhythms — a timetable changes every term and is fetched per day, a
/// faculty list changes once a term and is fetched once — and folding
/// this in would add a second caching profile to a class that already
/// carries one.
class FacultyDirectoryService {
  FacultyDirectoryService._();

  static final FacultyDirectoryService instance = FacultyDirectoryService._();

  static const Duration _timeout = Duration(seconds: 15);

  /// How long a directory stays fresh.
  ///
  /// A day, rather than the rooms' six hours: this sheet is rewritten
  /// between terms, not between lectures, and re-reading it on every
  /// open would be network spent on a document that has not moved.
  static const Duration _ttl = Duration(hours: 24);

  /// Bumped when the member shape or the parsing changes, so caches
  /// written by an older parse are discarded rather than shown as a
  /// list with the wrong fields in it.
  static const int _cacheVersion = 1;

  static const String _cacheKey = 'faculty_directory';

  // ================= PUBLIC API =================

  /// Loads every configured school's directory.
  ///
  /// [forceRefresh] (pull-to-refresh) ignores the cache age and hits the
  /// network. A failed fetch falls back to whatever was cached — an
  /// out-of-date list of offices beats no list, which is the difference
  /// between finding a lecturer and not.
  Future<FacultyDirectory> load({bool forceRefresh = false}) async {
    final cached = await _readCache();

    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _ttl) {
      return cached;
    }

    try {
      final members = <FacultyMember>[];
      final terms = <String>{};
      for (final source in kFacultySources) {
        if (source.sheetId.isEmpty) continue;
        final csv = await _fetch(source);
        final parsed = parseFacultyCsv(csv, school: source.label);
        members.addAll(parsed.members);
        if (parsed.term.isNotEmpty) terms.add(parsed.term);
      }
      final fetchedAt = DateTime.now();
      await _writeCache(members, terms.join(' · '), fetchedAt);
      return (
        members: members,
        term: terms.join(' · '),
        fetchedAt: fetchedAt,
        fromCache: false,
      );
    } catch (e) {
      debugPrint('Faculty directory fetch failed: $e');
      if (cached != null) {
        return (
          members: cached.members,
          term: cached.term,
          fetchedAt: cached.fetchedAt,
          fromCache: true,
        );
      }
      rethrow;
    }
  }

  Future<String> _fetch(FacultySource source) async {
    // The CSV export, not the gviz endpoint: gviz merges the sheet's
    // department header rows into the cell below them, which is exactly
    // the structure the parse depends on to know who is in which
    // department.
    final uri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${source.sheetId}'
      '/export?format=csv',
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Faculty sheet fetch failed (${response.statusCode})',
        uri,
      );
    }
    final body = response.body;
    // Google answers with an HTML login/consent page when the sheet
    // isn't shared publicly — treat that as a failure, not as data.
    if (body.trimLeft().startsWith('<!DOCTYPE') ||
        body.trimLeft().startsWith('<html')) {
      throw const FormatException('Faculty sheet is not publicly shared');
    }
    return body;
  }

  // ================= PARSING =================

  /// Reads a faculty-offices CSV into people.
  ///
  /// The sheet is not a tidy table. It opens with a title row and a
  /// header row, files the head of the faculty above every department
  /// with no serial number at all, marks each department with a
  /// `Faculty Department of …` row spanning the width of the sheet, and
  /// ends Software Engineering with a row that is entirely blank.
  ///
  /// So the parse keys off two signals rather than on column numbers:
  ///
  /// * a row beginning `Faculty Department of` switches which department
  ///   the following people belong to;
  /// * a row containing an `@` is a person.
  ///
  /// Everything else — title, header, department marker, blank row —
  /// fails the second test and falls out, which is why the head of the
  /// faculty is still found: their serial number is missing and their
  /// name has slid into the first column, but their email has not
  /// moved.
  ///
  /// Rows are **not** de-duplicated. The sheet genuinely contains two
  /// people called Irfan Ullah in different departments at different
  /// ranks, and Science & Humanities lists Mishal Shahid and Maheen Ali
  /// twice with different addresses. Any merge keyed on a name would
  /// delete a real faculty member to tidy up a row; the sheet's owner
  /// is the one who can tell which copy is right.
  static ({List<FacultyMember> members, String term}) parseFacultyCsv(
    String csv, {
    required String school,
  }) {
    final members = <FacultyMember>[];
    var department = '';

    // The title is the first row, column zero, and it names the term the
    // list was published for. Read before the loop rather than inside it:
    // any later row that fails the email test is junk, and letting those
    // compete for the term would let a stray `3,,,,` row win.
    final rows = parseCsv(csv);
    final term = rows.isEmpty ? '' : _clean(rows.first.first);

    for (final raw in rows) {
      final cells = [for (final c in raw) _clean(c)];
      if (cells.every((c) => c.isEmpty)) continue;

      // A department marker, before the email test: it has no email and
      // would otherwise be skipped as noise.
      final marker = cells.first.toLowerCase();
      if (marker.startsWith(_departmentPrefix)) {
        // Only a marker when the rest of the row is empty — a person's
        // name could begin with the same words, though none does yet.
        if (cells.skip(1).every((c) => c.isEmpty)) {
          department = _clean(cells.first.substring(_departmentPrefix.length));
          continue;
        }
      }

      final emailAt = cells.indexWhere((c) => c.contains('@'));
      // No email means this is not a person: the header row, a
      // department marker, a blank row left behind by the sheet's own
      // editor.
      if (emailAt < 0) continue;

      // Walk back from the email rather than counting columns from the
      // left, because the head of the faculty has no serial number and
      // so every column after theirs sits one place to the left of where
      // everyone else's does.
      final designationAt = _lastNonEmptyBefore(cells, emailAt);
      final nameAt =
          designationAt == null ? null : _lastNonEmptyBefore(cells, designationAt);
      if (nameAt == null) continue; // an email with no name above it

      members.add(
        FacultyMember.fromRow(
          name: cells[nameAt],
          designation: designationAt == null ? '' : cells[designationAt],
          email: cells[emailAt],
          office: emailAt + 1 < cells.length ? cells[emailAt + 1] : '',
          // Filed under no department means filed under nobody but the
          // head — the sheet puts the FSC head above every marker.
          department: department.isEmpty ? _fscDepartment : department,
          school: school,
        ),
      );
    }

    return (members: members, term: term);
  }

  // ================= CACHE =================

  Future<FacultyDirectory?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_cacheKey);
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['v'] != _cacheVersion) return null; // stale format
      return (
        members: [
          for (final m in decoded['members'] as List<dynamic>)
            FacultyMember.fromJson(Map<String, dynamic>.from(m as Map)),
        ],
        term: decoded['term'] as String? ?? '',
        fetchedAt:
            DateTime.tryParse(decoded['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        fromCache: true,
      );
    } catch (e) {
      debugPrint('Faculty cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeCache(
    List<FacultyMember> members,
    String term,
    DateTime fetchedAt,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'v': _cacheVersion,
          'fetchedAt': fetchedAt.toIso8601String(),
          'term': term,
          'members': [for (final m in members) m.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('Faculty cache write failed: $e');
    }
  }

  // Test hook. Only [load] should drive the parser; tests hand it a
  // saved copy of the real sheet instead of fetching over the network.
  ({List<FacultyMember> members, String term}) debugParseFacultyCsv(
    String csv, {
    String school = 'School of Computing',
  }) => parseFacultyCsv(csv, school: school);

  static const String _departmentPrefix = 'faculty department of';

  /// The department the sheet files the head of the faculty under: none
  /// of them, because that row sits above every department marker.
  static const String _fscDepartment = 'FSC Administration';

  /// A cell's worth of the sheet's sloppiness: tabs, carriage returns
  /// and line breaks all become one space, and runs of spaces collapse.
  ///
  /// This is where `"Mr. Shoaib Saleem Khattak \n"` stops being a name
  /// with a line break hiding in it, and `Dr. Muhammad Arshad Islam \t`
  /// stops carrying a tab nobody can see until it is printed.
  static String _clean(String s) => s
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// The last non-empty cell before [before], or null.
  static int? _lastNonEmptyBefore(List<String> cells, int before) {
    for (var i = before - 1; i >= 0; i--) {
      if (cells[i].isNotEmpty) return i;
    }
    return null;
  }
}
