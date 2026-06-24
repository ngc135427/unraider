import 'package:flutter/services.dart';

class RememberedLogin {
  const RememberedLogin({
    this.rememberMe = false,
    this.domain = '',
    this.username = 'root',
    this.useHttps = false,
  });

  final bool rememberMe;
  final String domain;
  final String username;
  final bool useHttps;
}

class LoginPreferences {
  static const channelName = 'unraider/login_preferences';
  static const _channel = MethodChannel(channelName);

  static Future<RememberedLogin> load() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>('load');
      if (result == null) {
        return const RememberedLogin();
      }

      return RememberedLogin(
        rememberMe: result['rememberMe'] == true,
        domain: _asString(result['domain']),
        username: _asString(result['username']).isEmpty
            ? 'root'
            : _asString(result['username']),
        useHttps: result['useHttps'] == true,
      );
    } on MissingPluginException {
      return const RememberedLogin();
    }
  }

  static Future<void> save({
    required bool rememberMe,
    required String domain,
    required String username,
    required bool useHttps,
  }) async {
    try {
      await _channel.invokeMethod<void>('save', {
        'rememberMe': rememberMe,
        'domain': domain,
        'username': username,
        'useHttps': useHttps,
      });
    } on MissingPluginException {
      return;
    }
  }

  static String _asString(Object? value) {
    final text = value?.toString() ?? '';
    return text.trim();
  }
}
