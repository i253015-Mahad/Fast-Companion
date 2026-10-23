// The deferred marks check that runs some hours after a sign-in.
//
// Two things needed proving and neither needs a device, a session or a
// network: that the check spends exactly two of the portal's five requests
// rather than four, and that it still notices an upload at all. A check
// that saved requests by reading the wrong page would be worthless, and one
// that read everything would sign the student out of Flex.
import 'package:fast_companion/services/flex_alert_extract.dart';
import 'package:fast_companion/services/flex_alert_poller.dart';
import 'package:fast_companion/services/flex_alert_snapshot.dart';
import 'package:fast_companion/services/flex_background_poller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A dashboard carrying all three rotating links, so a poll that fetches
/// more than it was asked for is visible.
const _home = '''
<html><body>
  <a href="/Student/StudentMarks?semid=20263">Marks</a>
  <a href="/Student/Transcript?dump=abc123def">Transcript</a>
  <a href="/Student/Challan?dump=abc123def">Challan</a>
</body></html>
''';

/// Shaped as the portal writes it: a course heading, an assessment button,
/// and a collapse holding the table.
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

/// A sink that only records what it was told.
class _RecordingSink implements FlexAlertSink {
  final List<List<String>> lines = [];

  @override
  Future<void> showSummary({
    required String uid,
    required List<String> lines,
  }) async {
    this.lines.add(List.of(lines));
  }

  @override
  Future<void> showSessionExpired({required String uid}) async {}
}

void main() {
  late Map<String, FlexSnapshot> saved;
  late List<String> fetched;
  late _RecordingSink sink;

  /// A poller watching only what [FlexBackgroundPoller] watches, over a
  /// fixed set of pages, recording every path it asks for.
  FlexAlertPoller poller(
    Map<String, ({bool loginRedirect, String? body})> pages,
  ) {
    return FlexAlertPoller(
      onlySources: FlexBackgroundPoller.sources,
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

  /// Ages every "last polled" stamp so the next poll sees marks as stale —
  /// otherwise the TTL would make the second half of a test cost nothing.
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
    sink = _RecordingSink();
  });

  test('the deferred check spends two requests, never four', () async {
    // Every page is stale and every link is offered. A check that took
    // them all would spend four of a five-request session — and the fifth
    // belongs to the student's own browsing.
    await poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (
        loginRedirect: false,
        body: _marks('8'),
      ),
      '/Student/Transcript?dump=abc123def': (
        loginRedirect: false,
        body: '<html></html>',
      ),
      '/Student/Challan?dump=abc123def': (
        loginRedirect: false,
        body: '<html></html>',
      ),
    }).poll('user-1');

    expect(fetched, [
      '/Home',
      '/Student/StudentMarks?semid=20263',
    ], reason: '/Home because the marks link carries a rotating token; '
        'nothing beyond marks, because the session is spent forever');
  });

  test('it still says so when a mark is uploaded', () async {
    // Baseline, silently — as every first fetch must be.
    final first = await poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (
        loginRedirect: false,
        body: _marks('8'),
      ),
    }).poll('user-1');
    expect(first.notified, isFalse);
    expect(sink.lines, isEmpty);

    await ageTimestamps();

    // The university uploads, three hours later, app closed.
    fetched.clear();
    final second = await poller({
      '/Home': (loginRedirect: false, body: _home),
      '/Student/StudentMarks?semid=20263': (
        loginRedirect: false,
        body: _marks('17'),
      ),
    }).poll('user-1');

    expect(second.notified, isTrue,
        reason: 'a restricted poll must not have lost the ability to '
            'detect the one change the whole feature exists for');
    expect(second.changeCount, 1);
    expect(sink.lines, hasLength(1),
        reason: 'one summary per poll, not one per course');
  });

  group('the uid guard', () {
    test('accepts a real uid', () {
      expect(FlexBackgroundPoller.uidOf({'uid': 'abc'}), 'abc');
    });

    test('refuses anything that would write to the wrong key', () {
      // Each of these would otherwise spend portal requests storing a
      // snapshot under a key nobody reads, while the real account's
      // snapshot went uncompared.
      expect(FlexBackgroundPoller.uidOf({}), isNull, reason: 'absent');
      expect(FlexBackgroundPoller.uidOf({'uid': ''}), isNull, reason: 'empty');
      expect(FlexBackgroundPoller.uidOf({'uid': null}), isNull,
          reason: 'null');
      expect(FlexBackgroundPoller.uidOf({'uid': 7}), isNull,
          reason: 'not a string');
      expect(
        FlexBackgroundPoller.uidOf({'uid': 'anonymous'}),
        'anonymous',
        reason: 'the guard checks shape, not identity — refusing it here '
            'would hide a real problem behind a silent skip',
      );
    });
  });
}
