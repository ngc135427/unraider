import 'package:flutter/services.dart';

class VideoStreamConfiguration {
  const VideoStreamConfiguration({
    this.enabled = false,
    this.webDavUrl = '',
    this.unraidPathPrefix = '/mnt/user',
    this.apiToken = '',
  });

  final bool enabled;
  final String webDavUrl;
  final String unraidPathPrefix;
  final String apiToken;
}

class VideoStreamPreferences {
  VideoStreamPreferences._();

  static const channelName = 'unraider/video_stream_preferences';
  static const _channel = MethodChannel(channelName);

  static Future<VideoStreamConfiguration> load() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('load');
      if (result == null) {
        return const VideoStreamConfiguration();
      }
      final url = _asString(result['webDavUrl']);
      final token = _asString(result['apiToken']);
      final prefix = _asString(result['unraidPathPrefix']);
      return VideoStreamConfiguration(
        enabled:
            result['enabled'] == true && url.isNotEmpty && token.isNotEmpty,
        webDavUrl: url,
        unraidPathPrefix: prefix.isEmpty ? '/mnt/user' : prefix,
        apiToken: token,
      );
    } on MissingPluginException {
      return const VideoStreamConfiguration();
    }
  }

  static Future<void> save(VideoStreamConfiguration configuration) async {
    try {
      await _channel.invokeMethod<void>('save', <String, Object>{
        'enabled': configuration.enabled,
        'webDavUrl': configuration.webDavUrl.trim(),
        'unraidPathPrefix': configuration.unraidPathPrefix.trim().isEmpty
            ? '/mnt/user'
            : configuration.unraidPathPrefix.trim(),
        'apiToken': configuration.apiToken.trim(),
      });
    } on MissingPluginException {
      return;
    }
  }

  static String _asString(Object? value) => value?.toString().trim() ?? '';
}
