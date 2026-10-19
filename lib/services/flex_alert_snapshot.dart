// Decides whether a fetched page is worth waking a student for.
//
// Each source keeps a hash per course — marks, grades, fees — and the last
// hashes are stored per account. Comparing the two says what moved. Three
// answers exist, and they are not equally loud:
//
//     first fetch   store it, say nothing
//     nothing moved say nothing
//     something moved   say it, then store the new state
//
// The first fetch is silent because there is nothing to compare against:
// every mark on the page is "new" relative to nothing, and telling a
// student they have marks they have had for a month is the fastest way to
// teach them to ignore the notification. The baseline is the point of the
// first poll, not a result of it.
//
// Storage, per account, as one JSON blob:
//
//     flex_snapshot_<uid> ->
//       {"v":1,
//        "sources":{
//          "marks":{"CS2001":"6054333133821526423", ...},
//          "grades":{"CS2001":"4643466684441503709", ...},
//          "fees":{"1":"754325625271333650", ...}}}
//
// Keyed by account uid, never by roll number — the roll number is the
// student's own data and this is the app's bookkeeping, and the rest of the
// app (`LocalStorageService`) already keys per-account values by uid.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One source of alerts, and the hashes of the courses it listed.
///
/// Keyed by course code for marks and grades, and by challan serial for
/// fees, so that the comparison can name *which* thing moved rather than
/// only that the page is different.
typedef FlexSourceHashes = Map<String, String>;

/// The stored state of one account's alerts: every source, and the last
/// hashes seen for it.
class FlexSnapshot {
  /// Source name to the hashes of the courses it listed.
  final Map<String, FlexSourceHashes> sources;

  const FlexSnapshot(this.sources);

  /// An account with nothing stored yet — every source is empty, which
  /// reads as "nothing compared", not as "nothing on the page".
  const FlexSnapshot.empty() : sources = const {};

  /// One source's hashes, or nothing if that source has never been seen.
  FlexSourceHashes? source(String name) => sources[name];

  /// The stored state as the string that goes into preferences.
  ///
  /// Sources and keys are sorted so the same state always writes the same
  /// bytes: an unsorted blob would differ after a map rehash and leave a
  /// diff of nothing that means nothing.
  String encode() => jsonEncode({
        'v': 1,
        'sources': {
          for (final e in (sources.entries.toList()
                ..sort((a, b) => a.key.compareTo(b.key))))
            e.key: {
              for (final c in (e.value.entries.toList()
                    ..sort((a, b) => a.key.compareTo(b.key))))
                c.key: c.value,
            },
        },
      });

  /// Reads back what [encode] wrote, or an empty snapshot when the payload
  /// is not this format.
  ///
  /// Unreadable is treated as absent rather than as an error: the worst a
  /// lost snapshot does is re-baseline silently, and refusing to parse would
  /// leave the account unable to alert at all until someone cleared the key.
  static FlexSnapshot decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const FlexSnapshot.empty();
      if (decoded['v'] != 1) return const FlexSnapshot.empty();

      final rawSources = decoded['sources'];
      if (rawSources is! Map<String, dynamic>) {
        return const FlexSnapshot.empty();
      }

      final sources = <String, FlexSourceHashes>{};
      rawSources.forEach((name, value) {
        if (value is Map) {
          sources[name] = value.map((k, v) => MapEntry(
                k.toString(),
                v.toString(),
              ));
        }
      });
      return FlexSnapshot(sources);
    } catch (_) {
      return const FlexSnapshot.empty();
    }
  }
}

/// One thing that moved, as the alert names it.
class FlexAlertChange {
  /// The course code or challan serial that moved.
  final String key;

  /// What it is — `marks`, `grades` or `fees`.
  final String kind;

  /// Extra detail for the notification: a course name, an amount.
  ///
  /// Left off when the caller has nothing to add, since the key alone still
  /// identifies what changed.
  final String detail;

  const FlexAlertChange(this.key, this.kind, {this.detail = ''});

  @override
  String toString() =>
      detail.isEmpty ? '$kind $key' : '$kind $key ($detail)';
}

/// The outcome of comparing one poll against the last.
class FlexAlertResult {
  /// Whether the new state was stored, so the caller need not do it.
  final bool stored;

  /// What moved, empty on a silent fetch.
  final List<FlexAlertChange> changes;

  /// The state to store. Null only when the caller passed nothing to
  /// compare, and then there is nothing worth writing either.
  final FlexSnapshot? next;

  /// Whether the comparison was thrown away and replaced with a fresh
  /// baseline, rather than reported — see [_compareSource].
  final bool rebaselined;

  const FlexAlertResult({
    required this.stored,
    this.changes = const [],
    this.next,
    this.rebaselined = false,
  });

  /// Whether any alert should be raised. False on a silent baseline, which
  /// is the common case on a first poll and on every uneventful one after.
  bool get shouldNotify => changes.isNotEmpty;

  /// A line per source naming what moved, for the body of the one summary
  /// notification. Empty when nothing moved.
  ///
  /// Only the first few changes are named. A source that moves thirty
  /// courses at once has already been swallowed by the re-baseline guard, so
  /// anything reaching here is a handful, and a notification that lists
  /// every one of them is a wall of text nobody finishes reading.
  List<String> summarize() {
    const labels = {
      'marks': 'Marks changed',
      'grades': 'Grades updated',
      'fees': 'Fees changed',
    };
    const perSource = 5;

    final out = <String>[];
    final byKind = <String, List<FlexAlertChange>>{};
    for (final c in changes) {
      byKind.putIfAbsent(c.kind, () => []).add(c);
    }
    byKind.forEach((kind, list) {
      final label = labels[kind] ?? 'Changed';
      final names = list
          .take(perSource)
          .map((c) => c.detail.isEmpty ? c.key : c.detail)
          .join(', ');
      final more = list.length > perSource
          ? ' and ${list.length - perSource} more'
          : '';
      out.add('$label: $names$more');
    });
    return out;
  }
}

/// More than this share of courses moving at once is not a mark being
/// uploaded — it is the page being new.
///
/// A term turning over, a portal-wide recalculation, or a re-taken course
/// being filed all move everything together. Reported as changes, a student
/// would get one notification listing every course they have ever taken,
/// which teaches them the alert means nothing. So a jump this large is
/// swallowed and re-baselined silently: the next poll has nothing to
/// compare against, and says nothing.
///
/// Half is picked from the shape of the pages rather than measured: marks
/// and grades arrive a course at a time, so a real upload touches one or
/// two courses out of eight, while a new term touches all of them. Anything
/// past the middle is far closer to "all" than to "a couple".
const _rebuiltShare = 0.5;

/// How many things have to be involved before that share means anything.
///
/// A share of one in one is 1.0, so a source listing a single item — one
/// challan, a student who has just enrolled and has one course — would trip
/// the guard on every genuine change and be swallowed every time. The
/// judgement only applies to a page large enough to have a middle at all:
/// below this, a change is reported, because there is nothing for it to be
/// confused with.
const _rebuiltFloor = 4;

/// Compares this poll's hashes against what was stored, and says what moved.
///
/// Per course rather than per page: a page-level hash can only say "the
/// marks page differs", which makes a useless notification. Comparing course
/// by course names what changed, which is the entire reason a student reads
/// the alert.
///
/// [current] maps a source name to that source's per-course hashes — marks
/// and grades by course code, fees by challan serial.
///
/// Three outcomes, in the order they are considered:
///
/// * the stored hashes are absent or empty for a source — a first fetch for
///   that source, so it is stored and nothing is reported;
/// * more than [_rebuiltShare] of the courses moved at once — a new term or
///   a portal-wide change, so the new state is stored as a fresh baseline
///   and nothing is reported ([FlexAlertResult.rebaselined]);
/// * otherwise each course that moved, appeared or vanished is reported,
///   and the new state is stored.
///
/// A course that vanishes is a change worth reporting: it means the portal
/// dropped a row, which is either a correction the student should know
/// about or a sign the page came back wrong. But when *every* course
/// vanishes, that is the empty-page case, and the re-baseline guard above
/// catches it before it can cry wolf.
FlexAlertResult compareSnapshots(FlexSnapshot? stored, Map<String, FlexSourceHashes> current) {
  final old = stored ?? const FlexSnapshot.empty();

  final changes = <FlexAlertChange>[];
  final nextSources = <String, FlexSourceHashes>{};
  var rebuilt = false;

  final names = <String>{...old.sources.keys, ...current.keys}.toList()..sort();
  for (final name in names) {
    final before = old.source(name) ?? const <String, String>{};
    final after = current[name] ?? const <String, String>{};

    // Keep the stored hashes for a source this poll did not reach. The
    // session serves a strictly limited number of requests, so a poll that
    // could not fetch grades must not erase the grades it knew — the next
    // poll would then treat every one of them as new.
    if (after.isEmpty && before.isNotEmpty) {
      nextSources[name] = before;
      continue;
    }
    if (after.isEmpty) continue;

    nextSources[name] = after;
    final outcome = _compareSource(name, before, after, changes);
    if (outcome == _SourceOutcome.rebaselined) rebuilt = true;
  }

  final next = FlexSnapshot(nextSources);
  if (changes.isEmpty && !rebuilt) {
    return FlexAlertResult(stored: false, next: next);
  }
  return FlexAlertResult(
    stored: true,
    changes: changes,
    next: next,
    rebaselined: rebuilt,
  );
}

enum _SourceOutcome { unchanged, reported, rebaselined }

_SourceOutcome _compareSource(
  String name,
  FlexSourceHashes before,
  FlexSourceHashes after,
  List<FlexAlertChange> changes,
) {
  // No stored hashes means the first fetch of this source: it is a baseline
  // and not news, so nothing is reported.
  if (before.isEmpty) return _SourceOutcome.unchanged;

  final shared = before.keys.where(after.containsKey).toList();
  final moved = shared.where((k) => before[k] != after[k]).length;
  final appeared = after.keys.where((k) => !before.containsKey(k)).length;
  final vanished = before.keys.where((k) => !after.containsKey(k)).length;
  final affected = moved + appeared + vanished;

  // More than half the courses moved at once: the page is new, not edited.
  // Counted against everything either version listed, so a term turning
  // over — every old course gone, every new one appeared — is caught even
  // though no course is present in both.
  final total = (before.keys.toSet()..addAll(after.keys)).length;
  final share = total == 0 ? 0.0 : affected / total;
  if (total >= _rebuiltFloor && share > _rebuiltShare) {
    return _SourceOutcome.rebaselined;
  }

  // Only the courses both versions listed can be reported as changed: the
  // rest were caught by the guard above or are too few to name.
  for (final key in shared) {
    if (before[key] != after[key]) {
      changes.add(FlexAlertChange(key, name));
    }
  }
  for (final key in after.keys.where((k) => !before.containsKey(k))) {
    changes.add(FlexAlertChange(key, name));
  }
  for (final key in before.keys.where((k) => !after.containsKey(k))) {
    changes.add(FlexAlertChange(key, name));
  }
  return _SourceOutcome.reported;
}

/// The stored snapshots, one per account, and the poll that reads them.
class FlexSnapshotStore {
  static const _prefix = 'flex_snapshot_';

  static String _key(String uid) => '$_prefix$uid';

  /// What was stored for this account, or nothing when there is none yet.
  ///
  /// A payload that cannot be vouched for — written for another version, or
  /// not a snapshot at all — reads as absent rather than raising: the worst
  /// that follows is one silent re-baseline.
  static Future<FlexSnapshot> load(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(uid));
      if (raw == null) return const FlexSnapshot.empty();
      return FlexSnapshot.decode(raw);
    } catch (e) {
      // Reading preferences is not worth failing a poll over.
      return const FlexSnapshot.empty();
    }
  }

  static Future<void> save(String uid, FlexSnapshot snapshot) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(uid), snapshot.encode());
    } catch (_) {
      // Losing the snapshot costs one silent re-baseline, so it is not
      // worth failing the poll over either.
    }
  }

  /// Drops this account's snapshot, so the next poll baselines again.
  static Future<void> clear(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(uid));
    } catch (_) {
      // Nothing to recover: the snapshot is already as good as gone.
    }
  }

  /// Loads, compares and stores in one step.
  ///
  /// The new state is stored whenever there is one, whether or not anything
  /// was reported. Storing only after a successful notification would leave
  /// the old state in place when the notification fails, and the next poll
  /// would report the same change again — the alert a student gets twice is
  /// the alert they stop trusting.
  static Future<FlexAlertResult> record(
    String uid,
    Map<String, FlexSourceHashes> current,
  ) async {
    final stored = await load(uid);
    final result = compareSnapshots(stored, current);
    final next = result.next;
    if (next != null && result.stored) {
      await save(uid, next);
    }
    return result;
  }
}
