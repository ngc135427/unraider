import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class AppLogger {
  const AppLogger._();

  static const _channel = MethodChannel('unraider/app_log');
  static String? _logFilePath;

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
    try {
      await _channel.invokeMethod<void>('append', <String, Object?>{
        'line': line,
      });
    } on Object catch (writeError) {
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
