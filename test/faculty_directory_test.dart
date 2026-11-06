// test/faculty_directory_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:fast_companion/models/faculty_member.dart';
import 'package:fast_companion/services/faculty_directory_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
  // A campus-website department page, shaped like the four the site
  // actually publishes: a spotlight above the cards, cards with a name,
  // a title and a contact row, and one card nobody can email.
  // ---------------------------------------------------------------------

  const dcePage = '''
<!DOCTYPE html>
<html><body>
<div class="head-spotlight">
  <div class="faculty-info">
    <h4>Dr. Muhammad Tariq</h4>
    <p class="faculty-title">Head of Department</p>
  </div>
</div>
<div class="col-lg-4" data-aos="fade-up">
  <div class="faculty-card">
    <div class="faculty-info">
      <h4>Dr. Falak Khan</h4>
      <p class="faculty-title">Professor, HoS (FSE) &amp; HoD (Computer Engineering)</p>
      <div class="faculty-contact">
        <a href="Tel:4111"><i class="bi bi-telephone"></i> 4000</a>
        <a href="mailto:Falak.Khan@nu.edu.pk"><i class="bi bi-envelope"></i> Email</a>
        <a href="../Profile.php?id=4848" class="profile-link">Profile</a>
      </div>
    </div>
  </div>
  <div class="faculty-card">
    <div class="faculty-info">
      <h4>Ms. Sadaf Noor</h4>
      <p class="faculty-title">Lecturer</p>
      <div class="faculty-contact">
        <a href="Tel:123">123</a>
        <a href="../Profile.php?id=4849">Profile</a>
      </div>
    </div>
  </div>
  <div class="faculty-card">
    <div class="faculty-info">
      <h4>Dr. Muhammad Tariq</h4>
      <p class="faculty-title">Professor, HoS (FSE) &amp; HoD (Computer Engineering)</p>
      <div class="faculty-contact">
        <a href="Tel:356">4000</a>
        <a href="mailto:tariq.khan@nu.edu.pk">Email</a>
      </div>
    </div>
  </div>
  <div class="faculty-card">
    <div class="faculty-info">
      <h4>Ms. Tooba</h4>
      <p class="faculty-title">Lab Engineer</p>
      <div class="faculty-contact">
        <a href="Tel:529">529</a>
        <a href="mailto:">Email</a>
      </div>
    </div>
  </div>
  <div class="faculty-card">
    <div class="faculty-info">
      <h4>Ms. Rabia Sultan</h4>
      <p class="faculty-title">Lab Engineer</p>
      <div class="faculty-contact">
        <a href="mailto:">Email</a>
      </div>
    </div>
  </div>
</div>
</body></html>
''';

  const dmsPage = '''
<div class="faculty-card">
  <div class="faculty-info">
    <h4>Dr. Niaz Ahmed</h4>
    <p class="faculty-title">Associate Professor</p>
    <div class="faculty-contact">
      <a href="Tel:254">254</a>
      <a href="mailto:Niaz.Ahmed@isb.nu.edu.pk">Email</a>
    </div>
  </div>
</div>
''';

  List<FacultyMember> dce() => svc.debugParseFacultyHtml(dcePage);

  group('reading a faculty page', () {
    test('reads name, designation and email off a card', () {
      final falak = dce().singleWhere((m) => m.name == 'Dr. Falak Khan');
      expect(
        falak.designation,
        'Professor, HoS (FSE) & HoD (Computer Engineering)',
      );
      expect(falak.email, 'Falak.Khan@nu.edu.pk');
      expect(falak.school, 'School of Engineering');
      expect(falak.department, 'Computer Engineering');
    });

    test('leaves the room empty for the overlay to fill', () {
      // The page's only numbers are phone extensions — `4000`, and the
      // placeholder `123` on the card nobody can email.
      final falak = dce().singleWhere((m) => m.name == 'Dr. Falak Khan');
      expect(falak.office, isEmpty);
      expect(falak.status, OfficeStatus.unlisted);
      expect(falak.hasOffice, isFalse);
    });

    test('skips the spotlight and every card without an address', () {
      // The headline `Head of Department` block sits above the cards
      // and has no email; Sadaf's card has a Tel: extension but no
      // mailto link at all. Four remain: three addressed, two of those
      // listed below with the address the site left blank.
      expect(dce(), hasLength(4));
      expect(dce().where((m) => m.name.contains('Sadaf')), isEmpty);
      expect(dce().where((m) => m.designation == 'Head of Department'), isEmpty);
    });

    test('lists a person the site forgot to give an address', () {
      // `href="mailto:"` is empty on DCE's real page. Hiding her for
      // the university's typo would be worse than a card with no
      // Email button — which the screen already draws for this.
      final tooba = dce().singleWhere((m) => m.name == 'Ms. Tooba');
      expect(tooba.email, isEmpty);
      expect(tooba.designation, 'Lab Engineer');
      expect(tooba.matches('tooba'), isTrue);
      // And the second addressless card is a second person, not a
      // duplicate caught by an empty dedupe key.
      expect(dce().where((m) => m.name.contains('Rabia')), hasLength(1));
    });

    test('lists the head once, under their real designation', () {
      final tariqs = [for (final m in dce()) if (m.name.contains('Tariq')) m];
      expect(tariqs, hasLength(1));
      expect(tariqs.single.designation, contains('& HoD'));
      expect(tariqs.single.designation, isNot(contains('&amp;')));
      expect(tariqs.single.isHoD, isTrue);
      expect(tariqs.single.rank, FacultyRank.professor);
    });

    test('drops the spotlight line even when it carries an address', () {
      const spotlight = '''
<div class="faculty-card">
  <div class="faculty-info">
    <h4>Dr. Ayesha Razzaq</h4>
    <p class="faculty-title">Head of Department</p>
    <div class="faculty-contact"><a href="mailto:ayesha.razzaq@nu.edu.pk">Email</a></div>
  </div>
</div>
<div class="faculty-card">
  <div class="faculty-info">
    <h4>Dr. Ayesha Razzaq</h4>
    <p class="faculty-title">Assistant Professor &amp; HoD</p>
    <div class="faculty-contact"><a href="mailto:ayesha.razzaq@nu.edu.pk">Email</a></div>
  </div>
</div>
''';
      final people = svc.debugParseFacultyHtml(spotlight);
      expect(people, hasLength(1));
      expect(people.single.designation, 'Assistant Professor & HoD');
      expect(people.single.rank, FacultyRank.assistantProfessor);
    });

    test('files a management page under its own school', () {
      final people = svc.debugParseFacultyHtml(
        dmsPage,
        school: 'School of Management',
        department: 'Management Sciences',
      );
      final niaz = people.single;
      expect(niaz.school, 'School of Management');
      expect(niaz.department, 'Management Sciences');
      expect(niaz.email, 'Niaz.Ahmed@isb.nu.edu.pk');
      expect(niaz.rank, FacultyRank.associateProfessor);
    });

    test('refuses a page whose markup it cannot read', () {
      // Contacts exist but no cards: an empty list here would wipe the
      // school from the directory, so it throws instead and the cache
      // covers the gap.
      expect(
        () => svc.debugParseFacultyHtml('<a href="mailto:x@nu.edu.pk">e</a>'),
        throwsFormatException,
      );
    });
  });

  // ---------------------------------------------------------------------
  // The overlay sheet: two columns, `Email | Office`, which the user
  // fills in because the website publishes no rooms.
  // ---------------------------------------------------------------------

  const overlay = '''
Email,Office
Falak.Khan@nu.edu.pk,D-205
niaz.ahmed@isb.nu.edu.pk,D-404
roomless@example.com,
''';

  group('the office overlay', () {
    test('reads the rows that name a room', () {
      // The header has no address, and the row with no room beside the
      // address is not a room — neither reaches the map.
      expect(svc.debugParseOfficeCsv(overlay), {
        'falak.khan@nu.edu.pk': 'D-205',
        'niaz.ahmed@isb.nu.edu.pk': 'D-404',
      });
    });

    test('gives a page person their room, whatever the case', () {
      final people = svc.debugApplyOffices(dce(), svc.debugParseOfficeCsv(overlay));
      final falak = people.singleWhere((m) => m.name == 'Dr. Falak Khan');
      expect(falak.office, 'D-205');
      expect(falak.status, OfficeStatus.listed);
      expect(falak.block, 'D');
    });

    test('leaves anyone the overlay does not mention unlisted', () {
      final people = svc.debugApplyOffices(dce(), svc.debugParseOfficeCsv(overlay));
      final tariq = people.singleWhere((m) => m.name.contains('Tariq'));
      expect(tariq.office, isEmpty);
      expect(tariq.status, OfficeStatus.unlisted);
    });

    test('keeps the rooms the computing sheet already carries', () {
      final fromSheet = svc.debugParseFacultyCsv(synthetic).members;
      final people = svc.debugApplyOffices(fromSheet, svc.debugParseOfficeCsv(overlay));
      expect(
        people.singleWhere((m) => m.name.contains('Arshad Islam')).office,
        'D-101 D',
      );
      expect(
        people.singleWhere((m) => m.name.contains('Zia Ul Qayyum')).office,
        isEmpty,
      );
    });

    test('an empty overlay changes nothing at all', () {
      final fromSheet = svc.debugParseFacultyCsv(synthetic).members;
      expect(svc.debugApplyOffices(fromSheet, const {}), same(fromSheet));
    });
  });

  // ---------------------------------------------------------------------
  // load() itself, with the network swapped out. One unreachable source
  // must cost its own school, not the directory — and a partial answer
  // must never be cached, or the school would stay missing.
  // ---------------------------------------------------------------------

  group('loading when a source is down', () {
    Future<String> okSheet(String id) async => synthetic;
    Future<String> okSite(String url) async => dcePage;

    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('a dead source is retried once, then skipped for the rest', () async {
      var dceCalls = 0;
      final dir = await svc.load(
        forceRefresh: true,
        fetchSheet: okSheet,
        fetchSite: (url) async {
          if (url.contains('Faculty-DCE')) {
            dceCalls++;
            throw const FormatException('Faculty page carries no contacts');
          }
          return dcePage;
        },
      );

      expect(dceCalls, 2); // tried, retried, then left alone
      // The other three pages answered, so Engineering is still there —
      // filed under Electrical Engineering, because only DCE went missing.
      expect(
        dir.members.any((m) => m.department == 'Electrical Engineering'),
        isTrue,
      );
      expect(
        dir.members.any((m) => m.department == 'Computer Engineering'),
        isFalse,
      );
      expect(dir.members.any((m) => m.school == 'School of Computing'), isTrue);
      expect(dir.fromCache, isFalse);

      // A partial directory is never written to the cache, so the next
      // open has to try DCE all over again.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('faculty_directory'), isNull);
    });

    test('a source that fails once loads on the retry', () async {
      var dceCalls = 0;
      final dir = await svc.load(
        forceRefresh: true,
        fetchSheet: okSheet,
        fetchSite: (url) async {
          if (url.contains('Faculty-DCE') && ++dceCalls == 1) {
            throw const SocketException('flaky');
          }
          return dcePage;
        },
      );

      expect(dceCalls, 2);
      expect(
        dir.members.any((m) => m.department == 'Computer Engineering'),
        isTrue,
      );
    });

    test('everything down with a cache falls back to the whole cache',
        () async {
      final good = await svc.load(
        forceRefresh: true,
        fetchSheet: okSheet,
        fetchSite: okSite,
      );
      expect(good.fromCache, isFalse);
      expect(good.members, isNotEmpty);

      Future<String> dead(String _) async {
        throw const FormatException('down');
      }

      final dir = await svc.load(
        forceRefresh: true,
        fetchSheet: dead,
        fetchSite: dead,
      );

      expect(dir.fromCache, isTrue);
      expect(dir.members, hasLength(good.members.length));
      expect(
        [for (final m in dir.members) m.name],
        [for (final m in good.members) m.name],
      );
    });

    test('everything down with no cache rethrows the first failure',
        () async {
      await expectLater(
        svc.load(
          forceRefresh: true,
          fetchSheet: (id) async => throw const FormatException('sheet down'),
          fetchSite: (url) async => throw const SocketException('site down'),
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  // ---------------------------------------------------------------------
  // The real sheet, when a copy is on this machine. Every assertion here
  // is about the parser reading what the university actually publishes,
  // so the group stands down without it rather than failing.
  // ---------------------------------------------------------------------

  final dir = '${Platform.environment['TEMP']}\\opencode';
  final saved = File('$dir\\faculty_computing.csv').existsSync();

  group('the embedded campus trust roots', () {
    test('parse into real certificates a trust context accepts', () {
      final pem = svc.debugSectigoPem;
      // Both halves of the chain the campus site serves: the DV R36
      // intermediate and the Root R46 Android devices may be missing.
      expect('-----BEGIN CERTIFICATE-----'.allMatches(pem), hasLength(2));

      final context = SecurityContext(withTrustedRoots: true);
      expect(
        () => context.setTrustedCertificatesBytes(utf8.encode(pem)),
        returnsNormally,
        reason: 'a malformed PEM would throw here instead of at fetch time',
      );
    });
  });

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
