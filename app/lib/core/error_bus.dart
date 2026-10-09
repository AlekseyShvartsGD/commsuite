import 'package:flutter/foundation.dart';

/// Collects the most recent unhandled app/Dart errors so they can be shown
/// in-app immediately (useful when a crash otherwise closes the app
/// silently) and inspected in the UI.
final ValueNotifier<List<String>> errorBus =
    ValueNotifier<List<String>>(<String>[]);

void reportError(String message, [StackTrace? stack]) {
  final entry = stack == null ? message : '$message\n$stack';
  final current = List<String>.of(errorBus.value);
  current.insert(0, entry);
  final capped = current.take(3).toList();
  if (!listEquals(capped, errorBus.value)) {
    errorBus.value = capped;
  }
}