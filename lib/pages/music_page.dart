import 'dart:async';

import 'package:flutter/material.dart';

import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/phone_frame.dart';

part 'music_widgets.dart';
part 'music_utils.dart';

/// Process-local music library cache so reopening the page avoids rescans.
class _MusicLibraryCacheEntry {
  const _MusicLibraryCacheEntry({
    required this.rootPath,
    required this.tracks,
    required this.fetchedAt,
  });

  final String rootPath;
  final List<UnraidFileEntry> tracks;
  final DateTime fetchedAt;
}

final Map<String, _MusicLibraryCacheEntry> _musicLibraryCache =
    <String, _MusicLibraryCacheEntry>{};
const _musicLibraryCacheTtl = Duration(minutes: 3);

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
  Timer? _searchDebounce;
  UnraidFileEntry? _currentTrack;

  String get _cacheKey {
    final client = _client;
    if (client == null) {
      return _rootPath;
    }
    return '${client.baseUrl}|$_rootPath';
  }

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
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
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

  Future<void> _loadTracks({bool force = false}) async {
    final client = _client;
    if (client == null) {
      return;
    }

    if (!force) {
      final cached = _musicLibraryCache[_cacheKey];
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < _musicLibraryCacheTtl) {
        setState(() {
          _rootPath = cached.rootPath;
          _tracks = cached.tracks;
          _currentTrack ??= cached.tracks.isEmpty ? null : cached.tracks.first;
          _loading = false;
          _error = null;
        });
        return;
      }
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final roots = _candidateMusicRoots(_rootPath);
      List<UnraidFileEntry> tracks = const <UnraidFileEntry>[];
      var usedRoot = _rootPath;

      // Prefer the configured root first; only fall through to candidates when
      // the preferred root is empty so reopen/refresh stay predictable.
      for (var i = 0; i < roots.length; i++) {
        final root = roots[i];
        final found = await client.fetchMediaFiles(
          root,
          maxDepth: 8,
          includeImages: false,
          includeVideos: false,
          includeAudio: true,
          // Only force-refresh the preferred root; candidate fallthroughs can
          // reuse the short media-scan cache.
          forceRefresh: force && i == 0,
        );
        if (found.isNotEmpty) {
          tracks = found;
          usedRoot = root;
          break;
        }
        if (tracks.isEmpty) {
          usedRoot = root;
        }
      }

      if (!mounted) {
        return;
      }

      final cacheKey = '${client.baseUrl}|$usedRoot';
      _musicLibraryCache[cacheKey] = _MusicLibraryCacheEntry(
        rootPath: usedRoot,
        tracks: tracks,
        fetchedAt: DateTime.now(),
      );
      // Also key by the original requested root so first open hits cache.
      _musicLibraryCache[_cacheKey] = _musicLibraryCache[cacheKey]!;

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
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = '加载音乐库失败：$error';
      });
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      setState(() => _query = value);
    });
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
      onRefresh: () => _loadTracks(force: true),
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
            onChanged: _onSearchChanged,
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
              onAction: () => _loadTracks(force: true),
            )
          else if (tracks.isEmpty)
            _MusicState(
              icon: Icons.queue_music,
              title: '暂无音频文件',
              detail:
                  '请在 $_rootPath 或其常见子目录中放入 mp3 / flac 等音频文件后刷新。',
              actionLabel: '刷新',
              onAction: () => _loadTracks(force: true),
            )
          else ...[
            for (final track in tracks.take(20))
              _TrackTile(
                track: track,
                album: _albumName(track.path, _rootPath),
                selected: current?.path == track.path,
                onTap: () => _openPlayer(track),
              ),
            if (tracks.length > 20) ...[
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _openTracksPage,
                  child: Text('查看全部 ${tracks.length} 首'),
                ),
              ),
            ],
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
  Timer? _searchDebounce;

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
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tracks = _filtered;
    return _MusicScaffold(
      title: '歌曲',
      // Virtualized body: large libraries must not expand inside a
      // SingleChildScrollView or every tile is built up front.
      body: FadeSlide(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 12, 30, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TrackSearchBox(
                    onChanged: _onSearchChanged,
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
                ],
              ),
            ),
            Expanded(
              child: tracks.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 30),
                      child: _MusicState(
                        icon: Icons.search_off,
                        title: '没有匹配的歌曲',
                        detail: '试试其他关键词',
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(30, 0, 30, 30),
                      itemCount: tracks.length,
                      itemBuilder: (context, index) {
                        final track = tracks[index];
                        return _TrackTile(
                          track: track,
                          album: _albumName(track.path, widget.rootPath),
                          selected:
                              widget.currentTrack?.path == track.path,
                          onTap: () => widget.onSelect(track),
                        );
                      },
                    ),
            ),
          ],
        ),
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

