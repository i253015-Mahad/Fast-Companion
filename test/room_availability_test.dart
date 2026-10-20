// Rooms.
//
// The timetable records classes; this records rooms. The difference is
// the empty cell: a room free all day has none, so a parser built the
// usual way emits nothing for it and the room vanishes from the list
// entirely — the rooms a student is actually looking for.
//
// Three things have to be right for a "free now" list to be worth
// reading:
//
// * a room is listed because the sheet names it, not because it is
//   booked, and
// * a room two sheets share is checked against both of their books
//   before it is called free, and
// * a time range read off the sheet points forward. Computing's last
//   period is written `06:45-08:05` and means 18:45-20:05; read
//   literally the end sits eleven hours before its own start.
//
// Two groups: fixtures that always run, and the real sheets when a
// saved copy is present.
import 'dart:io';

import 'package:fast_companion/Screens/rooms_screen.dart';
import 'package:fast_companion/models/room_occupancy.dart';
import 'package:fast_companion/services/timetable_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Escapes cells into one CSV row the way gviz exports it.
String _csvRow(List<String> cells) => cells
    .map((c) => '"${c.replaceAll('"', '""')}"')
    .join(',');

List<String> _row(int length) => List.filled(length, '');

/// One CSV row of [length] cells with only [at] filled in, so a fixture
/// states column positions rather than counting out empty strings.
String _csvAt(int length, Map<int, String> at) {
  final cells = _row(length);
  at.forEach((i, v) => cells[i] = v);
  return _csvRow(cells);
}

void main() {
  final svc = TimetableService.instance;

  // ---------------------------------------------------------------------
  // The model: how a clock time becomes minutes, and how a label becomes
  // a building.
  // ---------------------------------------------------------------------

  group('times', () {
    test('a morning period keeps its own hours', () {
      expect(minutesRange('08:30', '09:50'), (510, 590));
    });

    test('an afternoon period is read past noon', () {
      expect(minutesRange('03:55', '05:15'), (955, 1035));
    });

    test('an evening period points forward, not backwards', () {
      // Computing's last period. Taken at face value 08:05 is the
      // morning, eleven hours before 06:45.
      expect(minutesRange('06:45', '08:05'), (1125, 1205));
      expect(clockOf(minutesRange('06:45', '08:05').$2), '20:05');
    });

    test('a period that ends the next morning is not stretched', () {
      // 11:30 to 02:15 is the afternoon, not a fourteen-hour class.
      expect(minutesRange('11:30', '02:15'), (690, 855));
    });

    test('a backwards range is refused rather than booked', () {
      expect(TimeRange.parse('14:00', '13:00'), isNull);
      expect(TimeRange.parse('08:30', '08:30'), isNull);
    });

    test('a class ending on the hour frees the room on the hour', () {
      // Half-open: 09:50 is the first free minute, so a query at 09:50
      // finds the room.
      final r = TimeRange.parse('08:30', '09:50')!;
      expect(r.contains(589), isTrue);
      expect(r.contains(590), isFalse);
    });
  });

  group('building labels', () {
    const cases = {
      'C-301': 'C',
      'A- 201': 'A', // management pads the space in
      'A--211': 'A', // and sometimes doubles the dash
      'C - 405': 'C',
      'Margala 4 (C-212': 'C', // computing leaves the bracket open
      'C-Rawal 4 (C-512)': 'C',
      'IT Lab 1 (D-210)': 'D',
      'Cyber (D-514)': 'D',
      'B-Computing-3': 'B', // a name, but still building B
      'B-Digital': 'B',
      'Mehran-2 (A-306)': 'A',
      'CALL-1 (A-213)': 'A',
      'Comp-I': '',
      'Karakoram-3': '',
      'Kybher-3': '',
      'Poth': '',
      'Koh': '',
      'PHY': '',
      'Khyber I': '',
      'Audi': '',
    };

    cases.forEach((label, building) {
      test('$label -> ${building.isEmpty ? "none" : building}', () {
        expect(buildingOf(label), building);
      });
    });

    test('a block name in front of a code does not claim its first letter', () {
      // `C-Rawal 4` is a Rawalpindi-block name; its room is C-512, and
      // `CALL-1` begins with a C that means nothing at all.
      expect(buildingOf('C-Rawal 4 (C-512)'), 'C');
      expect(buildingOf('CALL-1 (A-213)'), 'A');
    });
  });

  group('one room, two spellings', () {
    test('padding and doubled dashes collapse together', () {
      expect(roomKey('C - 405'), roomKey('C-405'));
      expect(roomKey('A--211'), roomKey('A-211'));
      expect(roomKey('A- 210'), roomKey('A-210'));
    });

    test('genuinely different rooms stay apart', () {
      expect(roomKey('C-405'), isNot(roomKey('C-406')));
      expect(roomKey('C-405'), isNot(roomKey('A-405')));
    });

    test('a room two schools share is booked against both', () {
      const day = 'Monday';
      const d = 510; // 08:30
      RoomOccupancy of(String room, String school, List<TimeRange> booked) =>
          RoomOccupancy(
            room: room,
            building: buildingOf(room),
            isLab: false,
            day: day,
            schools: [school],
            occupied: booked,
            dayStart: d,
            dayEnd: 1200,
          );

      final merged = coalesceRooms([
        of('C-405', 'computing', [TimeRange(start: 510, end: 590)]),
        of('C - 405', 'management', [TimeRange(start: 680, end: 760)]),
      ]);

      expect(merged, hasLength(1), reason: 'one room, however it is spelled');
      final room = merged.single;
      expect(room.schools, ['computing', 'management']);
      expect(room.room, 'C-405', reason: 'the unpadded spelling is shown');
      expect(room.occupied, hasLength(2));

      // Free between the two bookings, busy during each.
      expect(room.isFreeAt(600), isTrue);
      expect(room.isFreeAt(510), isFalse);
      expect(room.isFreeAt(700), isFalse);
      expect(room.freeUntil(600), 680);
    });

    test('a room booked by one school is free under the other', () {
      const d = 510;
      RoomOccupancy of(String room, String school) => RoomOccupancy(
        room: room,
        building: buildingOf(room),
        isLab: false,
        day: 'Monday',
        schools: [school],
        occupied: const [TimeRange(start: 680, end: 760)],
        dayStart: d,
        dayEnd: 1200,
      );

      final merged = coalesceRooms([of('B-227', 'engineering'), of('B-227', 'management')]);
      expect(merged.single.occupied.single.start, 680);
    });
  });

  group('gaps between bookings', () {
    test('back-to-back cells read as one block', () {
      final merged = mergeRanges([
        TimeRange.parse('08:30', '09:50')!,
        TimeRange.parse('10:00', '11:20')!,
        TimeRange.parse('09:50', '10:00')!,
      ]);
      expect(merged, hasLength(1));
      expect(merged.single.start, 510);
      expect(merged.single.end, 680);
    });

    test('a real gap survives to be offered', () {
      final merged = mergeRanges([
        TimeRange.parse('08:30', '09:50')!,
        TimeRange.parse('11:30', '12:50')!,
      ]);
      expect(merged, hasLength(2));
      expect(
        RoomOccupancy(
          room: 'C-301',
          building: 'C',
          isLab: false,
          day: 'Monday',
          schools: const ['computing'],
          occupied: merged,
          dayStart: 510,
          dayEnd: 1030,
        ).freeUntil(600),
        690,
        reason: 'free again at the start of the next period',
      );
    });

    test('a room with nothing booked is free all day', () {
      final empty = RoomOccupancy(
        room: 'C-302',
        building: 'C',
        isLab: false,
        day: 'Monday',
        schools: const ['computing'],
        occupied: const [],
        dayStart: 510,
        dayEnd: 1030,
      );
      expect(empty.isFreeAt(510), isTrue);
      expect(empty.isFreeAt(1029), isTrue);
      expect(empty.freeUntil(600), isNull, reason: 'nothing else is booked');
    });

    test('a busy room has no "free until"', () {
      final busy = RoomOccupancy(
        room: 'C-301',
        building: 'C',
        isLab: false,
        day: 'Monday',
        schools: const ['computing'],
        occupied: [TimeRange.parse('08:30', '09:50')!],
        dayStart: 510,
        dayEnd: 1030,
      );
      expect(busy.isFreeAt(540), isFalse);
      expect(busy.freeUntil(540), isNull);
    });

    test('survives a cache round trip', () {
      final original = RoomOccupancy(
        room: 'Margala 4 (C-212)',
        building: 'C',
        isLab: true,
        day: 'Monday',
        schools: const ['computing', 'management'],
        occupied: [TimeRange.parse('08:30', '11:15')!],
        dayStart: 510,
        dayEnd: 1205,
      );
      final back = RoomOccupancy.fromJson(original.toJson());
      expect(back.room, original.room);
      expect(back.building, original.building);
      expect(back.isLab, isTrue);
      expect(back.schools, original.schools);
      expect(back.occupied.single.start, original.occupied.single.start);
      expect(back.occupied.single.end, original.occupied.single.end);
      expect(back.dayStart, original.dayStart);
      expect(back.dayEnd, original.dayEnd);
    });
  });

  // ---------------------------------------------------------------------
  // The parsers. Column layouts are the sheets' own: Computing puts four
  // columns per period with a spacer between them (1, 6, 11...), its
  // evening grid starts at column 30, Engineering puts seventeen per
  // period (3, 21, 39...), Management nine with no spacer (3, 12, 21...).
  // ---------------------------------------------------------------------

  group('computing', () {
    const header = '''
<tr>
  <td>Room/ Time</td>
  <td colspan="4">08:30-09:50</td><td></td>
  <td colspan="4">10:00-11:20</td><td></td>
  <td colspan="4">11:30-12:50</td><td></td>
  <td colspan="4">01:00-02:20</td><td></td>
  <td colspan="4">02:30-03:50</td><td></td>
  <td colspan="4">03:55-05:15</td>
  <td>Room</td>
  <td>05:20-06:40</td><td></td><td></td><td></td><td></td>
  <td>06:45-08:05</td>
</tr>''';

    test('a room free all day is listed anyway', () {
      final rooms = svc.debugParseRoomsComputingCsv(
        '${_csvAt(14, {
          0: 'Room/ Time',
          1: '08:30-09:50',
          5: '10:00-11:20',
          9: '11:30-12:50',
          13: '01:00-02:20',
        })}\n'
        '${_csvAt(14, {0: 'C-302'})}\n',
        'Monday',
      );

      expect(rooms, hasLength(1));
      expect(rooms.single.room, 'C-302');
      expect(rooms.single.occupied, isEmpty);
      expect(rooms.single.isFreeAt(600), isTrue);
      expect(rooms.single.freeUntil(600), isNull);
    });

    test('the evening grid does not book into the daytime room beside it', () {
      // Both rooms live on one row: C-301's cells are to the left of the
      // second `Room` column, D-301's to the right.
      final rooms = svc.debugParseRoomsComputingHtml(
        '''
<table>
$header
<tr>
  <td>C-301</td>
  <td colspan="4">PF (SE-C)</td><td></td>
  <td colspan="4"></td><td></td>
  <td colspan="4"></td><td></td>
  <td colspan="4"></td><td></td>
  <td colspan="4"></td><td></td>
  <td colspan="4"></td>
  <td>D-301</td>
  <td colspan="5">MS Seminar (MS-A)</td>
  <td></td>
</tr>
</table>''',
        'Monday',
      );

      RoomOccupancy of(String name) => rooms.firstWhere(
        (r) => r.room == name,
        orElse: () => fail('$name not parsed: $rooms'),
      );

      final daytime = of('C-301');
      expect(daytime.occupied, hasLength(1));
      expect(daytime.occupied.single.start, 510); // 08:30
      expect(daytime.occupied.single.end, 590); // 09:50
      // Free when the evening class is on, which is the whole point.
      expect(daytime.isFreeAt(1040), isTrue);

      final evening = of('D-301');
      expect(evening.occupied, hasLength(1));
      expect(evening.occupied.single.start, 1040); // 17:20
      expect(evening.occupied.single.end, 1120); // 18:40
      expect(evening.isFreeAt(510), isTrue, reason: 'free all morning');
      expect(evening.freeUntil(600), 1040);
    });

    test('the lab separator switches the time headers too', () {
      // Labs are drawn against their own periods — `08:30-11:15`, three
      // hours wide, where the daytime grid says `08:30-09:50`. Reading
      // them against the daytime table runs every lab five minutes over.
      final rooms = svc.debugParseRoomsComputingCsv(
        '${_csvAt(14, {
          0: 'Room/ Time',
          1: '08:30-09:50',
          5: '10:00-11:20',
          9: '11:30-12:50',
          13: '01:00-02:20',
        })}\n'
        '${_csvAt(14, {0: 'C-301', 1: 'PF (SE-C)'})}\n'
        '${_csvAt(40, {
          0: 'Lab',
          1: '08:30-11:15',
          11: '11:30-02:15',
          21: '02:30-05:15',
          31: '05:20 - 08:05 (inc. 10 min. break)',
        })}\n'
        '${_csvAt(40, {0: 'Comp-I', 1: 'ICT Lab EE-A'})}\n'
        '${_csvAt(40, {0: 'Comp-II', 11: 'Net Lab EE-B'})}\n',
        'Wednesday',
      );

      RoomOccupancy of(String name) => rooms.firstWhere(
        (r) => r.room == name,
        orElse: () => fail('$name not parsed: $rooms'),
      );

      final lecture = of('C-301');
      expect(lecture.isLab, isFalse);
      expect(lecture.occupied.single.start, 510);
      expect(lecture.occupied.single.end, 590);

      final first = of('Comp-I');
      expect(first.isLab, isTrue);
      expect(first.occupied.single.start, 510);
      expect(
        first.occupied.single.end,
        675, // 11:15 — the lab's own period end, not the 11:20 of the
        // daytime table it shares a tab with.
      );

      // The second lab period starts at 11:30, which only the lab table
      // knows; the daytime table would place it at 10:00.
      final second = of('Comp-II');
      expect(second.isLab, isTrue);
      expect(second.occupied.single.start, 690);
      expect(second.occupied.single.end, 855);
    });

    test('the evening lab slot is recognised despite its annotation', () {
      // It is written `05:20 - 08:05 (inc. 10 min. break)`, which no
      // pattern ending at the second time can match.
      final rooms = svc.debugParseRoomsComputingCsv(
        '${_csvAt(14, {
          0: 'Room/ Time',
          1: '08:30-09:50',
          5: '10:00-11:20',
          9: '11:30-12:50',
          13: '01:00-02:20',
        })}\n'
        '${_csvAt(40, {
          0: 'Lab',
          1: '08:30-11:15',
          11: '11:30-02:15',
          21: '02:30-05:15',
          31: '05:20 - 08:05 (inc. 10 min. break)',
        })}\n'
        '${_csvAt(40, {0: 'Comp-III', 31: 'Night Lab EE-C'})}\n',
        'Wednesday',
      );

      final lab = rooms.single;
      expect(lab.isLab, isTrue);
      expect(lab.occupied.single.start, 1040); // 17:20
      expect(lab.occupied.single.end, 1205); // 20:05
      expect(lab.isFreeAt(1100), isFalse);
    });
  });

  group('engineering and management', () {
    const engHeader = '''
<tr>
  <td></td><td></td><td>Room</td>
  <td colspan="17">8:30 - 09:50</td><td></td>
  <td colspan="17">09:55 - 11:15</td><td></td>
  <td colspan="17">11:25 - 12:45</td><td></td>
  <td colspan="17">12:50 - 02:10</td>
</tr>''';

    test('a teacher row extends the booking to its stated time', () {
      // Engineering writes a make-up as a time on the teacher's row.
      final rooms = svc.debugParseRoomsEngineeringHtml(
        '''
<table>
$engHeader
<tr>
  <td>Monday</td><td>Classes</td><td>B-019</td>
  <td colspan="17">DB Systems EE-A</td><td></td>
  <td colspan="17"></td><td></td>
  <td colspan="17"></td><td></td>
  <td colspan="17"></td>
</tr>
<tr>
  <td></td><td></td><td></td>
  <td colspan="17">Dr. Farhan Khalid 05:15 -08:00</td>
</tr>
<tr>
  <td>Lab,Elect. Netwk. An</td>
</tr>
<tr>
  <td></td><td></td><td></td>
  <td colspan="17">Must Not Be Booked</td>
</tr>
</table>''',
      );

      final room = rooms.single;
      expect(room.room, 'B-019');
      expect(room.day, 'Monday');
      expect(room.occupied, hasLength(2), reason: 'the class and its make-up');
      expect(room.occupied.first.start, 510);
      expect(room.occupied.first.end, 590);
      // The evening make-up runs past the last labelled period, so the
      // day window has to grow with it.
      expect(room.occupied.last.start, 1035); // 17:15
      expect(room.occupied.last.end, 1200); // 20:00
      expect(room.dayEnd, 1200);

      expect(
        room.isFreeAt(1100),
        isFalse,
        reason: 'the make-up is a real booking',
      );
    });

    test('a footer row does not inherit the room above it', () {
      final rooms = svc.debugParseRoomsEngineeringHtml(
        '''
<table>
$engHeader
<tr>
  <td>Monday</td><td>Classes</td><td>B-020</td>
  <td colspan="17">DB Systems EE-A</td>
</tr>
<tr>
  <td>Tuesday</td><td>Classes</td><td>B-021</td>
  <td colspan="17">Calculus EE-B</td>
</tr>
</table>''',
      );

      expect(rooms.map((r) => r.room).toSet(), {'B-020', 'B-021'});
      expect(rooms.map((r) => r.day).toSet(), {'Monday', 'Tuesday'});
      // Every new day opens with classes, whatever the last one ended on.
      expect(rooms.every((r) => !r.isLab), isTrue);
    });

    test('management: a section code widens the block beside it', () {
      final header = _row(51);
      header[2] = 'Room';
      header[3] = '08:30-09:50';
      header[11] = '10:00-11:20';
      header[19] = '11:30-12:50';
      header[27] = '01:00-02:20';
      header[35] = '02:25-03:45';
      header[43] = '03:50-05:10';

      // Management draws a merged block with the course in the first
      // period and its section code in the last one it covers.
      final labRow = _row(51);
      labRow[0] = 'Monday';
      labRow[1] = 'Labs';
      labRow[2] = 'A-01';
      labRow[3] = 'LG2009 Data Analysis Lab';
      labRow[13] = 'AF03A';

      final rooms = svc.debugParseRoomsManagementCsv(
        '${_csvRow(header)}\n${_csvRow(labRow)}\n',
      );

      final room = rooms.single;
      expect(room.isLab, isTrue);
      expect(room.occupied.single.start, 510);
      expect(
        room.occupied.single.end,
        680, // the end of the second period the code sits in
      );
    });

    test('management: a class with its own time is not widened', () {
      final header = _row(51);
      header[2] = 'Room';
      header[3] = '08:30-09:50';
      header[11] = '10:00-11:20';
      header[19] = '11:30-12:50';
      header[27] = '01:00-02:20';
      header[35] = '02:25-03:45';
      header[43] = '03:50-05:10';

      // The typed time is the finer answer: this class ends at 10:20,
      // and stretching it to the end of the period would hold the room
      // for another hour.
      final timedRow = _row(51);
      timedRow[0] = 'Monday';
      timedRow[1] = 'Classes';
      timedRow[2] = 'A-02';
      timedRow[3] = 'SS1016 English - I (08:30-10:20)';
      timedRow[13] = 'BBA01B';

      final rooms = svc.debugParseRoomsManagementCsv(
        '${_csvRow(header)}\n${_csvRow(timedRow)}\n',
      );

      final room = rooms.single;
      expect(room.occupied.single.start, 510);
      expect(room.occupied.single.end, 620); // 10:20, not 11:20
      expect(room.isFreeAt(640), isTrue, reason: 'free again at 10:40');
    });

    test('management: the auditorium is not offered as a spare room', () {
      final header = _row(51);
      header[2] = 'Room';
      header[3] = '08:30-09:50';
      header[11] = '10:00-11:20';

      for (final label in ['Audi', 'Audiatoriam']) {
        final r = _row(51);
        r[0] = 'Monday';
        r[1] = 'Classes';
        r[2] = label;
        r[3] = 'Some Class';

        final rooms = svc.debugParseRoomsManagementCsv(
          '${_csvRow(header)}\n${_csvRow(r)}\n',
        );
        expect(rooms, isEmpty, reason: '$label must not be listed');
      }
    });

    test('management: sheet headings are not rooms', () {
      final rooms = svc.debugParseRoomsManagementCsv(
        '${_csvAt(51, {
          2: 'Room',
          3: '08:30-09:50',
          11: '10:00-11:20',
          19: '11:30-12:50',
          27: '01:00-02:20',
        })}\n'
        '${_csvAt(51, {
          0: 'Monday',
          1: 'Classes',
          2: 'B-227',
          3: 'AF1002 Financial Accounting',
        })}\n',
      );

      expect(rooms.single.room, 'B-227');
      expect(rooms.map((x) => x.room), isNot(contains('Room')));
      expect(rooms.map((x) => x.room), isNot(contains('Classes')));
    });
  });

  // ---------------------------------------------------------------------
  // The screen's own wiring. The data layer is covered above; what is
  // left is that the tab knows not to ask for anything until it is the
  // one being looked at.
  // ---------------------------------------------------------------------

  group('the tab itself', () {
    test('a day with no sheet asks nothing of the network', () async {
      final result = await TimetableService.instance.loadAllRooms('Sunday');
      expect(result.rooms, isEmpty);
      expect(result.fromCache, isFalse);
      expect(
        result.fetchedAt.millisecondsSinceEpoch,
        0,
        reason: 'nothing was fetched, so nothing should claim to be fresh',
      );
    });

    testWidgets('offers its controls before any sheet has been read', (
      tester,
    ) async {
      // Not active, so nothing is fetched — the tab proves itself by
      // staying quiet until it is the one on screen. The app opens on
      // Notes, so this is the state every student sees first.
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RoomsScreen(active: false))),
      );
      await tester.pump();

      expect(find.text('BLOCK'), findsOneWidget);
      expect(find.text('KIND'), findsOneWidget);
      expect(find.text('WHEN'), findsOneWidget);
      expect(find.text('Monday'), findsOneWidget);
      expect(find.text('Labs'), findsOneWidget);
      expect(find.text('Pick a time…'), findsOneWidget);

      // No title to look for: the wayfinding tab's shifter heads the
      // screen now, and this screen is only ever shown under it.

      // No count and no list: the sheets have not been asked for, so
      // there is nothing to offer and nothing to report an error about.
      expect(find.textContaining('free now'), findsNothing);
      expect(find.byType(RefreshIndicator), findsNothing);

      // Unmount so the screen's clock does not outlive the test.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a tab that starts as the one on screen still opens', (
      tester,
    ) async {
      // The app never does this — it opens on Notes — but the screen
      // must not depend on it. Loading has to be able to begin from
      // initState, where the skeleton paints before any of it resolves.
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: RoomsScreen(active: true))),
      );

      expect(tester.takeException(), isNull);
      // The header is above the loading skeleton, so it is the proof the
      // screen built at all — the title the other test used to lean on
      // now belongs to the shifter.
      expect(find.text('BLOCK'), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  // ---------------------------------------------------------------------
  // The real sheets, when a copy is on this machine. Every assertion
  // here is about the parser reading what the university actually
  // publishes, so the group stands down without the sheets rather than
  // failing.
  // ---------------------------------------------------------------------

  final dir = '${Platform.environment['TEMP']}\\opencode';
  File f(String name) => File('$dir\\$name');
  bool has(String name) => f(name).existsSync();
  final saved =
      has('ct_Monday.html') &&
      has('sheet_eng.html') &&
      has('sheet_mgmt.csv');

  group('real sheets', () {
    List<RoomOccupancy> computing(String day) => svc
        .debugParseRoomsComputingHtml(f('ct_$day.html').readAsStringSync(), day);
    List<RoomOccupancy> engineering() => svc.debugParseRoomsEngineeringHtml(
      f('sheet_eng.html').readAsStringSync(),
    );
    List<RoomOccupancy> management() =>
        svc.debugParseRoomsManagementCsv(f('sheet_mgmt.csv').readAsStringSync());

    /// Invariants every parse has to satisfy, whichever sheet it came
    /// from.
    void checkInvariants(List<RoomOccupancy> rooms, String source) {
      expect(rooms, isNotEmpty, reason: '$source produced no rooms');

      for (final room in rooms) {
        expect(
          const {'', 'A', 'B', 'C', 'D'}.contains(room.building),
          isTrue,
          reason: '${room.room} has building "${room.building}"',
        );
        expect(
          room.room.toLowerCase().startsWith('audi'),
          isFalse,
          reason: '${room.room} should not be listed',
        );
        expect(room.dayStart, greaterThan(0));
        expect(
          room.dayEnd,
          greaterThan(room.dayStart),
          reason: '${room.room} has an empty day window',
        );

        var previous = -1;
        for (final r in room.occupied) {
          expect(r.start, greaterThanOrEqualTo(previous));
          expect(
            r.end,
            greaterThan(r.start),
            reason: '${room.room} has a backwards booking $r',
          );
          expect(
            r.start,
            greaterThanOrEqualTo(room.dayStart),
            reason: '${room.room} books before its day starts',
          );
          expect(
            r.end,
            lessThanOrEqualTo(room.dayEnd),
            reason: '${room.room} books after its day ends',
          );
          previous = r.end;
        }
      }
    }

    test('every school publishes rooms, with both kinds', () {
      final days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'];
      var sawLabs = false;
      var sawClassrooms = false;
      var sawAllFourBuildings = false;

      for (final day in days) {
        final c = computing(day);
        checkInvariants(c, 'computing/$day');
        expect(c.length, greaterThan(20), reason: 'computing/$day');
        sawLabs = sawLabs || c.any((r) => r.isLab);
        sawClassrooms = sawClassrooms || c.any((r) => !r.isLab);

        for (final list in [engineering(), management()]) {
          final dayList = [for (final r in list) if (r.day == day) r];
          if (dayList.isEmpty) continue;
          checkInvariants(dayList, day);
          sawLabs = sawLabs || dayList.any((r) => r.isLab);
          sawClassrooms = sawClassrooms || dayList.any((r) => !r.isLab);
        }

        final buildings = {
          for (final r in c)
            if (r.building.isNotEmpty) r.building,
        };
        sawAllFourBuildings =
            sawAllFourBuildings || const {'A', 'B', 'C', 'D'}.every(buildings.contains);
      }

      expect(sawLabs, isTrue, reason: 'no labs anywhere');
      expect(sawClassrooms, isTrue, reason: 'no classrooms anywhere');
      expect(
        sawAllFourBuildings,
        isTrue,
        reason: 'computing covers C and D, management A, engineering B',
      );
    });

    test('labs and classrooms do not overlap within a school and day', () {
      for (final day in ['Monday', 'Wednesday']) {
        final rooms = computing(day);
        final labs = {
          for (final r in rooms)
            if (r.isLab) roomKey(r.room),
        };
        final classes = {
          for (final r in rooms)
            if (!r.isLab) roomKey(r.room),
        };
        expect(
          labs.intersection(classes),
          isEmpty,
          reason: 'a room is filed under one section or the other, not both',
        );
      }
    });

    test('a room two schools share is checked against both books', () {
      // Computing and Management overlap on the block-C rooms, and only
      // from Wednesday on: `C - 405` (Management's padded spelling) is
      // Wednesday's, `C-406` and `C-407` Thursday's.
      for (final day in ['Wednesday', 'Thursday']) {
        final merged = coalesceRooms([
          ...computing(day),
          for (final r in management())
            if (r.day == day) r,
        ]);

        final shared = merged.where((r) => r.schools.length > 1).toList();
        expect(shared, isNotEmpty, reason: '$day has a shared room');

        for (final room in shared) {
          expect(room.schools, containsAll(['computing', 'management']));
          expect(
            room.building,
            'C',
            reason: '${room.room} is a block-C room on both sheets',
          );
          expect(room.occupied, isNotEmpty);
          expect(room.dayEnd, greaterThan(room.dayStart));
        }

        // Counted once, not once per sheet.
        final computingRooms = computing(day).length;
        final managementRooms = [
          for (final r in management())
            if (r.day == day) r,
        ].length;
        expect(merged.length, lessThan(computingRooms + managementRooms));
      }
    });

    test('a shared room is busy when either school has it', () {
      const day = 'Wednesday';
      const at = 600; // 10:00
      final merged = coalesceRooms([
        ...computing(day),
        for (final r in management())
          if (r.day == day) r,
      ]);

      final shared = merged.firstWhere(
        (r) => r.schools.length > 1,
        orElse: () => fail('no shared room on $day'),
      );
      final fromComputing = computing(day).firstWhere(
        (r) => roomKey(r.room) == roomKey(shared.room),
      );
      final fromManagement = [
        for (final r in management())
          if (r.day == day && roomKey(r.room) == roomKey(shared.room)) r,
      ].single;

      // Whatever either sheet says about it, the merged room is not free
      // while either of them has a class in it.
      expect(
        shared.isFreeAt(at),
        fromComputing.isFreeAt(at) && fromManagement.isFreeAt(at),
        reason: '${shared.room} must answer against both books',
      );
      expect(
        shared.occupied.length,
        greaterThanOrEqualTo(
          [
            ...fromComputing.occupied,
            ...fromManagement.occupied,
          ].length -
          1,
        ),
      );
    });

    test('a free room at a given time really is free', () {
      final all = coalesceRooms([
        ...computing('Monday'),
        for (final r in management())
          if (r.day == 'Monday') r,
        for (final r in engineering())
          if (r.day == 'Monday') r,
      ]);

      for (final at in [510, 600, 700, 900, 1035, 1100]) {
        final free = all.where((r) => r.isFreeAt(at)).toList();
        final busy = all.where((r) => !r.isFreeAt(at)).toList();

        for (final room in free) {
          final until = room.freeUntil(at);
          if (until != null) {
            expect(until, greaterThan(at));
            // "Free until" is the minute it is next taken, so the room
            // still holds right up to the one before.
            expect(
              room.isFreeAt(until - 1),
              isTrue,
              reason: '${room.room} claims free until $until but is taken '
                  'before then',
            );
            expect(
              room.isFreeAt(until),
              isFalse,
              reason: '${room.room} says it is free at the minute it is '
                  'booked',
            );
          }
        }

        // A busy room has nothing to offer, and must not be handed a
        // time that reads like it does.
        expect(
          busy.every((r) => r.freeUntil(at) == null),
          isTrue,
          reason: 'a busy room offered a "free until" at $at',
        );
      }

      expect(all.where((r) => r.isFreeAt(1035)).length, greaterThan(10));
    });

    test('rooms span the whole day, evening included', () {
      final c = computing('Monday');
      // Computing's last period runs to 20:05, so its day window has to
      // reach it even for a room that finishes at lunchtime.
      expect(c.map((r) => r.dayEnd).toSet(), everyElement(1205));

      final labs = c.where((r) => r.isLab).toList();
      expect(labs, isNotEmpty);
      expect(
        labs.map((r) => r.building).toSet(),
        containsAll(['C', 'D']),
        reason: 'the computing labs sit in both blocks',
      );
    });

    test('every free room offered belongs to the building asked for', () {
      final rooms = coalesceRooms([
        ...computing('Monday'),
        for (final r in management())
          if (r.day == 'Monday') r,
        for (final r in engineering())
          if (r.day == 'Monday') r,
      ]);

      // Block B only frees up once its first period is over, so no single
      // moment has to cover every block.
      const times = [510, 540, 600, 700, 900, 1035];
      final offered = <String, int>{};

      for (final building in ['A', 'B', 'C', 'D']) {
        var seen = false;
        for (final at in times) {
          final picked = [
            for (final r in rooms)
              if (r.building == building && r.isFreeAt(at)) r,
          ];
          expect(
            picked.every((r) => r.building == building),
            isTrue,
            reason: 'a room from another block offered under $building',
          );
          if (picked.isNotEmpty) {
            seen = true;
            offered[building] = (offered[building] ?? 0) + picked.length;
          }
        }
        expect(
          seen,
          isTrue,
          reason: 'nothing is ever free in block $building',
        );
      }

      // And no room is offered under two blocks at once.
      expect(
        rooms.map((r) => roomKey(r.room)).toSet().length,
        rooms.length,
        reason: 'a room has one building, however it is spelled',
      );
    });

    test('the rooms the parser is built for are actually there', () {
      final c = computing('Monday');
      for (final room in ['C-301', 'D-301', 'D-505']) {
        expect(
          c.map((r) => r.room),
          contains(room),
          reason: '$room is on the Monday sheet',
        );
      }
      // D-505 carries no cell on any day — it is the always-free room
      // that the previous parser lost entirely.
      final d505 = c.firstWhere((r) => r.room == 'D-505');
      expect(d505.building, 'D');
      expect(d505.dayEnd, 1205);
    });

    test('management lists the same room twice, in two spellings', () {
      final m = [
        for (final r in management())
          if (r.day == 'Monday') r,
      ];
      final keys = [for (final r in m) roomKey(r.room)];
      final merged = coalesceRooms(m);
      // Two spellings of one room must not survive as two rooms.
      expect(merged.length, lessThanOrEqualTo(keys.length));
      expect(
        merged.map((r) => roomKey(r.room)).toSet().length,
        merged.length,
        reason: 'coalescing must leave one room per key',
      );
    });
  }, skip: saved ? null : 'saved copies of the sheets are not on this machine');
}
