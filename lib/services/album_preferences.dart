import 'package:flutter/services.dart';

class AlbumBackupPreferences {
  const AlbumBackupPreferences({
    this.autoBackup = true,
    this.targetDir = '/mnt/user/photos/mobile',
    this.sourceId = '',
    this.sourceName = '本机所有照片',
  });

  final bool autoBackup;
  final String targetDir;
  final String sourceId;
  final String sourceName;
}

class AlbumPreferences {
  static const channelName = 'unraider/album_preferences';
  static const _channel = MethodChannel(channelName);

  static Future<AlbumBackupPreferences> load() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('load');
      if (result == null) {
        return const AlbumBackupPreferences();
      }
      return AlbumBackupPreferences(
        autoBackup: result['autoBackup'] != false,
        targetDir: _asString(result['targetDir']).isEmpty
            ? '/mnt/user/photos/mobile'
            : _asString(result['targetDir']),
        sourceId: _asString(result['sourceId']),
        sourceName: _asString(result['sourceName']).isEmpty
            ? '本机所有照片'
            : _asString(result['sourceName']),
      );
    } on MissingPluginException {
      return const AlbumBackupPreferences();
    }
  }

  static Future<void> save(AlbumBackupPreferences preferences) async {
    try {
      await _channel.invokeMethod<void>('save', {
        'autoBackup': preferences.autoBackup,
        'targetDir': preferences.targetDir,
        'sourceId': preferences.sourceId,
        'sourceName': preferences.sourceName,
      });
    } on MissingPluginException {
      return;
    }
  }

  static String _asString(Object? value) => (value?.toString() ?? '').trim();
}
