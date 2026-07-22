import 'dart:async';

import 'package:flutter/material.dart';

import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/phone_frame.dart';

class MusicPageArgs {
  const MusicPageArgs({
    required this.unraidClient,
    this.rootPath = '/mnt/user/music',
  });

  final UnraidClient unraidClient;
  final String rootPath;
}

class MusicPage extends StatefulWidget {
  const MusicPage({super.key});

  static const routeName = '/music';

  @override
  State<MusicPage> createState() => _MusicPageState();
}

class _MusicPageState extends State<MusicPage> {
  UnraidClient? _client;
  String _rootPath = '/mnt/user/music';
  List<UnraidFileEntry> _tracks = const <UnraidFileEntry>[];
  bool _loading = true;
  String? _error;
  String _query = '';
  UnraidFileEntry? _currentTrack;

  List<UnraidFileEntry> get _filteredTracks {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return _tracks;
    }
    return _tracks
        .where((track) {
          final album = _albumName(track.path, _rootPath).toLowerCase();
          return track.name.toLowerCase().contains(query) ||
              album.contains(query);
        })
        .toList(growable: false);
  }

  int get _albumCount {
    final albums = <String>{};
    for (final track in _tracks) {
      albums.add(_albumName(track.path, _rootPath));
    }
    return albums.length;
  }

  int get _losslessCount {
    return _tracks.where((track) {
      final lower = track.name.toLowerCase();
      return lower.endsWith('.flac') ||
          lower.endsWith('.wav') ||
          lower.endsWith('.aiff') ||
          lower.endsWith('.alac') ||
          lower.endsWith('.ape');
    }).length;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_client != null) {
      return;
    }
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is MusicPageArgs) {
      _client = args.unraidClient;
      _rootPath = args.rootPath;
      unawaited(_loadTracks());
    } else if (args is UnraidClient) {
      _client = args;
      unawaited(_loadTracks());
    } else {
      setState(() {
        _loading = false;
        _error = '缺少连接参数，请从主页应用入口打开音乐';
      });
    }
  }

  Future<void> _loadTracks() async {
    final client = _client;
    if (client == null) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final roots = _candidateMusicRoots(_rootPath);
      List<UnraidFileEntry> tracks = const <UnraidFileEntry>[];
      var usedRoot = _rootPath;

      for (final root in roots) {
        final found = await client.fetchAudioFiles(root, maxDepth: 8);
        if (found.isNotEmpty) {
          tracks = found;
          usedRoot = root;
          break;
        }
        // Keep the first empty successful scan as the active root.
        if (tracks.isEmpty) {
          usedRoot = root;
        }
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _rootPath = usedRoot;
        _tracks = tracks;
        _currentTrack ??= tracks.isEmpty ? null : tracks.first;
        _loading = false;
        _error = null;
      });
    } on UnraidClientException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '加载音乐库失败：$error';
      });
    }
  }

  void _openTracksPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MusicTracksPage(
          tracks: _tracks,
          rootPath: _rootPath,
          currentTrack: _currentTrack,
          onSelect: (track) {
            setState(() => _currentTrack = track);
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => MusicPlayerPage(
                  track: track,
                  album: _albumName(track.path, _rootPath),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _openPlayer([UnraidFileEntry? track]) {
    final selected = track ?? _currentTrack;
    if (selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('音乐库中暂无歌曲')),
      );
      return;
    }
    setState(() => _currentTrack = selected);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MusicPlayerPage(
          track: selected,
          album: _albumName(selected.path, _rootPath),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _filteredTracks;
    final current = _currentTrack;

    return _MusicScaffold(
      title: '音乐',
      onRefresh: _loadTracks,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MusicSummary(
            songCount: _tracks.length,
            albumCount: _albumCount,
            losslessCount: _losslessCount,
            onSongsTap: _openTracksPage,
          ),
          const SizedBox(height: 18),
          _NowPlayingCard(
            title: current?.name ?? '暂无播放',
            subtitle: current == null
                ? '从下方选择一首歌曲'
                : _albumName(current.path, _rootPath),
            enabled: current != null,
            onTap: () => _openPlayer(),
          ),
          const SizedBox(height: 18),
          _TrackSearchBox(
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 18),
          Text(
            '音乐库 · $_rootPath',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const _MusicLoading(label: '正在扫描 Unraid 音乐库…')
          else if (_error != null)
            _MusicState(
              icon: Icons.library_music_outlined,
              title: '音乐库读取失败',
              detail: _error!,
              actionLabel: '重试',
              onAction: _loadTracks,
            )
          else if (tracks.isEmpty)
            _MusicState(
              icon: Icons.queue_music,
              title: '暂无音频文件',
              detail:
                  '请在 $_rootPath 或其常见子目录中放入 mp3 / flac 等音频文件后刷新。',
              actionLabel: '刷新',
              onAction: _loadTracks,
            )
          else
            for (final track in tracks.take(40))
              _TrackTile(
                track: track,
                album: _albumName(track.path, _rootPath),
                selected: current?.path == track.path,
                onTap: () => _openPlayer(track),
              ),
          if (!_loading && _error == null && tracks.length > 40) ...[
            const SizedBox(height: 8),
            Center(
              child: TextButton(
                onPressed: _openTracksPage,
                child: Text('查看全部 ${tracks.length} 首'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class MusicTracksPage extends StatefulWidget {
  const MusicTracksPage({
    super.key,
    required this.tracks,
    required this.rootPath,
    required this.onSelect,
    this.currentTrack,
  });

  static const routeName = '/music-tracks';

  final List<UnraidFileEntry> tracks;
  final String rootPath;
  final UnraidFileEntry? currentTrack;
  final ValueChanged<UnraidFileEntry> onSelect;

  @override
  State<MusicTracksPage> createState() => _MusicTracksPageState();
}

class _MusicTracksPageState extends State<MusicTracksPage> {
  String _query = '';

  List<UnraidFileEntry> get _filtered {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) {
      return widget.tracks;
    }
    return widget.tracks
        .where((track) {
          final album = _albumName(track.path, widget.rootPath).toLowerCase();
          return track.name.toLowerCase().contains(query) ||
              album.contains(query);
        })
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _filtered;
    return _MusicScaffold(
      title: '歌曲',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TrackSearchBox(
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 18),
          Text(
            '全部歌曲 · ${tracks.length}',
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (tracks.isEmpty)
            const _MusicState(
              icon: Icons.search_off,
              title: '没有匹配的歌曲',
              detail: '试试其他关键词',
            )
          else
            for (final track in tracks)
              _TrackTile(
                track: track,
                album: _albumName(track.path, widget.rootPath),
                selected: widget.currentTrack?.path == track.path,
                onTap: () => widget.onSelect(track),
              ),
        ],
      ),
    );
  }
}

class MusicPlayerPage extends StatelessWidget {
  const MusicPlayerPage({
    super.key,
    required this.track,
    required this.album,
  });

  static const routeName = '/music-player';

  final UnraidFileEntry track;
  final String album;

  @override
  Widget build(BuildContext context) {
    final title = _displayTitle(track.name);
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
                          child: Icon(
                            track.isAudio
                                ? Icons.music_note
                                : Icons.audio_file,
                            color: Colors.white,
                            size: 78,
                          ),
                        ),
                      ),
                    ),
                    Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      album,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.74),
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      track.size.isEmpty ? track.path : '${track.size} · ${track.path}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 26),
                    const _PlayerProgress(),
                    const SizedBox(height: 24),
                    const _PlayerControls(),
                    const SizedBox(height: 18),
                    Text(
                      '当前可通过 Unraid 文件路径浏览该曲目。\n完整流式播放将在后续版本接入。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.58),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
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
    this.onRefresh,
  });

  final String title;
  final Widget child;
  final VoidCallback? onRefresh;

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
                if (onRefresh != null)
                  Positioned(
                    right: 8,
                    top: 0,
                    bottom: 0,
                    child: IconButton(
                      tooltip: '刷新',
                      onPressed: onRefresh,
                      icon: const Icon(Icons.refresh, color: Colors.white),
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

class _MusicSummary extends StatelessWidget {
  const _MusicSummary({
    required this.songCount,
    required this.albumCount,
    required this.losslessCount,
    required this.onSongsTap,
  });

  final int songCount;
  final int albumCount;
  final int losslessCount;
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
          _MusicStat(
            label: '歌曲',
            value: '$songCount',
            onTap: onSongsTap,
          ),
          _MusicStat(label: '专辑', value: '$albumCount'),
          _MusicStat(label: '无损', value: '$losslessCount'),
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
  const _TrackSearchBox({this.onChanged});

  final ValueChanged<String>? onChanged;

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
      child: Row(
        children: [
          const Icon(Icons.search, color: AppTheme.primary, size: 20),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              decoration: const InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: '搜索歌曲、专辑',
                hintStyle: TextStyle(color: AppTheme.textLight, fontSize: 14),
              ),
              style: const TextStyle(color: AppTheme.textDark, fontSize: 14),
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
            value: 0,
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
              '0:00',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.76),
                fontSize: 12,
              ),
            ),
            Text(
              '--:--',
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
            Icons.play_arrow,
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
  const _NowPlayingCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Ink(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: enabled
                  ? const [Color(0xFF3498DB), Color(0xFF52C41A)]
                  : const [Color(0xFF90A4AE), Color(0xFF78909C)],
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
          child: Row(
            children: [
              const Icon(Icons.play_circle_fill, color: Colors.white, size: 42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '正在播放',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.open_in_full, color: Colors.white),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.album,
    required this.onTap,
    this.selected = false,
  });

  final UnraidFileEntry track;
  final String album;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final icon = track.name.toLowerCase().endsWith('.flac') ||
            track.name.toLowerCase().endsWith('.wav')
        ? Icons.high_quality
        : Icons.music_note;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected
            ? AppTheme.primary.withValues(alpha: 0.08)
            : AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected ? AppTheme.primary.withValues(alpha: 0.35) : AppTheme.softLine,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: AppTheme.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _displayTitle(track.name),
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
                        album,
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
                  track.size.isEmpty ? '' : track.size,
                  style: const TextStyle(color: AppTheme.textLight, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MusicLoading extends StatelessWidget {
  const _MusicLoading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label, style: const TextStyle(color: AppTheme.textMedium)),
        ],
      ),
    );
  }
}

class _MusicState extends StatelessWidget {
  const _MusicState({
    required this.icon,
    required this.title,
    required this.detail,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(
        children: [
          Icon(icon, size: 42, color: AppTheme.primary),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textMedium),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

List<String> _candidateMusicRoots(String preferred) {
  final candidates = <String>[
    preferred,
    '/mnt/user/music',
    '/mnt/user/Music',
    '/mnt/user/media/music',
    '/mnt/user/Media/Music',
    '/mnt/user/音频',
    '/mnt/user/音乐',
  ];
  final seen = <String>{};
  return candidates
      .map((path) => path.trim().replaceAll(RegExp(r'/+$'), ''))
      .where((path) => path.isNotEmpty && seen.add(path))
      .toList(growable: false);
}

String _albumName(String path, String rootPath) {
  final normalized = path.replaceAll(r'\', '/');
  final root = rootPath.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  var relative = normalized;
  if (normalized.startsWith('$root/')) {
    relative = normalized.substring(root.length + 1);
  }
  final parts = relative.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length >= 2) {
    return parts[parts.length - 2];
  }
  if (parts.isNotEmpty) {
    return root.split('/').last.isEmpty ? '音乐库' : root.split('/').last;
  }
  return '音乐库';
}

String _displayTitle(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) {
    return fileName;
  }
  return fileName.substring(0, dot);
}
