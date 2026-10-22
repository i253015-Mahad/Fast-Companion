// A class written into a row that is not its own.
//
// The sheets record a class held outside its row's room by writing the
// real room after the class itself — `Pak Studies (SE-B) 11:30-01:15
// D-402` sitting on C-602's row, sometimes behind a `Room`, sometimes
// as plain trailing text. Two things used to read the row label
// instead, and both were wrong in the same direction:
//
// * the timetable showed the class in C-602 while gluing its own room
//   to the course name, as `Pak Studies D-402`; and
// * the rooms list booked C-602 and left D-402 free — which is a
//   person standing in a corridor at 11:30 waiting for a room that is
//   full.
//
// Alongside it, blocks C and D hold their classrooms from the third
// floor up. The Computing sheet lists `C-110`, which is a store rather
// than a room, and offering it as spare did the same thing again.
//
// Two groups: the timetable's own record of a class, and what the
// rooms list then offers.
import 'package:fast_companion/models/room_occupancy.dart';
import 'package:fast_companion/services/timetable_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Escapes cells into one CSV row the way gviz exports it.
String _csvRow(List<String> cells) => cells
    .map((c) => '"${c.replaceAll('"', '""')}"')
    .join(',');

/// One CSV row of [length] cells with only [at] filled in, so a fixture
/// states column positions rather than counting out empty strings.
String _csvAt(int length, Map<int, String> at) {
  final cells = List.filled(length, '');
  at.forEach((i, v) => cells[i] = v);
  return _csvRow(cells);
}

void main() {
  final svc = TimetableService.instance;

  final header = _csvAt(14, {
    0: 'Room/ Time',
    1: '08:30-09:50',
    5: '10:00-11:20',
    9: '11:30-12:50',
    13: '01:00-02:20',
  });

  // ---------------------------------------------------------------------
  // The room named at the end of a cell.
  // ---------------------------------------------------------------------

  group('the room at the end of the cell', () {
    // The real thing, down to the bold span the author used: row 26 of
    // Thursday, whose label is C-602 but whose class is in D-402.
    const html = '''
<table>
<tr>
  <td>Room/ Time</td>
  <td colspan="4">08:30-09:50</td><td></td>
  <td colspan="4">10:00-11:20</td><td></td>
  <td colspan="4">11:30-12:50</td><td></td>
  <td colspan="4">01:00-02:20</td><td></td>
  <td colspan="4">02:30-03:50</td><td></td>
  <td colspan="4">03:55-05:15</td>
  <td>Room</td>
</tr>
<tr>
  <td>C-602</td>
  <td colspan="9"></td><td></td>
  <td colspan="4">Pak Studies (SE-B) 11:30-01:15 <span style="font-weight:bold;">D-402</span></td>
</tr>
</table>''';

    test('the timetable puts the class in the room it names', () {
      final entries = svc.debugParseComputingHtml(html, 'Thursday');

      expect(entries, hasLength(1));
      final e = entries.single;
      expect(e.course, 'Pak Studies');
      expect(e.section, 'SE-B');
      expect(e.room, 'D-402', reason: 'the row says C-602; the cell says otherwise');
      expect(e.startTime, '11:30');
      expect(e.endTime, '01:15');
    });

    test('the course name loses the room that was glued to it', () {
      final entries = svc.debugParseComputingHtml(html, 'Thursday');

      // Left in place this reads `Pak Studies D-402`, which is the
      // course name a student searches for and cannot find.
      expect(entries.single.course, isNot(contains('D-402')));
    });

    test('a `Room` before the code is taken off whole', () {
      final entries = svc.debugParseComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-308', 1: 'Math for CI (CI) Room D-306'})}\n',
        'Thursday',
      );

      expect(entries.single.course, 'Math for CI');
      expect(entries.single.room, 'D-306');
    });

    test('plain trailing text counts the same as a bold span', () {
      // Monday's row 48: `SMD (CS) C-110 ` on D-405's row, no markup.
      final entries = svc.debugParseComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'D-405', 1: 'SMD (CS) C-110'})}\n',
        'Monday',
      );

      expect(entries.single.course, 'SMD');
      expect(entries.single.room, 'C-110');
    });

    test('a cell with no room of its own keeps the row it is written on', () {
      final entries = svc.debugParseComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-302', 1: 'PF (SE-C)'})}\n',
        'Monday',
      );

      expect(entries.single.course, 'PF');
      expect(entries.single.room, 'C-302');
    });

    test('a section at the end of a cell is not mistaken for a room', () {
      // `SE-B`, `PHD-A` and `AI-A` are the shapes a section takes. None
      // of them is three digits, so none of them is a room.
      final entries = svc.debugParseComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-302', 1: 'Seerah (CS-B)'})}\n'
        '${_csvAt(14, {0: 'C-303', 1: 'UHQ-I & II (PHD-A)'})}\n',
        'Wednesday',
      );

      expect(entries.first.room, 'C-302');
      expect(entries.last.room, 'C-303');
    });

    test('a cell holding nothing but a code does not hijack the row', () {
      // The evening grid hangs its own room column off a spare cell on
      // the row. A stray one in a data column is a label, not a class
      // naming where it sits.
      final entries = svc.debugParseComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-302', 1: 'D-311'})}\n',
        'Monday',
      );

      expect(entries.single.room, 'C-302');
    });
  });

  // ---------------------------------------------------------------------
  // What that does to the list of rooms to take.
  // ---------------------------------------------------------------------

  group('the rooms list', () {
    test('the class is booked into the room it names', () {
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-602', 9: 'Pak Studies (SE-B) 11:30-01:15 D-402'})}\n',
        'Thursday',
      );

      RoomOccupancy of(String name) => rooms.firstWhere(
        (r) => r.room == name,
        orElse: () => fail('$name not in $rooms'),
      );

      final real = of('D-402');
      expect(real.occupied.single.start, 690); // 11:30
      expect(real.occupied.single.end, 795); // 01:15, in the afternoon
      expect(real.isFreeAt(690), isFalse);

      final row = of('C-602');
      expect(row.occupied, isEmpty);
      expect(row.isFreeAt(690), isTrue);
      expect(row.freeUntil(690), isNull);
    });

    test('a class moved into a room with no row of its own still books it', () {
      // D-402 appears nowhere in this sheet. The class says it is
      // there, so there it is, and busy.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-302', 9: 'Pak Studies (SE-B) 11:30-01:15 D-402'})}\n',
        'Thursday',
      );

      expect(rooms.map((r) => r.room), containsAll(['C-302', 'D-402']));
      final moved = rooms.firstWhere((r) => r.room == 'D-402');
      expect(moved.occupied, hasLength(1));
      expect(moved.isFreeAt(700), isFalse);

      final vacated = rooms.firstWhere((r) => r.room == 'C-302');
      expect(vacated.occupied, isEmpty);
    });

    test('a code that only repeats the row label changes nothing', () {
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'D-402', 9: 'Pak Studies (SE-B) 11:30-01:15 D-402'})}\n',
        'Thursday',
      );

      expect(rooms, hasLength(1));
      expect(rooms.single.room, 'D-402');
      expect(rooms.single.occupied, hasLength(1));
    });

    test('the time inside the cell still wins over the period it sits in', () {
      // The class is typed into the 08:30 column but runs 11:30-01:15.
      // Lifting the room out must not disturb the time beside it.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-602', 1: 'Pak Studies (SE-B) 11:30-01:15 D-402'})}\n',
        'Thursday',
      );

      final real = rooms.firstWhere((r) => r.room == 'D-402');
      expect(real.occupied.single.start, 690);
      expect(real.occupied.single.end, 795);
      expect(real.isFreeAt(510), isTrue, reason: 'free at 08:30');
    });

    test('the whole of C-602 stays on offer once its classes have moved', () {
      // Thursday's row 26 moves three classes out and leaves nothing
      // behind, but a row the sheet still lists is still a room.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {
          0: 'C-602',
          1: 'LA (SE-A) D-411',
          9: 'Pak Studies (SE-B) 11:30-01:15 D-402',
          13: 'Func Eng (SE-D) 01:20-03:05 D-402',
        })}\n',
        'Thursday',
      );

      RoomOccupancy of(String name) => rooms.firstWhere(
        (r) => r.room == name,
        orElse: () => fail('$name not in $rooms'),
      );

      expect(of('C-602').occupied, isEmpty);
      expect(of('D-411').occupied.single.start, 510);

      // Both moved into D-402, back to back and not overlapping.
      final d402 = of('D-402');
      expect(d402.occupied, hasLength(2));
      expect(d402.occupied.first.end, lessThanOrEqualTo(d402.occupied.last.start));
    });
  });

  // ---------------------------------------------------------------------
  // Blocks C and D teach from the third floor up.
  // ---------------------------------------------------------------------

  group('rooms below the third floor', () {
    test('C-110 is not offered', () {
      // A store. The sheet lists it among the classrooms, which sent
      // people looking for a room in a corridor.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-110', 1: 'Fund of Data Vis'})}\n',
        'Thursday',
      );

      expect(rooms.map((r) => r.room), isNot(contains('C-110')));
    });

    test('a classroom above the third floor still is', () {
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-110', 1: 'Fund of Data Vis'})}\n'
        '${_csvAt(14, {0: 'C-301', 1: 'PF (SE-C)'})}\n'
        '${_csvAt(14, {0: 'D-402', 1: 'Pak Studies (AI-B)'})}\n',
        'Thursday',
      );

      expect(rooms.map((r) => r.room), containsAll(['C-301', 'D-402']));
    });

    test('a B room below the third floor is left alone', () {
      // Engineering teaches in B-019 and B-232, and the floor rule was
      // never given for A or B. They are not this bug.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'B-027', 1: 'EMT (EE-A)'})}\n',
        'Monday',
      );

      expect(rooms.map((r) => r.room), contains('B-027'));
    });

    test('a class moved into a store does not hold the row it left', () {
      // Monday's `SMD (CS) C-110` on D-405's row. The class is in
      // C-110, so D-405 is genuinely free — and C-110 is not something
      // anyone is offered anyway.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'D-405', 1: 'SMD (CS) C-110'})}\n',
        'Monday',
      );

      expect(rooms.map((r) => r.room), isNot(contains('C-110')));
      final vacated = rooms.firstWhere((r) => r.room == 'D-405');
      expect(vacated.occupied, isEmpty);
      expect(vacated.isFreeAt(510), isTrue);
    });

    test('a lab that merely names a room still counts as one', () {
      // `Margala 1 (C-209)` is a real lab whose label embeds a code on
      // a floor no classroom is on. The match looks at the start of the
      // label, so this one survives.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(40, {
          0: 'Lab',
          1: '08:30-11:15',
          11: '11:30-02:15',
          21: '02:30-05:15',
          31: '05:20 - 08:05 (inc. 10 min. break)',
        })}\n'
        '${_csvAt(40, {0: 'Margala 1 (C-209)', 1: 'Data St Lab (CS-A)'})}\n',
        'Thursday',
      );

      expect(rooms, hasLength(1));
      expect(rooms.single.room, 'Margala 1 (C-209)');
      expect(rooms.single.isLab, isTrue);
    });

    test('a store does not widen the day every room is offered over', () {
      // The evening window is taken from the bookings across the sheet.
      // A store's late booking must not stretch everyone else's day.
      final rooms = svc.debugParseRoomsComputingCsv(
        '$header\n'
        '${_csvAt(14, {0: 'C-110', 13: 'Fund of Data Vis 01:20-03:05'})}\n'
        '${_csvAt(14, {0: 'C-301', 1: 'PF (SE-C)'})}\n',
        'Thursday',
      );

      expect(rooms.single.room, 'C-301');
      expect(rooms.single.dayEnd, 860); // 02:20, the last labelled period
    });
  });
}
