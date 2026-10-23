// Asks the portal whether anything has changed, and says so once if it has.
//
// This runs when the Flex tab comes into view — there is no background
// scheduling, on purpose: the portal serves a session exactly five requests
// and then refuses, so a poll that runs on a timer burns the session the
// student is about to use. Polling when the tab is shown means the answers
// arrive when someone is there to read them.
//
// What one poll does, in order:
//
//   1. asks each source whether it is stale enough to be worth a request;
//   2. fetches only those, so a poll that finds fresh marks does not spend
//      a request re-reading the transcript;
//   3. hashes what came back and compares it to the stored snapshot;
//   4. stores the new state, then raises one summary if anything moved.
//
// Three answers are deliberately silent. The first fetch, because there is
// nothing to compare against. A source that came back empty, because a page
// that failed to parse is not a page that legitimately emptied — treating
// it as the second would tell a student every course they have ever taken
// has vanished. And more than half the courses changing at once, because
// that is a new term rather than a mark.
//
// Fetching is injected so the decisions can be tested without a device, a
// session or a network.
import 'package:shared_preferences/shared_preferences.dart';

import 'flex_alert_extract.dart';
import 'flex_alert_notifier.dart';
import 'flex_alert_snapshot.dart';
import 'flex_session_service.dart';

/// What one poll learned, for a caller that wants to react beyond the
/// notification — refreshing the screen, for instance.
class FlexPollOutcome {
  /// Whether the student was told anything.
  final bool notified;

  /// Whether the session had expired when the poll ran.
  final bool sessionExpired;

  /// Whether a new baseline was stored instead of reporting changes — a
  /// first fetch, or a page that was wholesale new.
  final bool rebaselined;

  /// How many things moved across every source.
  final int changeCount;

  const FlexPollOutcome({
    this.notified = false,
    this.sessionExpired = false,
    this.rebaselined = false,
    this.changeCount = 0,
  });
}

/// One page to fetch, and what to call it in the snapshot.
class _Source {
  final String name;

  /// The dashboard's link text that identifies this page's href.
  ///
  /// Matched against the live `/Home` document rather than hardcoded,
  /// because the portal puts a rotating `dump=` token on the transcript and
  /// challan links and a `semid` on marks. A path written down here would
  /// be stale by the next session and would 404 in silence — the alert
  /// would simply never fire, and nothing would say why.
  final String linkMarker;

  /// How long before the same page is worth another request.
  ///
  /// Not a rate limit — the five-request session is the real limit — but a
  /// way to not spend a request on a page the student was reading thirty
  /// seconds ago. The Flex tab polls on every visit, and two visits in
  /// quick succession should cost one fetch, not three.
  final Duration ttl;

  const _Source(this.name, this.linkMarker, this.ttl);
}

/// Everything the poller knows how to read, and what each page costs.
///
/// A poller may watch a subset (see `onlySources`): the portal's session
/// serves five requests and then refuses forever, so a background check has
/// to be able to spend two of them rather than all four.
const List<_Source> _sources = [
  // The marks page is the one that moves most often, so it is worth a
  // tighter window than the transcript, which only changes at term end.
  _Source(FlexAlertSources.marks, 'StudentMarks', Duration(minutes: 10)),
  _Source(FlexAlertSources.grades, 'Transcript', Duration(minutes: 60)),
  _Source(FlexAlertSources.fees, 'Challan', Duration(minutes: 30)),
];

typedef FlexFetchPage = Future<({bool loginRedirect, String? body})> Function(
  String path,
);

/// Raises the two things a poll may have to say.
///
/// Injected rather than called statically so a test can observe that a
/// notification *would* have been raised without needing the plugin, the
/// platform channels or a device behind it.
abstract class FlexAlertSink {
  Future<void> showSummary({required String uid, required List<String> lines});

  Future<void> showSessionExpired({required String uid});
}

/// The real sink: the notifications a poll is allowed to raise.
class _PluginFlexAlertSink implements FlexAlertSink {
  const _PluginFlexAlertSink();

  @override
  Future<void> showSummary({
    required String uid,
    required List<String> lines,
  }) =>
      FlexAlertNotifier.showSummary(uid: uid, lines: lines);

  @override
  Future<void> showSessionExpired({required String uid}) =>
      FlexAlertNotifier.showSessionExpired(uid: uid);
}

class FlexAlertPoller {
  FlexAlertPoller({
    FlexFetchPage? fetch,
    Future<FlexSnapshot> Function(String uid)? load,
    Future<void> Function(String uid, FlexSnapshot snapshot)? save,
    FlexAlertSink? sink,
    Set<String>? onlySources,
  })  : _fetch = fetch ?? _defaultFetch,
        _load = load ?? FlexSnapshotStore.load,
        _save = save ?? FlexSnapshotStore.save,
        _sink = sink ?? const _PluginFlexAlertSink(),
        _activeSources = onlySources == null
            ? _sources
            : _sources
                .where((s) => onlySources.contains(s.name))
                .toList(growable: false);

  final FlexFetchPage _fetch;
  final Future<FlexSnapshot> Function(String uid) _load;
  final Future<void> Function(String uid, FlexSnapshot snapshot) _save;
  final FlexAlertSink _sink;

  /// What this poller watches: the whole catalogue, or just what it was
  /// asked about. Restricting it is what keeps a background poll at two
  /// portal requests instead of four — see [_sources].
  final List<_Source> _activeSources;

  static Future<({bool loginRedirect, String? body})> _defaultFetch(
    String path,
  ) async {
    final r = await FlexSessionService.instance.fetchPage(path);
    return (loginRedirect: r.loginRedirect, body: r.body);
  }

  /// The last time a source was read, so a poll can skip a page that is
  /// still fresh. Per source rather than per poll: a student who has just
  /// read their marks should not pay for it again on the way to their fees.
  static const String _lastPollKey = 'flex_alert_last_poll_';

  static String _lastPollPref(String uid, String source) =>
      '$_lastPollKey${uid}_$source';

  /// Polls every source and raises one summary notification if anything
  /// changed.
  ///
  /// [uid] keys the snapshot to the signed-in account, so two accounts on
  /// one phone do not compare their marks against each other.
  Future<FlexPollOutcome> poll(String uid) async {
    final stored = await _load(uid);
    final current = <String, FlexSourceHashes>{};

    // What this poll managed to fetch. A source that was skipped or failed
    // is left out entirely, which is what tells the comparison to keep the
    // stored hashes for it rather than reading the gap as "no courses".
    final fetched = <String>{};

    // What this poll got a page for, which is a wider set than [fetched]: a
    // page that arrived but could not be parsed was still *read*, and the
    // timestamp has to say so or the next poll will spend a request on it
    // again — forever, since the same page will fail to parse the same way.
    final read = <String>{};
    var sessionExpired = false;

    // Which sources are worth a request at all this time.
    final stale = <_Source>[];
    for (final source in _activeSources) {
      if (!await _isFresh(uid, source)) stale.add(source);
    }

    // The dashboard is asked what each link currently is, because the
    // portal puts a rotating token on two of them and a semester id on the
    // third. One request rather than three, and it is spent only when there
    // is something to fetch — a poll with nothing stale costs nothing.
    Map<String, String>? routes;
    if (stale.isNotEmpty) {
      routes = await _routes();
      if (routes == null) {
        // The portal bounced the dashboard itself to sign-in — the session
        // has gone. Stop rather than spending the rest of the budget on
        // pages that will all come back as sign-in. The tail below is what
        // reports the expiry (once, not on every visit), so it has to be
        // reached rather than returned around.
        sessionExpired = true;
        stale.clear();
      } else if (routes.isEmpty) {
        // The dashboard loaded but advertised nothing we recognise. Guessing
        // a path would 404 in silence, so this poll simply does nothing and
        // the next one tries again.
        stale.clear();
      }
    }

    for (final source in stale) {
      final path = routes?[source.name];
      if (path == null) continue;

      final result = await _fetch(path);
      if (result.loginRedirect) {
        // The session died mid-poll. Stop rather than spending the rest of
        // the budget on pages that will all come back as sign-in, and say
        // so once.
        sessionExpired = true;
        break;
      }
      final body = result.body;
      if (body == null) continue;

      // The page arrived, so the clock starts now whether or not it
      // parses. A page that fails to parse will fail the same way next
      // time, and re-reading it on every poll would burn the session's
      // limited requests on an answer that is already known to be
      // unhelpful.
      read.add(source.name);

      final hashes = extractHashes(source.name, body);
      // A page that parsed to nothing is not a page with no courses. Leaving
      // it out keeps the stored hashes, so a broken parse can never read as
      // "every course vanished" — which would be both wrong and alarming.
      if (hashes == null) continue;

      current[source.name] = hashes;
      fetched.add(source.name);
    }

    final outcome = compareSnapshots(stored, current);

    // The new state goes back whether or not it was reported. A change that
    // failed to notify would otherwise be reported again on the next poll,
    // and an alert a student sees twice is one they stop trusting.
    final next = outcome.next;
    if (next != null && fetched.isNotEmpty) {
      await _save(uid, next);
    }
    if (read.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final prefs = await SharedPreferences.getInstance();
      for (final name in read) {
        await prefs.setInt(_lastPollPref(uid, name), now);
      }
      // A page was read, so the session works again — which means the next
      // expiry is a new one and is allowed to say so.
      try {
        await prefs.remove(_expiredNudgedKey(uid));
      } catch (_) {
        // Losing this costs at most one extra nudge later.
      }
    }

    if (outcome.shouldNotify) {
      await _sink.showSummary(uid: uid, lines: outcome.summarize());
    }
    if (sessionExpired) {
      await _nudgeExpiredOnce(uid);
    }

    return FlexPollOutcome(
      notified: outcome.shouldNotify,
      sessionExpired: sessionExpired,
      rebaselined: outcome.rebaselined,
      changeCount: outcome.changes.length,
    );
  }

  static String _expiredNudgedKey(String uid) => 'flex_alert_expired_nudged_$uid';

  /// Tells the student their session expired, at most once per expiry.
  ///
  /// Once, not once per visit: a student who has decided not to sign in yet
  /// would be asked again on every trip to the Flex tab, and a nag that
  /// repeats is one they learn to swipe away before reading. The flag is
  /// cleared when a poll manages to read a page again, so a *later* expiry
  /// still gets its own single mention.
  Future<void> _nudgeExpiredOnce(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_expiredNudgedKey(uid)) ?? false) return;
      await prefs.setBool(_expiredNudgedKey(uid), true);
    } catch (_) {
      // Without a working store there is nowhere to remember it. Nudge
      // anyway: an expired session is worth one mention even if it ends up
      // mentioning it again.
    }
    await _sink.showSessionExpired(uid: uid);
  }

  /// Where each source lives on the current session's dashboard.
  ///
  /// Every link the portal advertises carries a `dump=` token that is
  /// minted per session, so the href has to be read off the live document
  /// rather than written down: a path stored from an earlier session is
  /// stale by the next one and would 404 without a word. The same rule the
  /// attendance service follows, for the same reason.
  ///
  /// `null` means the *portal* said the session is gone, and only that.
  /// A fetch that merely failed — no session at all yet, a dropped
  /// connection, a 404 — comes back as an empty map, meaning "nothing here
  /// to work with", because those are not expiries: a student who has never
  /// signed into Flex should never be told their session expired, and a
  /// network blip is not worth saying anything about.
  ///
  /// A source with no matching link is simply absent from the map, and the
  /// poll skips it rather than guessing.
  Future<Map<String, String>?> _routes() async {
    final home = await _fetch('/Home');
    if (home.loginRedirect) return null;
    if (home.body == null) return const {};

    final out = <String, String>{};
    for (final source in _activeSources) {
      final link = RegExp(
        'href="([^"]*${source.linkMarker}[^"]*)"',
        caseSensitive: false,
      ).firstMatch(home.body!);
      if (link == null) continue;

      var href = link.group(1)!.replaceAll('&amp;', '&');
      if (href.startsWith('http')) {
        final uri = Uri.parse(href);
        final query = uri.query.isEmpty ? '' : '?${uri.query}';
        out[source.name] = '$uri.path$query';
      } else if (href.startsWith('/')) {
        out[source.name] = href;
      } else {
        out[source.name] = '/$href';
      }
    }
    return out;
  }

  /// Whether [source] was read recently enough to skip.
  ///
  /// A source that has never been read is always worth fetching — that is
  /// the first fetch, and it is the one that establishes the baseline the
  /// whole feature rests on.
  Future<bool> _isFresh(String uid, _Source source) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastPollPref(uid, source.name));
      if (last == null) return false;
      return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) <
          source.ttl;
    } catch (_) {
      // Not being able to read the timestamp must not stop the poll: a
      // fetch that happens twice is wasteful, a poll that never runs is
      // silent forever.
      return false;
    }
  }
}
