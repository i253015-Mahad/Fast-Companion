// Phase 1 — the challan parser against the sanitized fixture.
//
// The fixture is a real challan page with every value replaced by a
// same-shape placeholder, so these assertions are about *structure*: that
// the parser finds the rows, reads an amount and a date, and puts an amount
// into the right bucket — owed or paid — from the portal's own status word.
// The specific figures are placeholders and are not asserted as themselves.
//
// Fees come from here, and the one thing that must not go wrong is totalling
// the page as though every row were still owed. A student who has paid in
// full does not want an alert saying they owe money, so the paid/owed split
// is the heart of this test — and because the fixture only carries one
// status, the split is also exercised on hand-built rows.
import 'dart:io';

import 'package:fast_companion/services/flex_alert_challan.dart';
import 'package:flutter_test/flutter_test.dart';

final _fixture = File('test/fixtures/flex_challan.html');

void main() {
  late FlexChallanPage page;

  setUpAll(() {
    if (!_fixture.existsSync()) {
      markTestSkipped('challan fixture not present');
      return;
    }
    page = const FlexChallanParser().parse(_fixture.readAsStringSync());
  });

  test('reads the challan rows the page lists', () {
    // The fixture carries one issued challan. Zero would mean the parser
    // missed the table entirely, and a fee alert that sees an empty page
    // every time is worse than none: it reads as "nothing owed" forever.
    expect(page.rows, isNotEmpty);
    for (final r in page.rows) {
      expect(r.amount, isNotNull, reason: 'every row should carry an amount');
      expect(r.amount!, greaterThanOrEqualTo(0));
    }
  });

  test('reads an amount as a number, not as text', () {
    // The portal writes `206500 Rs.`; the parser has to reach the figure
    // through the currency suffix.
    for (final r in page.rows) {
      expect(r.amount, isA<double>());
    }
  });

  test('reads the dates the portal spells out', () {
    for (final r in page.rows) {
      expect(r.generatedOn, isNotNull,
          reason: 'a challan should say when it was issued');
      expect(r.dueDate, isNotNull,
          reason: 'a challan should say when it falls due');
      // The fixture's dates carry a placeholder year, but they are still
      // dates — the parser read day, month and year rather than leaving a
      // string behind.
      expect(r.generatedOn!.year, greaterThan(2000));
    }
  });

  test('puts a paid challan in the paid bucket, not the owed one', () {
    // The fixture's challan is marked paid, so its amount belongs to what
    // has been settled and must not appear as money owed. That is the
    // difference between a student who owes nothing and one who is being
    // told, wrongly, that they do — so the check is that the money lands on
    // the owed side of nothing, not merely that some number is positive.
    final paidRows = page.rows.where((r) => r.isPaid).toList();
    if (paidRows.isEmpty) {
      markTestSkipped('fixture carries no paid challan');
      return;
    }
    expect(page.outstanding, 0,
        reason: 'a page of paid challans owes nothing');
    expect(page.hasOutstanding, isFalse);
    expect(page.paid, greaterThan(0),
        reason: 'the settled amount should be recorded as paid');
    expect(page.paid, closeTo(paidRows.fold<double>(0, (s, r) => s + r.amount!), 0.001),
        reason: 'every paid challan should land in the paid total');
  });

  group('balance logic, on rows the fixture cannot cover', () {
    // The fixture carries a single status, so every status the parser has to
    // tell apart is exercised here instead — the split is the one place a
    // wrong answer would mislead a student about money.
    FlexChallan row(String status, double amount) =>
        FlexChallan(amount: amount, status: status);

    test('unpaid and partially paid challans are still owed', () {
      final owed = FlexChallanPage([
        row('Unpaid', 1000),
        row('Partially Paid', 400),
        row('Paid', 250),
      ]);
      expect(owed.outstanding, 1400,
          reason: 'a partially paid challan still carries what is left');
      expect(owed.paid, 250);
      expect(owed.hasOutstanding, isTrue);
      expect(owed.nextDue, isNull, reason: 'these rows carry no due date');
    });

    test('a voided challan is neither owed nor paid', () {
      // Counting a reversed challan as a payment would deduct money that was
      // never received; counting it as owed would charge fees never levied.
      // Either way the balance would be wrong in a way that looks right.
      final voided = FlexChallanPage([
        row('Unpaid', 1000),
        row('Void', 600),
        row('Cancelled', 300),
        row('Reversed', 200),
      ]);
      expect(voided.outstanding, 1000,
          reason: 'a voided challan drops out of the balance entirely');
      expect(voided.paid, 0);
    });

    test('the soonest due date among the owed rows is the one named', () {
      final soonest = DateTime(2026, 8, 15);
      final later = DateTime(2026, 9, 1);
      final dues = FlexChallanPage([
        FlexChallan(amount: 500, dueDate: later, status: 'Unpaid'),
        FlexChallan(amount: 700, dueDate: soonest, status: 'Unpaid'),
        // A paid row with an earlier date must not be named: it is settled,
        // and naming it would warn about a deadline that no longer applies.
        FlexChallan(amount: 100, dueDate: DateTime(2026, 8, 1), status: 'Paid'),
      ]);
      expect(dues.nextDue, soonest);
    });

    test('a row with no amount is skipped rather than read as zero', () {
      // The portal prints an empty cell where nothing is owed. Reading it as
      // zero would make a vanished challan indistinguishable from a settled
      // one, and the balance would silently drop.
      final page = const FlexChallanParser().parse('''
        <table><tr><th>S. No</th><th>Amount</th><th>Status</th></tr>
        <tr><td>1</td><td></td><td>Unpaid</td></tr>
        <tr><td>2</td><td>900 Rs.</td><td>Unpaid</td></tr>
        </table>''');
      expect(page.rows, hasLength(1),
          reason: 'the empty cell is not a challan');
      expect(page.outstanding, 900);
    });

    test('a table without an Amount column is not a fee table', () {
      // The page carries detail and modal tables beside the real one.
      // Guessing which of their numbers are charges would invent a balance.
      final page = const FlexChallanParser().parse('''
        <table><tr><th>Code</th><th>Name</th></tr>
        <tr><td>CS2001</td><td>Data Structures</td></tr></table>
        <table><tr><th>Amount</th><th>Status</th></tr>
        <tr><td>800 Rs.</td><td>Unpaid</td></tr></table>''');
      expect(page.rows, hasLength(1),
          reason: 'only the table with an Amount header is a fee table');
    });
  });

  test('hash is a fixed value, not one that moves with the process', () {
    // The snapshot is written now and compared on a later poll, after the
    // app has restarted. `Object.hash` is seeded per process and would
    // return a different number on every run, so a fee balance would look
    // changed on every fetch and the alert would cry wolf.
    expect(page.contentHash, '754325625271333650');
  });

  test('re-ordering the rows does not read as a change', () {
    // The portal lists challans newest first or oldest first by term. A fee
    // that has not moved is not a change, however the list is sorted.
    final reversed = FlexChallanPage(page.rows.reversed.toList());
    expect(reversed.contentHash, page.contentHash);
  });

  test('hash moves when an amount moves', () {
    final moved = FlexChallanPage([
      for (final r in page.rows)
        FlexChallan(
          serial: r.serial,
          amount: (r.amount ?? 0) + 1,
          generatedOn: r.generatedOn,
          dueDate: r.dueDate,
          status: r.status,
        ),
    ]);
    expect(moved.contentHash, isNot(page.contentHash),
        reason: 'a fee going up must move the hash');
  });

  test('two parses of the same page agree', () {
    final again = const FlexChallanParser().parse(_fixture.readAsStringSync());
    expect(again.contentHash, page.contentHash);
    expect(again.outstanding, page.outstanding);
    expect(again.paid, page.paid);
  });
}
