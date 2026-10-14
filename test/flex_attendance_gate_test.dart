// test/flex_attendance_gate_test.dart

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fast_companion/models/timetable_entry.dart';
import 'package:fast_companion/services/flex_attendance_service.dart';

/// The ring may only land on the signed-in student's own section.
///
/// `SE-C` is not a person: the sheet runs one in three intakes at once,
/// so a course match alone would stamp the student's 94% on a class
/// belonging to the batch above them. These tests hold the gate to the
/// real Fall 2026 portal page and the real Fall 2026 computing sheet.

/// The eight courses the portal lists for `BSE-3C`, with their real
/// percentages — a byte-for-byte copy of what the attendance page said.
final List<Map<String, dynamic>> portalCourses = [
  {
    'code': 'CL2001',
    'name': 'Data Structures - Lab',
    'section': 'BSE-3C',
    'percent': 100.0,
  },
  {
    'code': 'CS2001',
    'name': 'Data Structures',
    'section': 'BSE-3C',
    'percent': 94.0,
  },
  {
    'code': 'EE2003',
    'name': 'Computer Organization and Assembly Language',
    'section': 'BSE-3C',
    'percent': 88.0,
  },
  {
    'code': 'EL2003',
    'name': 'Computer Organization and Assembly Language - Lab',
    'section': 'BSE-3C',
    'percent': 88.0,
  },
  {
    'code': 'MT1004',
    'name': 'Linear Algebra',
    'section': 'BSE-3C',
    'percent': 94.0,
  },
  {
    'code': 'SE1001',
    'name': 'Introduction to Software Engineering',
    'section': 'BSE-3C',
    'percent': 100.0,
  },
  {
    'code': 'SS1015',
    'name': 'Pakistan Studies',
    'section': 'BSE-3C',
    'percent': 100.0,
  },
  {
    'code': 'SS1022',
    'name':
        'Understanding of Holy Quran II/Introduction to Major World Religions II',
    'section': 'BSE-3C',
    'percent': 100.0,
  },
];

TimetableEntry entry({
  required String course,
  required String section,
  required String batch,
  String program = 'SE',
  bool isLab = false,
}) => TimetableEntry(
  day: 'Monday',
  startTime: '08:30',
  endTime: '09:50',
  course: course,
  section: section,
  program: program,
  batch: batch,
  isLab: isLab,
);

/// `SE-C` as the Fall 2026 computing sheet really writes it: three
/// intakes sharing one section letter, each taking its own courses, plus
/// the same intake's other sections.
final List<TimetableEntry> sheet = [
  for (final c in [
    'COAL',
    'Data St',
    'LA',
    'Intro to SE',
    'Pak Studies',
    'UHQ-II',
  ])
    entry(course: c, section: 'SE-C', batch: '2025'),
  entry(course: 'COAL Lab', section: 'SE-C', batch: '2025', isLab: true),
  for (final c in ['Algo', 'AI', 'TBW'])
    entry(course: c, section: 'SE-C', batch: '2024'),
  for (final c in ['PF', 'Calculus'])
    entry(course: c, section: 'SE-C', batch: '2026'),
  for (final c in ['COAL', 'Data St'])
    entry(course: c, section: 'SE-B', batch: '2025'),
  entry(course: 'Data St', section: 'SE-A', batch: '2025'),
];

/// Resets the singleton and hands it a fresh cache to read.
Future<FlexAttendanceService> seeded({
  List<Map<String, dynamic>>? courses,
}) async {
  final service = FlexAttendanceService.instance;
  await service.clear();
  SharedPreferences.setMockInitialValues({
    'flex_attendance_cache': jsonEncode({
      'v': 1,
      'fetchedAt': DateTime.now().millisecondsSinceEpoch,
      'courses': courses ?? portalCourses,
    }),
  });
  await service.loadCached();
  return service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the portal names one section, and the sheet names a batch', () async {
    final service = await seeded();
    service.setEntries(sheet);

    final gate = service.gate;
    expect(gate, isNotNull);
    expect(gate!.program, 'SE');
    expect(gate.letter, 'C');
    // Read off the sheet's own course loads, not from the portal's
    // digits — 2024's SE-C takes Algo, 2026's takes PF, only 2025's
    // takes the courses the portal lists.
    expect(gate.batch, '2025');
  });

  test('rings land on the student\'s rows and nowhere else', () async {
    final service = await seeded();
    service.setEntries(sheet);

    final ringed = [
      for (final e in sheet)
        if (service.matchEntry(e) != null)
          '${e.course}@${e.section}/${e.batch}',
    ];

    expect(ringed, hasLength(7));
    expect(
      ringed,
      containsAll(<String>[
        'COAL@SE-C/2025',
        'Data St@SE-C/2025',
        'LA@SE-C/2025',
        'Intro to SE@SE-C/2025',
        'Pak Studies@SE-C/2025',
        'UHQ-II@SE-C/2025',
        'COAL Lab@SE-C/2025',
      ]),
    );
  });

  test('another intake of the same section is never ringed', () async {
    final service = await seeded();
    service.setEntries(sheet);

    for (final e in sheet.where((e) => e.batch != '2025')) {
      expect(
        service.matchEntry(e),
        isNull,
        reason: '${e.course} ${e.section}/${e.batch}',
      );
    }
  });

  test('the same course in another section is never ringed', () async {
    final service = await seeded();
    service.setEntries(sheet);

    for (final e in sheet.where((e) => e.section != 'SE-C')) {
      expect(service.matchEntry(e), isNull, reason: '${e.course} ${e.section}');
    }
  });

  test(
    'the lecture keeps the lecture\'s figure and the lab the lab\'s',
    () async {
      final service = await seeded();
      service.setEntries(sheet);

      final lecture = service.matchEntry(
        entry(course: 'Data St', section: 'SE-C', batch: '2025'),
      );
      final lab = service.matchEntry(
        entry(
          course: 'Data St Lab',
          section: 'SE-C',
          batch: '2025',
          isLab: true,
        ),
      );

      expect(lecture?.percent, 94.0);
      expect(lab?.percent, 100.0);
    },
  );

  test('a lapsed session leaves the last reading in place', () async {
    final service = await seeded();
    service.setEntries(sheet);
    expect(service.courses, hasLength(8));
    final readAt = service.fetchedAt;

    // No cookie at all — what a student whose session expired sees.
    await service.refresh(force: true);

    expect(service.courses, hasLength(8));
    expect(service.fetchedAt, readAt);
    expect(service.matchEntry(sheet.first)?.percent, 88.0); // COAL
  });

  test(
    'signing out is what drops the reading, not a session expiring',
    () async {
      final service = await seeded();
      await service.clear();

      expect(service.courses, isEmpty);
      expect(service.gate, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('flex_attendance_cache'), isNull);
    },
  );

  test('a page that states no section gives no rings', () async {
    final service = await seeded(
      courses: [
        for (final c in portalCourses) {...c, 'section': ''},
      ],
    );
    service.setEntries(sheet);

    expect(service.courses, hasLength(8));
    expect(service.gate, isNull);
  });

  test('a section this sheet can\'t be matched to gives no rings', () async {
    final service = await seeded(
      courses: [
        for (final c in portalCourses) {...c, 'section': 'XYZ/3'},
      ],
    );
    service.setEntries(sheet);

    expect(service.gate, isNull);
  });

  test('a department the sheet doesn\'t run gives no rings', () async {
    final service = await seeded(
      courses: [
        for (final c in portalCourses) {...c, 'section': 'XYZ-3C'},
      ],
    );
    service.setEntries(sheet);

    expect(service.gate, isNull);
  });

  test('a bare letter two departments share is claimed by neither', () async {
    // Engineering writes the same section both ways, and `A` alone
    // could be either department's.
    final entries = <TimetableEntry>[
      entry(
        course: 'Digital Logic Design',
        section: 'EE-A',
        batch: '2024',
        program: 'EE',
      ),
      entry(
        course: 'Digital Logic Design',
        section: 'A',
        batch: '2024',
        program: 'EE',
      ),
      entry(
        course: 'Linear Circuit Analysis',
        section: 'A',
        batch: '2024',
        program: '',
      ),
      entry(
        course: 'Thermodynamics',
        section: 'CE-A',
        batch: '2024',
        program: 'CE',
      ),
    ];

    final service = await seeded(
      courses: [
        {
          'code': 'EE2001',
          'name': 'Digital Logic Design',
          'section': 'BEE-3A',
          'percent': 75.0,
        },
        {
          'code': 'EE2002',
          'name': 'Linear Circuit Analysis',
          'section': 'BEE-3A',
          'percent': 80.0,
        },
      ],
    );
    service.setEntries(entries);

    expect(service.gate?.label, 'EE-A (2024)');
    expect(service.matchEntry(entries[0]), isNotNull); // EE-A
    expect(
      service.matchEntry(entries[1]),
      isNotNull,
    ); // bare A, department stated
    expect(
      service.matchEntry(entries[2]),
      isNull,
    ); // bare A, department unknown
    expect(service.matchEntry(entries[3]), isNull); // CE-A
  });
}
