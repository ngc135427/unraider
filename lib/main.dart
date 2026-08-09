import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:just_audio_background/just_audio_background.dart';

import 'pages/album_page.dart';
import 'pages/detail_page.dart';
import 'pages/login_page.dart';
import 'pages/main_shell_page.dart';
import 'pages/music_page.dart';
import 'pages/register_page.dart';
import 'services/app_logger.dart';
import 'theme/app_theme.dart';
import 'widgets/mini_player_bar.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Keep decoded image memory bounded when scrolling large photo grids.
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.maximumSize = 120;
      imageCache.maximumSizeBytes = 48 << 20; // 48 MB

      if (!kIsWeb) {
        await JustAudioBackground.init(
          androidNotificationChannelId: 'com.ngc.unraider.channel.audio',
          androidNotificationChannelName: '音乐播放',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          preloadArtwork: false,
        );
      }

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

      runApp(const UnraiderApp());
    },
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
      navigatorKey: _rootNavigatorKey,
      title: 'Unraider',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      initialRoute: LoginPage.routeName,
      builder: (context, child) {
        // Global mini player above every route so playback survives navigation.
        return Stack(
          fit: StackFit.expand,
          children: [
            child ?? const SizedBox.shrink(),
            Positioned.fill(
              // MaterialApp.builder places this widget beside the Navigator,
              // so give it an Overlay for IconButton tooltips and other
              // floating Material affordances.
              child: Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (context) => Align(
                      alignment: Alignment.bottomCenter,
                      child: SafeArea(
                        top: false,
                        // Sit above the 58px shell bottom nav; other routes
                        // just get a little extra bottom inset which is fine.
                        child: MiniPlayerBar(
                          navigatorKey: _rootNavigatorKey,
                          bottomOffset: 58,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
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
        DetailPage.routeName: (_) => const DetailPage(),
      },
    );
  }
}
