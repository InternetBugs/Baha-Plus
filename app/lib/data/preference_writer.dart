import 'dart:async';

import 'device_storage.dart';

class PreferenceWriter {
  PreferenceWriter(this.storage, {required this.onError});

  final DeviceStorage storage;
  final void Function() onError;
  final _keys = <String, _PreferenceWrite>{};
  bool _disposed = false;

  Future<void> write(
    String key,
    String value, {
    Duration debounce = Duration.zero,
  }) {
    if (_disposed) return Future.value();
    final state = _keys.putIfAbsent(key, _PreferenceWrite.new);
    state.latest = value;
    final done = state.done ??= Completer<void>();
    if (!state.writing) {
      final debouncePending = state.timer?.isActive == true;
      state.timer?.cancel();
      if (debouncePending && debounce > Duration.zero) {
        state.timer = Timer(debounce, () => _flush(key, state, debounce));
      } else {
        unawaited(_flush(key, state, debounce));
      }
    }
    return done.future;
  }

  Future<void> _flush(
    String key,
    _PreferenceWrite state,
    Duration debounce,
  ) async {
    state.writing = true;
    while (state.latest != null) {
      final value = state.latest!;
      state.latest = null;
      try {
        await storage.write(key, value);
      } catch (_) {
        onError();
      }
    }
    state.writing = false;
    state.done?.complete();
    state.done = null;
    if (debounce == Duration.zero || _disposed) {
      _keys.remove(key);
    } else {
      state.timer = Timer(debounce, () => _keys.remove(key));
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _keys.entries.toList()) {
      final state = entry.value;
      state.timer?.cancel();
      if (!state.writing) unawaited(_flush(entry.key, state, Duration.zero));
    }
  }
}

class _PreferenceWrite {
  String? latest;
  Completer<void>? done;
  Timer? timer;
  bool writing = false;
}
