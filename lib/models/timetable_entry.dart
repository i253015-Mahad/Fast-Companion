// lib/models/timetable_entry.dart

/// One class (or lab) slot as it appears on the university's timetable
/// sheets, normalized across the schools' differing sheet layouts.
class TimetableEntry {
  /// Full weekday name, e.g. "Monday".
  final String day;

  /// "08:30" / "" when the sheet only gave a slot label we couldn't read.
  final String startTime;

  /// "09:50".
  final String endTime;

  /// Course name as written on the sheet, e.g. "Programming Fundamentals".
  final String course;

  /// Section code, e.g. "CS-A", "EE-B". "" when the cell has none —
  /// reserved slots, generic announcements, and classes filed for the
  /// whole school (see [isForEverySection]).
  final String section;

  /// Program abbreviation inside [section] ("CS", "SE", "EE"...), "" if
  /// there was no section to derive it from.
  final String program;

  /// Batch year as written ("2026", "25"...), "" when absent.
  final String batch;

  final String room;

  /// Engineering sheets put the teacher on the row below the course;
  /// computing sheets don't carry one.
  final String teacher;

  final bool isLab;

  /// Schedule-change marker pulled from the cell, e.g. "ReSch" or
  /// "Resch Oct 12, 2026" — surfaced as a badge so make-up / moved
  /// classes are visible at a glance.
  final String note;

  const TimetableEntry({
    required this.day,
    required this.startTime,
    required this.endTime,
    required this.course,
    this.section = '',
    this.program = '',
    this.batch = '',
    this.room = '',
    this.teacher = '',
    this.isLab = false,
    this.note = '',
  });

  /// True for cells the sheet uses as placeholders ("Reserved for IC
  /// Design", "Friday Prayer Break") — filtered out of the day lists.
  bool get isPlaceholder =>
      section.isEmpty &&
      (course.isEmpty ||
          RegExp(
            r'^(reserved|resrved|reseved|reseved)\b',
            caseSensitive: false,
          ).hasMatch(course));

  /// The section with any sub-group suffix dropped.
  ///
  /// Computing splits a section into lab groups — `AI-A` for the shared
  /// lectures plus `AI-A1` / `AI-A2` for labs — and a student thinks of
  /// those as one section, so the filter offers `AI-A` alone and takes
  /// every sub-group with it. Only a trailing digit after a single
  /// letter counts (`CS-E2` -> `CS-E`), so engineering's `EE-A` and
  /// management's `AF01A` / `FT07A/B` pass through untouched.
  String get sectionGroup {
    final m = RegExp(r'^(.+)-([A-Z])\d$').firstMatch(section);
    return m == null ? section : '${m.group(1)!}-${m.group(2)!}';
  }

  /// True when the sheet filed this entry for every section rather than
  /// one.
  ///
  /// A cell that names no section — an exam lab written
  /// `AI (SE Lab Exam) October 23`, a combined session, a notice posted
  /// for the whole school — is not aimed at nobody; it is aimed at
  /// everybody, so choosing a section must not hide it. Placeholder
  /// cells also carry no section, but those are dropped as non-classes
  /// before a student ever sees them.
  bool get isForEverySection => section.isEmpty;

  /// A copy of this entry filed under [section] instead.
  TimetableEntry withSection(String section) => TimetableEntry(
    day: day,
    startTime: startTime,
    endTime: endTime,
    course: course,
    section: section,
    program: program,
    batch: batch,
    room: room,
    teacher: teacher,
    isLab: isLab,
    note: note,
  );

  /// Sort key: classes in start-time order within a day.
  ///
  /// The sheets write times without AM/PM (`08:30` = morning, `01:00` =
  /// afternoon), so plain string comparison would put 1 PM before 8 AM.
  /// Hours 01-07 are afternoon classes across all three schools' grids
  /// (the earliest slot any of them publishes is 08:30).
  int get startMinutes {
    final parts = startTime.split(':');
    if (parts.length != 2) return 0;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return 0;
    final hour = (h >= 1 && h <= 7) ? h + 12 : h;
    return hour * 60 + m;
  }

  Map<String, dynamic> toJson() => {
    'day': day,
    'startTime': startTime,
    'endTime': endTime,
    'course': course,
    'section': section,
    'program': program,
    'batch': batch,
    'room': room,
    'teacher': teacher,
    'isLab': isLab,
    'note': note,
  };

  factory TimetableEntry.fromJson(Map<String, dynamic> json) => TimetableEntry(
    day: json['day'] as String? ?? '',
    startTime: json['startTime'] as String? ?? '',
    endTime: json['endTime'] as String? ?? '',
    course: json['course'] as String? ?? '',
    section: json['section'] as String? ?? '',
    program: json['program'] as String? ?? '',
    batch: json['batch'] as String? ?? '',
    room: json['room'] as String? ?? '',
    teacher: json['teacher'] as String? ?? '',
    isLab: json['isLab'] as bool? ?? false,
    note: json['note'] as String? ?? '',
  );
}

/// How a school's sheet is arranged. Each layout has its own parser —
/// the three schools publish their timetables in incompatible shapes.
enum SheetLayout {
  /// Computing: one tab per weekday, a room x time grid whose cells read
  /// `Course (CS-A)`.
  computing,

  /// Engineering: a single tab of day blocks (Classes/Labs), room rows,
  /// course cell with the teacher on the row below.
  engineering,

  /// Management: a single tab of day blocks where each slot holds a
  /// `CODE Course Name` cell paired with a section-code cell beside it.
  management,
}

/// One school's timetable source: which Google Sheet to read and how that
/// sheet is laid out.
class SchoolConfig {
  /// Stable id used for cache keys and preferences.
  final String id;

  /// Chip label.
  final String label;

  /// Google Sheet document id (from its `/d/<id>/` URL).
  final String sheetId;

  /// Which parser the sheet needs.
  final SheetLayout layout;

  /// Tabs to fetch for schools whose sheets are split day-wise
  /// (computing: one tab per weekday). Empty for schools where a single
  /// tab contains every day (engineering, management).
  final Map<String, int> dayGids;

  /// Fallback gid when [dayGids] is empty.
  final int? defaultGid;

  /// False until the sheet link is known — the UI renders the chip
  /// disabled so the school stays visible but unselectable.
  final bool available;

  const SchoolConfig({
    required this.id,
    required this.label,
    required this.sheetId,
    required this.layout,
    this.dayGids = const {},
    this.defaultGid,
    this.available = true,
  });

  bool get hasDayTabs => dayGids.isNotEmpty;
}

/// The three schools FAST ISB publishes timetables for (Fall 2026).
const List<SchoolConfig> kSchools = [
  SchoolConfig(
    id: 'computing',
    label: 'Computing',
    sheetId: '1vlTuotLw34fedME3gNQj09cZw-todVomxAiu5P1wZ6Q',
    layout: SheetLayout.computing,
    // Tab gids read off the sheet's own tab bar (Fall 2026).
    dayGids: {
      'Monday': 1882612924,
      'Tuesday': 945396749,
      'Wednesday': 542677125,
      'Thursday': 571927841,
      'Friday': 1783333514,
      'Saturday': 1949393871,
    },
  ),
  SchoolConfig(
    id: 'engineering',
    label: 'Engineering',
    sheetId: '1fL2TWhPgbPc2d66vm_KywTpdsGBIaBLqlmz4JLPudCw',
    layout: SheetLayout.engineering,
    defaultGid: 115356958,
  ),
  SchoolConfig(
    id: 'management',
    label: 'Management',
    sheetId: '1AnFQQhv9lu4grESE2ypbDG7E1QOPGgGCRiejem5ocPw',
    layout: SheetLayout.management,
    // The "Timetable" tab; the other tabs are course plans/electives.
    defaultGid: 0,
  ),
];
