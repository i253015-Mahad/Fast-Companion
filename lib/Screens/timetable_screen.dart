// lib/Screens/timetable_screen.dart

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../models/timetable_entry.dart';
import '../services/timetable_service.dart';

/// Public, day-by-day timetable browser for the three FAST ISB schools.
///
/// Data comes from the university's own Google Sheets (see
/// [kSchools]); the chosen school/section persist between launches and
/// the last fetch is cached so the screen works offline.
class TimetableScreen extends StatefulWidget {
  const TimetableScreen({super.key});

  @override
  State<TimetableScreen> createState() => _TimetableScreenState();
}

class _TimetableScreenState extends State<TimetableScreen> {
  static const List<String> _weekOrder = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  static const _schoolPref = 'timetable_school';
  static const _sectionPref = 'timetable_section';
  static const _deptPref = 'timetable_department';
  static const _batchPref = 'timetable_batch';

  String _schoolId = 'computing';
  String _department = '';
  String _batch = '';
  String _section = '';
  String _day = '';

  bool _loading = true;
  String? _error;
  TimetableResult? _result;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final school = prefs.getString(_schoolPref);
      final section = prefs.getString(_sectionPref);
      final department = prefs.getString(_deptPref);
      final batch = prefs.getString(_batchPref);
      if (school != null && kSchools.any((s) => s.id == school)) {
        _schoolId = school;
      }
      _department = department ?? '';
      _batch = batch ?? '';
      _section = section ?? '';
    } catch (_) {
      // Preferences are best-effort; defaults are fine.
    }
    await _load();
  }

  SchoolConfig get _school =>
      kSchools.firstWhere((s) => s.id == _schoolId, orElse: () => kSchools[0]);

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await TimetableService.instance.load(
        _school,
        forceRefresh: force,
      );
      if (!mounted) return;

      setState(() {
        _result = result;
        _loading = false;
        // Drop filters the new semester's sheet no longer contains.
        // (An empty filter means "All" — deliberately not auto-picking a
        // section, since guessing a student's section would show them
        // the wrong schedule.)
        _normalizeFilters(result);
        // Default to today only on a fresh pick. The selected day is
        // never moved just because it happens to be empty — an empty
        // day shows its own "No classes scheduled." message instead.
        if (_day.isEmpty) _day = _todayOrDefault();
      });
      _savePrefs();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the timetable.\nCheck your connection.';
      });
    }
  }

  /// Today's weekday name; Sunday has no timetable so it falls back to
  /// Monday. Used only to pick the *initial* day — after that the day
  /// changes only when the student taps a tab, even if it has no classes.
  String _todayOrDefault() {
    // weekday: 1 = Monday ... 7 = Sunday.
    final weekday = DateTime.now().weekday;
    if (weekday >= 1 && weekday <= _weekOrder.length) {
      return _weekOrder[weekday - 1];
    }
    return _weekOrder.first; // Sunday -> Monday
  }

  /// Discards any selection the freshly loaded sheet can't satisfy:
  /// department against everything, batch against the department, and
  /// section against both. Runs after every load so a stale semester's
  /// choices can't leave the list silently empty.
  void _normalizeFilters(TimetableResult result) {
    if (_department.isNotEmpty && !result.departments.contains(_department)) {
      _department = '';
    }
    if (_batch.isNotEmpty && !_batchesFor(result).contains(_batch)) {
      _batch = '';
    }
    if (_section.isNotEmpty && !_sectionsFor(result).contains(_section)) {
      _section = '';
    }
  }

  /// The three filters form a hierarchy — department, then batch, then
  /// section — where each row is narrowed only by the rows above it.
  /// That keeps validation cycle-free: a stale section can never wipe
  /// out a valid batch, because batch is checked against the department
  /// alone.
  ///
  /// Departments on offer (top of the hierarchy, so not narrowed).
  List<String> _departmentsFor(TimetableResult result) {
    final set = <String>{};
    for (final e in result.entries) {
      if (e.isPlaceholder || e.program.isEmpty) continue;
      set.add(e.program);
    }
    return set.toList()..sort();
  }

  /// Batch years on offer for the current department.
  List<String> _batchesFor(TimetableResult result) {
    final set = <String>{};
    for (final e in result.entries) {
      if (e.isPlaceholder || e.batch.isEmpty) continue;
      if (_department.isNotEmpty && e.program != _department) continue;
      set.add(e.batch);
    }
    return set.toList()..sort();
  }

  /// Sections on offer for the current department/batch.
  List<String> _sectionsFor(TimetableResult result) {
    final set = <String>{};
    for (final e in result.entries) {
      if (e.isPlaceholder || e.section.isEmpty) continue;
      if (_department.isNotEmpty && e.program != _department) continue;
      if (_batch.isNotEmpty && e.batch != _batch) continue;
      set.add(e.section);
    }
    return set.toList()..sort();
  }

  /// Applies new filter values, re-validates the rest against the loaded
  /// sheet, and persists the choice. The selected day is left alone.
  void _setFilters({String? department, String? batch, String? section}) {
    setState(() {
      if (department != null) _department = department;
      if (batch != null) _batch = batch;
      if (section != null) _section = section;
      if (_result != null) _normalizeFilters(_result!);
    });
    _savePrefs();
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_schoolPref, _schoolId);
      await prefs.setString(_deptPref, _department);
      await prefs.setString(_batchPref, _batch);
      await prefs.setString(_sectionPref, _section);
    } catch (_) {}
  }

  void _selectSchool(String id) {
    if (id == _schoolId) return;
    setState(() {
      _schoolId = id;
      // The three schools publish entirely different programs — start
      // the filters over rather than carrying a section across.
      _department = '';
      _batch = '';
      _section = '';
      _result = null;
      _day = '';
    });
    _savePrefs();
    _load();
  }

  // ================= BUILD =================

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final filtered = result == null
        ? const <TimetableEntry>[]
        : _filtered(result);
    final departments = result == null
        ? const <String>[]
        : _departmentsFor(result);
    final batches = result == null ? const <String>[] : _batchesFor(result);
    final sections = result == null ? const <String>[] : _sectionsFor(result);

    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Timetable", style: AppTextStyles.title),
          const SizedBox(height: 16),
          _buildSchoolChips(),
          const SizedBox(height: 12),
          if (departments.isNotEmpty)
            _filterRow('DEPT', departments, _department, _selectDepartment),
          if (batches.isNotEmpty)
            _filterRow('BATCH', batches, _batch, _selectBatch),
          if (sections.isNotEmpty)
            _filterRow('SECTION', sections, _section, _selectSection),
          if (!_loading && _error == null && result != null) ...[
            _buildDayTabs(filtered),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          Expanded(child: _buildBody(result)),
        ],
      ),
    );
  }

  /// Entries matching the department, batch and section filters, in
  /// start-time order. The sheets carry placeholder cells ("Reserved for
  /// Adv Comp Vision") that aren't real classes — drop them.
  List<TimetableEntry> _filtered(TimetableResult result) {
    final entries = TimetableService.filterBy(
      result.entries,
      department: _department,
      batch: _batch,
      section: _section,
    ).where((e) => !e.isPlaceholder).toList();
    // 12-hour times without AM/PM — sort via startMinutes so 1 PM
    // doesn't come before 8 AM.
    entries.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    return entries;
  }

  Widget _buildSchoolChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final school in kSchools)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _schoolChip(school),
            ),
        ],
      ),
    );
  }

  /// A school pill built from a plain [Container] (like the day tabs)
  /// rather than a [ChoiceChip]: Material 3 chips paint their own
  /// surface-tint layer, so even `backgroundColor: Colors.transparent`
  /// left a visible fill on the unselected chips. Here unselected is a
  /// true transparent outline and selected is a filled yellow pill.
  Widget _schoolChip(SchoolConfig school) {
    final available = school.available;
    final selected = available && school.id == _schoolId;

    return InkWell(
      onTap: available ? () => _selectSchool(school.id) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? AppColors.cardYellow : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: !available
                ? Colors.white12
                : selected
                ? AppColors.cardYellow
                : Colors.white24,
          ),
        ),
        child: Text(
          school.label,
          style: TextStyle(
            color: !available
                ? Colors.white38
                : selected
                ? AppColors.textDark
                : Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  void _selectDepartment(String department) {
    if (department == _department) return;
    _setFilters(department: department);
  }

  void _selectBatch(String batch) {
    if (batch == _batch) return;
    _setFilters(batch: batch);
  }

  void _selectSection(String section) {
    if (section == _section) return;
    _setFilters(section: section);
  }

  /// One labelled filter line — a compact caption on the left and the
  /// scrollable "All + options" pills to its right. Department, batch and
  /// section each get their own row so a student can narrow by any
  /// combination instead of one catch-all section list.
  Widget _filterRow(
    String label,
    List<String> options,
    String selected,
    ValueChanged<String> onSelect,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.1,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _sectionPill('All', selected.isEmpty, () => onSelect('')),
                  for (final option in options)
                    _sectionPill(
                      option,
                      selected == option,
                      () => onSelect(option),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionPill(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppColors.cardGreen : Colors.white10,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppColors.cardGreen : Colors.white24,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? AppColors.textDark : Colors.white70,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }

  /// Day tabs, with a per-day class count for the current filters.
  ///
  /// All six days are always shown, even the ones with nothing in them
  /// (dimmed, with a zero count) — switching to a quiet day and reading
  /// "No classes scheduled" is more honest than hiding the day or
  /// jumping the student to another one.
  Widget _buildDayTabs(List<TimetableEntry> entries) {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.day] = (counts[e.day] ?? 0) + 1;
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final day in _weekOrder) _buildDayTab(day, counts[day] ?? 0),
        ],
      ),
    );
  }

  Widget _buildDayTab(String day, int count) {
    final empty = count == 0;
    final selected = _day == day;
    final labelColor = selected
        ? AppColors.textDark
        : empty
        ? Colors.white30
        : Colors.white70;
    final countColor = selected
        ? AppColors.textDark.withValues(alpha: 0.7)
        : empty
        ? Colors.white24
        : Colors.white38;

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        onTap: () => setState(() => _day = day),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.cardYellow : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? AppColors.cardYellow
                  : empty
                  ? Colors.white12
                  : Colors.white24,
            ),
          ),
          child: Row(
            children: [
              Text(
                day.substring(0, 3),
                style: TextStyle(
                  color: labelColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$count',
                style: TextStyle(
                  color: countColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(TimetableResult? result) {
    if (_loading) return _buildSkeleton();

    if (_error != null && result == null) {
      return _buildMessage(
        icon: Icons.cloud_off_rounded,
        message: _error!,
        actionLabel: 'Retry',
        onAction: () => _load(force: true),
      );
    }

    if (result == null) return _buildSkeleton();

    final entries = _filtered(result).where((e) => e.day == _day).toList();

    return RefreshIndicator(
      color: AppColors.cardOrange,
      backgroundColor: AppColors.navBar,
      onRefresh: () => _load(force: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.only(top: 4, bottom: 24),
        children: [
          if (result.fromCache)
            _banner(
              Icons.wifi_off_rounded,
              'Offline — showing your saved timetable',
            ),
          if (entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: _buildMessage(
                icon: Icons.event_busy_rounded,
                message: _emptyDayMessage(),
              ),
            )
          else
            for (var i = 0; i < entries.length; i++) _buildCard(entries[i], i),
          const SizedBox(height: 8),
          Center(child: _lastUpdated(result.fetchedAt)),
        ],
      ),
    );
  }

  /// Why today's list is empty: name whatever is being filtered (a
  /// section already implies its department, so only show the batch
  /// alongside it), and fall back to a plain message when nothing is.
  String _emptyDayMessage() {
    final active = <String>[];
    if (_section.isNotEmpty) {
      active.add(_section);
    } else if (_department.isNotEmpty) {
      active.add(_department);
    }
    if (_batch.isNotEmpty) active.add('batch $_batch');
    if (active.isEmpty) return 'No classes scheduled.';
    return 'No classes for ${active.join(' ')} on $_day.';
  }

  Widget _banner(IconData icon, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.cardYellow, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(TimetableEntry entry, int index) {
    // Rotate through the app's card palette; light cards get dark text.
    const palette = [
      AppColors.cardOrange,
      AppColors.cardGreen,
      AppColors.cardCream,
      AppColors.cardYellow,
    ];
    final color = palette[index % palette.length];
    final darkText =
        color == AppColors.cardCream || color == AppColors.cardYellow;
    final primary = darkText ? AppColors.textDark : Colors.white;
    final secondary = darkText
        ? AppColors.textDark.withValues(alpha: 0.65)
        : Colors.white70;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Time column. The sheets write 12-hour times with no AM/PM
          // ("01:00" is 1 PM), so spell it out.
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _clock(entry.startTime, isEnd: false),
                style: TextStyle(
                  color: primary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Container(
                width: 2,
                height: 26,
                margin: const EdgeInsets.symmetric(vertical: 4),
                color: primary.withValues(alpha: 0.3),
              ),
              Text(
                _clock(entry.endTime, isEnd: true, start: entry.startTime),
                style: TextStyle(color: secondary, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.course,
                  style: TextStyle(
                    color: primary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (entry.section.isNotEmpty)
                      _tag(entry.section, primary, secondary),
                    if (entry.room.isNotEmpty)
                      _tag(entry.room, primary, secondary),
                    if (entry.teacher.isNotEmpty)
                      _tag(entry.teacher, primary, secondary),
                    if (entry.isLab)
                      _badge('LAB', Colors.white, AppColors.background),
                    if (entry.note.isNotEmpty)
                      _badge(entry.note, AppColors.background, Colors.white),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _tag(String text, Color color, Color muted) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.place_outlined, size: 13, color: muted),
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(
            color: color,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _badge(String text, Color background, Color foreground) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: foreground,
          fontSize: 10.5,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppColors.navBar,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: AppColors.cardOrange),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.cardOrange,
                  foregroundColor: AppColors.textDark,
                ),
                child: Text(actionLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSkeleton() {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (var i = 0; i < 5; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 86,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(20),
            ),
          ),
      ],
    );
  }

  /// `08:30` -> `08:30 AM`, `01:00` -> `01:00 PM`.
  ///
  /// Start times: hours 8-11 are the morning slots, everything else is
  /// afternoon/evening (the grids run 08:30 to 08:05). End times take
  /// their meridiem from the start, since an end hour can't be told
  /// apart on its own (`06:45-08:05` is an evening class).
  String _clock(String time, {required bool isEnd, String? start}) {
    final h = int.tryParse(time.split(':').first);
    if (h == null) return time;

    bool pm;
    if (!isEnd) {
      pm = !(h >= 8 && h <= 11);
    } else {
      final startHour = int.tryParse((start ?? '').split(':').first);
      if (startHour == null) {
        pm = !(h >= 8 && h <= 11);
      } else {
        final startIsPm = !(startHour >= 8 && startHour <= 11);
        pm = startIsPm || h == 12 || h < startHour;
      }
    }
    return '$time ${pm ? 'PM' : 'AM'}';
  }

  Widget _lastUpdated(DateTime fetchedAt) {
    if (fetchedAt.millisecondsSinceEpoch == 0) {
      return const SizedBox.shrink();
    }
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = fetchedAt.hour % 12 == 0 ? 12 : fetchedAt.hour % 12;
    final minute = fetchedAt.minute.toString().padLeft(2, '0');
    final amPm = fetchedAt.hour < 12 ? 'AM' : 'PM';
    return Text(
      'Last updated ${fetchedAt.day} ${months[fetchedAt.month - 1]}, '
      '$hour:$minute $amPm  •  Pull down to refresh',
      style: const TextStyle(color: Colors.white38, fontSize: 11),
    );
  }
}
