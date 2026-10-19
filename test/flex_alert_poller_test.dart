// Phase 3 — the poll: from "the Flex tab came into view" to one summary.
//
// Everything the poller decides is exercised here against an injected
// fetch, so no session, device or network is involved. The parsers and the
// snapshot comparison are already tested; what needed testing is the
// wiring between them, and the three ways a poll has to stay quiet.
import 'package:fast_companion/services/flex_alert_extract.dart';
import 'package:fast_companion/services/flex_alert_poller.dart';
import 'package:fast_companion/services/flex_alert_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A dashboard as the portal writes it: every link carrying the rotating
/// `dump=` token that makes a hardcoded path useless.
const _home = '''
<html><body>
  <a href="/Student/StudentMarks?semid=20263">Marks</a>
  <a href="/Student/Transcript?dump=abc123def">Transcript</a>
  <a href="/Student/Challan?dump=abc123def">Challan</a>
</body></html>
''';

/// A marks page one course long. Shaped as the portal writes it — a course
/// heading, then an assessment button whose collapse holds the table — so
/// the parser reads it exactly as it reads the real thing.
String _marks(String obtained) => '''
<html><body>
  <h5>CS2001-Data Structures (BSE-3C)</h5>
  <div class="card-header" id="Assignment">
    <h5 class="mb-3">
      <button data-target="#CS2001-Assignment">Assignment</button>
    </h5>
  </div>
  <div id="CS2001-Assignment" class="collapse show">
    <div class="card-body">
      <table class="sum_table">
        <thead><tr class="titlerow">
          <th>Assignment #</th><th>Weightage</th><th>Obtained Marks</th>
        </tr></thead>
        <tbody>
          <tr class="calculationrow">
            <td>1</td><td>10</td><td>$obtained</td>
          </tr>
          <tr class="totalColumn_1">
            <td>Total</td><td>10</td><td>$obtained</td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</body></html>
''';

/// A sink that only writes down what it was told, so a test can assert on
/// the notification without a plugin, a channel or a device behind it.
class _RecordingSink implements FlexAlertSink {
  _RecordingSink(this.lines);

  /// Every summary raised, in order — one per poll that had something to
  /// say, and none for a poll that did not.
  final List<List<String>> lines;

  /// Every session-expired nudge raised, in order.
  final List<String> expired = [];

  @override
  Future<void> showSummary({
    required String uid,
    required List<String> lines,
  }) async {
    this.lines.add(List.of(lines));
  }

  @override
  Future<void> showSessionExpired({required String uid}) async {
    expired.add(uid);
  }
}

void main() {
  late Map<String, FlexSnapshot> saved;
  late List<String> fetched;
  late _RecordingSink sink;

  /// A poller over a fixed set of pages, recording what it asked for and
  /// what it would have said. The sink is faked so a reported change is
  /// observed without a plugin behind it — and it is shared across the
  /// pollers a test builds, so a sequence of polls reads as one
  /// conversation.
  FlexAlertPoller poller(
    Map<String, ({bool loginRedirect, String? body})> pages,
  ) {
    return FlexAlertPoller(
      fetch: (path) async {
        fetched.add(path);
        return pages[path] ?? (loginRedirect: false, body: null);
      },
      load: (uid) async => saved[uid] ?? const FlexSnapshot.empty(),
      save: (uid, snapshot) async {
        saved[uid] = snapshot;
      },
      sink: sink,
    );
  }

  /// Rewrites the stored "last polled" times to well before now, so the
  /// next poll sees every source as stale.
  ///
  /// The poller records when it fetched, and a poll straight after the last
  /// one is meant to cost nothing — which is the behaviour the TTL exists
  /// for. To exercise a *later* poll, the timestamps are aged rather than
  /// cleared, because clearing them would also wipe the per-account state
  /// under test.
  Future<void> ageTimestamps() async {
    final prefs = await SharedPreferences.getInstance();
    final old = DateTime.now()
        .subtract(const Duration(hours: 2))
        .millisecondsSinceEpoch;
    for (final uid in saved.keys) {
      for (final source in FlexAlertSources.all) {
        await prefs.setInt('flex_alert_last_poll_${uid}_$source', old);
      }
    }
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    saved = {};
    fetched = [];
    sink = _RecordingSink([]);
  });

  test('a first poll baselines silently and stores what it saw', () {
    // Nothing to compare against, so there is nothing to say. This is the
    // whole reason the first poll exists: it establishes the baseline the
    // next one can be judged against.
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
      '/Student/Transcript?dump=abc123def': (loginRedirect: false, body: '<html></html>'),
      '/Student/Challan?dump=abc123def': (loginRedirect: false, body: '<html></html>'),
    });

    return p.poll('user-1').then((outcome) {
      expect(outcome.notified, isFalse,
          reason: 'the first fetch has nothing to compare against');
      expect(outcome.changeCount, 0);
      expect(saved['user-1']!.sources[FlexAlertSources.marks], isNotNull,
          reason: 'the baseline must be stored for the next poll to use');
    });
  });

  test('follows the links the dashboard advertises, not stored paths', () {
    // The portal mints a `dump=` token per session, so the path has to come
    // off the live dashboard. Hardcoding it would 404 in silence, and the
    // alert would never fire with nothing to say why.
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
    });

    return p.poll('user-1').then((_) {
      expect(fetched, contains('/Home'));
      expect(fetched, contains('/Student/StudentMarks?semid=20263'),
          reason: 'the exact href the dashboard advertised');
      expect(fetched, isNot(contains('/Student/StudentMarks')),
          reason: 'never a guessed path without its query');
    });
  });

  test('a changed mark is reported once, and the new state stored', () {
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
    });

    return p.poll('user-1').then((_) {
      // The mark is remarked. A real poll would be minutes later; the
      // timestamps are aged rather than cleared, so this poll sees the
      // source as stale while the stored snapshot survives.
      return ageTimestamps().then((_) {
        final remarked = poller({
          '/Home': (loginRedirect: false, body: _home),
          '/Student/StudentMarks?semid=20263':
              (loginRedirect: false, body: _marks('17')),
        });

        return remarked.poll('user-1');
      });
    }).then((outcome) {
      expect(outcome.notified, isTrue,
          reason: 'a mark going up is exactly what the alert is for');
      expect(outcome.changeCount, 1);
      expect(sink.lines, hasLength(1),
          reason: 'one summary per poll, never one per change');
      expect(sink.lines.single.single, contains('CS2001'),
          reason: 'the alert has to say which course moved');
    });
  });

  test('a source that came back empty keeps its stored hashes', () {
    // A page that failed to parse is not a page with no courses. Reading it
    // as the second would tell the student every course they have ever
    // taken has vanished — wrong, and alarming.
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
    });

    return p.poll('user-1').then((_) {
      return ageTimestamps().then((_) {
        final broken = poller({
          '/Home': (loginRedirect: false, body: _home),
          '/Student/StudentMarks?semid=20263':
              (loginRedirect: false, body: '<html></html>'),
        });

        return broken.poll('user-1');
      });
    }).then((outcome) {
      expect(outcome.notified, isFalse,
          reason: 'an unreadable page is not a change');
      expect(saved['user-1']!.sources[FlexAlertSources.marks], isNotNull,
          reason: 'the stored hashes must survive a bad fetch');
    });
  });

  test('an expired session is reported as such, not as no changes', () async {
    // The student has to know their session died, or the alert simply stops
    // working one day and nothing says why.
    final p = poller({
      '/Home': (loginRedirect: true, body: null),
    });

    final outcome = await p.poll('user-1');

    expect(outcome.sessionExpired, isTrue);
    expect(outcome.notified, isFalse,
        reason: 'an expired session is not a change to report');
  });

  test('the expired-session nudge is raised once per expiry, not per visit', () async {
    // A student who has decided not to sign in yet would otherwise be asked
    // again on every trip to the Flex tab, and a nag that repeats is one
    // they learn to swipe away before reading.
    final expired = poller({
      '/Home': (loginRedirect: true, body: null),
    });

    await expired.poll('user-1');
    await expired.poll('user-1');
    await expired.poll('user-1');

    expect(sink.expired, hasLength(1),
        reason: 'three visits while expired should mention it once');
  });

  test('a working poll re-arms the nudge for the next expiry', () async {
    // A later expiry is a new one and deserves its own single mention —
    // otherwise the first one silences it forever, and the student is never
    // told when it happens again.
    final pages = <String, ({bool loginRedirect, String? body})>{
      '/Home': (loginRedirect: true, body: null),
    };
    final p = poller(pages);

    await p.poll('user-1');
    expect(sink.expired, hasLength(1));

    // The session comes back and a poll reads a page.
    pages['/Home'] = (loginRedirect: false, body: _home);
    pages['/Student/StudentMarks?semid=20263'] =
        (loginRedirect: false, body: _marks('8'));
    await ageTimestamps();
    await p.poll('user-1');
    expect(sink.expired, hasLength(1), reason: 'still only the first');

    // And then it expires again.
    pages['/Home'] = (loginRedirect: true, body: null);
    await ageTimestamps();
    await p.poll('user-1');

    expect(sink.expired, hasLength(2),
        reason: 'the second expiry is a different one and must be said');
  });

  test('a student who has never signed in is never told their session expired', () async {
    // The session service answers "no session" as a plain failed fetch, not
    // as a bounce — so a student who has not logged into Flex yet gets
    // silence from the alert, not a notification claiming something expired
    // that was never started. The portal's own sign-in page is already on
    // screen in front of them.
    final p = poller({
      '/Home': (loginRedirect: false, body: null),
    });

    final outcome = await p.poll('user-1');

    expect(outcome.sessionExpired, isFalse);
    expect(sink.expired, isEmpty,
        reason: 'never-signed-in is not an expiry');
  });

  test('a poll with nothing stale spends no requests', () {
    // The portal serves a session exactly five requests and then refuses.
    // Every one saved is a page the student can still open.
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
      '/Student/Transcript?dump=abc123def': (loginRedirect: false, body: '<html></html>'),
      '/Student/Challan?dump=abc123def': (loginRedirect: false, body: '<html></html>'),
    });

    return p.poll('user-1').then((_) {
      final requestsAfterFirst = fetched.length;
      return p.poll('user-1').then((_) {
        expect(fetched.length, requestsAfterFirst,
            reason: 'a second poll straight after must not fetch again');
      });
    });
  });

  test('a source with no link on the dashboard is skipped, not guessed', () {
    // The portal has refused `/Student/GradeReport` before. Where it does
    // not advertise a link, guessing the path would 404 in silence.
    const noGrades = '''
<html><body>
  <a href="/Student/StudentMarks?semid=20263">Marks</a>
  <a href="/Student/Challan?dump=abc123def">Challan</a>
</body></html>
''';
    final p = poller({
      '/Home': (loginRedirect: false, body: noGrades),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
      '/Student/Challan?dump=abc123def': (loginRedirect: false, body: '<html></html>'),
    });

    return p.poll('user-1').then((outcome) {
      expect(fetched, isNot(contains('/Student/Transcript')),
          reason: 'no link means no request');
      expect(outcome.notified, isFalse);
    });
  });

  test('snapshots are kept per account', () {
    // Two accounts on one phone must not compare their marks against each
    // other — a mark belonging to one would alert the other.
    final p = poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (loginRedirect: false, body: _marks('8')),
    });

    return p.poll('user-1').then((_) => p.poll('user-2')).then((outcome) {
      expect(outcome.notified, isFalse,
          reason: "user-2's first fetch is a baseline, not news");
      expect(saved.keys, containsAll(['user-1', 'user-2']));
    });
  });
}
