// Reads the Flex portal's challan page so the alert system can tell a new or
// changed fee balance from one it has already seen.
//
// The challan lists one row per issued fee challan, each carrying the amount
// and the dates it is due:
//
//     <tr>
//       <td class="text-center">1</td>
//       <td class="text-center">206500 Rs.</td>
//       <td class="text-center">01-Aug-2026</td>
//       <td class="text-center">15-Aug-2026</td>
//       <td class="text-center">Unpaid</td>
//       ...
//     </tr>
//
// Two figures matter and they are not the same thing: what is still owed and
// what has already been paid. The row's `Status` says which it is, so the
// parser reads amount and status together — an unpaid challan adds to the
// balance, a paid one does not, and a page that lists both must not be
// totalled as though every row were owed.
//
// Nothing here fetches. The page comes in as a String and leaves as typed
// values, so the parser can be tested against a fixture without a session.
import 'flex_alert_hash.dart';

/// One challan as the portal records it.
class FlexChallan {
  /// Serial number the portal lists it under, or `null` when absent.
  final int? serial;

  /// Amount as printed, in rupees. `null` when the cell held no number.
  final double? amount;

  /// When the challan was issued (`2026-08-01`), or `null`.
  final DateTime? generatedOn;

  /// When it falls due (`2026-08-15`), or `null`.
  final DateTime? dueDate;

  /// The portal's own word for it — `Paid`, `Unpaid`, `Partially Paid`.
  final String status;

  const FlexChallan({
    this.serial,
    this.amount,
    this.generatedOn,
    this.dueDate,
    this.status = '',
  });

  /// Whether the portal still counts this challan as owed.
  ///
  /// Read from the status word rather than from the amount, because a
  /// partially paid challan still carries a non-zero figure after most of it
  /// has been settled. Only a status that says paid clears the row.
  bool get isPaid => RegExp(r'^\s*paid', caseSensitive: false).hasMatch(status);

  /// Whether the portal counts this challan as outstanding at all.
  ///
  /// A voided or reversed challan is neither paid nor owed, so it is left
  /// out of the balance in both directions rather than being counted as a
  /// payment against fees that were never charged.
  bool get isVoid =>
      RegExp(r'\b(void|revers|cancel|refund)', caseSensitive: false)
          .hasMatch(status);

  /// A value that changes exactly when this challan's meaning changes, for
  /// snapshot comparison. A serial moves when the portal reissues, which is
  /// worth an alert; the dates are included because a shifted due date is a
  /// change a student would want to know about.
  ///
  /// [stableHash] rather than `Object.hash`: this value is written into a
  /// snapshot and compared on a later poll, across restarts, so it has to
  /// repeat. `Object.hash` is seeded per process and would report a change
  /// on every fetch.
  String get contentHash => stableHash([
        serial?.toString() ?? '',
        _num(amount),
        generatedOn?.toIso8601String() ?? '',
        dueDate?.toIso8601String() ?? '',
        status.toLowerCase(),
      ]);

  static String _num(double? v) => v == null ? '' : v.toStringAsFixed(2);
}

/// The challan page, read into its rows and the balance they add up to.
class FlexChallanPage {
  final List<FlexChallan> rows;

  const FlexChallanPage(this.rows);

  /// What is still owed, across every challan the portal has not marked
  /// paid. Voided and reversed challans are left out entirely — they were
  /// never money owed.
  double get outstanding => rows
      .where((r) => !r.isPaid && !r.isVoid)
      .fold(0.0, (sum, r) => sum + (r.amount ?? 0));

  /// What the portal has recorded as paid.
  double get paid =>
      rows.where((r) => r.isPaid).fold(0.0, (sum, r) => sum + (r.amount ?? 0));

  /// Whether any challan is still owed.
  bool get hasOutstanding => rows.any((r) => !r.isPaid && !r.isVoid);

  /// The due date that comes soonest among the challans still owed, which
  /// is the one an alert should name.
  DateTime? get nextDue {
    DateTime? soonest;
    for (final r in rows) {
      if (r.isPaid || r.isVoid || r.dueDate == null) continue;
      if (soonest == null || r.dueDate!.isBefore(soonest)) {
        soonest = r.dueDate;
      }
    }
    return soonest;
  }

  /// Everything the page listed, as a single hash, for snapshot comparison.
  ///
  /// The rows are sorted first so that the portal reordering its list —
  /// which it does, newest first or oldest first by term — does not read as
  /// a change when the fees themselves have not moved.
  String get contentHash {
    final hashes = rows.map((r) => r.contentHash).toList()..sort();
    return stableHash(hashes);
  }
}

/// Parses the portal's challan page.
///
/// Regex over the HTML rather than a DOM, matching the rest of the codebase
/// (`FlexAttendanceService`, the timetable): the page is server-rendered and
/// stable in the places relied on here, and adding a parser dependency to
/// read four fields is not worth it.
class FlexChallanParser {
  const FlexChallanParser();

  /// The main challan table, recognised by its `Amount` header. The total
  /// blocks that follow it (`lbTotalAmount` and friends) are separate
  /// elements and are not matched here, so the balance is built from the
  /// rows rather than trusted from a printed summary that may disagree with
  /// them.
  static final _table = RegExp(
    r'<table[^>]*>[\s\S]*?</table>',
    multiLine: true,
  );

  static final _headerCells = RegExp(r'<th[^>]*>([\s\S]*?)</th>');
  static final _dataCells = RegExp(r'<td[^>]*>([\s\S]*?)</td>');

  /// Reads the challan rows.
  ///
  /// Tables without an `Amount` header are skipped: the page carries detail
  /// and modal tables that are not fee rows, and guessing which numbers are
  /// charges in those would invent a balance.
  FlexChallanPage parse(String html) {
    final out = <FlexChallan>[];
    for (final table in _table.allMatches(html)) {
      out.addAll(_readTable(table.group(0)!));
    }
    return FlexChallanPage(out);
  }

  List<FlexChallan> _readTable(String table) {
    final headers = _headerCells
        .allMatches(table)
        .map((m) => _text(m.group(1)!))
        .where((t) => t.isNotEmpty)
        .toList();
    if (headers.isEmpty) return const [];

    int column(String label) {
      for (var i = 0; i < headers.length; i++) {
        if (headers[i].toLowerCase().contains(label)) return i;
      }
      return -1;
    }

    final amountCol = column('amount');
    final serialCol = column('s. no');
    final statusCol = column('status');
    final genCol = column('generated');
    final dueCol = column('due date');
    // Not a fee table.
    if (amountCol < 0) return const [];

    final out = <FlexChallan>[];
    for (final row in RegExp(r'<tr[^>]*>([\s\S]*?)</tr>').allMatches(table)) {
      final cells = _dataCells
          .allMatches(row.group(1)!)
          .map((m) => _text(m.group(1)!))
          .toList();
      if (cells.length <= amountCol) continue;

      String cellAt(int col) => col >= 0 && col < cells.length ? cells[col] : '';

      // A row with no amount is a spacer or a summary line, not a fee.
      final amount = _amount(cellAt(amountCol));
      if (amount == null) continue;

      out.add(
        FlexChallan(
          serial: _int(cellAt(serialCol)),
          amount: amount,
          generatedOn: _date(cellAt(genCol)),
          dueDate: _date(cellAt(dueCol)),
          status: cellAt(statusCol),
        ),
      );
    }
    return out;
  }

  /// An amount from a cell written as `206500 Rs.`, or `null` when there is
  /// no figure — the portal prints an empty cell where nothing is owed, and
  /// reading that as zero would hide a challan that has vanished.
  double? _amount(String text) {
    final m = RegExp(r'-?[\d,]+(?:\.\d+)?').firstMatch(text);
    if (m == null) return null;
    return double.tryParse(m.group(0)!.replaceAll(',', ''));
  }

  int? _int(String text) {
    final m = RegExp(r'\d+').firstMatch(text);
    if (m == null) return null;
    return int.tryParse(m.group(0)!);
  }

  /// A date written as the portal spells it (`15-Aug-2026`), or `null` when
  /// the cell holds no date. The year is read as given: a fixture's
  /// sanitized dates carry a placeholder year, and forcing them into range
  /// would hide whether the parser read the field at all.
  DateTime? _date(String text) {
    final m = RegExp(
      r'(\d{1,2})[-/](\d{1,2}|[A-Za-z]{3,9})[-/](\d{4})',
    ).firstMatch(text);
    if (m == null) return null;

    final day = int.tryParse(m.group(1)!);
    final year = int.tryParse(m.group(3)!);
    if (day == null || year == null) return null;

    final month = _month(m.group(2)!);
    if (month == null) return null;
    return DateTime(year, month, day);
  }

  int? _month(String raw) {
    final asNumber = int.tryParse(raw);
    if (asNumber != null && asNumber >= 1 && asNumber <= 12) return asNumber;
    final name = raw.trim().toLowerCase();
    if (name.length < 3) return null;
    const names = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec',
    ];
    final i = names.indexOf(name.substring(0, 3));
    return i < 0 ? null : i + 1;
  }

  /// The words inside a tag, entities resolved and spacing collapsed.
  String _text(String html) => html
      .replaceAll(RegExp(r'<[^>]+>'), ' ')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
