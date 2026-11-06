// lib/widgets/tutorial_overlay.dart
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/tutorial_content.dart';
import '../theme/app_colors.dart';
import 'tutorial_targets.dart';

/// Resolves a tutorial target id to its rectangle in **global**
/// coordinates, or null when the target isn't available (which falls
/// back to a centered card).
typedef TutorialTargetResolver = Future<Rect?> Function(String targetId);

/// Owns the current step index of a tutorial so a host can advance,
/// retreat, or move the overlay between host widgets without losing
/// progress. Listeners are the overlays rendering the tutorial.
class TutorialController extends ChangeNotifier {
  TutorialController({int initialIndex = 0}) : _index = initialIndex;

  int _index;
  int get index => _index;

  void goTo(int index) {
    if (index == _index) return;
    _index = index;
    notifyListeners();
  }
}

/// A full-screen tutorial overlay that walks the user through one step
/// at a time.
///
/// Each step can spotlight the widget it talks about: the rest of the
/// screen dims, a hole is cut around the target with an orange glow,
/// and the card sits next to it with an arrow pointing at it. Steps
/// without an available target show the classic centered card.
///
/// The overlay absorbs taps so the UI behind can't be used mid-tutorial
/// — except on a [TutorialStep.waitForTrigger] step, where taps pass
/// through the spotlight hole so the user can perform the action being
/// taught; the host then advances the [TutorialController].
class TutorialOverlay extends StatefulWidget {
  const TutorialOverlay({
    super.key,
    required this.title,
    required this.steps,
    this.skipText,
    this.nextText = 'Next',
    this.doneText = 'Got it!',
    this.controller,
    this.resolver,
    this.onWaitAction,
    this.waitActionText = 'Continue',
    required this.onSkip,
    required this.onDone,
  });

  /// Heading shown at the top of the card.
  final String title;

  /// The steps, one per page. At least one entry.
  final List<TutorialStep> steps;

  /// When non-null, a "skip" text button is shown that ends the tutorial
  /// immediately via [onSkip].
  final String? skipText;

  final String nextText;
  final String doneText;

  /// Externally owned step index. When null the overlay keeps its own.
  final TutorialController? controller;

  /// Custom target resolver (e.g. rects measured inside a WebView).
  /// Defaults to [defaultTargetResolver].
  final TutorialTargetResolver? resolver;

  /// Offered on a wait step whose target could not be resolved — lets
  /// the host perform the awaited action itself instead.
  final VoidCallback? onWaitAction;
  final String waitActionText;

  /// Called when the user skips (dismisses without finishing).
  final VoidCallback onSkip;

  /// Called when the user finishes the last step.
  final VoidCallback onDone;

  /// Default resolver: the registered [TutorialTargets] key's render
  /// box, in global coordinates.
  static Future<Rect?> defaultTargetResolver(String id) async {
    final key = TutorialTargets.resolveMounted(id);
    if (key == null) return null;
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  State<TutorialOverlay> createState() => _TutorialOverlayState();
}

class _TutorialOverlayState extends State<TutorialOverlay>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  int _localIndex = 0;

  /// Resolved target rect in global coordinates; null → centered card.
  Rect? _targetGlobal;

  /// Measured card size, used to place it beside the target.
  Size? _cardSize;

  final GlobalKey _cardKey = GlobalKey();

  /// Bumped on every resolve so a stale async result is dropped.
  int _resolveToken = 0;

  /// How often the current step's target is re-measured. Targets can
  /// move long after first paint — the Scaffold raises the FAB above a
  /// fixed SnackBar and drops it again when the message dismisses
  /// (~4s later) — so the spotlight keeps watching instead of
  /// measuring the target exactly once.
  static const Duration _trackInterval = Duration(milliseconds: 200);

  Timer? _trackTimer;

  late final AnimationController _controller;
  late final Animation<double> _fade;

  int get _index {
    final external = widget.controller?.index;
    final raw = external ?? _localIndex;
    return raw.clamp(0, widget.steps.length - 1);
  }

  TutorialStep get _currentStep => widget.steps[_index];

  bool get _isLast => _index >= widget.steps.length - 1;

  TutorialTargetResolver get _resolver =>
      widget.resolver ?? TutorialOverlay.defaultTargetResolver;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller?.addListener(_onControllerChanged);
    _controller = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
    );
    _fade = CurvedAnimation(parent: _controller, curve: Curves.easeOut);
    _controller.forward();
    _resolveCurrentTarget();
  }

  @override
  void didUpdateWidget(TutorialOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onControllerChanged);
      widget.controller?.addListener(_onControllerChanged);
      _resetTracking();
      _resolveCurrentTarget();
    } else if (!identical(oldWidget.steps, widget.steps)) {
      // A different tutorial took over this slot (e.g. the Notes
      // welcome handing over to the first-note tutorial) — start it
      // from step 1 instead of inheriting the old tutorial's position.
      _localIndex = 0;
      _resetTracking();
      _resolveCurrentTarget();
    }
  }

  @override
  void dispose() {
    _trackTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.controller?.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // Rotation / resize moved everything — re-measure the target.
    _resetTracking();
    _resolveCurrentTarget();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    _resetTracking();
    setState(() {});
    _resolveCurrentTarget();
  }

  void _goNext() {
    if (_isLast) {
      widget.onDone();
      return;
    }
    _setIndex(_index + 1);
  }

  void _setIndex(int index) {
    final external = widget.controller;
    if (external != null) {
      // The listener re-resolves the target for us.
      external.goTo(index);
    } else {
      _resetTracking();
      setState(() => _localIndex = index);
      _resolveCurrentTarget();
    }
  }

  /// Measures the current step's target after the frame has settled.
  void _resolveCurrentTarget() {
    final token = ++_resolveToken;
    final targetId = _currentStep.targetId;
    // Settle timers fire between frames, when no frame may be pending
    // — request one so the post-frame callback actually runs.
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || token != _resolveToken) return;
      Rect? rect;
      if (targetId != null) {
        rect = await _resolver(targetId);
      }
      if (!mounted || token != _resolveToken) return;
      setState(() => _targetGlobal = rect);
      _measureCard();
      _startTracking();
    });
  }

  /// Forgets the tracking timer — used when the step (or its
  /// surroundings) change so tracking never leaks into the next step.
  void _resetTracking() {
    _trackTimer?.cancel();
    _trackTimer = null;
  }

  /// Re-measures the current step's target every [_trackInterval] so a
  /// target that moves after first paint (FAB entrance, a SnackBar
  /// dismissal dropping the FAB back down, a list finishing loading)
  /// stays spotlighted correctly. Centred steps (no target) don't
  /// track, and the tick setStates only when the rect actually
  /// changed — a static screen costs nothing after the first measure.
  void _startTracking() {
    _trackTimer?.cancel();
    _trackTimer = null;
    if (_currentStep.targetId == null) return;
    _trackTimer = Timer.periodic(_trackInterval, (_) => _trackTarget());
  }

  Future<void> _trackTarget() async {
    if (!mounted) return;
    final targetId = _currentStep.targetId;
    if (targetId == null) {
      _resetTracking();
      return;
    }
    final token = ++_resolveToken;
    final rect = await _resolver(targetId);
    if (!mounted || token != _resolveToken) return;
    if (rect != _targetGlobal) setState(() => _targetGlobal = rect);
  }

  /// The card's height changes with its text — re-measure after each
  /// rebuild so the placement math stays right.
  void _measureCard() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _cardKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final size = box.size;
      if (_cardSize != size) setState(() => _cardSize = size);
    });
  }

  /// The target rect in overlay-local coordinates, clamped to the
  /// screen; null when unresolved or entirely off-screen.
  Rect? _localHole(Size screen) {
    final global = _targetGlobal;
    if (global == null) return null;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    final local = box.globalToLocal(global.topLeft) & global.size;
    final clamped = local.intersect(Offset.zero & screen);
    if (clamped.width < 8 || clamped.height < 8) return null;
    return clamped;
  }

  ({double left, double top}) _placeCard(
    Size screen,
    Rect? hole,
    double cardW,
    double cardH,
  ) {
    if (hole == null) {
      return (
        left: (screen.width - cardW) / 2,
        top: (screen.height - cardH) / 2,
      );
    }
    final double left = (hole.center.dx - cardW / 2)
        .clamp(16.0, math.max(16.0, screen.width - 16 - cardW))
        .toDouble();
    const gap = 20.0;
    double top;
    if (hole.bottom + gap + cardH <= screen.height - 16) {
      top = hole.bottom + gap;
    } else {
      final above = hole.top - gap - cardH;
      top = above >= 16 ? above : math.max(16.0, (screen.height - cardH) / 2);
    }
    top = top.clamp(16.0, math.max(16.0, screen.height - 16 - cardH));
    return (left: left, top: top);
  }

  /// Transparent barriers tiling the screen *minus* the hole, so taps
  /// inside the spotlight reach the app underneath (wait steps).
  List<Widget> _bars(Size screen, Rect hole) {
    final h = hole.inflate(16).intersect(Offset.zero & screen);
    if (h.width < 1 || h.height < 1) {
      return const [
        Positioned.fill(
          child: ModalBarrier(dismissible: false, color: Colors.transparent),
        ),
      ];
    }
    return [
      Positioned(left: 0, top: 0, right: 0, height: h.top, child: _bar()),
      Positioned(left: 0, top: h.bottom, right: 0, bottom: 0, child: _bar()),
      Positioned(left: 0, top: h.top, width: h.left, height: h.height,
          child: _bar()),
      Positioned(left: h.right, top: h.top, right: 0, height: h.height,
          child: _bar()),
    ];
  }

  Widget _bar() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: const SizedBox.expand(),
      );

  @override
  Widget build(BuildContext context) {
    // A Material ancestor supplies a sane DefaultTextStyle everywhere the
    // overlay is hosted. Without one (e.g. the flex root OverlayEntry, which
    // sits outside any Scaffold), Text falls back to MaterialApp's debug
    // error style — monospace with a yellow underline.
    return Material(
      type: MaterialType.transparency,
      child: FadeTransition(
        opacity: _fade,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final screen = Size(constraints.maxWidth, constraints.maxHeight);
            final hole = _localHole(screen);
            final cardW = math.min(340.0, math.max(0.0, screen.width - 48));
            final cardH = _cardSize?.height ?? 210.0;
            final pos = _placeCard(screen, hole, cardW, cardH);
            final cardRect = Rect.fromLTWH(pos.left, pos.top, cardW, cardH);
            final passThrough = _currentStep.waitForTrigger && hole != null;

            return Stack(
              fit: StackFit.expand,
              children: [
                // The dim with a hole cut around the target.
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(painter: _SpotlightPainter(hole)),
                  ),
                ),
                // Arrow from the card to the hole.
                if (hole != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ArrowPainter(hole: hole, card: cardRect),
                      ),
                    ),
                  ),
                // Blocking layer: full-screen normally, tiled around the
                // hole on a wait step so the highlighted control is tappable.
                if (passThrough)
                  ..._bars(screen, hole)
                else
                  const Positioned.fill(
                    child: ModalBarrier(
                      dismissible: false,
                      color: Colors.transparent,
                    ),
                  ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  left: pos.left,
                  top: pos.top,
                  width: cardW,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.94, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _controller,
                        curve: Curves.easeOut,
                      ),
                    ),
                    child: _buildCard(holeShown: hole != null),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildCard({required bool holeShown}) {
    final total = widget.steps.length;
    final waiting = _currentStep.waitForTrigger;
    // A wait step with no resolvable target falls back to an explicit
    // action button (or plain Next) so the user is never stuck.
    final waitFallback =
        waiting && !holeShown && widget.onWaitAction != null;

    return KeyedSubtree(
      key: _cardKey,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 340),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
        decoration: BoxDecoration(
          color: AppColors.navBar,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: AppColors.cardOrange.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lightbulb_rounded,
                    color: AppColors.cardOrange,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Step ${_index + 1} of $total',
              style: const TextStyle(
                color: AppColors.cardOrange,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: child,
              ),
              child: Text(
                _currentStep.text,
                key: ValueKey<int>(_index),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
            ),
            const SizedBox(height: 18),
            // Page dots.
            Row(
              children: [
                for (var i = 0; i < total; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    margin: const EdgeInsets.only(right: 6),
                    width: i == _index ? 18 : 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: i == _index
                          ? AppColors.cardOrange
                          : Colors.white24,
                      borderRadius: BorderRadius.circular(3.5),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (widget.skipText != null)
                  TextButton(
                    onPressed: widget.onSkip,
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white54,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      widget.skipText!,
                      style: const TextStyle(fontSize: 13),
                    ),
                  )
                else
                  const SizedBox(width: 8),
                // A wait step with its target shown offers no Next —
                // the tap-through on the highlighted control advances.
                if (!(waiting && holeShown))
                  waitFallback
                      ? ElevatedButton(
                          onPressed: widget.onWaitAction,
                          style: _primaryButtonStyle(),
                          child: Text(
                            widget.waitActionText,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      : ElevatedButton(
                          onPressed: _goNext,
                          style: _primaryButtonStyle(),
                          child: Text(
                            _isLast ? widget.doneText : widget.nextText,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                else
                  const SizedBox(width: 8),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static ButtonStyle _primaryButtonStyle() => ElevatedButton.styleFrom(
        backgroundColor: AppColors.cardOrange,
        foregroundColor: AppColors.textDark,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 11),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        elevation: 0,
      );
}

/// Full-screen dim with a rounded-rect hole punched around [hole] and
/// an orange glow on its edge — the spotlight.
class _SpotlightPainter extends CustomPainter {
  const _SpotlightPainter(this.hole);

  final Rect? hole;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..addRect(Offset.zero & size);
    final r = hole;
    if (r != null) {
      path.addRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(14)),
      );
    }
    path.fillType = PathFillType.evenOdd;
    canvas.drawPath(
      path,
      Paint()..color = Colors.black54,
    );
    if (r != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(14)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = AppColors.cardOrange,
      );
    }
  }

  @override
  bool shouldRepaint(_SpotlightPainter oldDelegate) =>
      oldDelegate.hole != hole;
}

/// A thin arrow from the card's edge to the hole's edge.
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.hole, required this.card});

  final Rect hole;
  final Rect card;

  /// Distance from [rect]'s center to its wall along [d].
  static double _exitT(Rect rect, Offset d) {
    final c = rect.center;
    var t = double.infinity;
    if (d.dx.abs() > 1e-6) {
      t = math.min(t, (d.dx > 0 ? rect.right - c.dx : c.dx - rect.left) /
          d.dx.abs());
    }
    if (d.dy.abs() > 1e-6) {
      t = math.min(t, (d.dy > 0 ? rect.bottom - c.dy : c.dy - rect.top) /
          d.dy.abs());
    }
    return t.isFinite ? t : 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final delta = hole.center - card.center;
    if (delta.distanceSquared < 16) return;
    final n = delta / delta.distance;

    final start = card.center + n * _exitT(card, n) + n * 6;
    final end = hole.center -
        n * _exitT(hole, Offset(-n.dx, -n.dy)) -
        n * 4;
    if ((end - start).distanceSquared < 64) return;

    final paint = Paint()
      ..color = AppColors.cardOrange
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawLine(start, end, paint);

    // Arrowhead at [end], pointing along n.
    const barb = 9.0;
    const angle = 0.45;
    final back = -n;
    final leftBarb = Offset(
      back.dx * math.cos(angle) - back.dy * math.sin(angle),
      back.dx * math.sin(angle) + back.dy * math.cos(angle),
    );
    final rightBarb = Offset(
      back.dx * math.cos(-angle) - back.dy * math.sin(-angle),
      back.dx * math.sin(-angle) + back.dy * math.cos(-angle),
    );
    canvas.drawLine(end, end + leftBarb * barb, paint);
    canvas.drawLine(end, end + rightBarb * barb, paint);
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      oldDelegate.hole != hole || oldDelegate.card != card;
}
