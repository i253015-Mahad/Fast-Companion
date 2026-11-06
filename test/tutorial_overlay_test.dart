import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fast_companion/models/tutorial_content.dart';
import 'package:fast_companion/widgets/tutorial_overlay.dart';

/// Spotlight behaviour: the card parks next to its target, falls back to
/// the centre when nothing resolves, pages with Next, and — on a wait
/// step — lets taps through the highlighted hole while blocking the rest.
void main() {
  const targetKey = Key('tutorial-test-target');
  const title = 'Welcome!';

  Widget host({
    required List<TutorialStep> steps,
    required TutorialTargetResolver resolver,
    VoidCallback? onDone,
    VoidCallback? onTargetPressed,
  }) {
    return MaterialApp(
      home: Stack(
        children: [
          Positioned(
            left: 20,
            top: 40,
            width: 120,
            height: 48,
            child: ElevatedButton(
              key: targetKey,
              onPressed: onTargetPressed ?? () {},
              child: const Text('Go'),
            ),
          ),
          Positioned.fill(
            child: TutorialOverlay(
              title: title,
              steps: steps,
              resolver: resolver,
              onSkip: () {},
              onDone: onDone ?? () {},
            ),
          ),
        ],
      ),
    );
  }

  testWidgets('the card parks below a resolvable target', (tester) async {
    await tester.pumpWidget(
      host(
        steps: const [
          TutorialStep('first step', targetId: 'btn'),
          TutorialStep('second step', targetId: 'btn'),
        ],
        resolver: (_) async => tester.getRect(find.byKey(targetKey)),
      ),
    );
    await tester.pumpAndSettle();

    final target = tester.getRect(find.byKey(targetKey));
    final card = tester.getRect(find.text('Step 1 of 2'));

    expect(card.top, greaterThan(target.bottom),
        reason: 'the card should sit below the highlighted target');
  });

  testWidgets('the card centres when the target cannot be resolved',
      (tester) async {
    await tester.pumpWidget(
      host(
        steps: const [
          TutorialStep('first step', targetId: 'missing'),
          TutorialStep('second step', targetId: 'missing'),
        ],
        resolver: (_) async => null,
      ),
    );
    await tester.pumpAndSettle();

    final screen = tester.getSize(find.byType(TutorialOverlay));
    final card = tester.getRect(find.text('Step 1 of 2'));

    // The card caps at 340 wide and centres; its text sits 20px inside.
    expect(card.left, closeTo((screen.width - 340) / 2 + 20, 2.0),
        reason: 'an unresolvable target falls back to a centred card');
    expect(card.center.dy, greaterThan(screen.height * 0.25));
    expect(card.center.dy, lessThan(screen.height * 0.75));
  });

  testWidgets('Next advances to the following step', (tester) async {
    var done = false;
    await tester.pumpWidget(
      host(
        steps: const [
          TutorialStep('alpha step'),
          TutorialStep('beta step'),
        ],
        resolver: (_) async => null,
        onDone: () => done = true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('alpha step'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
    await tester.pumpAndSettle();

    expect(find.text('beta step'), findsOneWidget);
    expect(find.text('alpha step'), findsNothing);
    expect(find.text('Step 2 of 2'), findsOneWidget);
    expect(
      find.widgetWithText(ElevatedButton, 'Got it!'),
      findsOneWidget,
      reason: 'the last step swaps Next for the done button',
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Got it!'));
    await tester.pumpAndSettle();
    expect(done, isTrue);
  });

  testWidgets('a wait step taps through the hole but blocks elsewhere',
      (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      host(
        steps: const [
          TutorialStep('intro'),
          TutorialStep('tap the highlighted button to continue',
              targetId: 'btn', waitForTrigger: true),
        ],
        resolver: (_) async => tester.getRect(find.byKey(targetKey)),
        onTargetPressed: () => pressed = true,
      ),
    );
    await tester.pumpAndSettle();

    // Page past the intro onto the wait step.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
    await tester.pumpAndSettle();

    // Taps outside the spotlight are swallowed by the barrier.
    await tester.tapAt(const Offset(790, 590));
    await tester.pumpAndSettle();
    expect(pressed, isFalse, reason: 'outside taps must not reach the app');

    // Taps inside the highlighted hole reach the control underneath.
    await tester.tap(find.byKey(targetKey));
    await tester.pumpAndSettle();
    expect(pressed, isTrue, reason: 'the highlighted control stays tappable');
  });

  testWidgets('the spotlight follows a target that settles into place later',
      (tester) async {
    Widget buildHost(double targetTop) {
      return MaterialApp(
        home: Stack(
          children: [
            Positioned(
              left: 20,
              top: targetTop,
              width: 120,
              height: 48,
              child: ElevatedButton(
                key: targetKey,
                onPressed: () {},
                child: const Text('Go'),
              ),
            ),
            Positioned.fill(
              child: TutorialOverlay(
                title: title,
                steps: const [TutorialStep('first step', targetId: 'btn')],
                resolver: (_) async => tester.getRect(find.byKey(targetKey)),
                onSkip: () {},
                onDone: () {},
              ),
            ),
          ],
        ),
      );
    }

    await tester.pumpWidget(buildHost(40));
    await tester.pumpAndSettle();

    final cardBefore = tester.getRect(find.text('Step 1 of 1'));

    // The target moves after the overlay's first measurement (the FAB
    // entrance animation does exactly this) — the overlay is not told.
    await tester.pumpWidget(buildHost(140));
    await tester.pump();

    // Let the settle re-checks fire and re-measure.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      final card = tester.getRect(find.text('Step 1 of 1'));
      if (card.top > cardBefore.top + 40) break;
    }

    final target = tester.getRect(find.byKey(targetKey));
    final card = tester.getRect(find.text('Step 1 of 1'));
    expect(card.top, greaterThan(cardBefore.top),
        reason: 'the hole must follow a target that moved after measuring');
    // The card travels exactly as far as the target did (its text sits
    // a fixed distance inside the card, so compare the deltas).
    expect(card.top - cardBefore.top, closeTo(target.top - 40, 2.0),
        reason: 'the card re-parks below the settled target');
  });

  testWidgets('a different step list restarts the tutorial at step 1',
      (tester) async {
    const stepsA = [
      TutorialStep('alpha step'),
      TutorialStep('beta step'),
    ];
    const stepsB = [
      TutorialStep('gamma step'),
      TutorialStep('delta step'),
    ];

    await tester.pumpWidget(
      host(
        steps: stepsA,
        resolver: (_) async => null,
      ),
    );
    await tester.pumpAndSettle();

    // Page to the last step so the overlay holds index 1.
    await tester.tap(find.widgetWithText(ElevatedButton, 'Next'));
    await tester.pumpAndSettle();
    expect(find.text('Step 2 of 2'), findsOneWidget);

    // Another tutorial takes over the same overlay slot (the notes
    // welcome hands over to the first-note tutorial this way). It must
    // start from step 1 rather than inheriting index 1.
    await tester.pumpWidget(
      host(
        steps: stepsB,
        resolver: (_) async => null,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('gamma step'), findsOneWidget);
    expect(find.text('delta step'), findsNothing);
    expect(find.text('Step 1 of 2'), findsOneWidget);
  });
}
