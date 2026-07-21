import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'pages/album_page.dart';
import 'pages/detail_page.dart';
import 'pages/login_page.dart';
import 'pages/main_shell_page.dart';
import 'pages/music_page.dart';
import 'pages/register_page.dart';
import 'services/app_logger.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.initialize();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      AppLogger.log(
        'flutter_error',
        error: details.exception,
        stackTrace: details.stack,
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      AppLogger.log(
        'platform_error',
        error: error,
        stackTrace: stackTrace,
      ),
    );
    return true;
  };

  runZonedGuarded(
    () => runApp(const UnraiderApp()),
    (error, stackTrace) {
      unawaited(
        AppLogger.log(
          'zone_error',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    },
  );
}

class UnraiderApp extends StatelessWidget {
  const UnraiderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Unraider',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      initialRoute: LoginPage.routeName,
      routes: {
        LoginPage.routeName: (_) => const LoginPage(),
        RegisterPage.routeName: (_) => const RegisterPage(),
        MainShellPage.routeName: (_) => const MainShellPage(),
        ManagementDetailPage.routeName: (_) => const ManagementDetailPage(),
        AlbumPage.routeName: (_) => const AlbumPage(),
        AlbumGroupsPage.routeName: (_) => const AlbumGroupsPage(),
        AlbumVideosPage.routeName: (_) => const AlbumVideosPage(),
        AlbumBackupPage.routeName: (_) => const AlbumBackupPage(),
        MusicPage.routeName: (_) => const MusicPage(),
        MusicTracksPage.routeName: (_) => const MusicTracksPage(),
        MusicPlayerPage.routeName: (_) => const MusicPlayerPage(),
        DetailPage.routeName: (_) => const DetailPage(),
      },
    );
  }
}
