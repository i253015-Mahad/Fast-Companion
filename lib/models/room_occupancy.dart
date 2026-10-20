// lib/models/room_occupancy.dart

/// Minutes since midnight for a standalone clock time.
///
/// The sheets write times with no AM/PM: `08:30` is morning and `01:00`
/// is afternoon, because the earliest slot any school publishes is
/// 08:30. Hours 01-07 are therefore afternoon — the same rule
/// `TimetableEntry.startMinutes` applies to its start times.
///
/// Use [minutesRange] for both ends of a slot; a bare hour is only
/// unambiguous once you know which end of a range it is.
int minutesOf(String clock) {
  final parts = clock.split(':');
  if (parts.length != 2) return 0;
  final h = int.tryParse(parts[0].trim());
  final m = int.tryParse(parts[1].trim());
  if (h == null || m == null) return 0;
  final hour = (h >= 1 && h <= 7) ? h + 12 : h;
  return hour * 60 + m;
}

/// Whether a clock time falls in the ambiguous 01-07 band, where the
/// sheet means the afternoon and a bare hour cannot say so.
bool _afternoon(String clock) {
  final h = int.tryParse(clock.split(':').first.trim());
  return h != null && h >= 1 && h <= 7;
}

/// Both ends of a sheet time range, as minutes since midnight.
///
/// Read on its own the hours are not enough: Computing's last slot is
/// written `06:45-08:05` and means 18:45-20:05, so taking the end
/// literally puts it eleven hours before its own start. An end that
/// lands at or before its start is therefore pushed past noon — but only
/// when the start is itself in the ambiguous 01-07 band, because a start
/// at `14:00` leaves nothing to interpret: an end before it is simply
/// broken, and quietly stretching it would book a room backwards into a
/// twelve-hour block.
(int, int) minutesRange(String start, String end) {
  final s = minutesOf(start);
  var e = minutesOf(end);
  if (_afternoon(start) && e <= s) e += 12 * 60;
  return (s, e);
}

/// `14:05` for 845 — zero-padded 24h, matching how the timetable
/// already normalizes its times for display and sorting.
String clockOf(int minutes) {
  final m = minutes % (24 * 60);
  final h = (m ~/ 60).toString().padLeft(2, '0');
  final mm = (m % 60).toString().padLeft(2, '0');
  return '$h:$mm';
}

/// One stretch during which a room is taken.
///
/// Half-open: [start] is busy, [end] is the first free minute, so a
/// class ending 09:50 frees the room for a 09:50 query.
class TimeRange {
  final int start;
  final int end;

  const TimeRange({required this.start, required this.end});

  /// Reads a booking written the way the sheets write it.
  ///
  /// Returns null when the two times cannot be ordered into a forward
  /// range, which would otherwise book a room backwards in time and
  /// call it busy at no moment in particular.
  static TimeRange? parse(String start, String end) {
    final (s, e) = minutesRange(start, end);
    return e > s ? TimeRange(start: s, end: e) : null;
  }

  bool contains(int minutes) => minutes >= start && minutes < end;

  @override
  String toString() => '${clockOf(start)}-${clockOf(end)}';
}

/// One room's schedule on one day, as one school's sheet records it.
///
/// Deliberately *not* a [TimetableEntry]: those record only occupied
/// cells, so a room free the whole day emits nothing and vanishes from
/// the list entirely — precisely the rooms this feature exists to find.
/// This keeps the room itself, the cells it takes, and the day's window,
/// so "free until when" is answerable.
class RoomOccupancy {
  /// Label exactly as the sheet wrote it: `C-301`, `Margala 4 (C-212`,
  /// `Comp-I`.
  final String room;

  /// `A`..`D` read off the label, or `''` when the label carries no
  /// room code (`Comp-I`, `Karakoram-3`).
  final String building;

  /// Whether the sheet filed this room under its `Labs` section rather
  /// than `Classes` — read from that header, never guessed from the
  /// name.
  final bool isLab;

  /// Full weekday the schedule belongs to, e.g. `Monday`.
  final String day;

  /// Which schools' sheets recorded this schedule. Usually one; two when
  /// [coalesceRooms] has merged a room two schools share.
  final List<String> schools;

  /// Occupied stretches, sorted by start and merged, so back-to-back
  /// cells read as one block rather than two.
  final List<TimeRange> occupied;

  /// First minute the day's timetable covers, and the last it runs to.
  ///
  /// The bounds come from the sheet's own time headers rather than from
  /// the classes, so a room with nothing booked still knows what "free
  /// rest of day" means.
  final int dayStart;
  final int dayEnd;

  const RoomOccupancy({
    required this.room,
    required this.building,
    required this.isLab,
    required this.day,
    required this.schools,
    required this.occupied,
    required this.dayStart,
    required this.dayEnd,
  });

  bool isFreeAt(int minutes) => !occupied.any((r) => r.contains(minutes));

  /// The first minute a room free at [minutes] is next taken — so the
  /// room is free up to but not including it — or null when nothing else
  /// is booked and it holds until [dayEnd].
  ///
  /// A room that is already busy has no "free until", so it returns null
  /// there too: a caller cannot be handed a time and read it as an offer
  /// of the room.
  int? freeUntil(int minutes) {
    if (!isFreeAt(minutes)) return null;
    for (final r in occupied) {
      if (r.start > minutes) return r.start;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'room': room,
    'building': building,
    'isLab': isLab,
    'day': day,
    'schools': schools,
    'occupied': [for (final r in occupied) [r.start, r.end]],
    'dayStart': dayStart,
    'dayEnd': dayEnd,
  };

  factory RoomOccupancy.fromJson(Map<String, dynamic> json) =>
      RoomOccupancy(
        room: json['room'] as String? ?? '',
        building: json['building'] as String? ?? '',
        isLab: json['isLab'] as bool? ?? false,
        day: json['day'] as String? ?? '',
        schools: [
          for (final s in json['schools'] as List<dynamic>? ?? const [])
            s as String,
        ],
        occupied: [
          for (final r in json['occupied'] as List<dynamic>? ?? const [])
            TimeRange(
              start: (r as List<dynamic>)[0] as int,
              end: r[1] as int,
            ),
        ],
        dayStart: json['dayStart'] as int? ?? 0,
        dayEnd: json['dayEnd'] as int? ?? 0,
      );

  @override
  String toString() =>
      '$room${isLab ? ' (lab)' : ''} ${clockOf(dayStart)}-${clockOf(dayEnd)} '
      'occupied=${occupied.map((e) => e.toString()).toList()}';
}

/// Builds the building letter from a room label, or `''` when the label
/// carries none.
///
/// The sheets spell the same thing three ways, and each needs its own
/// pattern:
///
/// * `C-301` — a bare code. Management pads it (`A- 201`) and
///   occasionally doubles the dash (`A--211`), so separators are
///   flexible.
/// * `Margala 4 (C-212` — a block name wrapping a code. Computing
///   leaves the bracket open, so the closing paren is *not* required.
/// * `B-Computing-3` — a name beginning with a letter and a hyphen but
///   no room number.
///
/// The third pattern runs last on purpose: `C-Rawal 4 (C-512)` has to
/// resolve through the second, because its `C-` prefix names the block
/// rather than a room, and `CALL-1 (A-213)` must report A from the
/// bracket instead of C from its first four letters.
String buildingOf(String label) {
  final bare = RegExp(r'^([A-D])\s*-+\s*(\d+)').firstMatch(label);
  if (bare != null) return bare.group(1)!;

  final wrapped = RegExp(r'\(([A-D])\s*-+\s*\d+').firstMatch(label);
  if (wrapped != null) return wrapped.group(1)!;

  final named = RegExp(r'^([A-D])\s*-').firstMatch(label);
  if (named != null) return named.group(1)!;

  return '';
}

/// The key two sheets' spellings of one room share.
///
/// Management writes `C - 405` where Computing writes `C-405`, and
/// writes both `A- 210` and `A-210` on its own sheet. Compared as
/// written those are three rooms, and the real one would be checked
/// against half its bookings. Collapsing whitespace and runs of dashes
/// makes each pair one room without touching anything that
/// differentiates them — case is kept, because `Audi` and `A-211` are
/// already separated by the hyphen.
String roomKey(String label) => label
    .trim()
    .toUpperCase()
    .replaceAll(RegExp(r'\s+'), '')
    .replaceAll(RegExp(r'-+'), '-');

/// Collapses the same room as reported by more than one sheet.
///
/// `C-405`, `C-406` and `C-407` sit in both Computing's and
/// Management's grids, and `B-227` in Engineering's and Management's.
/// Those are one physical room booked twice; keeping each sheet's copy
/// apart would advertise it as free while a class from another school
/// is in it.
///
/// The surviving label is whichever spelling names a building and, of
/// those, the shortest — so the list reads `C-405` rather than
/// Management's padded `C - 405`.
List<RoomOccupancy> coalesceRooms(Iterable<RoomOccupancy> rooms) {
  final byKey = <String, RoomOccupancy>{};
  for (final r in rooms) {
    final key = roomKey(r.room);
    final seen = byKey[key];
    if (seen == null) {
      byKey[key] = r;
      continue;
    }
    byKey[key] = RoomOccupancy(
      room: _betterLabel(seen.room, r.room),
      building: seen.building.isNotEmpty ? seen.building : r.building,
      // A room filed under `Labs` by either sheet is the lab; both
      // sheets describe the same four walls.
      isLab: seen.isLab || r.isLab,
      day: seen.day,
      schools: {...seen.schools, ...r.schools}.toList()..sort(),
      occupied: mergeRanges([...seen.occupied, ...r.occupied]),
      dayStart:
          seen.dayStart < r.dayStart ? seen.dayStart : r.dayStart,
      dayEnd: seen.dayEnd > r.dayEnd ? seen.dayEnd : r.dayEnd,
    );
  }
  return byKey.values.toList();
}

/// Which of two spellings of one room should be shown.
///
/// A label that names a building beats one that does not, so the list
/// shows `C-405` rather than a bare block name; between equals the
/// shorter spelling is the unpadded one.
String _betterLabel(String a, String b) {
  final aHasBuilding = buildingOf(a).isNotEmpty;
  final bHasBuilding = buildingOf(b).isNotEmpty;
  if (aHasBuilding != bHasBuilding) {
    return aHasBuilding ? a : b;
  }
  return b.length < a.length ? b : a;
}

/// Collapses overlapping and touching stretches so a class spanning two
/// sheet cells reads as one booking, and so the gap before the next
/// booking is measured from the true end rather than from a seam.
List<TimeRange> mergeRanges(List<TimeRange> ranges) {
  if (ranges.isEmpty) return const [];
  final sorted = [...ranges]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <TimeRange>[sorted.first];
  for (final r in sorted.skip(1)) {
    final last = merged.removeLast();
    // `<=` rather than `<` so two cells meeting exactly at a boundary
    // become one block: the room is not free in the instant between.
    if (r.start <= last.end) {
      merged.add(
        TimeRange(
          start: last.start,
          end: r.end > last.end ? r.end : last.end,
        ),
      );
    } else {
      merged.add(last);
      merged.add(r);
    }
  }
  return merged;
}
