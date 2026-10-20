// lib/widgets/attendance_ring.dart

import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A small circular read-out of one course's attendance, meant to sit at
/// the right-hand end of a timetable card.
///
/// It sits on a solid dark badge because the cards underneath rotate
/// through the app's whole palette. The arc has to be a colour that
/// means something — teal for clear, yellow for just under, orange for
/// well under — and the card below may well be that very colour: a teal
/// ring on a teal card is simply not there, which a translucent scrim
/// over the card only softens. A fixed dark disc instead puts the same
/// large distance between the badge and every arc colour, and gives the
/// white percentage something to sit on however pale the card is.
///
/// There is deliberately no "unknown" state: a course the portal can't
/// be matched to simply doesn't get a ring, rather than showing an empty
/// arc that reads as 0%.
class AttendanceRing extends StatelessWidget {
  const AttendanceRing({
    super.key,
    required this.percent,
    this.size = 46,
    this.asOf,
  });

  /// Attendance as the portal reports it, 0-100.
  final double percent;

  final double size;

  /// When the figure was actually read off the portal.
  ///
  /// Rings outlive the session that produced them — a student who
  /// hasn't opened Flex in a while still sees what was last known — so
  /// a figure that has gone a day or more without a reading says so.
  /// Nothing on screen changes: it is the label and the tooltip that
  /// carry it, since a stale number presented as current would be the
  /// one thing worse than no number.
  final DateTime? asOf;

  /// FAST holds students to 80%, so green is "clear of the bar", yellow
  /// is just under it, and orange is far enough under to be a problem.
  ///
  /// The colours come from the card palette so the ring reads as part of
  /// the app rather than an overlay dropped on top of it.
  Color get color {
    if (percent >= 80) return AppColors.cardGreen;
    if (percent >= 70) return AppColors.cardYellow;
    return AppColors.cardOrange;
  }

  @override
  Widget build(BuildContext context) {
    final label = _label();

    return Semantics(
      label: label,
      child: Tooltip(
        message: label,
        child: Container(
          width: size,
          height: size,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.background,
          ),
          child: CustomPaint(
            painter: _RingPainter(percent: percent, color: color),
            child: Center(
              child: Text(
                '${percent.round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  height: 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// What the ring says about itself. The percentage is the whole label
  /// unless the figure has gone a day or more without being read, when
  /// its date is added — the ring stays on after the session that
  /// produced it has lapsed, and a number that has quietly stopped
  /// moving should be able to say so.
  String _label() {
    final base = 'Attendance ${percent.round()} percent';
    final at = asOf;
    if (at == null) return base;
    if (DateTime.now().difference(at).inDays < 1) return base;
    return '$base, last read ${at.day} ${_months[at.month - 1]}';
  }

  static const List<String> _months = [
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
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.percent, required this.color});

  static const double stroke = 4.0;

  /// How far the arc is held in from the badge's rim.
  ///
  /// Without it the arc's outer edge *is* the badge's edge — and on a
  /// card the same colour as the arc, the two join up. A teal ring on a
  /// teal card then stops reading as a ring at all and just looks like a
  /// smaller badge, so the badge has to show through outside it to keep
  /// them apart.
  static const double gap = 4.0;

  final double percent;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = min(size.width, size.height) / 2 - gap - stroke / 2;
    final rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: radius,
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = Colors.white24;
    canvas.drawCircle(size.center(Offset.zero), radius, track);

    // A full ring has to stay a ring rather than close into a disc, so a
    // perfect score stops just short of meeting its own tail.
    final fraction = (percent.clamp(0, 100) / 100) * 0.999;
    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, -pi / 2, 2 * pi * fraction, false, arc);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.percent != percent || old.color != color;
}
