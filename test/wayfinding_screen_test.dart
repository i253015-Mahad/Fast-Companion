// test/wayfinding_screen_test.dart

import 'package:fast_companion/Screens/rooms_screen.dart';
import 'package:fast_companion/Screens/wayfinding_screen.dart';
import 'package:fast_companion/theme/app_colors.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Both halves are handed `active: false` so neither asks a sheet for
  // anything: the shifter's job is to be a control, and a control that
  // needs the network to be pressed is a control that cannot be tested.
  Widget wrap() => const MaterialApp(
    home: Scaffold(body: WayfindingScreen(active: false)),
  );

  /// The tab keeps a 30-second clock, so settling would never settle.
  /// A fixed step is enough to finish the cross-fade.
  Future<void> settle(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  /// Unmounts, so the rooms half's clock does not outlive the test and
  /// leave a pending timer behind.
  Future<void> done(WidgetTester tester) =>
      tester.pumpWidget(const SizedBox.shrink());

  group('the shifter', () {
    testWidgets('opens on the rooms half', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      expect(find.text('BLOCK').hitTestable(), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsNothing);

      await done(tester);
    });

    testWidgets('the marker slides to the half in front', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      AlignmentGeometry alignment() =>
          tester.widget<AnimatedAlign>(find.byType(AnimatedAlign)).alignment;

      expect(alignment(), Alignment.centerLeft);

      await tester.tap(find.text('Teachers'));
      await settle(tester);
      expect(alignment(), Alignment.centerRight);

      await tester.tap(find.text('Rooms'));
      await settle(tester);
      expect(alignment(), Alignment.centerLeft);

      await done(tester);
    });

    testWidgets('slides to the directory and back again', (tester) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.tap(find.text('Teachers'));
      await settle(tester);

      expect(find.byType(TextField).hitTestable(), findsOneWidget);
      // Still in the tree, just not in front: losing it would mean
      // losing the filters and scroll position on every flip.
      expect(find.text('BLOCK'), findsOneWidget);
      expect(find.text('BLOCK').hitTestable(), findsNothing);

      await tester.tap(find.text('Rooms'));
      await settle(tester);

      expect(find.text('BLOCK').hitTestable(), findsOneWidget);
      expect(find.byType(TextField).hitTestable(), findsNothing);

      await done(tester);
    });

    testWidgets('pressing the half already in front changes nothing', (
      tester,
    ) async {
      await tester.pumpWidget(wrap());
      await tester.pump();

      await tester.tap(find.text('Rooms'));
      await settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('BLOCK').hitTestable(), findsOneWidget);

      await done(tester);
    });
  });

  group('a block handed over from a teacher', () {
    Widget build(String? block) => MaterialApp(
      home: Scaffold(body: RoomsScreen(active: false, requestedBlock: block)),
    );

    testWidgets('selects that block on the rooms half', (tester) async {
      await tester.pumpWidget(build(null));
      await tester.pump();

      // Unselected pills write their label in a dim white.
      expect(
        tester.widget<Text>(find.text('D')).style?.color,
        Colors.white70,
      );

      await tester.pumpWidget(build('D'));
      await tester.pump();

      // Selected pills take the accent fill and write in dark text — the
      // same treatment the screen's own taps give them.
      expect(
        tester.widget<Text>(find.text('D')).style?.color,
        AppColors.textDark,
      );

      await done(tester);
    });

    testWidgets('leaves a block the student chose themselves alone', (
      tester,
    ) async {
      await tester.pumpWidget(build('D'));
      await tester.pump();

      // The student taps B by hand.
      await tester.tap(find.text('B'));
      await tester.pump();

      // The wrapper still holds D, but it has not changed since the last
      // build, so it must not drag the list back.
      await tester.pumpWidget(build('D'));
      await tester.pump();

      expect(
        tester.widget<Text>(find.text('B')).style?.color,
        AppColors.textDark,
      );

      await done(tester);
    });
  });
}
