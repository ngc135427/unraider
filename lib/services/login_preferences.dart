import 'package:flutter/services.dart';

class RememberedLogin {
  const RememberedLogin({
    this.rememberMe = false,
    this.domain = '',
    this.username = 'root',
    this.password = '',
    this.useHttps = false,
  });

  final bool rememberMe;
  final String domain;
  final String username;
  final String password;
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
        password: _asString(result['password']),
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
    required String password,
    required bool useHttps,
  }) async {
    try {
      // Never persist credentials when "remember me" is off.
      await _channel.invokeMethod<void>('save', {
        'rememberMe': rememberMe,
        'domain': rememberMe ? domain : '',
        'username': rememberMe ? username : 'root',
        'password': rememberMe ? password : '',
        'useHttps': rememberMe ? useHttps : false,
      });
    } on MissingPluginException {
      return;
    }
  }

  /// Explicitly wipe stored login preferences (e.g. logout / clear form).
  static Future<void> clear() {
    return save(
      rememberMe: false,
      domain: '',
      username: 'root',
      password: '',
      useHttps: false,
    );
  }

  static String _asString(Object? value) {
    final text = value?.toString() ?? '';
    return text.trim();
  }
}
