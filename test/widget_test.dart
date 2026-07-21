import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/main.dart';
import 'package:unraider/services/login_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(LoginPreferences.channelName);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') {
        return {
          'rememberMe': false,
          'domain': '',
          'username': 'root',
          'password': '',
          'useHttps': false,
        };
      }
      if (call.method == 'save') {
        return null;
      }
      throw MissingPluginException();
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows the login screen', (tester) async {
    await tester.pumpWidget(const UnraiderApp());
    await tester.pumpAndSettle();

    expect(find.text('服务器地址'), findsOneWidget);
    expect(find.text('用户名'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
  });

  testWidgets('restores remembered login fields', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'load') {
        return {
          'rememberMe': true,
          'domain': 'tower.local',
          'username': 'root',
          'password': 'secret',
          'useHttps': true,
        };
      }
      if (call.method == 'save') {
        return null;
      }
      throw MissingPluginException();
    });

    await tester.pumpWidget(const UnraiderApp());
    await tester.pumpAndSettle();

    final fields =
        tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
    expect(fields[0].controller?.text, 'tower.local');
    expect(fields[1].controller?.text, 'root');
    expect(fields[2].controller?.text, 'secret');
    expect(fields, hasLength(3));
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(find.text('https://'), findsOneWidget);
  });

  test('saves remembered password with login preferences', () async {
    Map<dynamic, dynamic>? savedPayload;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'save') {
        savedPayload = call.arguments as Map<dynamic, dynamic>;
        return null;
      }
      throw MissingPluginException();
    });

    await LoginPreferences.save(
      rememberMe: true,
      domain: 'tower.local',
      username: 'root',
      password: 'secret',
      useHttps: true,
    );

    expect(savedPayload, isNotNull);
    expect(savedPayload?['rememberMe'], isTrue);
    expect(savedPayload?['domain'], 'tower.local');
    expect(savedPayload?['username'], 'root');
    expect(savedPayload?['password'], 'secret');
    expect(savedPayload?['useHttps'], isTrue);
  });
}
