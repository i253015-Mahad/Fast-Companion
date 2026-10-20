// lib/Screens/rooms_screen.dart

import 'dart:async';

import 'package:flutter/material.dart';

import '../models/room_occupancy.dart';
import '../services/timetable_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';

/// Which classrooms and labs are free, by building and by day.
///
/// The timetable answers "where should I be?"; this answers "where can I
/// go?", which is a different question of the same sheets — see
/// [TimetableService.loadAllRooms] for why the two read the same source
/// so differently. Only rooms that are actually free are listed: a busy
/// room has nothing to offer, so it is left out rather than shown
/// greyed, and the question "is this free?" is answered on every card as
/// a time.
///
/// All three schools are read for every question, so unlike the
/// timetable there is no school picker — `C-405` is a room whichever
/// sheet named it, and asking either school alone would answer about it
/// from half its bookings.
class RoomsScreen extends StatefulWidget {
  const RoomsScreen({super.key, required this.active});

  /// Whether this tab is the one on screen.
  ///
  /// The tabs sit in an [IndexedStack] and are all built at startup, so
  /// without this the screen would fetch three sheets before anyone had
  /// opened it. It stays loaded once it has been, because a student
  /// switching tabs should not re-download the week to come back.
  final bool active;

  @override
  State<RoomsScreen> createState() => _RoomsScreenState();
}

class _RoomsScreenState extends State<RoomsScreen> {
  static const _weekOrder = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
  ];

  /// The blocks a room can name. A label carrying none (`Comp-I`,
  /// `Karakoram-3`) belongs to no block, so it is offered only while
  /// "All" is selected — putting it under a block would be a guess.
  static const _blocks = ['A', 'B', 'C', 'D'];

  static const _typeAll = '';
  static const _typeClassrooms = 'classrooms';
  static const _typeLabs = 'labs';

  /// A fetch time that reads as "never", so the footer hides itself
  /// rather than dating the list to 1970.
  static final _never = DateTime.fromMillisecondsSinceEpoch(0);

  late final String _today;

  String _day = '';
  String _block = ''; // '' = every block
  String _type = _typeAll;
  bool _useNow = true;
  int _pickedAt = 12 * 60; // where the time picker starts
  DateTime _now = DateTime.now();

  bool _loading = true;
  bool _opened = false;
  String? _error;
  List<RoomOccupancy> _rooms = const [];
  DateTime _fetchedAt = _never;
  bool _fromCache = false;

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _today = _todayOrDefault();
    _day = _today;
    // The list is only ever as current as the last moment it was worth
    // recomputing, and a tab left open in a pocket outlives any clock
    // reading painted once. One tick a minute is more than a room list
    // needs; quieter than that and "free now" stops meaning now.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) => _tick());

    // Never on the first frame in practice — the app opens on Notes —
    // but nothing should depend on that: a tab that starts as the one on
    // screen has to ask for its rooms too.
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant RoomsScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      _now = DateTime.now();
      // Nothing is fetched until the tab is opened for the first time —
      // see [active]. After that the cache is doing its job and a switch
      // back is a setState, not a download.
      if (_opened) {
        setState(() {});
      } else {
        _load();
      }
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _tick() {
    if (!mounted || !widget.active || !_useNow) return;
    final now = DateTime.now();
    // Nothing on screen depends on the clock until the minute changes.
    if (now.hour == _now.hour && now.minute == _now.minute) return;
    setState(() => _now = now);
  }

  /// Today's weekday; Sunday is on no sheet so it falls back to Monday —
  /// only ever to pick the *initial* day, never to move one the student
  /// chose.
  String _todayOrDefault() {
    final weekday = DateTime.now().weekday;
    if (weekday >= 1 && weekday <= _weekOrder.length) {
      return _weekOrder[weekday - 1];
    }
    return _weekOrder.first;
  }

  /// The moment the list is being read against: the real clock in "now"
  /// mode, the picked time otherwise.
  int get _at => _useNow ? _now.hour * 60 + _now.minute : _pickedAt;

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final result = await TimetableService.instance.loadAllRooms(
        _day,
        forceRefresh: force,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _opened = true;
        _rooms = result.rooms;
        _fetchedAt = result.fetchedAt;
        _fromCache = result.fromCache;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load the rooms.\nCheck your connection.';
      });
    }
  }

  void _selectDay(String day) {
    if (day == _day) return;
    // Every day is its own fetch — Computing keeps one tab per weekday —
    // so a new day reloads rather than filtering what is already here.
    setState(() => _day = day);
    _load();
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _at ~/ 60, minute: _at % 60),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pickedAt = picked.hour * 60 + picked.minute;
      _useNow = false;
    });
  }

  /// Every room free at the chosen moment that also matches the block
  /// and kind filters, ordered the way a building is walked.
  List<RoomOccupancy> _free() {
    final at = _at;
    final free = [
      for (final room in _rooms)
        if (room.isFreeAt(at) &&
            (_block.isEmpty || room.building == _block) &&
            (_type == _typeAll ||
                (room.isLab ? _typeLabs : _typeClassrooms) == _type))
          room,
    ];
    free.sort(_compare);
    return free;
  }

  /// Block first — with the rooms carrying no block code last, since
  /// they cannot be walked to from any of the others — then by room.
  int _compare(RoomOccupancy a, RoomOccupancy b) {
    final byBlock = (a.building.isEmpty ? 'Z' : a.building).compareTo(
      b.building.isEmpty ? 'Z' : b.building,
    );
    if (byBlock != 0) return byBlock;
    return _natural(roomKey(a.room), roomKey(b.room));
  }

  /// Orders two labels the way a person reads them rather than the way a
  /// string sorts, so `A-12` comes before `A-101`.
  ///
  /// Both sides come from [roomKey], which is what folds `A--211` and
  /// `A- 210` into their plain spellings first — otherwise the padded
  /// spelling would sort as a different room, in the wrong place.
  int _natural(String a, String b) {
    final ka = _chunks(a);
    final kb = _chunks(b);
    final n = ka.length < kb.length ? ka.length : kb.length;
    for (var i = 0; i < n; i++) {
      final x = ka[i];
      final y = kb[i];
      final c = x is int && y is int
          ? x.compareTo(y)
          : x.toString().compareTo(y.toString());
      if (c != 0) return c;
    }
    return ka.length.compareTo(kb.length);
  }

  /// Alternating runs of digits and everything else, so `A-101` becomes
  /// `['A-', 101]` and can be compared a piece at a time.
  static List<Object> _chunks(String s) => [
    for (final m in RegExp(r'(\d+)|(\D+)').allMatches(s))
      m.group(1) == null ? m.group(2)! : int.parse(m.group(1)!),
  ];

  /// `845` -> `02:05 PM`.
  ///
  /// The sheets carry no meridiem and the grids run from 08:30 to 20:05,
  /// so a bare `14:05` would read as a 24-hour clock the rest of the app
  /// never uses. Hour is zero-padded to match the timetable's cards.
  static String _clock(int minutes) {
    final m = minutes % (24 * 60);
    final h24 = m ~/ 60;
    final h = (h24 % 12 == 0 ? 12 : h24 % 12).toString().padLeft(2, '0');
    return '$h:${(m % 60).toString().padLeft(2, '0')} '
        '${h24 < 12 ? 'AM' : 'PM'}';
  }

  /// The headline: what is being counted, and against when.
  String _summary(int count) {
    final plural = count == 1 ? 'room' : 'rooms';
    if (_useNow && _day == _today) return '$count $plural free now';
    final onDay = _day == _today ? '' : ' on $_day';
    return '$count $plural free at ${_clock(_at)}$onDay';
  }

  /// The line every card carries — the answer the screen exists for.
  String _freeLine(RoomOccupancy room) {
    final until = room.freeUntil(_at);
    // Null means nothing else is booked, so it holds to the end of the
    // day's own window rather than to some hour someone guessed.
    if (until == null) return 'Free the rest of the day';
    return 'Free until ${_clock(until)}';
  }

  /// Why the list is empty, naming whatever is being filtered rather
  /// than repeating the count the header already shows.
  String _emptyMessage() {
    if (_rooms.isEmpty) return 'No rooms are published for $_day.';
    final what = switch (_type) {
      _typeLabs => 'labs',
      _typeClassrooms => 'classrooms',
      _ => 'rooms',
    };
    final where = _block.isEmpty ? '' : ' in block $_block';
    final when = _useNow && _day == _today
        ? 'right now'
        : 'at ${_clock(_at)}';
    final kind = what == 'rooms' ? 'No rooms are' : 'No $what are';
    return '$kind free$where $when.';
  }

  @override
  Widget build(BuildContext context) {
    final free = _loading || _error != null ? const <RoomOccupancy>[] : _free();

    return Padding(
      padding: const EdgeInsets.all(18),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The header is a stack of fixed-height rows — title, three
          // filter rows, day tabs, summary — and in landscape that stack
          // is taller than the screen is: it pushed the room list off the
          // bottom and painted the overflow stripes over the tabs.
          //
          // Capping it answers that in every orientation at once. A
          // [ConstrainedBox] around a [SingleChildScrollView] still sizes
          // to its content whenever the content fits, and a
          // [ConstrainedBox] is not a flexible child, so it never claims
          // the list's share of the column: portrait is untouched, and
          // only a header that would otherwise crowd the list out starts
          // scrolling.
          final headerBudget = constraints.maxHeight * 0.7;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: headerBudget),
                child: SingleChildScrollView(
                  child: _buildHeader(free),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(child: _buildBody(free)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildHeader(List<RoomOccupancy> free) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Rooms', style: AppTextStyles.title),
        const SizedBox(height: 14),
        _filterRow('BLOCK', [
          _pill('All', _block.isEmpty, () => setState(() => _block = '')),
          for (final b in _blocks)
            _pill(b, _block == b, () => setState(() => _block = b)),
        ]),
        _filterRow('KIND', [
          _pill('All', _type == _typeAll, () => setState(() => _type = _typeAll)),
          _pill(
            'Classrooms',
            _type == _typeClassrooms,
            () => setState(() => _type = _typeClassrooms),
          ),
          _pill(
            'Labs',
            _type == _typeLabs,
            () => setState(() => _type = _typeLabs),
          ),
        ]),
        _filterRow('WHEN', [
          _pill(
            _useNow ? 'Now · ${_clock(_at)}' : 'Now',
            _useNow,
            () => setState(() => _useNow = true),
          ),
          _pill(
            _useNow ? 'Pick a time…' : 'At ${_clock(_at)}',
            !_useNow,
            _pickTime,
          ),
        ]),
        const SizedBox(height: 4),
        _buildDayTabs(),
        const SizedBox(height: 8),
        Text(
          _loading || _error != null ? ' ' : _summary(free.length),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  /// One labelled filter line — a caption on the left and the scrollable
  /// pills to its right, the same shape the timetable uses for its
  /// filters so the two tabs read as one screen.
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

  Widget _buildDayTabs() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final day in _weekOrder)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                onTap: () => _selectDay(day),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _day == day ? AppColors.cardYellow : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _day == day
                          ? AppColors.cardYellow
                          : Colors.white24,
                    ),
                  ),
                  child: Text(
                    day,
                    style: TextStyle(
                      color: _day == day ? AppColors.textDark : Colors.white70,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(List<RoomOccupancy> free) {
    if (_loading) return _buildSkeleton();

    if (_error != null) {
      return _buildMessage(
        icon: Icons.cloud_off_rounded,
        message: _error!,
        actionLabel: 'Retry',
        onAction: () => _load(force: true),
      );
    }

    // Grouped only while every block is showing: once a block has been
    // chosen the header over the list would be saying the same thing as
    // the filter, and the rooms that carry no block code — all labs —
    // are listed under "All" alone, since no block can be their home.
    final grouped = _block.isEmpty && free.isNotEmpty;

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
            _banner(
              Icons.wifi_off_rounded,
              'Offline — showing your saved rooms',
            ),
          if (free.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 40),
              child: _buildMessage(
                icon: Icons.meeting_room_rounded,
                message: _emptyMessage(),
              ),
            )
          else ...[
            for (var i = 0; i < free.length; i++) ...[
              if (grouped && (i == 0 || free[i].building != free[i - 1].building))
                _blockHeader(free[i].building),
              _buildRoom(free[i], i),
            ],
          ],
          const SizedBox(height: 8),
          Center(child: _lastUpdated(_fetchedAt)),
        ],
      ),
    );
  }

  Widget _blockHeader(String building) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 8),
      child: Text(
        building.isEmpty ? 'NO BLOCK CODE' : 'BLOCK $building',
        style: const TextStyle(
          color: Colors.white60,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        ),
      ),
    );
  }

  Widget _buildRoom(RoomOccupancy room, int index) {
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
        ? AppColors.textDark.withValues(alpha: 0.7)
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
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        room.room,
                        style: TextStyle(
                          color: primary,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    if (room.isLab) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: darkText
                              ? AppColors.textDark.withValues(alpha: 0.15)
                              : Colors.white24,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'LAB',
                          style: TextStyle(
                            color: secondary,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _freeLine(room),
                  style: TextStyle(
                    color: secondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (room.building.isEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'No block code on the sheet',
                    style: TextStyle(color: secondary, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
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

  Widget _lastUpdated(DateTime fetchedAt) {
    if (fetchedAt.millisecondsSinceEpoch == 0) {
      return const SizedBox.shrink();
    }
    final age = DateTime.now().difference(fetchedAt);
    final label = age.inMinutes < 1
        ? 'just now'
        : age.inHours < 1
        ? '${age.inMinutes} min ago'
        : age.inDays < 1
        ? '${age.inHours} h ago'
        : '${age.inDays} d ago';

    return Text(
      'Room sheet updated $label',
      style: const TextStyle(color: Colors.white38, fontSize: 11),
    );
  }
}
