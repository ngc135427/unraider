import 'package:flutter/material.dart';

import 'pages/album_page.dart';
import 'pages/detail_page.dart';
import 'pages/login_page.dart';
import 'pages/main_shell_page.dart';
import 'pages/music_page.dart';
import 'pages/register_page.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const UnraiderApp());
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
