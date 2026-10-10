// lib/app_signals.dart
import 'package:flutter/foundation.dart';

/// Bumped whenever a note is edited through a path that doesn't go through
/// HomeScreen's own openAndEditNote() — currently just the widget's "edit"
/// button deep link (main.dart's openNote handler). HomeScreen listens and
/// refreshes its list when this changes, so returning from that screen
/// shows the edit instead of a stale list.
final ValueNotifier<int> homeRefreshSignal = ValueNotifier<int>(0);
