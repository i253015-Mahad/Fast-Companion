// lib/services/timetable_service.dart

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/timetable_entry.dart';

/// A timetable loaded from a school's Google Sheet, with the time we
/// fetched it so the UI can show a "last updated" footer and know when
/// it's serving stale (offline) data.
class TimetableResult {
  final List<TimetableEntry> entries;
  final DateTime fetchedAt;

  /// True when [entries] came from the local cache instead of the network.
  final bool fromCache;

  const TimetableResult({
    required this.entries,
    required this.fetchedAt,
    this.fromCache = false,
  });

  /// Section codes present in this timetable, sorted for the pill list.
  List<String> get sections {
    final set = <String>{};
    for (final e in entries) {
      if (e.section.isNotEmpty) set.add(e.section);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// Departments (program letters) present, sorted for the pill list.
  List<String> get departments {
    final set = <String>{};
    for (final e in entries) {
      if (e.program.isNotEmpty) set.add(e.program);
    }
    final list = set.toList()..sort();
    return list;
  }

  /// Batch years present, sorted numerically for the pill list.
  List<String> get batches {
    final set = <String>{};
    for (final e in entries) {
      if (e.batch.isNotEmpty) set.add(e.batch);
    }
    final list = set.toList()..sort();
    return list;
  }
}

/// One expanded cell from an htmlview table. Merged cells keep their
/// value only in the top-left position; the spanned positions hold an
/// empty cell, exactly mirroring how the CSV export flattens merges.
class SheetCell {
  final String text;
  final String bg; // "#aabbcc", or "" when the cell has no fill.

  /// How many sheet columns the cell was merged across (its colspan).
  ///
  /// This is how the sheets say a class runs longer than one period: a
  /// lecture is one slot wide, and a three-hour lab is drawn as a single
  /// cell whose colour reaches across two of them. The value lives only
  /// on the top-left cell, so [span] is the only surviving record of how
  /// far the colour actually extended.
  final int span;

  const SheetCell({this.text = '', this.bg = '', this.span = 1});
}

/// A legend swatch: a colored banner cell that names a program/batch.
class _LegendSwatch {
  final String dept; // "CS", "EE"... ("" for swatches like "BS Repeat")
  final String batch; // "2026", or "" when the swatch has no year.
  final bool drop; // true for MS / PhD swatches (removed from results).
  final int r, g, b;
  const _LegendSwatch({
    required this.dept,
    required this.batch,
    required this.drop,
    required this.r,
    required this.g,
    required this.b,
  });
}

/// Fetches the university's published Google Sheets timetables and turns
/// them into [TimetableEntry]s.
///
/// Only the BS programs are surfaced. Computing and Engineering publish
/// their program/batch as a *cell background color* keyed to a legend
/// banner in the sheet; we read that color from the `htmlview` endpoint
/// (which carries each cell's CSS class + a `<style>` block) so every
/// class can be tagged with its department and batch year, and MS/PhD
/// cells can be dropped. Management writes its program into the section
/// code itself, so it stays on the plain CSV endpoint.
///
/// Results are cached per school in shared_prefs so the screen opens
/// instantly offline; a failed refresh falls back to that cache.
class TimetableService {
  TimetableService._();

  static final TimetableService instance = TimetableService._();

  static const Duration _timeout = Duration(seconds: 15);

  /// Bumped whenever the entry shape or parsing changes so stale caches
  /// (missing the color-derived program/batch, management batch codes
  /// that are now stored as years, engineering sections folded into
  /// their program prefix, lab end times that still stopped at the
  /// first of the two periods a lab spans, management lectures that
  /// were being welded together the way labs are, lab end times that
  /// ran into the period *after* the block, brackets that the sheets
  /// left open — a room written `Margala 4 (C-212` — or a course whose
  /// code had no space before its name, `LG2009Data Analysis`, and so
  /// never appeared at all) are discarded.
  static const int _cacheVersion = 10;

  /// The management sheet numbers its batches by odd intake counts
  /// (`01`, `03`, `05`, `07`, with `01` being the newest) rather than by
  /// year. This is the year that `01` joined; each +2 on the intake
  /// number is one year earlier. The course levels confirm the mapping:
  /// batch 01 sits in 1000-level courses (`AF1003`), 03 in 2000-level
  /// (`AF2003`), 05 in 3000-level (`AF 3001`) and 07 in 4000-level
  /// (`MG4011`). Bump this by one each fall, when the university admits
  /// a fresh `01`.
  static const int _managementIntakeYear = 2026;

  final Map<String, TimetableResult> _memory = {};

  // ================= PUBLIC API =================

  /// Loads a school's timetable.
  ///
  /// Returns the cached copy immediately when [allowCache] is true and
  /// the cache is fresh enough (or the network fails). [forceRefresh]
  /// (pull-to-refresh) ignores the cache age and hits the network.
  Future<TimetableResult> load(
    SchoolConfig school, {
    bool forceRefresh = false,
    bool allowCache = true,
  }) async {
    if (!school.available) {
      throw StateError('No sheet configured for ${school.label} yet');
    }

    final cached = await _readCache(school.id);

    // Fresh cache: serve it without touching the network unless the
    // caller explicitly asked for a refresh.
    if (allowCache &&
        !forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.fetchedAt) <
            const Duration(hours: 6)) {
      _memory[school.id] = cached;
      return cached;
    }

    try {
      final entries = await _fetchAll(school);
      final result = TimetableResult(
        entries: entries,
        fetchedAt: DateTime.now(),
      );
      await _writeCache(school.id, result);
      _memory[school.id] = result;
      return result;
    } catch (e) {
      // Offline (or the sheet is temporarily unreachable): fall back to
      // whatever we last had so the screen still shows something.
      if (cached != null) {
        return TimetableResult(
          entries: cached.entries,
          fetchedAt: cached.fetchedAt,
          fromCache: true,
        );
      }
      rethrow;
    }
  }

  /// Drops the in-memory copy (the cache file is kept) so the next
  /// [load] re-reads it.
  void invalidate(String schoolId) => _memory.remove(schoolId);

  /// Keeps only the entries a student would see, matching the chosen
  /// department, batch and section. Any empty filter passes everything
  /// for that dimension.
  ///
  /// A section matches either exactly or by its [TimetableEntry.sectionGroup],
  /// so the filter's `AI-A` pill also picks up the `AI-A1` / `AI-A2`
  /// lab groups.
  static List<TimetableEntry> filterBy(
    List<TimetableEntry> entries, {
    String department = '',
    String batch = '',
    String section = '',
  }) {
    return entries.where((e) {
      if (department.isNotEmpty && e.program != department) return false;
      if (batch.isNotEmpty && e.batch != batch) return false;
      if (section.isNotEmpty &&
          e.section != section &&
          e.sectionGroup != section) {
        return false;
      }
      return true;
    }).toList();
  }

  // ================= FETCH =================

  Future<List<TimetableEntry>> _fetchAll(SchoolConfig school) async {
    if (school.hasDayTabs) {
      final futures = school.dayGids.entries.map(
        (kv) => _fetchComputingDay(school, kv.key, kv.value),
      );
      final results = await Future.wait(futures);
      return [for (final r in results) ...r];
    }
    if (school.layout == SheetLayout.engineering) {
      return _fetchEngineering(school);
    }
    return _fetchManagement(school);
  }

  /// Computing: one tab per weekday, read from `htmlview` so the color
  /// legend is available. Falls back to the gviz CSV (no colors) if the
  /// htmlview endpoint is unreachable.
  Future<List<TimetableEntry>> _fetchComputingDay(
    SchoolConfig school,
    String day,
    int gid,
  ) async {
    try {
      final html = await _fetchHtml(school, gid);
      return _parseComputingHtml(html, day);
    } catch (e) {
      debugPrint('Computing htmlview failed, falling back to CSV: $e');
      final csv = await _fetchCsv(school, gid);
      return _parseComputing(csv, day);
    }
  }

  /// Engineering: a single tab read from `htmlview` (the real 195-row
  /// day-block sheet — the gviz endpoint resolves to a different tab).
  /// Falls back to the export CSV if htmlview is unreachable.
  Future<List<TimetableEntry>> _fetchEngineering(SchoolConfig school) async {
    final gid = school.defaultGid!;
    try {
      final html = await _fetchHtml(school, gid);
      return _parseEngineeringHtml(html);
    } catch (e) {
      debugPrint('Engineering htmlview failed, falling back to export CSV: $e');
      final csv = await _fetchCsvExport(school, gid);
      return _parseEngineering(csv);
    }
  }

  /// Management: program/batch live in the section code, so the plain
  /// gviz CSV is enough.
  Future<List<TimetableEntry>> _fetchManagement(SchoolConfig school) async {
    final csv = await _fetchCsv(school, school.defaultGid);
    return _parseManagement(csv);
  }

  Future<String> _fetchHtml(SchoolConfig school, int gid) async {
    final uri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${school.sheetId}'
      '/htmlview/sheet?headers=true&gid=$gid',
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Timetable fetch failed (${response.statusCode})',
        uri,
      );
    }
    final body = response.body;
    if (!body.contains('<table')) {
      throw const FormatException('Timetable sheet is not publicly shared');
    }
    return body;
  }

  Future<String> _fetchCsv(SchoolConfig school, int? gid) async {
    final uri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${school.sheetId}'
      '/gviz/tq?tqx=out:csv${gid == null ? '' : '&gid=$gid'}',
    );
    return _fetchText(uri);
  }

  Future<String> _fetchCsvExport(SchoolConfig school, int gid) async {
    final uri = Uri.parse(
      'https://docs.google.com/spreadsheets/d/${school.sheetId}'
      '/export?format=csv&gid=$gid',
    );
    return _fetchText(uri);
  }

  Future<String> _fetchText(Uri uri) async {
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Timetable fetch failed (${response.statusCode})',
        uri,
      );
    }
    final body = response.body;
    // Google answers with an HTML login/consent page when the sheet
    // isn't shared publicly — treat that as a failure, not as data.
    if (body.trimLeft().startsWith('<!DOCTYPE') ||
        body.trimLeft().startsWith('<html')) {
      throw const FormatException('Timetable sheet is not publicly shared');
    }
    return body;
  }

  // ================= HTML TABLE =================

  /// Parses an htmlview document into a grid of [SheetCell]s, resolving
  /// colspan/rowspan so every cell sits at its true (row, column). The
  /// returned rows are dense: the list index always equals the sheet
  /// column, matching how the CSV parsers index their rows.
  static ({List<List<SheetCell>> grid, Map<String, String> classToBg})
  _parseHtmlTable(String html) {
    final classToBg = <String, String>{};
    for (final m in RegExp(
      r'\.([A-Za-z][\w-]*)\s*\{([^}]*)\}',
    ).allMatches(html)) {
      final bg = RegExp(
        r'background(?:-color)?:\s*(#[0-9a-fA-F]{3,8}|rgb[^;)\s]+)',
      ).firstMatch(m.group(2)!);
      if (bg != null) classToBg[m.group(1)!] = bg.group(1)!.toLowerCase();
    }

    final grid = <List<SheetCell>>[];
    // occupied[r][c] is true when a rowspan from above covers that slot.
    final occupied = <List<bool>>[];

    for (final tr in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(html)) {
      final r = grid.length;
      while (occupied.length <= r) {
        occupied.add(<bool>[]);
      }
      final occ = occupied[r];

      final row = <SheetCell>[];
      var col = 0;
      for (final cell in RegExp(
        r'<(th|td)([^>]*)>([\s\S]*?)</\1>',
      ).allMatches(tr.group(1)!)) {
        if (cell.group(1) == 'th') continue; // row-number gutter
        final attrs = cell.group(2)!;
        final cls =
            RegExp(r'class="([^"]*)"').firstMatch(attrs)?.group(1) ?? '';
        if (cls.contains('freezebar')) continue; // UI artifact, not a column
        final colspan =
            int.tryParse(
              RegExp(r'colspan="(\d+)"').firstMatch(attrs)?.group(1) ?? '1',
            ) ??
            1;
        final rowspan =
            int.tryParse(
              RegExp(r'rowspan="(\d+)"').firstMatch(attrs)?.group(1) ?? '1',
            ) ??
            1;
        final text = _stripHtml(cell.group(3)!);
        final bg = classToBg[cls.split(RegExp(r'\s+')).first] ?? '';

        // Slide past slots already filled by a rowspan from above.
        while (col < occ.length && occ[col]) {
          _setCell(row, col, const SheetCell());
          col++;
        }

        _setCell(row, col, SheetCell(text: text, bg: bg, span: colspan));

        // Mark the spanned slots in the rows below as occupied.
        if (rowspan > 1) {
          for (var rr = 1; rr < rowspan; rr++) {
            while (occupied.length <= r + rr) {
              occupied.add(<bool>[]);
            }
            final pr = occupied[r + rr];
            for (var cc = 0; cc < colspan; cc++) {
              final c = col + cc;
              while (pr.length <= c) {
                pr.add(false);
              }
              pr[c] = true;
            }
          }
        }
        col += colspan;
      }
      grid.add(row);
    }
    return (grid: grid, classToBg: classToBg);
  }

  /// Sets [cell] at index [col] of [row], growing the row with empty
  /// cells so the index always equals the true sheet column.
  static void _setCell(List<SheetCell> row, int col, SheetCell cell) {
    while (row.length <= col) {
      row.add(const SheetCell());
    }
    row[col] = cell;
  }

  static String _stripHtml(String s) => _balanceParens(
    s
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim(),
  );

  /// Closes brackets the sheets leave open and drops the stray ones.
  ///
  /// The sheets are typed by hand and lose them: the computing sheet
  /// writes a room as `Margala 4 (C-212` with no closing paren, which
  /// otherwise reaches the card unbalanced, and a management course cell
  /// is written `(10:00-11:50))`. Text that is already balanced is
  /// returned untouched, which is the normal case.
  static String _balanceParens(String s) {
    var open = 0;
    final kept = StringBuffer();
    for (final r in s.split('')) {
      if (r == '(') {
        open++;
      } else if (r == ')') {
        if (open == 0) continue; // closer with nothing to close
        open--;
      }
      kept.write(r);
    }
    for (var i = 0; i < open; i++) {
      kept.write(')');
    }
    return kept.toString();
  }

  static List<String> _texts(List<SheetCell> row) => [
    for (final c in row) c.text,
  ];

  /// Reads every colored banner cell that names a program/batch into a
  /// list of swatches keyed by their background color.
  static List<_LegendSwatch> _buildLegend(List<List<SheetCell>> grid) {
    final swatches = <_LegendSwatch>[];
    for (final row in grid) {
      for (final cell in row) {
        final label = cell.text.trim();
        if (label.isEmpty || cell.bg.isEmpty) continue;
        // Legend labels always begin with a program-level word; course
        // cells begin with the course name, so this cleanly separates
        // the banner from the timetable body. Case matters here: the
        // legend writes "MS" but teacher cells start with "Ms.", and
        // letting those through would poison the color lookup.
        if (!RegExp(r'^(BS|MS|Phd|PhD|Batch)\b').hasMatch(label)) {
          continue;
        }
        final rgb = _hexToRgb(cell.bg);
        if (rgb == null) continue;
        final p = _parseLegendLabel(label);
        swatches.add(
          _LegendSwatch(
            dept: p.dept,
            batch: p.batch,
            drop: p.drop,
            r: rgb.$1,
            g: rgb.$2,
            b: rgb.$3,
          ),
        );
      }
    }
    return swatches;
  }

  static ({String dept, String batch, bool drop}) _parseLegendLabel(
    String text,
  ) {
    final drop = RegExp(r'\b(MS|Phd|PhD)\b').hasMatch(text);
    var dept = '';
    final prog = RegExp(r'\b(CS|DS|AI|CY|SE|EE|CE)\b').firstMatch(text);
    if (prog != null) dept = prog.group(1)!;
    var batch = '';
    final yr = RegExp(r'(20\d\d)').firstMatch(text);
    if (yr != null) batch = yr.group(1)!;
    return (dept: dept, batch: batch, drop: drop);
  }

  /// Matches a cell's background color to the nearest legend swatch.
  ///
  /// Returns the department/batch of a BS swatch, or [drop] = true when
  /// the color matches an MS/PhD swatch. When the color is equidistant
  /// from a BS and an MS swatch (they share `#ffe599`), the section
  /// prefix in the cell text breaks the tie.
  static ({String dept, String batch, bool drop}) _resolveColor(
    List<_LegendSwatch> swatches,
    String bg,
    String sectionPrefix, {
    double threshold = 60,
  }) {
    final rgb = _hexToRgb(bg);
    if (rgb == null) return (dept: '', batch: '', drop: false);

    _LegendSwatch? bestKeep, bestDrop;
    var keepD = double.infinity, dropD = double.infinity;
    for (final s in swatches) {
      final d = _dist(rgb.$1, rgb.$2, rgb.$3, s.r, s.g, s.b);
      if (s.drop) {
        if (d < dropD) {
          dropD = d;
          bestDrop = s;
        }
      } else {
        if (d < keepD) {
          keepD = d;
          bestKeep = s;
        }
      }
    }

    final keepOk = bestKeep != null && keepD <= threshold;
    final dropOk = bestDrop != null && dropD <= threshold;

    if (keepOk && dropOk) {
      // Shared color: trust the section prefix, otherwise treat as MS.
      if (sectionPrefix.isNotEmpty && bestKeep.dept == sectionPrefix) {
        return (dept: bestKeep.dept, batch: bestKeep.batch, drop: false);
      }
      return (dept: '', batch: '', drop: true);
    }
    if (dropOk && (!keepOk || dropD < keepD)) {
      return (dept: '', batch: '', drop: true);
    }
    if (keepOk) {
      return (dept: bestKeep.dept, batch: bestKeep.batch, drop: false);
    }
    return (dept: '', batch: '', drop: false);
  }

  static (int, int, int)? _hexToRgb(String hex) {
    var h = hex.replaceAll('#', '');
    if (h.length == 3) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length < 6) return null;
    final r = int.tryParse(h.substring(0, 2), radix: 16);
    final g = int.tryParse(h.substring(2, 4), radix: 16);
    final b = int.tryParse(h.substring(4, 6), radix: 16);
    if (r == null || g == null || b == null) return null;
    return (r, g, b);
  }

  static double _dist(int r1, int g1, int b1, int r2, int g2, int b2) {
    final dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
    return sqrt(dr * dr + dg * dg + db * db);
  }

  // ================= PARSING (HTML) =================

  static final RegExp _slotRe = RegExp(
    r'^\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*$',
  );

  // ---------------------------------------------------------------------
  // Test hooks. These parsers stay private because only [load] should
  // drive them; tests hand them saved copies of the real sheets instead
  // of fetching over the network.

  /// Parses one day's Computing htmlview page.
  @visibleForTesting
  List<TimetableEntry> debugParseComputingHtml(String html, String day) =>
      _parseComputingHtml(html, day);

  /// Parses an Engineering htmlview page (all days at once).
  @visibleForTesting
  List<TimetableEntry> debugParseEngineeringHtml(String html) =>
      _parseEngineeringHtml(html);

  /// Parses the Management gviz CSV (all days at once).
  @visibleForTesting
  List<TimetableEntry> debugParseManagementCsv(String csv) =>
      _parseManagement(csv);

  /// Parses the Computing CSV fallback for one day.
  @visibleForTesting
  List<TimetableEntry> debugParseComputingCsv(String csv, String day) =>
      _parseComputing(csv, day);

  /// Parses the Engineering CSV fallback (all days at once).
  @visibleForTesting
  List<TimetableEntry> debugParseEngineeringCsv(String csv) =>
      _parseEngineering(csv);

  /// Computing day-tab grid read from htmlview: the header row holds the
  /// time slots, each data row is a room with one course cell per slot.
  /// Cell colors tag each class with its department/batch; MS/PhD cells
  /// are dropped.
  List<TimetableEntry> _parseComputingHtml(String html, String day) {
    final grid = _parseHtmlTable(html).grid;
    final legend = _buildLegend(grid);

    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < grid.length; i++) {
      final found = _timeColumns(_texts(grid[i]));
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    final roomCols = <int>[];
    for (var j = 0; j < grid[headerIndex].length; j++) {
      if (grid[headerIndex][j].text.trimLeft().toLowerCase().startsWith(
        'room',
      )) {
        roomCols.add(j);
      }
    }

    final entries = <TimetableEntry>[];
    for (var i = headerIndex + 1; i < grid.length; i++) {
      final row = grid[i];

      final rooms = <({int col, String name})>[];
      for (final c in roomCols) {
        if (c < row.length && row[c].text.trim().isNotEmpty) {
          rooms.add((col: c, name: row[c].text.trim()));
        }
      }
      if (rooms.isEmpty) continue;

      for (var j = 0; j < row.length; j++) {
        final raw = row[j].text.trim();
        if (raw.isEmpty || roomCols.contains(j)) continue;
        if (_slotRe.hasMatch(raw)) continue;

        var room = '';
        var roomCol = -1;
        for (final r in rooms) {
          if (r.col < j && r.col > roomCol) {
            room = r.name;
            roomCol = r.col;
          }
        }
        if (room.isEmpty) continue;

        var slot = -1;
        for (var k = 0; k < timeCols.length; k++) {
          if (timeCols[k].col <= j && timeCols[k].col > roomCol) slot = k;
        }
        if (slot < 0) continue;

        // How far the cell's colour reaches. A merged lab block covers
        // two periods, and that span — not the first slot alone — is
        // what says how long the class is. It is capped at the next
        // room's column so a wide cell can't be read as running into
        // the neighbouring room's half of the row.
        var spanEndCol = j + row[j].span - 1;
        for (final rc in roomCols) {
          if (rc <= j) continue;
          if (rc - 1 < spanEndCol) spanEndCol = rc - 1;
          break;
        }

        // A time written inside the cell itself still wins over the
        // span, which is how one-off rescheduled classes are recorded.
        final parsed = _parseComputingCell(
          raw,
          timeCols[slot].start,
          _spannedEnd(timeCols, slot, spanEndCol),
        );
        final prefix = parsed.section.contains('-')
            ? parsed.section.split('-').first
            : '';
        final color = _resolveColor(legend, row[j].bg, prefix);
        if (color.drop) continue; // MS / PhD cell — removed.

        entries.add(
          TimetableEntry(
            day: day,
            startTime: parsed.start,
            endTime: parsed.end,
            course: parsed.course,
            section: parsed.section,
            program: color.dept.isNotEmpty ? color.dept : prefix,
            batch: color.batch.isNotEmpty ? color.batch : parsed.batch,
            room: room,
            isLab: parsed.isLab,
            note: parsed.note,
          ),
        );
      }
    }
    return entries;
  }

  /// Engineering sheet read from htmlview: day block (col 0, rowspan),
  /// Classes/Labs group (col 1), room (col 2), then one column per time
  /// slot with the teacher on the row below. Cell colors tag each class
  /// with its department/batch; MS/PhD cells are dropped.
  List<TimetableEntry> _parseEngineeringHtml(String html) {
    final grid = _parseHtmlTable(html).grid;
    final legend = _buildLegend(grid);

    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < grid.length && i < 12; i++) {
      final found = _timeColumns(_texts(grid[i]));
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];

    final entries = <TimetableEntry>[];
    var day = '';
    var kind = '';
    var room = '';

    for (var i = headerIndex + 1; i < grid.length; i++) {
      final row = grid[i];
      String text(int c) => c < row.length ? row[c].text.trim() : '';

      var c0 = text(0);
      var c1 = text(1);
      var c2 = text(2);

      if (c0.isNotEmpty) {
        final match = days.where((d) => c0.startsWith(d));
        if (match.isNotEmpty) {
          day = match.first;
          room = '';
          kind = '';
        } else {
          // Any other row-0 label ("Colour Keys") ends the day blocks.
          day = '';
          room = '';
          kind = '';
          continue;
        }
      }
      if (c1 == 'Classes' || c1 == 'Labs') {
        kind = c1;
        if (c2 == c1) c2 = '';
      }
      if (c2.isNotEmpty && c2 != 'Room' && c2 != room) room = c2;
      if (day.isEmpty) continue;

      final isCourseRow = c0.isNotEmpty || c1.isNotEmpty || c2.isNotEmpty;

      for (var ti = 0; ti < timeCols.length; ti++) {
        final t = timeCols[ti];
        final raw = text(t.col);
        if (raw.isEmpty) continue;
        if (_slotRe.hasMatch(raw)) continue;

        if (isCourseRow) {
          final cell = t.col < row.length ? row[t.col] : const SheetCell();
          final parsed = _parseEngineeringCell(raw, kind);
          final prefix = parsed.section.contains('-')
              ? parsed.section.split('-').first
              : '';
          final color = _resolveColor(legend, cell.bg, prefix);
          if (color.drop) continue; // MS / PhD cell — removed.

          entries.add(
            TimetableEntry(
              day: day,
              startTime: _normalizeTime(t.start),
              // A lab is one cell across two periods (colspan 35 against
              // a period's 17), so its colour reaching into the period
              // after this one is what makes it three hours rather than
              // one.
              endTime: _normalizeTime(
                _spannedEnd(timeCols, ti, t.col + cell.span - 1),
              ),
              course: parsed.course,
              section: parsed.section,
              program: color.dept,
              batch: color.batch.isNotEmpty ? color.batch : parsed.batch,
              room: room,
              isLab: parsed.isLab,
              note: parsed.note,
            ),
          );
        } else {
          // Teacher row: attach to the course above in the same slot.
          final slotStart = _normalizeTime(t.start);
          for (var k = entries.length - 1; k >= 0; k--) {
            final e = entries[k];
            if (e.day == day && e.startTime == slotStart && e.teacher.isEmpty) {
              final split = _parseTeacher(raw);
              entries[k] = TimetableEntry(
                day: e.day,
                startTime: split.start.isEmpty
                    ? e.startTime
                    : _normalizeTime(split.start),
                endTime: split.end.isEmpty
                    ? e.endTime
                    : _normalizeTime(split.end),
                course: e.course,
                section: e.section,
                program: e.program,
                batch: e.batch,
                room: e.room,
                teacher: split.teacher,
                isLab: e.isLab,
                note: split.note.isNotEmpty ? split.note : e.note,
              );
              break;
            }
          }
        }
      }
    }
    return _foldBareEngineeringSections(entries);
  }

  /// Section codes the engineering sheet writes with an explicit program
  /// prefix (`CE-A`, `EE-A`) or as a bare letter (`A`, `B`, `C`, `D`).
  static final RegExp _prefixedSectionRe = RegExp(r'^[A-Z]{2,3}-([A-Z]\d?)$');
  static final RegExp _bareSectionRe = RegExp(r'^[A-Z]$');

  /// Files stray bare-letter engineering sections under their program.
  ///
  /// The sheet prefixes the newest batch's sections (`CE-A`, `EE-A`) but
  /// leaves older ones as a bare letter — and three different EE batches
  /// (2023, 2024, 2025) all reuse `A`/`B`/`C`/`D`. So a bare letter is
  /// *not* merely a sub-group of `<DEPT>-<letter>`: folding all of them
  /// would drag three years of EE classes into the 2026 batch's section.
  ///
  /// Only fold where that same department **and** batch already owns the
  /// prefixed section. In practice that catches the one `CE-A` lab the
  /// sheet parked in bare `A`, so the CE section list reads
  /// `CE-A` / `CE-B` / `CE-C` instead of growing a stray `A` — while
  /// the EE letters keep meaning exactly what the sheet wrote.
  static List<TimetableEntry> _foldBareEngineeringSections(
    List<TimetableEntry> entries,
  ) {
    // "<program>|<batch>|<letter>" of every prefixed section present.
    final owned = <String>{};
    for (final e in entries) {
      if (e.program.isEmpty || e.batch.isEmpty) continue;
      final m = _prefixedSectionRe.firstMatch(e.section);
      if (m != null) owned.add('${e.program}|${e.batch}|${m.group(1)!}');
    }
    if (owned.isEmpty) return entries;

    return [
      for (final e in entries)
        e.program.isNotEmpty &&
                e.batch.isNotEmpty &&
                _bareSectionRe.hasMatch(e.section) &&
                owned.contains('${e.program}|${e.batch}|${e.section}')
            ? e.withSection('${e.program}-${e.section}')
            : e,
    ];
  }

  // ================= PARSING (CSV fallback / management) =================

  /// Computing day-tab grid from the gviz CSV (fallback path — no cell
  /// colors, so department comes from the section prefix and batch from
  /// any explicit `(... , 25)` label).
  List<TimetableEntry> _parseComputing(String csv, String day) {
    final rows = _parseCsv(csv);

    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < rows.length; i++) {
      final found = _timeColumns(rows[i]);
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    final roomCols = <int>[];
    for (var j = 0; j < rows[headerIndex].length; j++) {
      if (rows[headerIndex][j].trimLeft().toLowerCase().startsWith('room')) {
        roomCols.add(j);
      }
    }

    final entries = <TimetableEntry>[];
    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];

      final rooms = <({int col, String name})>[];
      for (final c in roomCols) {
        if (c < row.length && row[c].trim().isNotEmpty) {
          rooms.add((col: c, name: row[c].trim()));
        }
      }
      if (rooms.isEmpty) continue;

      for (var j = 0; j < row.length; j++) {
        final raw = row[j].trim();
        if (raw.isEmpty || roomCols.contains(j)) continue;
        if (_slotRe.hasMatch(raw)) continue;

        var room = '';
        var roomCol = -1;
        for (final r in rooms) {
          if (r.col < j && r.col > roomCol) {
            room = r.name;
            roomCol = r.col;
          }
        }
        if (room.isEmpty) continue;

        var slot = -1;
        for (var k = 0; k < timeCols.length; k++) {
          if (timeCols[k].col <= j && timeCols[k].col > roomCol) slot = k;
        }
        if (slot < 0) continue;

        final parsed = _parseComputingCell(
          raw,
          timeCols[slot].start,
          timeCols[slot].end,
        );

        // The CSV has no colours and no merges: a two-period lab arrives
        // as a single cell with the period beside it left blank. The
        // course name is what's left that says it's a lab, and that
        // blank period is what's left that says it runs past its own
        // slot — so a lab with a free period after it takes that period
        // too. Lectures are never extended on this evidence alone,
        // since a free period after a lecture is simply a free period.
        var endTime = parsed.end;
        if (parsed.isLab &&
            slot + 1 < timeCols.length &&
            timeCols[slot + 1].col < row.length &&
            row[timeCols[slot + 1].col].trim().isEmpty) {
          endTime = _normalizeTime(_blockEnd(timeCols, slot, slot + 1));
        }

        final prefix = parsed.section.contains('-')
            ? parsed.section.split('-').first
            : '';
        entries.add(
          TimetableEntry(
            day: day,
            startTime: parsed.start,
            endTime: endTime,
            course: parsed.course,
            section: parsed.section,
            program: prefix,
            batch: parsed.batch,
            room: room,
            isLab: parsed.isLab,
            note: parsed.note,
          ),
        );
      }
    }
    return entries;
  }

  /// Engineering day-block sheet from the export CSV (fallback path — no
  /// cell colors, so department comes from the section prefix).
  List<TimetableEntry> _parseEngineering(String csv) {
    final rows = _parseCsv(csv);

    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < rows.length && i < 12; i++) {
      final found = _timeColumns(rows[i]);
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];

    final entries = <TimetableEntry>[];
    var day = '';
    var kind = '';
    var room = '';

    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      String cell(int c) => c < row.length ? row[c].trim() : '';

      var c0 = cell(0);
      var c1 = cell(1);
      var c2 = cell(2);

      if (c0.isNotEmpty) {
        final match = days.where((d) => c0.startsWith(d));
        if (match.isNotEmpty) {
          day = match.first;
          room = '';
          kind = '';
        } else {
          day = '';
          room = '';
          kind = '';
          continue;
        }
      }
      if (c1 == 'Classes' || c1 == 'Labs') {
        kind = c1;
        if (c2 == c1) c2 = '';
      }
      if (c2.isNotEmpty && c2 != 'Room' && c2 != room) room = c2;
      if (day.isEmpty) continue;

      final isCourseRow = c0.isNotEmpty || c1.isNotEmpty || c2.isNotEmpty;

      for (var ti = 0; ti < timeCols.length; ti++) {
        final t = timeCols[ti];
        final raw = cell(t.col);
        if (raw.isEmpty) continue;
        if (_slotRe.hasMatch(raw)) continue;

        if (isCourseRow) {
          final parsed = _parseEngineeringCell(raw, kind);
          final prefix = parsed.section.contains('-')
              ? parsed.section.split('-').first
              : '';

          // The export CSV has no merges to read, so a lab's two-period
          // block arrives as one cell with the period after it blank.
          // The Classes/Labs column still says it's a lab, so that blank
          // period beside it is enough to claim the second one too.
          var endTime = _normalizeTime(t.end);
          if (parsed.isLab &&
              ti + 1 < timeCols.length &&
              timeCols[ti + 1].col < row.length &&
              cell(timeCols[ti + 1].col).isEmpty) {
            endTime = _normalizeTime(_blockEnd(timeCols, ti, ti + 1));
          }

          entries.add(
            TimetableEntry(
              day: day,
              startTime: _normalizeTime(t.start),
              endTime: endTime,
              course: parsed.course,
              section: parsed.section,
              program: prefix,
              batch: parsed.batch,
              room: room,
              isLab: parsed.isLab,
              note: parsed.note,
            ),
          );
        } else {
          final slotStart = _normalizeTime(t.start);
          for (var k = entries.length - 1; k >= 0; k--) {
            final e = entries[k];
            if (e.day == day && e.startTime == slotStart && e.teacher.isEmpty) {
              final split = _parseTeacher(raw);
              entries[k] = TimetableEntry(
                day: e.day,
                startTime: split.start.isEmpty
                    ? e.startTime
                    : _normalizeTime(split.start),
                endTime: split.end.isEmpty
                    ? e.endTime
                    : _normalizeTime(split.end),
                course: e.course,
                section: e.section,
                program: e.program,
                batch: e.batch,
                room: e.room,
                teacher: split.teacher,
                isLab: e.isLab,
                note: split.note.isNotEmpty ? split.note : e.note,
              );
              break;
            }
          }
        }
      }
    }
    return _foldBareEngineeringSections(entries);
  }

  /// Management sheet: day blocks (col 0), Classes/Labs (col 1), room
  /// (col 2), then per time slot a `CODE Course Name` cell paired with a
  /// section-code cell to its right. The section code carries the
  /// department (AF/BBA/BSBA/FT/CS/EE) and batch (01/03/05/07); `MS`
  /// sections are dropped (graduate).
  List<TimetableEntry> _parseManagement(String csv) {
    final rows = _parseCsv(csv);

    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < rows.length && i < 12; i++) {
      final found = _timeColumns(rows[i]);
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
    ];

    // `AF01A`, `BSBA05C`, `FT07A/B`, `MS`...
    final sectionRe = RegExp(r'^[A-Z]{2,5}\s?\d{0,2}[A-Z]{0,3}(?:/[A-Z]\d?)?$');
    // `MG4011 Entrepreneurship`, `LG2009Data Analysis for Business -II
    // Lab` — the sheets do not always put a space between the code and
    // the name, so the gap is optional. Requiring it dropped the whole
    // cell and the class never appeared at all. A cell can also carry
    // two codes for a combined session, `SS1022/SS1021 U-Holy Quran`,
    // and those belong to the code, not the name.
    final courseRe = RegExp(
      r'^([A-Z]{2}\s?\d{4}(?:\s*/\s*[A-Z]{2}\s?\d{4})?)\s*(.*)$',
    );

    final entries = <TimetableEntry>[];
    var day = '';
    var kind = '';
    var room = '';

    for (var i = headerIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      String cell(int c) =>
          c < row.length ? row[c].replaceAll(RegExp(r'\s+'), ' ').trim() : '';

      final c0 = cell(0);
      final c1 = cell(1);
      final c2 = cell(2);

      if (c0.isNotEmpty) {
        final match = days.where((d) => c0.startsWith(d));
        if (match.isNotEmpty) {
          day = match.first;
          room = '';
          kind = '';
        } else {
          // Footer/legend rows ("BS(AF)-Batch 2024") end the day blocks.
          day = '';
          room = '';
          kind = '';
          continue;
        }
      }
      if (c1 == 'Classes' || c1 == 'Labs') kind = c1;
      if (c2.isNotEmpty &&
          c2 != 'Room' &&
          c2.toLowerCase() != 'labs' &&
          c2 != room) {
        room = c2;
      }

      if (day.isEmpty || room.isEmpty) continue;
      if (c0.isEmpty && c1.isEmpty && c2.isEmpty) continue;

      final cells = <({int col, String text})>[];
      for (var j = 3; j < row.length; j++) {
        final text = cell(j);
        if (text.isEmpty || _slotRe.hasMatch(text)) continue;
        cells.add((col: j, text: text));
      }

      // Management draws a two-period lab by writing the same course and
      // section into the period and the one after it. Remembering the
      // entry just made lets that pair be read as the single three-hour
      // block it is, instead of two short classes back to back.
      var lastEntryIndex = -1;
      var lastSlot = -1;
      var lastHadInlineTime = false;
      var lastRawSection = '';

      for (var k = 0; k < cells.length; k++) {
        final match = courseRe.firstMatch(cells[k].text);
        if (match == null) continue;

        var slot = -1;
        for (var s = 0; s < timeCols.length; s++) {
          if (timeCols[s].col <= cells[k].col) slot = s;
        }
        if (slot < 0) continue;

        var start = timeCols[slot].start;
        var end = timeCols[slot].end;
        var name = match.group(2)!;
        var hasInlineTime = false;

        // Brackets are usual but not required — a cell is also written
        // `Psychology 8:30 - 10:20` — so the time is taken either way
        // and stripped from the name rather than left on display.
        final inline = RegExp(
          r'\(?(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\)?',
        ).firstMatch(name);
        if (inline != null) {
          start = inline.group(1)!;
          end = inline.group(2)!;
          name = name
              .replaceAll(RegExp(r'\(?\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}\)?'), '')
              .trim();
          // A time typed into the cell is a deliberate one-off (a
          // rescheduled class), so it is never joined to its neighbour.
          hasInlineTime = true;
        }

        // The section code sits at the far end of the same period as its
        // course. It is kept exactly as written as well as parsed:
        // codes like `BBA01A2` carry a group digit the section grammar
        // doesn't model, but two cells writing the same code are still
        // unarguably the same section — while a cell belonging to the
        // *next* period, or no cell at all, is not a section to compare.
        var section = '';
        var rawSection = '';
        if (k + 1 < cells.length) {
          final next = cells[k + 1];
          final periodEnd = slot + 1 < timeCols.length
              ? timeCols[slot + 1].col - 1
              : timeCols[slot].col +
                    (timeCols[slot].col - timeCols[slot - 1].col) -
                    1;
          if (next.col <= periodEnd) {
            rawSection = next.text;
            if (sectionRe.hasMatch(next.text)) {
              section = _padManagementIntake(next.text.replaceAll(' ', ''));
              k++; // consume it so it isn't mistaken for a course
            }
          }
        }

        // Decompose the section code into department + batch. The
        // department is the leading letters; the batch is an odd intake
        // number (`01`/`03`/`05`/`07`) that [_managementBatch] turns into
        // the admission year, so the batch filter reads the same as
        // Computing's and Engineering's.
        var dept = '';
        var batch = '';
        if (section.isNotEmpty) {
          final sm = RegExp(r'^([A-Za-z]+)(\d{1,2})?').firstMatch(section);
          if (sm != null) {
            dept = sm.group(1)!.toUpperCase();
            final b = sm.group(2);
            if (b != null) {
              // The sheet has stray unpadded codes ("AF3A"); pad to two
              // digits before mapping.
              batch = _managementBatch(b.length == 1 ? '0$b' : b);
            }
          }
        }
        if (dept == 'MS') continue; // graduate — removed.

        // A sheet that skips the space usually puts a separator instead:
        // `AF5007-Advanced Financial Management`. It is dropped rather
        // than joined with a space, which would read `AF5007 -Advanced`.
        // Only a separator at the very start goes — the ones inside a
        // name (`U-Holy Quran-I&II`) are part of it.
        final displayName = name
            .trim()
            .replaceFirst(RegExp(r'^[-–—:;,.]+\s*'), '');
        final courseText = displayName.isEmpty
            ? match.group(1)!.replaceAll(' ', '')
            : '${match.group(1)!.replaceAll(' ', '')} $displayName';
        final isLab =
            kind == 'Labs' ||
            RegExp(r'\blab\b', caseSensitive: false).hasMatch(name);

        // The second half of a two-period lab: same course, the same
        // section written the same way, and the very next period — the
        // sheet wrote the lab out twice, so both periods are its own.
        // Stretch the entry already made over it rather than listing the
        // lab twice. An absent section blocks the join: with nothing to
        // tell two neighbouring cells apart, assuming they match would
        // weld unrelated groups together.
        //
        // Only labs join. Management has no merged cells to read — it
        // writes one cell per period — so a repeated pair of cells for
        // any other course is equally read as two back-to-back sessions,
        // and those are listed as the sheet drew them.
        if (isLab &&
            lastEntryIndex >= 0 &&
            !hasInlineTime &&
            !lastHadInlineTime &&
            slot == lastSlot + 1 &&
            entries[lastEntryIndex].course == courseText &&
            rawSection.isNotEmpty &&
            rawSection == lastRawSection) {
          final prev = entries[lastEntryIndex];
          entries[lastEntryIndex] = TimetableEntry(
            day: prev.day,
            startTime: prev.startTime,
            endTime: _normalizeTime(_blockEnd(timeCols, lastSlot, slot)),
            course: prev.course,
            section: prev.section,
            program: prev.program,
            batch: prev.batch,
            room: prev.room,
            isLab: prev.isLab,
          );
          // Step forward so a third period in a row extends it again
          // rather than starting a fresh entry.
          lastSlot = slot;
          lastHadInlineTime = hasInlineTime;
          lastRawSection = rawSection;
          continue;
        }

        lastEntryIndex = entries.length;
        lastSlot = slot;
        lastHadInlineTime = hasInlineTime;
        lastRawSection = rawSection;

        entries.add(
          TimetableEntry(
            day: day,
            startTime: _normalizeTime(start),
            endTime: _normalizeTime(end),
            course: courseText,
            section: section,
            program: dept,
            batch: batch,
            room: room,
            isLab: isLab,
          ),
        );
      }
    }
    return entries;
  }

  /// Management's intake code (`01`, `03`...) as the admission year.
  /// Unknown or even codes pass through untouched, so nothing is
  /// silently relabelled if the sheet ever changes shape.
  static String _managementBatch(String code) {
    final n = int.tryParse(code);
    if (n == null || n < 1 || n.isEven || n > 20) return code;
    return '${_managementIntakeYear - (n - 1) ~/ 2}';
  }

  /// Pads a one-digit intake so both spellings are one section.
  ///
  /// The sheet writes `AF3A` next to `AF03A`, `BBA3A` next to
  /// `BBA03A`, `FT3A` next to `FT03A` — the same section (batch
  /// `03` = the 2025 intake, which is what [_managementBatch] already
  /// maps both to) typed two ways in different blocks. Left as-is the
  /// section list offers both, and once the code is shortened for
  /// display they would read as the very same chip twice.
  ///
  /// Only a single digit *between* the department letters and the
  /// section letters counts, so `AF07A`, `BSBA01E` and `FT07A/B` are
  /// left alone.
  static String _padManagementIntake(String section) {
    final m = RegExp(r'^([A-Za-z]{2,5})(\d)(?=[A-Za-z])').firstMatch(section);
    if (m == null) return section;
    return '${m.group(1)!}0${m.group(2)!}${section.substring(m.end)}';
  }

  // ================= CELL TEXT =================

  ({
    String course,
    String section,
    String batch,
    String start,
    String end,
    bool isLab,
    String note,
  })
  _parseComputingCell(String raw, String slotStart, String slotEnd) {
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    var section = '';
    var batch = '';
    final paren = RegExp(r'\(([^)]*)\)').firstMatch(text);
    if (paren != null) {
      final inner = paren.group(1)!.trim();
      final sm = RegExp(
        r'^([A-Za-z]{1,4})\s*-\s*([A-Z]\d?)'
        r'(?:\s*,\s*(\d{2,4}))?$',
      ).firstMatch(inner);
      if (sm != null) {
        section = '${sm.group(1)!}-${sm.group(2)!}'.toUpperCase();
        // The sheet sometimes writes a 2-digit batch ("25"); normalize
        // to the full year so it matches the color legend's "2025".
        final b = sm.group(3) ?? '';
        batch = b.length == 2 ? '20$b' : b;
      }
    }

    var note = '';
    if (RegExp(r'\bReSch\b', caseSensitive: false).hasMatch(text)) {
      note = 'ReSch';
    }

    var start = slotStart;
    var end = slotEnd;
    final inline = RegExp(
      r'\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}',
    ).firstMatch(text.replaceAll(RegExp(r'\([^)]*\)'), ''));
    if (inline != null) {
      final parts = inline.group(0)!.split(RegExp(r'\s*-\s*'));
      start = parts[0];
      end = parts[1];
    }

    var course = text
        .replaceAll(RegExp(r'\([^)]*\)'), '')
        .replaceAll(RegExp(r'\d{1,2}:\d{2}\s*-\s*\d{1,2}:\d{2}'), '')
        .replaceAll(RegExp(r'\bReSch\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    return (
      course: course,
      section: section,
      batch: batch,
      start: _normalizeTime(start),
      end: _normalizeTime(end),
      isLab: RegExp(r'\blab\b', caseSensitive: false).hasMatch(course),
      note: note,
    );
  }

  /// Engineering cells are `Course EE-A`, `Course A` (bare letter
  /// sections) or `EMT -A`; schedule changes appear as
  /// `(Resch) Oct 12, 2026` and some labs carry `(Batch 2025)`.
  ({String course, String section, String batch, bool isLab, String note})
  _parseEngineeringCell(String raw, String kind) {
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    var note = '';
    final resch = RegExp(
      r'\(Resch\)\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (resch != null) {
      note = 'Resch ${resch.group(1)!.trim()}';
      text = text.substring(0, resch.start).trim();
    }

    var section = '';
    var batch = '';
    final batchMatch = RegExp(
      r'\((?:Batch\s*)?(\d{4})\)$',
      caseSensitive: false,
    ).firstMatch(text);
    if (batchMatch != null) {
      batch = batchMatch.group(1)!;
      text = text.substring(0, batchMatch.start).trim();
    }

    final programSection = RegExp(
      r'^(.*?)\s*([A-Z]{2,3})\s*-\s*([A-Z]\d?)\s*$',
    ).firstMatch(text);
    final bareSection = RegExp(r'^(.*?)\s+([A-E])$').firstMatch(text);
    if (programSection != null && programSection.group(1)!.trim().isNotEmpty) {
      if (programSection.group(2)!.length == 2) {
        section = '${programSection.group(2)!}-${programSection.group(3)!}';
        text = programSection.group(1)!.trim();
      } else {
        section = programSection.group(3)!;
        text = '${programSection.group(1)!} ${programSection.group(2)!}'.trim();
      }
    } else if (programSection != null &&
        programSection.group(1)!.trim().isEmpty &&
        programSection.group(2)!.length == 3) {
      section = programSection.group(3)!;
      text = programSection.group(2)!;
    } else if (bareSection != null && bareSection.group(1)!.trim().isNotEmpty) {
      section = bareSection.group(2)!;
      text = bareSection.group(1)!.trim();
    }

    return (
      course: text,
      section: section,
      batch: batch,
      isLab:
          kind == 'Labs' ||
          RegExp(r'\blab\b', caseSensitive: false).hasMatch(text),
      note: note,
    );
  }

  /// Teacher cell. It can also carry the change information:
  ///  * `Engr. Aleena Shafiq (Resch) Oct 12, 2026` — moved class
  ///  * `Dr. Muhammad Adnan 05:15 - 08:00` — make-up at a new time
  ///  * `09-10-26` — just a date, no teacher
  ({String teacher, String note, String start, String end}) _parseTeacher(
    String raw,
  ) {
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();

    final dateOnly = RegExp(r'^\d{1,2}-\d{1,2}-\d{2,4}$').firstMatch(text);
    if (dateOnly != null) {
      return (teacher: '', note: 'Resch $text', start: '', end: '');
    }

    var body = text;
    var note = '';
    final resch = RegExp(
      r'\s*\(Resch\)\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(body);
    if (resch != null) {
      note = 'Resch ${resch.group(1)!.trim()}';
      body = body.substring(0, resch.start).trim();
    }

    var start = '';
    var end = '';
    final inline = RegExp(
      r'(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\s*$',
    ).firstMatch(body);
    if (inline != null) {
      start = inline.group(1)!;
      end = inline.group(2)!;
      body = body.substring(0, inline.start).trim();
    }

    return (teacher: body, note: note, start: start, end: end);
  }

  /// `8:30` and `08:30` both appear across the two sheets — normalize
  /// everything to zero-padded 24h so sorting and display agree.
  static String _normalizeTime(String t) {
    final parts = t.split(':');
    if (parts.length != 2) return t;
    final h = int.tryParse(parts[0]);
    if (h == null) return t;
    return '${h.toString().padLeft(2, '0')}:${parts[1].padLeft(2, '0')}';
  }

  List<({int col, String start, String end})> _timeColumns(List<String> row) {
    final found = <({int col, String start, String end})>[];
    for (var j = 0; j < row.length; j++) {
      final m = _slotRe.firstMatch(row[j]);
      if (m != null) {
        found.add((col: j, start: m.group(1)!, end: m.group(2)!));
      }
    }
    return found;
  }

  /// When a cell's colour reaches past its own time slot, when does the
  /// class actually end?
  ///
  /// [ownSlot] is the period the cell starts in, and [spanEndCol] is the
  /// last sheet column the cell's merged colour covers. The sheets draw
  /// a three-hour lab as one cell across two slots — Computing's COAL
  /// Lab sits at column 11 with colspan 9, covering the 11:30-12:50 and
  /// 01:00-02:20 periods — and reading only the first of those is what
  /// made every lab look like a single 1h20m lecture.
  ///
  /// A period only counts as occupied when the cell covers it *whole*.
  /// Merely reaching into the next one means the cell was drawn that way
  /// for spacing, not length — an `FSM` block five columns wide brushes
  /// a single column of the period beside it and must not be read as
  /// running for three hours.
  static String _spannedEnd(
    List<({int col, String start, String end})> timeCols,
    int ownSlot,
    int spanEndCol,
  ) {
    var last = ownSlot;
    for (var k = ownSlot + 1; k < timeCols.length; k++) {
      if (spanEndCol < _slotLastCol(timeCols, k)) break;
      last = k;
    }
    return _blockEnd(timeCols, ownSlot, last);
  }

  /// Where a block that occupies [ownSlot] through [lastSlot] ends.
  ///
  /// A block runs until the last period it covers *finishes*, which is how
  /// the labs are actually timetabled: 11:30 and 01:00 come out as
  /// 11:30-02:20, not 11:30-02:30 — the sheet's coloured block stops at
  /// the end of the second period, it does not run into the next one. A
  /// block one period long returns its own period's end, so ordinary
  /// lectures are unaffected.
  static String _blockEnd(
    List<({int col, String start, String end})> timeCols,
    int ownSlot,
    int lastSlot,
  ) => timeCols[lastSlot].end;

  /// The last sheet column period [k] occupies.
  ///
  /// A period label is followed by one spacer column — the break between
  /// classes — so the period ends two columns before the next label.
  static int _slotLastCol(
    List<({int col, String start, String end})> timeCols,
    int k,
  ) {
    if (k + 1 < timeCols.length) return timeCols[k + 1].col - 2;
    if (k > 0) {
      // The final label has no successor; keep the spacing of the one
      // before it.
      return timeCols[k].col + (_slotLastCol(timeCols, k - 1) -
          timeCols[k - 1].col);
    }
    return timeCols[k].col;
  }

  // ================= CSV =================

  /// Minimal RFC-4180 CSV reader (quotes, doubled quotes, embedded
  /// newlines) — the sheets use all three.
  static List<List<String>> _parseCsv(String text) {
    final rows = <List<String>>[];
    var row = <String>[];
    var field = StringBuffer();
    var inQuotes = false;

    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inQuotes) {
        if (c == '"') {
          if (i + 1 < text.length && text[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(c);
        }
      } else if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        row.add(field.toString());
        field = StringBuffer();
      } else if (c == '\n') {
        row.add(field.toString());
        rows.add(row);
        row = <String>[];
        field = StringBuffer();
      } else if (c != '\r') {
        field.write(c);
      }
    }
    if (field.isNotEmpty || row.isNotEmpty) {
      row.add(field.toString());
      rows.add(row);
    }
    // The sheets lose brackets as often in CSV as in HTML — a course is
    // written `(10:00-11:50))` and a room with no closing paren — so
    // every field is repaired the same way the HTML cells are.
    for (final r in rows) {
      for (var i = 0; i < r.length; i++) {
        r[i] = _balanceParens(r[i]);
      }
    }
    return rows;
  }

  // ================= CACHE =================

  static String _key(String schoolId) => 'timetable_$schoolId';

  Future<TimetableResult?> _readCache(String schoolId) async {
    try {
      final cached = _memory[schoolId];
      if (cached != null && !cached.fromCache) return cached;

      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_key(schoolId));
      if (raw == null) return null;

      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['v'] != _cacheVersion) return null; // stale format
      final entries = (decoded['entries'] as List<dynamic>)
          .map(
            (e) => TimetableEntry.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .toList();
      return TimetableResult(
        entries: entries,
        fetchedAt:
            DateTime.tryParse(decoded['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (e) {
      debugPrint('Timetable cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeCache(String schoolId, TimetableResult result) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(schoolId),
        jsonEncode({
          'v': _cacheVersion,
          'fetchedAt': result.fetchedAt.toIso8601String(),
          'entries': result.entries.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (e) {
      debugPrint('Timetable cache write failed: $e');
    }
  }
}
