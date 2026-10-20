// lib/models/faculty_member.dart

import 'room_occupancy.dart';

/// How senior a faculty member is, read off the designation.
///
/// The derivation order in [rankOf] is load-bearing: `Professor` is
/// checked only after the two compound ranks, because every associate
/// and assistant designation also contains the word `Professor` and
/// would otherwise swallow them into one bucket.
enum FacultyRank {
  professor('Professor'),
  associateProfessor('Associate Professor'),
  assistantProfessor('Assistant Professor'),
  lecturer('Lecturer'),
  instructor('Instructor'),

  /// Anything the sheet's designation does not map onto — today that is
  /// the single row reading `Assistant Office`, which is a typo in the
  /// sheet rather than a rank, and is shown as it was written rather
  /// than guessed at.
  other('Other');

  const FacultyRank(this.label);

  /// Short form for the filter pills, where the full label is too wide
  /// for a phone.
  final String label;

  static const List<FacultyRank> filterable = [
    professor,
    associateProfessor,
    assistantProfessor,
    lecturer,
    instructor,
  ];

  /// The rank a designation describes, or [other].
  ///
  /// Compounds like `Associate Professor & HoD` are handled by the rank
  /// words alone; the `HoD`/`Director` half is carried separately as a
  /// badge, because a head of department is still one of these ranks.
  static FacultyRank rankOf(String designation) {
    final d = designation.toLowerCase();
    // Order matters — see the enum's doc.
    if (d.contains('associate professor')) return FacultyRank.associateProfessor;
    if (d.contains('assistant professor')) return FacultyRank.assistantProfessor;
    if (d.contains('professor')) return FacultyRank.professor;
    if (d.contains('lecturer')) return FacultyRank.lecturer;
    if (d.contains('instructor')) return FacultyRank.instructor;
    return FacultyRank.other;
  }
}

/// What the office column actually says about where to find someone.
///
/// Kept apart from the office string because the sheet uses that column
/// for two different kinds of answer: a room, and a statement that there
/// is no room to give. Three people on the Computing sheet have `ON
/// LEAVE` written there, and rendering that as a room number would be
/// the funniest bug in the app.
enum OfficeStatus {
  /// A room code, or something room-shaped that is not a code
  /// (`Director office`).
  listed,

  /// `ON LEAVE`.
  onLeave,

  /// Blank.
  unlisted,
}

/// One person on a school's faculty-offices sheet.
class FacultyMember {
  /// Full name exactly as the sheet wrote it, cleaned: `Dr. Muhammad
  /// Arshad Islam`, including the honorific, because that is how a
  /// student will address them and how the sheet identifies them.
  final String name;

  /// Designation as written, including any compound half — `Associate
  /// Professor & Coordinator GSC`. The badges and [rank] are derived
  /// from this rather than replacing it.
  final String designation;

  /// Office email, original case preserved for display. Compared
  /// lowercased, never rewritten: the sheet spells several addresses
  /// with capitals mid-word (`Usama.Imtiaz@…`) and those still work.
  final String email;

  /// Office as written, cleaned — `D-109 E`, `B-215A`, `Director
  /// office`. Empty when the sheet listed none.
  final String office;

  /// Department as the sheet's own header names it, minus the `Faculty
  /// Department of` prefix the sheet repeats on every one.
  final String department;

  /// Which school's sheet listed them.
  final String school;

  /// [FacultyRank] derived from [designation].
  final FacultyRank rank;

  /// [OfficeStatus] derived from [office].
  final OfficeStatus status;

  final bool isHoD;
  final bool isDirector;
  final bool isCoordinator;

  const FacultyMember({
    required this.name,
    required this.designation,
    required this.email,
    required this.office,
    required this.department,
    required this.school,
    required this.rank,
    required this.status,
    this.isHoD = false,
    this.isDirector = false,
    this.isCoordinator = false,
  });

  /// Builds one from a cleaned sheet row.
  ///
  /// Every field is passed already normalised; the parser is where the
  /// sheet's stray tabs, newlines and trailing spaces are dealt with,
  /// so that what reaches a model is what gets shown.
  factory FacultyMember.fromRow({
    required String name,
    required String designation,
    required String email,
    required String office,
    required String department,
    required String school,
  }) {
    return FacultyMember(
      name: name,
      designation: designation,
      email: email,
      office: office,
      department: department,
      school: school,
      rank: FacultyRank.rankOf(designation),
      status: statusOfOffice(office),
      isHoD: _hasRole(designation, const ['hod', 'head']),
      isDirector: _hasRole(designation, const ['director']),
      isCoordinator: _hasRole(designation, const ['coordinator']),
    );
  }

  /// The building letter an office sits in, or `''`.
  ///
  /// Delegated to the rooms feature's [buildingOf] rather than
  /// reimplemented, because office and classroom labels share one
  /// spelling — `C-201 A`, `D-620G`, `B-215A` — and that function
  /// already copes with Management's padding and Computing's open
  /// brackets. It correctly yields `''` for `Director office` and `ON
  /// LEAVE`, neither of which is a block.
  String get block => buildingOf(office);

  /// Whether the sheet gave them a room, however unusual its spelling.
  bool get hasOffice => status == OfficeStatus.listed;

  /// The name as a student would look it up: honorific stripped, so an
  /// A-Z list reads `Arshad` … `Zill-E-Huma` rather than grouping every
  /// `Dr.` together at the top and calling it alphabetical.
  String get lookupName => name.replaceFirst(
    RegExp(r'^(Dr|Mr|Ms|Mrs|Prof)\.?\s+', caseSensitive: false),
    '',
  );

  /// Whether a search box's text appears anywhere a student might expect
  /// to find it.
  ///
  /// Office codes are included deliberately: typing `D-109` is how you
  /// ask "who is on that corridor", and that query is useless if the
  /// search only knows about names.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        lookupName.toLowerCase().contains(q) ||
        email.toLowerCase().contains(q) ||
        designation.toLowerCase().contains(q) ||
        office.toLowerCase().contains(q) ||
        department.toLowerCase().contains(q);
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'designation': designation,
    'email': email,
    'office': office,
    'department': department,
    'school': school,
    'rank': rank.name,
    'status': status.name,
    'isHoD': isHoD,
    'isDirector': isDirector,
    'isCoordinator': isCoordinator,
  };

  factory FacultyMember.fromJson(Map<String, dynamic> json) => FacultyMember(
    name: json['name'] as String? ?? '',
    designation: json['designation'] as String? ?? '',
    email: json['email'] as String? ?? '',
    office: json['office'] as String? ?? '',
    department: json['department'] as String? ?? '',
    school: json['school'] as String? ?? '',
    rank: FacultyRank.values.firstWhere(
      (r) => r.name == json['rank'],
      orElse: () => FacultyRank.other,
    ),
    status: OfficeStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => OfficeStatus.unlisted,
    ),
    isHoD: json['isHoD'] as bool? ?? false,
    isDirector: json['isDirector'] as bool? ?? false,
    isCoordinator: json['isCoordinator'] as bool? ?? false,
  );

  @override
  String toString() =>
      '$name [$rank] ${department.isEmpty ? '-' : department} '
      '${office.isEmpty ? '(no office)' : office}';
}

/// What the office column says about someone's whereabouts.
OfficeStatus statusOfOffice(String office) {
  final o = office.trim().toLowerCase();
  if (o.isEmpty) return OfficeStatus.unlisted;
  if (o.contains('on leave') || o.contains('leave')) return OfficeStatus.onLeave;
  return OfficeStatus.listed;
}

/// Whether a designation carries one of the given roles.
bool _hasRole(String designation, List<String> roles) {
  final d = designation.toLowerCase();
  return roles.any(d.contains);
}
