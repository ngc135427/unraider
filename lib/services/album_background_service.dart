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

  String get actionableDiagnostic {
    if (lastError.isEmpty) return '';
    final value = lastError.toLowerCase();
    if (value.contains('permission') ||
        value.contains('权限') ||
        value.contains('denied')) {
      return '媒体权限不可用：请在系统设置中允许照片和视频访问后重试。原始错误：$lastError';
    }
    if (value.contains('401') ||
        value.contains('403') ||
        value.contains('认证') ||
        value.contains('unauthorized')) {
      return 'Unraid 认证失败：请检查登录密码或 WebDAV Token。原始错误：$lastError';
    }
    if (value.contains('space') ||
        value.contains('enospc') ||
        value.contains('空间') ||
        value.contains('storage')) {
      return '目标存储空间不足或受到系统存储限制：请释放空间后重试。原始错误：$lastError';
    }
    if (value.contains('battery') ||
        value.contains('电池') ||
        value.contains('background')) {
      return '后台执行受电池策略限制：请允许后台运行并关闭针对本应用的省电限制。原始错误：$lastError';
    }
    if (value.contains('network') ||
        value.contains('timeout') ||
        value.contains('网络') ||
        value.contains('连接')) {
      return '网络当前不可用：请确认 Wi-Fi/仅充电策略和 Unraid 连通性后重试。原始错误：$lastError';
    }
    return lastError;
  }
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
