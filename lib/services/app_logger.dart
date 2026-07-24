import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Lightweight process logger with batched native writes.
///
/// Debug output is printed immediately. File appends go through a short queue
/// so rapid logging does not spam the MethodChannel on the platform thread.
class AppLogger {
  const AppLogger._();

  static const _channel = MethodChannel('unraider/app_log');
  static const _flushInterval = Duration(milliseconds: 250);
  static const _maxBatchSize = 32;

  static String? _logFilePath;
  static final List<String> _pendingLines = <String>[];
  static Timer? _flushTimer;
  static Future<void> _writeChain = Future<void>.value();
  static bool _flushScheduled = false;

  static String? get logFilePath => _logFilePath;

  static Future<void> initialize() async {
    try {
      _logFilePath = await _channel.invokeMethod<String>('path');
      await log('app_start logFilePath=${_logFilePath ?? 'unavailable'}');
    } on Object catch (error) {
      debugPrint('UnraiderLog logger_init_failed error=$error');
    }
  }

  static Future<void> log(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) async {
    final line = _formatLine(message, error: error, stackTrace: stackTrace);
    debugPrint('UnraiderLog $line');
    _enqueue(line);
  }

  /// Flush any buffered lines immediately. Useful before process exit tests.
  static Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    _flushScheduled = false;
    await _drainPending();
    await _writeChain;
  }

  static void _enqueue(String line) {
    _pendingLines.add(line);
    if (_pendingLines.length >= _maxBatchSize) {
      unawaited(_drainPending());
      return;
    }
    if (_flushScheduled) {
      return;
    }
    _flushScheduled = true;
    _flushTimer = Timer(_flushInterval, () {
      _flushScheduled = false;
      unawaited(_drainPending());
    });
  }

  static Future<void> _drainPending() async {
    if (_pendingLines.isEmpty) {
      return;
    }
    final batch = List<String>.from(_pendingLines);
    _pendingLines.clear();
    _writeChain = _writeChain.then((_) => _writeBatch(batch));
    await _writeChain;
  }

  static Future<void> _writeBatch(List<String> lines) async {
    if (lines.isEmpty) {
      return;
    }
    try {
      // Prefer a multi-line append when the platform supports it; fall back to
      // one append per line for older channel implementations.
      try {
        await _channel.invokeMethod<void>('appendBatch', <String, Object?>{
          'lines': lines,
        });
        return;
      } on MissingPluginException {
        // Channel method not registered — use single-line appends.
      } on PlatformException {
        // Older native side may only expose `append`.
      }

      for (final line in lines) {
        await _channel.invokeMethod<void>('append', <String, Object?>{
          'line': line,
        });
      }
    } on MissingPluginException {
      // Unit tests / desktop hosts without the channel: console only.
    } on Object catch (writeError) {
      // Tests / non-Flutter isolates may lack a ServicesBinding; keep console
      // output only and avoid noisy repeated failures.
      final text = writeError.toString();
      if (text.contains('Binding has not yet been initialized') ||
          text.contains('ServicesBinding')) {
        return;
      }
      debugPrint('UnraiderLog logger_write_failed error=$writeError');
    }
  }

  static String _formatLine(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    final buffer = StringBuffer()
      ..write(DateTime.now().toIso8601String())
      ..write(' ')
      ..write(message);
    if (error != null) {
      buffer
        ..write(' error=')
        ..write(error);
    }
    if (stackTrace != null) {
      buffer
        ..write('\n')
        ..write(stackTrace);
    }
    return buffer.toString();
  }
}
