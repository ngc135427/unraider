import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/video_stream_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(VideoStreamPreferences.channelName);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('loads persisted video stream configuration', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'load');
      return <String, Object>{
        'enabled': true,
        'webDavUrl': 'https://files.example.com/dav/data/',
        'unraidPathPrefix': '/mnt/user',
        'apiToken': 'api-token',
      };
    });

    final configuration = await VideoStreamPreferences.load();
    expect(configuration.enabled, isTrue);
    expect(configuration.webDavUrl, 'https://files.example.com/dav/data/');
    expect(configuration.unraidPathPrefix, '/mnt/user');
    expect(configuration.apiToken, 'api-token');
  });

  test('saves video stream configuration independently', () async {
    Map<dynamic, dynamic>? payload;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'save');
      payload = call.arguments as Map<dynamic, dynamic>;
      return null;
    });

    await VideoStreamPreferences.save(
      const VideoStreamConfiguration(
        enabled: true,
        webDavUrl: 'https://files.example.com/dav/data/',
        unraidPathPrefix: '/mnt/user',
        apiToken: 'api-token',
      ),
    );

    expect(payload?['enabled'], isTrue);
    expect(payload?['webDavUrl'], 'https://files.example.com/dav/data/');
    expect(payload?['unraidPathPrefix'], '/mnt/user');
    expect(payload?['apiToken'], 'api-token');
  });
}
