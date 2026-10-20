// lib/Screens/teachers_screen.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/faculty_member.dart';
import '../services/faculty_directory_service.dart';
import '../theme/app_colors.dart';

/// Who teaches where, and how to reach them.
///
/// The second half of the wayfinding tab: the rooms list answers "where
/// is a free lab", this answers "where is Dr X", and the two share one
/// building scheme, which is what makes the handoff at the bottom of a
/// card worth having.
class TeachersScreen extends StatefulWidget {
  const TeachersScreen({
    super.key,
    required this.active,
    this.onShowBlock,
  });

  /// Whether this tab is the one on screen.
  ///
  /// Same deal as [RoomsScreen]'s: the tabs sit in an [IndexedStack] and
  /// are all built at startup, so without this the directory would
  /// download a sheet nobody had asked for.
  final bool active;

  /// Hands a building letter back to the wrapper, which flips the tab
  /// over to the rooms list and selects that block.
  ///
  /// Null until the wrapper supplies one; the card's "see block" action
  /// hides itself rather than pointing at nothing.
  final void Function(String block)? onShowBlock;

  @override
  State<TeachersScreen> createState() => _TeachersScreenState();
}

class _TeachersScreenState extends State<TeachersScreen> {
  /// The school filter. Only rendered once there is more than one school
  /// to pick between — a row of pills offering one choice is noise, and
  /// the day a second faculty sheet appears the row appears with it.
  static const String _schoolAll = '';

  static const String _sortDepartment = 'department';
  static const String _sortName = 'name';

  String _school = _schoolAll;
  String _department = '';
  FacultyRank? _rank;
  String _sort = _sortDepartment;
  String _query = '';
  final TextEditingController _search = TextEditingController();

  bool _loading = true;
  bool _opened = false;
  String? _error;
  List<FacultyMember> _members = const [];
  String _term = '';
  DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fromCache = false;

  /// The expanded card, if any. One at a time: a directory is read, not
  /// compared, and several open cards would bury the list.
  String? _expanded;

  @override
  void initState() {
    super.initState();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant TeachersScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      // Nothing is fetched until the tab is opened for the first time.
      // After that the cache is doing its job and a switch back is a
      // setState, not a download.
      if (_opened) {
        setState(() {});
      } else {
        _load();
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await FacultyDirectoryService.instance.load(
        forceRefresh: force,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _opened = true;
        _members = result.members;
        _term = result.term;
        _fetchedAt = result.fetchedAt;
        _fromCache = result.fromCache;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the faculty list.\nCheck your connection.';
      });
    }
  }

  // ================= DERIVED =================

  List<String> get _schools {
    final seen = <String>{};
    for (final m in _members) {
      if (m.school.isNotEmpty) seen.add(m.school);
    }
    return seen.toList()..sort();
  }

  List<String> get _departments {
    final seen = <String>[];
    for (final m in _members) {
      if (!seen.contains(m.department)) seen.add(m.department);
    }
    return seen;
  }

  /// What the list is showing, after every filter and the search.
  List<FacultyMember> get _visible {
    final q = _query.trim();
    return [
      for (final m in _members)
        if ((_school == _schoolAll || m.school == _school) &&
            (_department.isEmpty || m.department == _department) &&
            (_rank == null || m.rank == _rank) &&
            m.matches(q))
          m,
    ];
  }

  /// Splits what is visible into the headers the list is grouped under.
  ///
  /// Grouped by department in the sheet's own order, which is roughly
  /// seniority, so a department reads head-first. An A-Z sort instead
  /// groups by initial and sorts inside each by the name without its
  /// honorific — grouping every `Dr.` together and calling that
  /// alphabetical would be worse than not sorting.
  ///
  /// While searching, nothing is grouped. Someone hunting for one name
  /// does not want to be told which department the other matches are in;
  /// they want the shortest possible list.
  List<(String, List<FacultyMember>)> _groups() {
    final visible = _visible;
    if (_query.trim().isNotEmpty) return [('', visible)];

    final grouped = <String, List<FacultyMember>>{};
    for (final m in visible) {
      final key = _sort == _sortDepartment ? m.department : _letterOf(m);
      (grouped[key] ??= []).add(m);
    }

    final keys = grouped.keys.toList();
    if (_sort == _sortName) {
      keys.sort();
    } // department keys are already in sheet order
    return [for (final k in keys) (k, grouped[k]!)];
  }

  /// The letter an A-Z group is filed under.
  String _letterOf(FacultyMember m) {
    final c = m.lookupName.toUpperCase().replaceAll(RegExp(r'[^A-Z]'), '');
    return c.isEmpty ? '#' : c[0];
  }

  // ================= UI =================

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: _buildHeader(),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _searchField(),
        const SizedBox(height: 12),
        if (_schools.length > 1) ...[
          _filterRow('SCHOOL', [
            _pill('All', _school == _schoolAll, () => setState(() => _school = _schoolAll)),
            for (final s in _schools)
              _pill(s, _school == s, () => setState(() => _school = s)),
          ]),
        ],
        _filterRow('DEPT', [
          _pill('All', _department.isEmpty, () => setState(() => _department = '')),
          for (final d in _departments)
            _pill(d, _department == d, () => setState(() => _department = d)),
        ]),
        _filterRow('RANK', [
          _pill('All', _rank == null, () => setState(() => _rank = null)),
          for (final r in FacultyRank.filterable)
            _pill(_rankLabel(r), _rank == r, () => setState(() => _rank = r)),
        ]),
        _filterRow('SORT', [
          _pill('Department', _sort == _sortDepartment, () => setState(() => _sort = _sortDepartment)),
          _pill('A-Z', _sort == _sortName, () => setState(() => _sort = _sortName)),
        ]),
      ],
    );
  }

  /// Short enough for a phone-sized pill; the full designation is on
  /// every card anyway.
  String _rankLabel(FacultyRank r) => switch (r) {
    FacultyRank.professor => 'Professor',
    FacultyRank.associateProfessor => 'Assoc.',
    FacultyRank.assistantProfessor => 'Asst.',
    FacultyRank.lecturer => 'Lecturer',
    FacultyRank.instructor => 'Instructor',
    FacultyRank.other => 'Other',
  };

  Widget _searchField() {
    return TextField(
      controller: _search,
      onChanged: (v) => setState(() => _query = v),
      style: const TextStyle(color: Colors.white, fontSize: 15),
      cursorColor: AppColors.cardGreen,
      decoration: InputDecoration(
        hintText: 'Search a name, email or office — try D-109',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 14),
        prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white38),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
        filled: true,
        fillColor: Colors.white10,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// One labelled filter line — a caption on the left and the scrollable
  /// pills to its right, the same shape the rooms tab uses so the two
  /// halves of this screen read as one.
  Widget _filterRow(String label, List<Widget> pills) {
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
              child: Row(children: pills),
            ),
          ),
        ],
      ),
    );
  }

  /// Built from a plain [Container] rather than a [ChoiceChip]: Material 3
  /// chips paint their own surface-tint layer, so even a transparent
  /// background left a visible fill on the unselected ones.
  Widget _pill(String label, bool selected, VoidCallback onTap) {
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

  Widget _buildBody() {
    if (_loading) return _buildSkeleton();

    if (_error != null) {
      return _buildMessage(
        icon: Icons.cloud_off_rounded,
        message: _error!,
        actionLabel: 'Retry',
        onAction: () => _load(force: true),
      );
    }

    final groups = _groups();
    final total = _visible.length;

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
          if (_fromCache)
            _banner(Icons.wifi_off_rounded, 'Offline — showing your saved list'),
          if (total == 0)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: _buildMessage(
                icon: Icons.person_search_rounded,
                message: 'No one here matches “${_query.trim()}”.',
              ),
            )
          else ...[
            for (final (header, people) in groups) ...[
              if (header.isNotEmpty) _groupHeader(header),
              for (final m in people) _buildCard(m),
            ],
          ],
          const SizedBox(height: 8),
          Center(child: _lastUpdated()),
        ],
      ),
    );
  }

  Widget _banner(IconData icon, String text) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.cardYellow),
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

  Widget _groupHeader(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          color: AppColors.cardOrange,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.3,
        ),
      ),
    );
  }

  Widget _buildCard(FacultyMember m) {
    final open = _expanded == mKey(m);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() => _expanded = open ? null : mKey(m)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: open ? Colors.white.withValues(alpha: 0.10) : Colors.white10,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: open ? AppColors.cardGreen : Colors.white24,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _nameLine(m)),
                  const SizedBox(width: 10),
                  _officePill(m),
                ],
              ),
              if (m.designation.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  m.designation,
                  style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                ),
              ],
              if (m.email.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  m.email,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                ),
              ],
              if (open) ...[
                const SizedBox(height: 12),
                const Divider(color: Colors.white24, height: 1),
                const SizedBox(height: 10),
                _actions(m),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// A key that survives two people sharing a name — the sheet lists two
  /// Irfan Ullahs — by folding in the department and the address.
  String mKey(FacultyMember m) =>
      '${m.name}|${m.department}|${m.email}'.toLowerCase();

  Widget _nameLine(FacultyMember m) {
    final badges = <Widget>[
      if (m.isHoD) _badge('HoD'),
      if (m.isDirector) _badge('Director'),
      if (m.isCoordinator) _badge('Coordinator'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          m.name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        if (badges.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: badges),
        ],
      ],
    );
  }

  Widget _badge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.cardOrange,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.textDark,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  /// Where to find them — or, when the sheet says there is nowhere to
  /// find them, says so rather than leaving a gap that looks like a bug.
  Widget _officePill(FacultyMember m) {
    final (label, fill, border, text) = switch (m.status) {
      OfficeStatus.listed => (
        m.office,
        AppColors.cardGreen,
        AppColors.cardGreen,
        AppColors.textDark,
      ),
      OfficeStatus.onLeave => (
        'On leave',
        AppColors.cardYellow,
        AppColors.cardYellow,
        AppColors.textDark,
      ),
      OfficeStatus.unlisted => (
        'No office listed',
        Colors.transparent,
        Colors.white24,
        Colors.white54,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: border),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: text,
          fontSize: 12.5,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _actions(FacultyMember m) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        if (m.email.isNotEmpty)
          _action(Icons.mail_rounded, 'Email', () => _email(m)),
        if (m.email.isNotEmpty)
          _action(Icons.copy_rounded, 'Copy', () => _copy(m)),
        if (m.block.isNotEmpty && widget.onShowBlock != null)
          _action(Icons.meeting_room_rounded, 'See block ${m.block}',
              () => widget.onShowBlock!(m.block)),
      ],
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: AppColors.cardGreen),
            const SizedBox(width: 6),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _email(FacultyMember m) async {
    final uri = Uri.parse('mailto:${m.email}');
    if (!await launchUrl(uri)) {
      _snack('Nothing here can open a mail app.');
    }
  }

  Future<void> _copy(FacultyMember m) async {
    // Captured before the await: by the time the clipboard has it, this
    // card may have been scrolled away and disposed.
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: m.email));
    messenger.showSnackBar(
      SnackBar(
        content: Text('Copied ${m.email}'),
        backgroundColor: AppColors.navBar,
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: AppColors.navBar),
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required String message,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
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
        for (var i = 0; i < 6; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            height: 76,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(18),
            ),
          ),
      ],
    );
  }

  Widget _lastUpdated() {
    if (_fetchedAt.millisecondsSinceEpoch == 0) {
      return const SizedBox.shrink();
    }
    final age = DateTime.now().difference(_fetchedAt);
    final label = age.inMinutes < 1
        ? 'just now'
        : age.inHours < 1
        ? '${age.inMinutes} min ago'
        : age.inDays < 1
        ? '${age.inHours} h ago'
        : '${age.inDays} d ago';

    return Text(
      'Faculty list updated $label${_term.isEmpty ? '' : ' · $_term'}',
      style: const TextStyle(color: Colors.white38, fontSize: 11),
    );
  }
}
