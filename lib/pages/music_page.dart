import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/phone_frame.dart';

class MusicPage extends StatelessWidget {
  const MusicPage({super.key});

  static const routeName = '/music';

  static const _tracks = [
    _Track('Midnight Drive', 'NAS Library', '3:42', Icons.music_note),
    _Track('Home Server', 'Favorites', '4:18', Icons.album),
    _Track('Backup Melody', 'Recently Added', '2:56', Icons.library_music),
    _Track('Array Lights', 'Media Share', '5:08', Icons.graphic_eq),
  ];

  @override
  Widget build(BuildContext context) {
    return _MusicScaffold(
      title: '音乐',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MusicSummary(
            onSongsTap: () => Navigator.of(context).pushNamed(
              MusicTracksPage.routeName,
            ),
          ),
          const SizedBox(height: 18),
          _NowPlayingCard(
            onTap: () => Navigator.of(context).pushNamed(
              MusicPlayerPage.routeName,
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            '音乐库',
            style: TextStyle(
              color: AppTheme.textDark,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          for (final track in _tracks) _TrackTile(track: track),
        ],
      ),
    );
  }
}

class MusicTracksPage extends StatelessWidget {
  const MusicTracksPage({super.key});

  static const routeName = '/music-tracks';

  @override
  Widget build(BuildContext context) {
    return _MusicScaffold(
      title: '歌曲',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TrackSearchBox(),
          const SizedBox(height: 18),
          const Text(
            '全部歌曲',
            style: TextStyle(
              color: AppTheme.textDark,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          for (final track in MusicPage._tracks) _TrackTile(track: track),
        ],
      ),
    );
  }
}

class MusicPlayerPage extends StatelessWidget {
  const MusicPlayerPage({super.key});

  static const routeName = '/music-player';

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          SizedBox(
            height: 68,
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  top: 10,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: Colors.white),
                    label: const Text(
                      '收起',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 20, 30, 34),
              child: FadeSlide(
                child: Column(
                  children: [
                    Expanded(
                      child: Center(
                        child: Container(
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [Color(0xFF3498DB), Color(0xFF52C41A)],
                            ),
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF3498DB)
                                    .withValues(alpha: 0.28),
                                blurRadius: 28,
                                offset: const Offset(0, 14),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.white,
                            size: 78,
                          ),
                        ),
                      ),
                    ),
                    const Text(
                      'Midnight Drive',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'NAS Library',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.74),
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 26),
                    const _PlayerProgress(),
                    const SizedBox(height: 24),
                    const _PlayerControls(),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MusicScaffold extends StatelessWidget {
  const _MusicScaffold({
    required this.title,
    required this.child,
  });

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          SizedBox(
            height: 48,
            child: Stack(
              children: [
                Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    label: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 112),
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 12, 30, 30),
                child: FadeSlide(
                  child: child,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Track {
  const _Track(this.title, this.album, this.duration, this.icon);

  final String title;
  final String album;
  final String duration;
  final IconData icon;
}

class _MusicSummary extends StatelessWidget {
  const _MusicSummary({required this.onSongsTap});

  final VoidCallback onSongsTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          _MusicStat(label: '歌曲', value: '286', onTap: onSongsTap),
          const _MusicStat(label: '专辑', value: '42'),
          const _MusicStat(label: '无损', value: '96'),
        ],
      ),
    );
  }
}

class _MusicStat extends StatelessWidget {
  const _MusicStat({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(color: AppTheme.textLight, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackSearchBox extends StatelessWidget {
  const _TrackSearchBox();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: const Row(
        children: [
          Icon(Icons.search, color: AppTheme.primary, size: 20),
          SizedBox(width: 9),
          Expanded(
            child: Text(
              '搜索歌曲、专辑',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: AppTheme.textLight, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerProgress extends StatelessWidget {
  const _PlayerProgress();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: 0.38,
            minHeight: 5,
            backgroundColor: Colors.white.withValues(alpha: 0.18),
            valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '1:26',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.76),
                fontSize: 12,
              ),
            ),
            Text(
              '3:42',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.76),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PlayerControls extends StatelessWidget {
  const _PlayerControls();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.skip_previous, color: Colors.white, size: 34),
        ),
        const SizedBox(width: 18),
        Container(
          width: 64,
          height: 64,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.pause,
            color: AppTheme.primary,
            size: 34,
          ),
        ),
        const SizedBox(width: 18),
        IconButton(
          onPressed: () {},
          icon: const Icon(Icons.skip_next, color: Colors.white, size: 34),
        ),
      ],
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF3498DB), Color(0xFF52C41A)],
            ),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF3498DB).withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            children: [
              Icon(Icons.play_circle_fill, color: Colors.white, size: 42),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '正在播放',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Midnight Drive',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.open_in_full, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({required this.track});

  final _Track track;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(track.icon, color: AppTheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textDark,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  track.album,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMedium,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            track.duration,
            style: const TextStyle(color: AppTheme.textLight, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
