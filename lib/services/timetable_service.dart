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
  const SheetCell({this.text = '', this.bg = ''});
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
  /// (missing the color-derived program/batch) are discarded.
  static const int _cacheVersion = 3;

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
  static List<TimetableEntry> filterBy(
    List<TimetableEntry> entries, {
    String department = '',
    String batch = '',
    String section = '',
  }) {
    return entries.where((e) {
      if (department.isNotEmpty && e.program != department) return false;
      if (batch.isNotEmpty && e.batch != batch) return false;
      if (section.isNotEmpty && e.section != section) return false;
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

        _setCell(row, col, SheetCell(text: text, bg: bg));

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

  static String _stripHtml(String s) => s
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

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

        final parsed = _parseComputingCell(
          raw,
          timeCols[slot].start,
          timeCols[slot].end,
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

      for (final t in timeCols) {
        final raw = text(t.col);
        if (raw.isEmpty) continue;
        if (_slotRe.hasMatch(raw)) continue;

        if (isCourseRow) {
          final bg = t.col < row.length ? row[t.col].bg : '';
          final parsed = _parseEngineeringCell(raw, kind);
          final prefix = parsed.section.contains('-')
              ? parsed.section.split('-').first
              : '';
          final color = _resolveColor(legend, bg, prefix);
          if (color.drop) continue; // MS / PhD cell — removed.

          entries.add(
            TimetableEntry(
              day: day,
              startTime: _normalizeTime(t.start),
              endTime: _normalizeTime(t.end),
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
    return entries;
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
        final prefix = parsed.section.contains('-')
            ? parsed.section.split('-').first
            : '';
        entries.add(
          TimetableEntry(
            day: day,
            startTime: parsed.start,
            endTime: parsed.end,
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

      for (final t in timeCols) {
        final raw = cell(t.col);
        if (raw.isEmpty) continue;
        if (_slotRe.hasMatch(raw)) continue;

        if (isCourseRow) {
          final parsed = _parseEngineeringCell(raw, kind);
          final prefix = parsed.section.contains('-')
              ? parsed.section.split('-').first
              : '';
          entries.add(
            TimetableEntry(
              day: day,
              startTime: _normalizeTime(t.start),
              endTime: _normalizeTime(t.end),
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
    return entries;
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
    // `MG4011 Entrepreneurship`, `LG2009Data Analysis for Business -II Lab`
    final courseRe = RegExp(r'^([A-Z]{2}\s?\d{4})\s+(.*)$');

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

        final inline = RegExp(
          r'\((\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})\)',
        ).firstMatch(name);
        if (inline != null) {
          start = inline.group(1)!;
          end = inline.group(2)!;
          name = name.replaceAll(RegExp(r'\(.*?\)'), '').trim();
        }

        var section = '';
        if (k + 1 < cells.length) {
          final next = cells[k + 1];
          if (sectionRe.hasMatch(next.text)) {
            section = next.text.replaceAll(' ', '');
            k++; // consume it so it isn't mistaken for a course
          }
        }

        // Decompose the section code into department + batch year.
        var dept = '';
        var batch = '';
        if (section.isNotEmpty) {
          final sm = RegExp(r'^([A-Za-z]+)(\d{1,2})?').firstMatch(section);
          if (sm != null) {
            dept = sm.group(1)!.toUpperCase();
            final b = sm.group(2);
            if (b != null) batch = b.length == 1 ? '0$b' : b;
          }
        }
        if (dept == 'MS') continue; // graduate — removed.

        entries.add(
          TimetableEntry(
            day: day,
            startTime: _normalizeTime(start),
            endTime: _normalizeTime(end),
            course: '${match.group(1)!.replaceAll(' ', '')} ${name.trim()}'
                .trim(),
            section: section,
            program: dept,
            batch: batch,
            room: room,
            isLab:
                kind == 'Labs' ||
                RegExp(r'\blab\b', caseSensitive: false).hasMatch(name),
          ),
        );
      }
    }
    return entries;
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
