// test/faculty_directory_test.dart

import 'dart:io';

import 'package:fast_companion/models/faculty_member.dart';
import 'package:fast_companion/services/faculty_directory_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final svc = FacultyDirectoryService.instance;

  // ---------------------------------------------------------------------
  // A sheet built to contain every shape the real one actually uses.
  // ---------------------------------------------------------------------

  const synthetic = '''
Faculty Offices-School of Computing Fall-2025,,,,
Sr #,Name,Designation,Email,Office#
Dr. Hasan Mujtaba,,"Professor & Head, FSC ",hasan.mujtaba@nu.edu.pk,C-201 A
 Faculty Department of Computer Science ,,,
1,Dr. Muhammad Arshad Islam \t,Professor & HoD,arshad.islam@nu.edu.pk,D-101 D
2,Dr. Zia Ul Qayyum,Professor,zia.qayyum@nu.edu.pk,
3,Dr. Waseem Shahzad,Professor & Director,waseem.shahzad@nu.edu.pk,Director office
 Faculty Department of Software Engineering ,,,
1,"Dr. Atif Aftab Ahmed Jilani
",Associate Professor & HoD \t,atif.jilani@nu.edu.pk,C-502 C
2,Ms. Noor ul Ain,Instructor,Noor.ulAin@nu.edu.pk,C-502 G
3,,,,,
 Faculty Department of Science And Humanities ,,,
20,Ms. Lubna,Lecturer,lubna@nu.edu.pk,ON LEAVE
33,Ms.Maheen Ali,Assistant Office,maheen.ali.v@isb.nu.edu.pk,D-513F
''';

  List<FacultyMember> members() =>
      svc.debugParseFacultyCsv(synthetic).members;

  FacultyMember named(String name) =>
      members().singleWhere((m) => m.name.contains(name));

  group('reading the sheet', () {
    test('keeps only the rows that are people', () {
      // Title, header, three department markers and one entirely blank
      // row are all in the fixture; none is a person.
      expect(members(), hasLength(8));
    });

    test('reads the term off the title row', () {
      expect(svc.debugParseFacultyCsv(synthetic).term, contains('Fall-2025'));
    });

    test('files the head of the faculty under no department', () {
      // No serial number, so their name has slid into the first column
      // and every column after it sits one place left of everyone
      // else's. Walking back from the email still finds them.
      final head = named('Hasan Mujtaba');
      expect(head.department, 'FSC Administration');
      expect(head.office, 'C-201 A');
      expect(head.rank, FacultyRank.professor);
      expect(head.isHoD, isTrue);
    });

    test('follows the department markers', () {
      expect(named('Arshad Islam').department, 'Computer Science');
      expect(named('Atif Aftab').department, 'Software Engineering');
      expect(named('Lubna').department, 'Science And Humanities');
    });
  });

  group('the cells the sheet gets wrong', () {
    test('turns tabs and line breaks into plain spaces', () {
      expect(named('Arshad Islam').name, 'Dr. Muhammad Arshad Islam');
      // The trailing tab is on this designation, not on the name.
      expect(named('Atif Aftab').designation, 'Associate Professor & HoD');
      // The name itself spans a line break in the fixture.
      expect(named('Atif Aftab').name, 'Dr. Atif Aftab Ahmed Jilani');
    });

    test('reads ON LEAVE as a whereabouts, not a room', () {
      final lubna = named('Lubna');
      expect(lubna.status, OfficeStatus.onLeave);
      expect(lubna.hasOffice, isFalse);
      expect(lubna.block, isEmpty);
    });

    test('reads a blank office as unlisted', () {
      expect(named('Zia Ul Qayyum').status, OfficeStatus.unlisted);
      expect(named('Zia Ul Qayyum').office, isEmpty);
    });

    test('keeps a spelled-out office but draws no block from it', () {
      final waseem = named('Waseem Shahzad');
      expect(waseem.status, OfficeStatus.listed);
      expect(waseem.office, 'Director office');
      expect(waseem.block, isEmpty);
      expect(waseem.isDirector, isTrue);
    });

    test('keeps the case of an email it would not have chosen', () {
      expect(named('Noor ul Ain').email, 'Noor.ulAin@nu.edu.pk');
    });
  });

  group('ranks', () {
    test('checks the compound ranks before the bare one', () {
      // Every associate and assistant designation also contains the word
      // `Professor`; ordering is the whole trick.
      expect(
        FacultyRank.rankOf('Associate Professor & HoD'),
        FacultyRank.associateProfessor,
      );
      expect(
        FacultyRank.rankOf('Assistant Professor'),
        FacultyRank.assistantProfessor,
      );
      expect(FacultyRank.rankOf('Professor & Director'), FacultyRank.professor);
      expect(FacultyRank.rankOf('Lecturer'), FacultyRank.lecturer);
      expect(FacultyRank.rankOf('Instructor'), FacultyRank.instructor);
    });

    test('carries the roles separately from the rank', () {
      final atif = named('Atif Aftab');
      expect(atif.rank, FacultyRank.associateProfessor);
      expect(atif.isHoD, isTrue);
      expect(atif.isCoordinator, isFalse);
    });

    test('does not invent a rank for a designation that has none', () {
      // `Assistant Office` is a typo in the sheet, not a rank.
      final maheen = named('Maheen Ali');
      expect(maheen.rank, FacultyRank.other);
      expect(maheen.designation, 'Assistant Office');
    });
  });

  group('looking someone up', () {
    test('sorts by the name without its honorific', () {
      expect(named('Lubna').lookupName, 'Lubna');
      expect(named('Hasan Mujtaba').lookupName, 'Hasan Mujtaba');
    });

    test('finds by name, email, designation and office alike', () {
      expect(named('Lubna').matches('lub'), isTrue);
      expect(named('Lubna').matches('LUBNA@NU'), isTrue);
      expect(named('Lubna').matches('lecturer'), isTrue);
      expect(named('Hasan Mujtaba').matches('C-201'), isTrue);
      expect(named('Lubna').matches('C-201'), isFalse);
    });

    test('an empty search matches everyone', () {
      expect(members().every((m) => m.matches('  ')), isTrue);
    });
  });

  group('the cache', () {
    test('survives a round trip through json', () {
      final original = named('Atif Aftab');
      final back = FacultyMember.fromJson(original.toJson());
      expect(back.name, original.name);
      expect(back.designation, original.designation);
      expect(back.email, original.email);
      expect(back.office, original.office);
      expect(back.department, original.department);
      expect(back.school, original.school);
      expect(back.rank, original.rank);
      expect(back.isHoD, original.isHoD);
    });

    test('an unknown rank in a stale cache becomes other, not a crash', () {
      final back = FacultyMember.fromJson({'name': 'X', 'rank': 'savant'});
      expect(back.rank, FacultyRank.other);
    });
  });

  // ---------------------------------------------------------------------
  // The real sheet, when a copy is on this machine. Every assertion here
  // is about the parser reading what the university actually publishes,
  // so the group stands down without it rather than failing.
  // ---------------------------------------------------------------------

  final dir = '${Platform.environment['TEMP']}\\opencode';
  final saved = File('$dir\\faculty_computing.csv').existsSync();

  group('real faculty sheet', () {
    final parsed = svc.debugParseFacultyCsv(
      File('$dir\\faculty_computing.csv').readAsStringSync(),
    );
    final all = parsed.members;

    test('finds every person on it', () {
      // 1 head + 64 CS + 38 AI&DS + 30 SE + 17 Cyber + 51 Science &
      // Humanities. The sheet is a saved snapshot, so this is exact.
      expect(all, hasLength(201));
    });

    test('reads every department the sheet marks', () {
      expect(
        {for (final m in all) m.department},
        containsAll(<String>{
          'FSC Administration',
          'Computer Science',
          'Artificial Intelligence & Data Science',
          'Software Engineering',
          'Cyber Security',
          'Science And Humanities',
        }),
      );
    });

    test('leaves no control character in any field', () {
      for (final m in all) {
        for (final field in [m.name, m.designation, m.email, m.office]) {
          expect(field.contains('\n'), isFalse, reason: '${m.name}: $field');
          expect(field.contains('\r'), isFalse, reason: '${m.name}: $field');
          expect(field.contains('\t'), isFalse, reason: '${m.name}: $field');
          expect(field, field.trim());
        }
      }
    });

    test('gives everyone a name and an address', () {
      expect(all.every((m) => m.name.isNotEmpty), isTrue);
      expect(all.every((m) => m.email.contains('@')), isTrue);
    });

    test('reads the three people the sheet marks ON LEAVE', () {
      final onLeave = [for (final m in all) if (m.status == OfficeStatus.onLeave) m];
      expect(onLeave, hasLength(3));
      expect(onLeave.map((m) => m.name), containsAll(['Ms. Lubna', 'Ms. Summayah Malik', 'Ms. Eeman']));
      expect(onLeave.every((m) => !m.hasOffice), isTrue);
    });

    test('draws a block from every office that has one', () {
      final withBlock = [for (final m in all) if (m.block.isNotEmpty) m];
      expect(withBlock.length, greaterThan(180));
      expect(withBlock.every((m) => const ['A', 'B', 'C', 'D'].contains(m.block)), isTrue);
    });

    test('keeps both people called Irfan Ullah', () {
      // Same name, different departments, different ranks — a merge
      // keyed on the name would delete one of them.
      final irfans = [for (final m in all) if (m.lookupName == 'Irfan Ullah') m];
      expect(irfans, hasLength(2));
    });

    test('shows the duplicated instructors twice, as the sheet does', () {
      final mishal = [for (final m in all) if (m.lookupName == 'Mishal Shahid') m];
      expect(mishal, hasLength(2), reason: 'rows 32 and 55 of the sheet');
    });

    test('every rank it assigns came from a real designation', () {
      final others = [for (final m in all) if (m.rank == FacultyRank.other) m];
      // `Assistant Office` is the only designation on the sheet that is
      // not one of the five ranks.
      expect(others.map((m) => m.designation), ['Assistant Office']);
    });
  }, skip: saved ? null : 'a saved copy of the faculty sheet is not on this machine');
}
