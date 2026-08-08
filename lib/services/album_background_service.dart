import 'package:flutter/services.dart';

import 'album_preferences.dart';
import 'unraid_client.dart';

class AlbumBackgroundStatus {
  const AlbumBackgroundStatus({
    required this.stage,
    required this.pending,
    required this.completed,
    required this.failed,
    required this.bytesPerSecond,
    required this.lastSuccessMs,
    required this.lastRunMs,
    required this.lastError,
  });

  factory AlbumBackgroundStatus.fromMap(Map<dynamic, dynamic>? map) {
    return AlbumBackgroundStatus(
      stage: map?['stage']?.toString() ?? 'idle',
      pending: (map?['pending'] as num?)?.toInt() ?? 0,
      completed: (map?['completed'] as num?)?.toInt() ?? 0,
      failed: (map?['failed'] as num?)?.toInt() ?? 0,
      bytesPerSecond: (map?['bytesPerSecond'] as num?)?.toInt() ?? 0,
      lastSuccessMs: (map?['lastSuccessMs'] as num?)?.toInt() ?? 0,
      lastRunMs: (map?['lastRunMs'] as num?)?.toInt() ?? 0,
      lastError: map?['lastError']?.toString() ?? '',
    );
  }

  final String stage;
  final int pending;
  final int completed;
  final int failed;
  final int bytesPerSecond;
  final int lastSuccessMs;
  final int lastRunMs;
  final String lastError;
}

class AlbumBackgroundService {
  static const _channel = MethodChannel('unraider/album_background');

  static Future<void> configure({
    required UnraidClient client,
    required AlbumBackupPreferences preferences,
  }) async {
    try {
      await _channel.invokeMethod<void>('configure', <String, Object?>{
        ...client.albumBackgroundConfiguration,
        'enabled': preferences.autoBackup,
        'wifiOnly': preferences.wifiOnly,
        'chargingOnly': preferences.chargingOnly,
        'concurrency': preferences.transferConcurrency,
      });
    } on MissingPluginException {
      // Background scheduling is Android-only.
    }
  }

  static Future<void> runNow() async {
    try {
      await _channel.invokeMethod<void>('runNow');
    } on MissingPluginException {
      return;
    }
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      return;
    }
  }

  static Future<AlbumBackgroundStatus> status() async {
    try {
      final value =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('status');
      return AlbumBackgroundStatus.fromMap(value);
    } on MissingPluginException {
      return AlbumBackgroundStatus.fromMap(null);
    }
  }
}
