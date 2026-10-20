// lib/services/timetable_service.dart

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/room_occupancy.dart';
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

/// A room being read out of one sheet: the stretches it is booked, and
/// whether the sheet filed it under its `Labs` section.
///
/// One entry per (day, room); a room that appears twice on a tab — the
/// daytime and evening grids both list Computing's D-block — accumulates
/// into the same entry, which is what makes "free at 6pm" correct for it.
class _RoomDraft {
  final List<TimeRange> occupied = [];

  /// Starts as the section the room was first seen in and is promoted to
  /// a lab if either section claims it. No room is in both today, so
  /// this only ever settles the same way as the sheet's own header.
  bool isLab;

  _RoomDraft(this.isLab);
}

/// One school's rooms for one day, and how fresh they are.
///
/// [fromCache] is what lets a screen say it is showing a saved copy
/// instead of presenting hours-old rooms as if they had just been read.
/// A record rather than a class because the three values only ever
/// travel together.
typedef RoomDay = ({
  List<RoomOccupancy> rooms,
  DateTime fetchedAt,
  bool fromCache,
});

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
  ) => _blockEnd(timeCols, ownSlot, _spannedSlot(timeCols, ownSlot, spanEndCol));

  /// The last period a cell starting in [ownSlot] covers, given that its
  /// merged fill reaches [spanEndCol].
  ///
  /// Same rule as [_spannedEnd], kept as an index so callers who need
  /// the period's *minutes* rather than its clock label do not have to
  /// convert a bare time back out of context.
  static int _spannedSlot(
    List<({int col, String start, String end})> timeCols,
    int ownSlot,
    int spanEndCol,
  ) {
    var last = ownSlot;
    for (var k = ownSlot + 1; k < timeCols.length; k++) {
      if (spanEndCol < _slotLastCol(timeCols, k)) break;
      last = k;
    }
    return last;
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

  // ================= ROOMS =================

  /// How long a room list stays fresh, on the same window the timetable
  /// cache uses — both are read from the same sheets.
  static const Duration _roomsTtl = Duration(hours: 6);

  /// A fetch time that reads as "never", so a list with no history
  /// behind it hides the footer rather than dating itself to 1970.
  static final _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  /// The weekday names the sheets use for their day blocks.
  static const List<String> _weekdays = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  /// Matches a cell that *begins* with a time range.
  ///
  /// Computing labels its last evening lab slot
  /// `05:20 - 08:05 (inc. 10 min. break)`, which no `^...$` pattern can
  /// match. Reading only the strict columns would leave that one period
  /// unrecognised, and everything booked into it — every evening lab —
  /// would read as free.
  static final RegExp _leadingSlotRe = RegExp(
    r'^\s*(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})',
  );

  /// Matches a time range written inside a cell, as the sheets do for a
  /// class that does not sit on the period boundary.
  static final RegExp _inlineSlotRe = RegExp(
    r'(\d{1,2}:\d{2})\s*-\s*(\d{1,2}:\d{2})',
  );

  /// Matches Management's bare section codes — `AF07B`, `BBA01B`,
  /// `FT07A/B` — which sit in a period of their own beside the course
  /// they belong to.
  ///
  /// Two digits is what separates a code from a course number: `BSBA05C`
  /// is a section, `MG4011` is a course.
  static final RegExp _sectionCodeRe = RegExp(
    r'^[A-Z]{2,5}\s?\d{2}[A-Z]{0,2}(?:/[A-Z]\d?)?$',
  );

  /// Every room [school] publishes for [day], with the stretches each is
  /// booked.
  ///
  /// Separate from [load] because the two need different things out of
  /// the same sheet: a [TimetableEntry] is one occupied cell, so a room
  /// free the whole day emits nothing and vanishes from the list
  /// entirely — precisely the rooms this is for. This keeps the room
  /// labels and the empty cells too.
  ///
  /// [day] is a full weekday name. Sunday is on no sheet, so it returns
  /// empty rather than borrowing another day's rooms.
  Future<RoomDay> loadRooms(
    SchoolConfig school,
    String day, {
    bool forceRefresh = false,
  }) async {
    if (!school.available || !_weekdays.contains(day)) {
      return (
        rooms: const <RoomOccupancy>[],
        fetchedAt: _epoch,
        fromCache: false,
      );
    }

    final cached = await _readRoomCache(school.id, day);
    if (!forceRefresh &&
        cached != null &&
        DateTime.now().difference(cached.$1) < _roomsTtl) {
      return (rooms: cached.$2, fetchedAt: cached.$1, fromCache: true);
    }

    try {
      final rooms = await _fetchRooms(school, day);
      final fetchedAt = DateTime.now();
      await _writeRoomCache(school.id, day, rooms);
      return (rooms: rooms, fetchedAt: fetchedAt, fromCache: false);
    } catch (e) {
      // An hour-old list beats none at all — but only when there is one
      // to fall back on.
      if (cached != null) {
        return (rooms: cached.$2, fetchedAt: cached.$1, fromCache: true);
      }
      rethrow;
    }
  }

  /// Every room published for [day] across all three schools, with a
  /// room two sheets share booked against both of their books.
  ///
  /// The union is about correctness and not only coverage: `C-405` sits
  /// in Computing's and Management's Wednesday grids and `C-406`/`C-407`
  /// in Thursday's, so listing each sheet's copy side by side would
  /// offer a room that a class from the other school is sitting in.
  ///
  /// One day at a time, because Computing spreads its weekdays over six
  /// tabs — asking for the whole week would be six requests to show one
  /// day's rooms.
  Future<RoomDay> loadAllRooms(String day, {bool forceRefresh = false}) async {
    final results = await Future.wait([
      for (final school in kSchools)
        loadRooms(school, day, forceRefresh: forceRefresh),
    ]);

    var fetchedAt = _epoch;
    var fromCache = true;
    for (final r in results) {
      if (r.fetchedAt.isAfter(fetchedAt)) fetchedAt = r.fetchedAt;
      // Fresh if any school answered from the network: a list that mixes
      // a live fetch with a saved copy is still partly live.
      if (!r.fromCache) fromCache = false;
    }

    return (
      rooms: coalesceRooms(results.expand((r) => r.rooms)),
      fetchedAt: fetchedAt,
      fromCache: fromCache,
    );
  }

  Future<List<RoomOccupancy>> _fetchRooms(
    SchoolConfig school,
    String day,
  ) async {
    if (school.hasDayTabs) {
      final gid = school.dayGids[day];
      if (gid == null) return const [];
      try {
        final html = await _fetchHtml(school, gid);
        return _parseRoomsComputing(_parseHtmlTable(html).grid, day, school.id);
      } catch (e) {
        debugPrint(
          'Computing room sheet htmlview failed, falling back to CSV: $e',
        );
        final csv = await _fetchCsv(school, gid);
        return _parseRoomsComputing(_asGrid(_parseCsv(csv)), day, school.id);
      }
    }

    if (school.layout == SheetLayout.engineering) {
      // Unlike [load] there is no CSV fallback here. Engineering draws a
      // lab as one cell merged across two periods, and a CSV flattens
      // that merge to a single occupied cell — leaving the lab's second
      // period reading as spare time, and offering a busy room to
      // whoever asked. No list is the safer answer.
      final html = await _fetchHtml(school, school.defaultGid!);
      return _keepDay(
        _parseRoomsDayBlocks(_parseHtmlTable(html).grid, school.id),
        day,
      );
    }

    final csv = await _fetchCsv(school, school.defaultGid);
    return _keepDay(
      _parseRoomsDayBlocks(_asGrid(_parseCsv(csv)), school.id),
      day,
    );
  }

  static List<RoomOccupancy> _keepDay(
    List<RoomOccupancy> rooms,
    String day,
  ) => [for (final r in rooms) if (r.day == day) r];

  /// Wraps parsed CSV rows in the same cell shape the HTML parser
  /// produces, so one room parser can read both.
  ///
  /// A CSV cannot carry a merge, so every cell comes back one column
  /// wide — which costs nothing for Management, whose two-period labs
  /// are written into both period cells rather than drawn as one block.
  static List<List<SheetCell>> _asGrid(List<List<String>> rows) => [
    for (final r in rows) [for (final f in r) SheetCell(text: f)],
  ];

  /// Time columns of a header row, as (column, start, end).
  ///
  /// Unlike [_timeColumns] a label only has to *start* with a range, so
  /// Computing's annotated evening lab slot still counts.
  static List<({int col, String start, String end})> _leadingTimeColumns(
    List<String> row,
  ) {
    final found = <({int col, String start, String end})>[];
    for (var j = 0; j < row.length; j++) {
      final m = _leadingSlotRe.firstMatch(row[j]);
      if (m != null) {
        found.add((col: j, start: m.group(1)!, end: m.group(2)!));
      }
    }
    return found;
  }

  /// Widens a day window to cover [cols].
  ///
  /// The window starts at zero, so the first row to report times sets
  /// both ends and every later one only grows them.
  static (int, int) _windowFrom(
    (int, int) window,
    List<({int col, String start, String end})> cols,
  ) {
    if (cols.isEmpty) return window;
    final (s, e) = minutesRange(cols.first.start, cols.last.end);
    return (
      window.$1 == 0 || s < window.$1 ? s : window.$1,
      e > window.$2 ? e : window.$2,
    );
  }

  /// Each period as start/end minutes, in the half-day reading
  /// [minutesRange] gives a pair of clock times.
  static List<(int, int)> _slotMinutes(
    List<({int col, String start, String end})> timeCols,
  ) => [for (final t in timeCols) minutesRange(t.start, t.end)];

  /// Whether a label in a sheet's room column names a room.
  ///
  /// The sheets park their own headings in that column — `Room`,
  /// `Classes`, `Labs` — and the auditorium sits in it while being one
  /// hall booked for events rather than by the hour, so all of them are
  /// dropped before anything else looks at them.
  static bool _isRoomLabel(String label) {
    final lower = label.trim().toLowerCase();
    if (lower.isEmpty) return false;
    if (lower == 'room' || lower == 'classes') return false;
    if (lower == 'lab' || lower == 'labs') return false;
    // `Audi` and `Audiatoriam`: one hall, never spare between events.
    if (lower.startsWith('audi')) return false;
    return true;
  }

  /// The period a cell at [col] falls in: the last time label at or
  /// before it that still sits after [afterCol], or -1 when there is
  /// none.
  ///
  /// The second half of that is what keeps Computing's two grids apart.
  /// Its rows carry a room label at column 0 *and* another beside the
  /// evening grid, with cells for both on the same row, so a cell may
  /// only be booked against a period starting after the label it belongs
  /// to — otherwise an evening class lands in a daytime room.
  static int _slotFor(
    List<({int col, String start, String end})> timeCols,
    int col,
    int afterCol,
  ) {
    var slot = -1;
    for (var k = 0; k < timeCols.length; k++) {
      if (timeCols[k].col > col) break;
      if (timeCols[k].col <= afterCol) continue;
      slot = k;
    }
    return slot;
  }

  /// Books one occupied cell.
  ///
  /// [slot] is the period the cell starts in and [spanEndCol] the last
  /// column its merged fill reaches. Returns the booking so a caller can
  /// widen it — see the section codes in the day-block sheets.
  static TimeRange? _record(
    Map<(String, String), _RoomDraft> drafts, {
    required String day,
    required String room,
    required bool isLab,
    required List<({int col, String start, String end})> timeCols,
    required List<(int, int)> slotMinutes,
    required int slot,
    required int spanEndCol,
    required String body,
  }) {
    if (day.isEmpty || slot < 0 || !_isRoomLabel(room)) return null;

    TimeRange? range;
    // A time typed into the cell overrides the period: the sheets record
    // rescheduled and split classes that way, and keeping only the
    // period would call a room free while a class sits in it.
    final inline = _inlineSlotRe.firstMatch(body);
    if (inline != null) {
      range = TimeRange.parse(
        _normalizeTime(inline.group(1)!),
        _normalizeTime(inline.group(2)!),
      );
    } else {
      // Both ends come from period tables rather than from a bare clock
      // time, so an evening slot's `08:05` end is read against the
      // 18:40 start beside it instead of as the morning.
      final last = _spannedSlot(timeCols, slot, spanEndCol);
      range = TimeRange(
        start: slotMinutes[slot].$1,
        end: slotMinutes[last].$2,
      );
    }
    if (range == null || range.end <= range.start) return null;

    final draft = drafts.putIfAbsent((day, room), () => _RoomDraft(isLab));
    // A room filed under `Labs` by either section stays a lab.
    if (isLab) draft.isLab = true;
    draft.occupied.add(range);
    return range;
  }

  static List<RoomOccupancy> _finishRooms(
    Map<(String, String), _RoomDraft> drafts,
    String schoolId,
    (int, int) window,
  ) {
    // A class can sit outside the periods the header advertises —
    // Engineering records a make-up as `05:15 -08:00` — and a window
    // stopping at the last labelled period would then call the rest of
    // the day free while a booking is in it.
    var start = window.$1;
    var end = window.$2;
    for (final draft in drafts.values) {
      for (final r in draft.occupied) {
        if (start == 0 || r.start < start) start = r.start;
        if (r.end > end) end = r.end;
      }
    }

    return [
      for (final e in drafts.entries)
        RoomOccupancy(
          room: e.key.$2,
          building: buildingOf(e.key.$2),
          isLab: e.value.isLab,
          day: e.key.$1,
          schools: [schoolId],
          occupied: mergeRanges(e.value.occupied),
          dayStart: start,
          dayEnd: end,
        ),
    ];
  }

  /// One day's Computing tab: a room x time grid, a second evening grid
  /// hung off its own `Room` column to the right, and a `Lab` separator
  /// that opens labs with time headers of their own — `08:30-11:15`
  /// against the daytime `08:30-09:50`.
  ///
  /// Returns that one day only; the tab holds no other.
  static List<RoomOccupancy> _parseRoomsComputing(
    List<List<SheetCell>> grid,
    String day,
    String schoolId,
  ) {
    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < grid.length && i < 12; i++) {
      final found = _leadingTimeColumns(_texts(grid[i]));
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    // Every column headed `Room`: column 0 for the daytime grid, and one
    // more beside the evening grid.
    final roomCols = <int>[
      for (var j = 0; j < grid[headerIndex].length; j++)
        if (grid[headerIndex][j].text
            .trimLeft()
            .toLowerCase()
            .startsWith('room'))
          j,
    ];
    if (roomCols.isEmpty) return const [];

    var window = _windowFrom((0, 0), timeCols);

    final drafts = <(String, String), _RoomDraft>{};
    var kind = 'Classes';
    var activeCols = timeCols;

    for (var i = headerIndex + 1; i < grid.length; i++) {
      final row = grid[i];
      String text(int c) => c < row.length ? row[c].text.trim() : '';

      // The labs name themselves in the room column and restate the time
      // headers. Switching the label without the headers — or the
      // headers without the label — would read every lab as running
      // past its true end.
      final section = text(roomCols.first).toLowerCase();
      if (section == 'lab' || section == 'labs') {
        kind = 'Labs';
        final labCols = _leadingTimeColumns(_texts(row));
        if (labCols.length >= 3) {
          activeCols = labCols;
          window = _windowFrom(window, labCols);
        }
        continue;
      }
      if (section == 'classes') {
        kind = 'Classes';
        continue;
      }

      final rooms = <({int col, String name})>[
        for (final c in roomCols)
          if (_isRoomLabel(text(c))) (col: c, name: text(c)),
      ];
      if (rooms.isEmpty) continue;

      // A room is listed the moment the sheet names it, not the moment
      // it is booked: the ones free the whole day carry no cell at all,
      // and losing those is the bug this is here to fix.
      for (final r in rooms) {
        drafts.putIfAbsent((day, r.name), () => _RoomDraft(kind == 'Labs'));
      }

      final slotMinutes = _slotMinutes(activeCols);

      for (var j = 0; j < row.length; j++) {
        if (roomCols.contains(j)) continue;
        final cell = row[j];
        final body = cell.text.trim();
        if (body.isEmpty || _slotRe.hasMatch(body)) continue;

        // A cell belongs to the nearest room label on its left; with two
        // grids sharing the row, anything else books an evening class
        // into a daytime room.
        var room = '';
        var roomCol = -1;
        for (final r in rooms) {
          if (r.col < j && r.col > roomCol) {
            room = r.name;
            roomCol = r.col;
          }
        }
        if (room.isEmpty) continue;

        // A fill reaching the next label column has run into the other
        // grid rather than into a longer class.
        var spanEndCol = j + cell.span - 1;
        for (final rc in roomCols) {
          if (rc > j) {
            if (rc - 1 < spanEndCol) spanEndCol = rc - 1;
            break;
          }
        }

        _record(
          drafts,
          day: day,
          room: room,
          isLab: kind == 'Labs',
          timeCols: activeCols,
          slotMinutes: slotMinutes,
          slot: _slotFor(activeCols, j, roomCol),
          spanEndCol: spanEndCol,
          body: body,
        );
      }
    }
    return _finishRooms(drafts, schoolId, window);
  }

  /// Engineering's and Management's shared shape: the day down column 0,
  /// `Classes`/`Labs` down column 1, the room down column 2, and one
  /// column per period from 3 on — Management pairing a course with its
  /// section code, Engineering drawing a lab as one merged cell with the
  /// teacher on the row below.
  ///
  /// Every day lives on one tab, so all of them are returned and the
  /// caller keeps the one it asked for.
  static List<RoomOccupancy> _parseRoomsDayBlocks(
    List<List<SheetCell>> grid,
    String schoolId,
  ) {
    var headerIndex = -1;
    var timeCols = <({int col, String start, String end})>[];
    for (var i = 0; i < grid.length && i < 12; i++) {
      final found = _leadingTimeColumns(_texts(grid[i]));
      if (found.length >= 4) {
        headerIndex = i;
        timeCols = found;
        break;
      }
    }
    if (headerIndex < 0 || timeCols.isEmpty) return const [];

    final window = _windowFrom((0, 0), timeCols);
    final slotMinutes = _slotMinutes(timeCols);
    final drafts = <(String, String), _RoomDraft>{};

    var day = '';
    var kind = 'Classes';
    var room = '';

    for (var i = headerIndex + 1; i < grid.length; i++) {
      final row = grid[i];
      String text(int c) => c < row.length ? row[c].text.trim() : '';
      final c0 = text(0);
      final c1 = text(1);
      final c2 = text(2);

      if (c0.isNotEmpty) {
        if (_weekdays.contains(c0)) {
          day = c0;
          // A block always opens with classes, so a new day must not
          // inherit the labs it finished the last one with.
          kind = 'Classes';
        } else {
          // Anything else in column 0 closes the block: the sheet's own
          // footers and legend rows, which would otherwise inherit the
          // room of the last class above them.
          day = '';
          room = '';
          continue;
        }
      }
      if (c1 == 'Classes' || c1 == 'Labs') kind = c1;
      // Engineering opens its labs with `Labs` in the room column;
      // Management sometimes writes it in both.
      if (c2 == 'Labs') kind = 'Labs';
      if (_isRoomLabel(c2) && c2 != room) room = c2;

      if (day.isEmpty || room.isEmpty) continue;

      // As in Computing: being named is enough to be listed, so a room
      // with an empty row still turns up as free all day.
      drafts.putIfAbsent((day, room), () => _RoomDraft(kind == 'Labs'));

      var bookingStart = -1;
      var bookingWasTimed = false;

      for (var j = 3; j < row.length; j++) {
        final body = row[j].text.trim();
        if (body.isEmpty || _slotRe.hasMatch(body)) continue;
        final slot = _slotFor(timeCols, j, 2);
        if (slot < 0) continue;

        // Management pairs a course with its section code in a later
        // period of the same block, and that code's period is where the
        // block really stops — widening the booking to it is what makes
        // a two-period lab three hours instead of one. A code carrying
        // its own time is left alone: the time is the finer answer, and
        // the course cell has already booked it.
        if (_sectionCodeRe.hasMatch(body)) {
          if (bookingStart >= 0 && !bookingWasTimed) {
            final range = TimeRange(
              start: bookingStart,
              end: slotMinutes[slot].$2,
            );
            if (range.end > range.start) {
              drafts
                  .putIfAbsent((day, room), () => _RoomDraft(kind == 'Labs'))
                  .occupied
                  .add(range);
            }
          }
          continue;
        }

        final booked = _record(
          drafts,
          day: day,
          room: room,
          isLab: kind == 'Labs',
          timeCols: timeCols,
          slotMinutes: slotMinutes,
          slot: slot,
          spanEndCol: row[j].span > 1 ? j + row[j].span - 1 : j,
          body: body,
        );
        bookingStart = booked?.start ?? -1;
        bookingWasTimed = _inlineSlotRe.hasMatch(body);
      }
    }
    return _finishRooms(drafts, schoolId, window);
  }

  static String _roomsKey(String schoolId, String day) =>
      'rooms_${schoolId}_$day';

  Future<(DateTime, List<RoomOccupancy>)?> _readRoomCache(
    String schoolId,
    String day,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_roomsKey(schoolId, day));
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      if (decoded['v'] != _cacheVersion) return null; // stale format
      return (
        DateTime.tryParse(decoded['fetchedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
        [
          for (final r in decoded['rooms'] as List<dynamic>)
            RoomOccupancy.fromJson(Map<String, dynamic>.from(r as Map)),
        ],
      );
    } catch (e) {
      debugPrint('Room cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeRoomCache(
    String schoolId,
    String day,
    List<RoomOccupancy> rooms,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _roomsKey(schoolId, day),
        jsonEncode({
          'v': _cacheVersion,
          'fetchedAt': DateTime.now().toIso8601String(),
          'rooms': [for (final r in rooms) r.toJson()],
        }),
      );
    } catch (e) {
      debugPrint('Room cache write failed: $e');
    }
  }

  // Test hooks. These parsers stay private because only [loadRooms]
  // should drive them; tests hand them saved copies of the real sheets
  // instead of fetching over the network.

  /// Parses one day's Computing htmlview page for rooms.
  @visibleForTesting
  List<RoomOccupancy> debugParseRoomsComputingHtml(
    String html,
    String day, {
    String schoolId = 'computing',
  }) => _parseRoomsComputing(_parseHtmlTable(html).grid, day, schoolId);

  /// Parses the Computing CSV fallback for rooms.
  @visibleForTesting
  List<RoomOccupancy> debugParseRoomsComputingCsv(
    String csv,
    String day, {
    String schoolId = 'computing',
  }) => _parseRoomsComputing(_asGrid(_parseCsv(csv)), day, schoolId);

  /// Parses an Engineering htmlview page for rooms (all days at once).
  @visibleForTesting
  List<RoomOccupancy> debugParseRoomsEngineeringHtml(
    String html, {
    String schoolId = 'engineering',
  }) => _parseRoomsDayBlocks(_parseHtmlTable(html).grid, schoolId);

  /// Parses the Management CSV for rooms (all days at once).
  @visibleForTesting
  List<RoomOccupancy> debugParseRoomsManagementCsv(
    String csv, {
    String schoolId = 'management',
  }) => _parseRoomsDayBlocks(_asGrid(_parseCsv(csv)), schoolId);

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
