import 'dart:async';

import 'package:flutter/foundation.dart';

class RuntimeLogBuffer {
  RuntimeLogBuffer({
    this.maxEntries = 80,
    this.maxPendingEntries = 160,
    this.flushInterval = const Duration(milliseconds: 750),
  }) : assert(maxEntries > 0),
       assert(maxPendingEntries > 0);

  final int maxEntries;
  final int maxPendingEntries;
  final Duration flushInterval;

  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  final List<String> _entries = <String>[];
  final List<String> _pending = <String>[];
  Timer? _flushTimer;
  bool _disposed = false;

  List<String> get entries => List<String>.unmodifiable(_entries);

  void add(String entry) {
    if (_disposed || entry.isEmpty) {
      return;
    }
    _pending.add(entry);
    if (_pending.length > maxPendingEntries) {
      _pending.removeRange(0, _pending.length - maxPendingEntries);
    }
    _flushTimer ??= Timer(flushInterval, flush);
  }

  void replaceAll(Iterable<String> entries) {
    if (_disposed) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    _entries
      ..clear()
      ..addAll(entries);
    _trimEntries();
    revision.value += 1;
  }

  void clear() {
    if (_disposed) {
      return;
    }
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    if (_entries.isEmpty) {
      return;
    }
    _entries.clear();
    revision.value += 1;
  }

  void flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed || _pending.isEmpty) {
      return;
    }
    _entries.addAll(_pending);
    _pending.clear();
    _trimEntries();
    revision.value += 1;
  }

  void _trimEntries() {
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _flushTimer?.cancel();
    _flushTimer = null;
    _pending.clear();
    revision.dispose();
  }
}
