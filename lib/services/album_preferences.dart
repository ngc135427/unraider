import 'package:flutter/services.dart';

class AlbumBackupPreferences {
  const AlbumBackupPreferences({
    this.autoBackup = true,
    this.targetDir = '/mnt/user/photos/mobile',
    this.sourceId = '',
    this.sourceIds = const <String>[],
    this.sourceName = '本机所有照片',
  });

  final bool autoBackup;
  final String targetDir;
  final String sourceId;
  final List<String> sourceIds;
  final String sourceName;

  List<String> get selectedSourceIds {
    if (sourceIds.isNotEmpty) {
      return sourceIds;
    }
    return sourceId.isEmpty ? const <String>[] : <String>[sourceId];
  }
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
        sourceIds: _asStringList(result['sourceIds']),
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
        'sourceId': preferences.selectedSourceIds.length == 1
            ? preferences.selectedSourceIds.single
            : '',
        'sourceIds': preferences.selectedSourceIds,
        'sourceName': preferences.sourceName,
      });
    } on MissingPluginException {
      return;
    }
  }

  static String _asString(Object? value) => (value?.toString() ?? '').trim();

  static List<String> _asStringList(Object? value) {
    if (value is! Iterable) {
      return const <String>[];
    }
    return value
        .map(_asString)
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
  }
}
