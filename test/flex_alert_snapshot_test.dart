// Phase 2 — deciding whether a poll is worth a notification.
//
// Everything here is pure: hashes in, an answer out. No session, no
// preferences, no fixtures — the parsers are already tested, and what needs
// testing here is the *decision*, which is the part a student actually
// feels. A poll that alerts on every fetch is one they turn off, and a poll
// that stays quiet when marks arrive is one they stop waiting for.
import 'package:fast_companion/services/flex_alert_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Eight courses, as a real marks page lists them — enough that the
/// re-baseline guard can tell "a couple of marks arrived" from "the page is
/// new", which is the whole judgement this module makes.
FlexSourceHashes eightCourses({String Function(String code)? hash}) => {
      for (var i = 1; i <= 8; i++)
        'CS20$i': (hash ?? ((code) => 'h$code'))('CS20$i'),
    };

void main() {
  group('the first fetch', () {
    test('stores the baseline and says nothing', () {
      // Every mark on the page is "new" relative to nothing. Telling a
      // student they have marks they have had for a month is the fastest
      // way to teach them to ignore the alert.
      final result =
          compareSnapshots(null, {'marks': eightCourses()});

      expect(result.shouldNotify, isFalse);
      expect(result.changes, isEmpty);
      expect(result.next, isNotNull);
      expect(result.next!.sources['marks'], eightCourses(),
          reason: 'the first fetch has to leave a baseline behind');
    });

    test('treats an empty stored snapshot as nothing, not as no changes', () {
      final result = compareSnapshots(
        const FlexSnapshot.empty(),
        {'grades': eightCourses()},
      );

      expect(result.shouldNotify, isFalse);
      expect(result.next!.sources['grades'], eightCourses());
    });

    test('a source never seen before baselines on its own', () {
      // Fees arrive for the first time while marks already have a baseline.
      // The new source is not news; the old one must not be disturbed.
      final stored = FlexSnapshot({'marks': eightCourses()});
      final result = compareSnapshots(stored, {
        'marks': eightCourses(),
        'fees': {'1': 'h1'},
      });

      expect(result.shouldNotify, isFalse);
      expect(result.next!.sources['fees'], {'1': 'h1'});
      expect(result.next!.sources['marks'], eightCourses());
    });
  });

  group('an uneventful poll', () {
    test('reports nothing', () {
      final stored = FlexSnapshot({
        'marks': eightCourses(),
        'grades': eightCourses(),
        'fees': {'1': 'h1', '2': 'h2'},
      });
      final result = compareSnapshots(stored, {
        'marks': eightCourses(),
        'grades': eightCourses(),
        'fees': {'1': 'h1', '2': 'h2'},
      });

      expect(result.shouldNotify, isFalse);
      expect(result.stored, isFalse,
          reason: 'nothing changed, so there is nothing to write');
    });

    test('a course being renamed elsewhere does not move its hash', () {
      // The parsers leave the name out of the hash, so a rename cannot
      // reach here. This pins that contract from the other side.
      final before = eightCourses();
      final after = Map<String, String>.from(before);
      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isFalse);
    });
  });

  group('a real change', () {
    test('names the course that moved', () {
      // One mark uploaded out of eight. This is the common case and the
      // one the alert exists for, so the notification has to say which
      // course, not merely that the page differs.
      final before = eightCourses();
      final after = Map<String, String>.from(before);
      after['CS203'] = 'a-new-mark';

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isTrue);
      expect(result.changes, hasLength(1));
      expect(result.changes.single.key, 'CS203');
      expect(result.changes.single.kind, 'marks');
      expect(result.stored, isTrue,
          reason: 'the new state has to be stored, or the next poll repeats it');
      expect(result.next!.sources['marks'], after);
    });

    test('names a course that appeared and one that vanished', () {
      final before = eightCourses();
      final after = Map<String, String>.from(before)
        ..remove('CS201')
        ..['CS209'] = 'hCS209';

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.changes.map((c) => c.key), containsAll(['CS201', 'CS209']));
    });

    test('a course dropping off the page is a change worth reporting', () {
      // It is either a correction the student should know about or a sign
      // the page came back wrong — and staying silent about the second
      // would let a broken fetch look like a clean one.
      final before = eightCourses();
      final after = Map<String, String>.from(before)..remove('CS201');

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isTrue);
      expect(result.changes.single.key, 'CS201');
    });

    test('reports changes across sources together', () {
      final before = eightCourses();
      final marks = Map<String, String>.from(before);
      marks['CS201'] = 'a-new-mark';
      final grades = Map<String, String>.from(before);
      grades['CS202'] = 'a-new-grade';

      final result = compareSnapshots(FlexSnapshot({'marks': before, 'grades': before}),
          {'marks': marks, 'grades': grades});

      expect(result.changes, hasLength(2));
      expect(result.changes.map((c) => c.kind), containsAll(['marks', 'grades']));
    });
  });

  group('the re-baseline guard', () {
    test('a term turning over is swallowed, not reported', () {
      // Every old course gone, every new one appeared. Reported as changes
      // this would be one notification listing every course the student has
      // ever taken, and the next poll would report it all again.
      final before = eightCourses();
      final after = {
        for (var i = 1; i <= 8; i++) 'CS30$i': 'hCS30$i',
      };

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isFalse,
          reason: 'a whole new page is a new baseline, not news');
      expect(result.rebaselined, isTrue);
      expect(result.stored, isTrue,
          reason: 'the new baseline must be stored, or the next poll repeats it');
      expect(result.next!.sources['marks'], after);
    });

    test('a portal-wide recalculation is swallowed', () {
      // Every course's marks recomputed at once — which the portal does.
      final before = eightCourses();
      final after = eightCourses(hash: (code) => 'recomputed$code');

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isFalse);
      expect(result.rebaselined, isTrue);
      expect(result.next!.sources['marks'], after);
    });

    test('half the courses moving is still news', () {
      // The guard is *more than* half, so exactly half reports. A student
      // who really did have four marks uploaded deserves to hear it.
      final before = eightCourses();
      final after = Map<String, String>.from(before);
      for (var i = 1; i <= 4; i++) {
        after['CS20$i'] = 'new$i';
      }

      final result =
          compareSnapshots(FlexSnapshot({'marks': before}), {'marks': after});

      expect(result.shouldNotify, isTrue);
      expect(result.changes, hasLength(4));
      expect(result.rebaselined, isFalse);
    });

    test('one course out of many moving is news, however large the page', () {
      // The share is what matters, not the count: one mark out of fifty is
      // still a mark the student is waiting for.
      final many = {
        for (var i = 1; i <= 50; i++) 'CS2$i': 'hCS2$i',
      };
      final after = Map<String, String>.from(many);
      after['CS27'] = 'a-new-mark';

      final result =
          compareSnapshots(FlexSnapshot({'marks': many}), {'marks': after});

      expect(result.shouldNotify, isTrue);
      expect(result.changes.single.key, 'CS27');
    });

    test('guarding one source leaves the others alone', () {
      // A new term must not silence a fee that actually arrived. Each
      // source is judged on its own, so a rebuilt marks page and a new
      // challan are two different answers in one poll.
      final before = eightCourses();
      final newTerm = {
        for (var i = 1; i <= 8; i++) 'CS30$i': 'hCS30$i',
      };

      final result = compareSnapshots(
        FlexSnapshot({
          'marks': before,
          'fees': {'1': 'h1'},
        }),
        {
          'marks': newTerm,
          'fees': {'1': 'a-new-amount'},
        },
      );

      expect(result.rebaselined, isTrue);
      expect(result.changes, hasLength(1),
          reason: 'the changed challan is still reported');
      expect(result.changes.single.key, '1');
      expect(result.next!.sources['marks'], newTerm);
      expect(result.next!.sources['fees'], {'1': 'a-new-amount'});
    });

    test('a source too small to have a middle is never swallowed', () {
      // One challan is the whole of a fees source for most students, and
      // its share is 1.0 whenever it changes. Judged on share alone it
      // would be re-baselined every time and the student would never hear
      // that a fee arrived.
      final result = compareSnapshots(
        FlexSnapshot({
          'fees': {'1': 'h1'},
        }),
        {
          'fees': {'1': 'a-new-amount'},
        },
      );

      expect(result.shouldNotify, isTrue);
      expect(result.rebaselined, isFalse);
      expect(result.changes.single.key, '1');
    });
  });

  group('a poll that did not reach a source', () {
    test('keeps what it already knew instead of reporting it new', () {
      // The session serves a strictly limited number of requests, so a poll
      // that could not fetch grades must not erase them — the next poll
      // would treat every grade as newly arrived and alert on all of them.
      final marks = eightCourses();
      final grades = eightCourses();

      final result = compareSnapshots(
        FlexSnapshot({'marks': marks, 'grades': grades}),
        {'marks': marks}, // grades missing from this poll
      );

      expect(result.shouldNotify, isFalse);
      expect(result.next!.sources['grades'], grades,
          reason: 'an unfetched source keeps its stored hashes');
    });
  });

  group('encoding', () {
    test('survives a round trip', () {
      final snapshot = FlexSnapshot({
        'marks': {'CS2001': '111', 'CS2002': '222'},
        'fees': {'1': '333'},
      });

      final back = FlexSnapshot.decode(snapshot.encode());

      expect(back.sources, snapshot.sources);
    });

    test('writes the same bytes for the same state, whatever order it was built in', () {
      // An unsorted blob would differ after a map rehash, and a diff of
      // nothing that means nothing is worse than no diff at all.
      final a = FlexSnapshot({
        'marks': {'b': '2', 'a': '1'},
      });
      final b = FlexSnapshot({
        'marks': {'a': '1', 'b': '2'},
      });

      expect(a.encode(), b.encode());
    });

    test('an unreadable payload reads as empty rather than throwing', () {
      // The worst a lost snapshot does is re-baseline silently. Refusing to
      // parse would leave the account unable to alert at all.
      expect(FlexSnapshot.decode('not json').sources, isEmpty);
      expect(FlexSnapshot.decode('{"v":2,"sources":{}}').sources, isEmpty,
          reason: 'a future format is not this format');
      expect(FlexSnapshot.decode('{"v":1}').sources, isEmpty);
      expect(FlexSnapshot.decode('[1,2,3]').sources, isEmpty);
    });
  });

  group('the notification text', () {
    test('names what moved, by source', () {
      final result = compareSnapshots(
        FlexSnapshot({
          'marks': {'CS2001': '1', 'CS2002': '2'},
          'fees': {'1': '9'},
        }),
        {
          'marks': {'CS2001': 'a-changed-mark', 'CS2002': '2'},
          'fees': {'1': 'a-new-amount'},
        },
      );

      final body = result.summarize().join('\n');
      expect(body, contains('Marks changed'));
      expect(body, contains('CS2001'));
      expect(body, isNot(contains('CS2002')),
          reason: 'an unmoved course is not news');
      expect(body, contains('Fees changed'));
    });

    test('is empty when nothing moved', () {
      final result = compareSnapshots(
        FlexSnapshot({'marks': eightCourses()}),
        {'marks': eightCourses()},
      );

      expect(result.summarize(), isEmpty);
    });

    test('does not become a wall of text when many courses move', () {
      // Past the guard's threshold this cannot be reached, but the cap
      // keeps a long list from ever filling the screen.
      final many = {
        for (var i = 1; i <= 8; i++) 'CS20$i': 'h$i',
      };
      final after = Map<String, String>.from(many);
      for (var i = 1; i <= 4; i++) {
        after['CS20$i'] = 'new$i';
      }

      final line = compareSnapshots(FlexSnapshot({'marks': many}),
              {'marks': after})
          .summarize()
          .single;

      // Four changes: a label and four names, and no "and n more" yet.
      expect(line, 'Marks changed: CS201, CS202, CS203, CS204');
    });

    test('caps the list and counts what it left out', () {
      // Reachable only on a page large enough that many changes stay under
      // the re-baseline guard's share. Five names fill the line and the
      // rest are counted rather than listed, so the notification never
      // becomes a wall of text.
      final many = {
        for (var i = 1; i <= 20; i++) 'CS2$i': 'hCS2$i',
      };
      final after = Map<String, String>.from(many);
      for (var i = 1; i <= 8; i++) {
        after['CS2$i'] = 'new$i';
      }

      final line = compareSnapshots(FlexSnapshot({'marks': many}),
              {'marks': after})
          .summarize()
          .single;

      expect(line, 'Marks changed: CS21, CS22, CS23, CS24, CS25 and 3 more');
    });
  });

  group('the store', () {
    test('round-trips a snapshot through preferences', () async {
      SharedPreferences.setMockInitialValues({});
      final snapshot = FlexSnapshot({
        'marks': {'CS2001': '111'},
      });

      await FlexSnapshotStore.save('user-1', snapshot);
      final loaded = await FlexSnapshotStore.load('user-1');

      expect(loaded.sources, snapshot.sources);
    });

    test('keeps accounts apart', () async {
      SharedPreferences.setMockInitialValues({});
      await FlexSnapshotStore.save(
          'user-1', FlexSnapshot({'marks': {'CS2001': '111'}}));
      await FlexSnapshotStore.save(
          'user-2', FlexSnapshot({'marks': {'CS2001': '222'}}));

      expect((await FlexSnapshotStore.load('user-1')).sources['marks'],
          {'CS2001': '111'});
      expect((await FlexSnapshotStore.load('user-2')).sources['marks'],
          {'CS2001': '222'});
      expect((await FlexSnapshotStore.load('user-3')).sources, isEmpty,
          reason: 'an account with nothing stored baselines on its own');
    });

    test('clearing a snapshot sends the next poll back to a baseline', () async {
      SharedPreferences.setMockInitialValues({});
      await FlexSnapshotStore.save(
          'user-1', FlexSnapshot({'marks': eightCourses()}));

      await FlexSnapshotStore.clear('user-1');

      expect((await FlexSnapshotStore.load('user-1')).sources, isEmpty);
    });

    test('record stores the new state whether or not it alerted', () async {
      // Storing only after a successful notification would leave the old
      // state behind when the notification fails, and the next poll would
      // report the same change again. An alert a student gets twice is one
      // they stop trusting.
      SharedPreferences.setMockInitialValues({});
      final before = eightCourses();
      await FlexSnapshotStore.save('user-1', FlexSnapshot({'marks': before}));
      final after = Map<String, String>.from(before);
      after['CS203'] = 'a-new-mark';

      final first = await FlexSnapshotStore.record('user-1', {'marks': after});
      expect(first.shouldNotify, isTrue);

      final second = await FlexSnapshotStore.record('user-1', {'marks': after});
      expect(second.shouldNotify, isFalse,
          reason: 'the same page must not alert twice');
    });
  });
}
