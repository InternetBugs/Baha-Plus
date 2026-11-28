import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

class HttpPoolCancelled implements Exception {
  const HttpPoolCancelled({this.disposed = false});

  final bool disposed;
}

class RetryingHttpClientPool {
  RetryingHttpClientPool({
    http.Client? client,
    http.Client Function()? clientFactory,
    this.closeInjectedClient = true,
  }) : _factory = clientFactory ?? http.Client.new,
       _ownsClient = client == null,
       _current = _ClientSlot(client ?? (clientFactory ?? http.Client.new)()) {
    _clients.add(_current);
  }

  final bool closeInjectedClient;
  final bool _ownsClient;
  final http.Client Function() _factory;
  _ClientSlot _current;
  final _clients = <_ClientSlot>{};
  final _operations = <Completer<void>>{};
  bool _disposed = false;

  static bool isTransportError(Object error) =>
      error is SocketException ||
      error is TlsException ||
      error is HttpException ||
      error is TimeoutException ||
      error is http.ClientException && error is! http.RequestAbortedException;

  Future<T> run<T>(
    Future<T> Function(http.Client client, Future<void> abort, int attempt)
    send, {
    required Duration timeout,
    int maxRetries = 0,
    Future<void>? cancel,
    Duration? Function(Object error, int attempt)? retryAfter,
  }) async {
    if (_disposed) throw const HttpPoolCancelled(disposed: true);
    final stop = Completer<void>();
    _operations.add(stop);
    if (cancel != null) {
      unawaited(
        cancel.then(
          (_) => _complete(stop),
          onError: (Object _, StackTrace _) => _complete(stop),
        ),
      );
    }
    try {
      for (var attempt = 0; ; attempt++) {
        if (stop.isCompleted) throw HttpPoolCancelled(disposed: _disposed);
        final slot = _current;
        try {
          return await _attempt(slot, send, stop.future, attempt, timeout);
        } catch (error) {
          if (stop.isCompleted) throw HttpPoolCancelled(disposed: _disposed);
          if (attempt >= maxRetries) rethrow;
          final delay = retryAfter?.call(error, attempt);
          if (delay == null) rethrow;
          if (isTransportError(error)) _rotate(slot);
          await _waitRetry(delay, stop.future);
        }
      }
    } finally {
      _operations.remove(stop);
      _complete(stop);
    }
  }

  Future<T> _attempt<T>(
    _ClientSlot slot,
    Future<T> Function(http.Client, Future<void>, int) send,
    Future<void> stop,
    int attempt,
    Duration timeout,
  ) async {
    final abort = Completer<void>();
    slot.active++;
    try {
      return await Future.any([
        Future<T>.microtask(() {
          if (abort.isCompleted) throw HttpPoolCancelled(disposed: _disposed);
          return send(slot.client, abort.future, attempt);
        }),
        stop.then<T>((_) {
          _complete(abort);
          throw HttpPoolCancelled(disposed: _disposed);
        }),
      ]).timeout(timeout);
    } finally {
      _complete(abort);
      slot.active--;
      _closeIfRetired(slot);
    }
  }

  Future<void> _waitRetry(Duration delay, Future<void> stop) async {
    if (delay <= Duration.zero) return;
    final wake = Completer<void>();
    final timer = Timer(delay, () => _complete(wake));
    try {
      await Future.any([wake.future, stop]);
    } finally {
      timer.cancel();
    }
  }

  void _rotate(_ClientSlot failed) {
    if (!_ownsClient || _disposed || !identical(_current, failed)) return;
    _current = _ClientSlot(_factory());
    _clients.add(_current);
    failed.retired = true;
    _closeIfRetired(failed);
  }

  void _closeIfRetired(_ClientSlot slot) {
    if (slot.retired && slot.active == 0 && _clients.remove(slot)) {
      slot.client.close();
    }
  }

  void abortAll() {
    for (final stop in _operations) {
      _complete(stop);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    abortAll();
    for (final slot in _clients) {
      if (_ownsClient || closeInjectedClient) slot.client.close();
    }
    _clients.clear();
  }

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }
}

class _ClientSlot {
  _ClientSlot(this.client);

  final http.Client client;
  int active = 0;
  bool retired = false;
}

Future<void> cancelResponse(http.StreamedResponse response) =>
    response.stream.listen((_) {}, onError: (Object _) {}).cancel();
