import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../services/music_player_service.dart';
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
const _maxMusicLibraryCacheEntries = 8;

void _storeMusicLibraryCache(String key, _MusicLibraryCacheEntry entry) {
  _musicLibraryCache.remove(key);
  if (_musicLibraryCache.length >= _maxMusicLibraryCacheEntries) {
    _musicLibraryCache.remove(_musicLibraryCache.keys.first);
  }
  _musicLibraryCache[key] = entry;
}

_MusicLibraryCacheEntry? _readMusicLibraryCache(String key) {
  final cached = _musicLibraryCache[key];
  if (cached == null) {
    return null;
  }
  if (DateTime.now().difference(cached.fetchedAt) >= _musicLibraryCacheTtl) {
    _musicLibraryCache.remove(key);
    return null;
  }
  // LRU touch for frequently reopened libraries.
  _musicLibraryCache.remove(key);
  _musicLibraryCache[key] = cached;
  return cached;
}

class _MusicLoadState {
  const _MusicLoadState({
    this.loading = true,
    this.error,
  });

  final bool loading;
  final String? error;

  _MusicLoadState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return _MusicLoadState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

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
  bool _loadingTracks = false;
  int _loadGeneration = 0;
  /// Loading/error strip is isolated so search typing does not rebuild summary.
  final ValueNotifier<_MusicLoadState> _loadState =
      ValueNotifier<_MusicLoadState>(const _MusicLoadState());
  /// Search query is isolated so typing does not rebuild summary/now-playing.
  final ValueNotifier<String> _query = ValueNotifier<String>('');
  Timer? _searchDebounce;
  UnraidFileEntry? _currentTrack;

  // Memoized derived stats so rebuilds from search typing do not rescan the
  // full library for album / lossless counts.
  List<UnraidFileEntry>? _statsTracksRef;
  String? _statsRootRef;
  int _albumCountCached = 0;
  int _losslessCountCached = 0;
  String _filterQueryRef = '';
  List<UnraidFileEntry>? _filterTracksRef;
  String? _filterRootRef;
  List<UnraidFileEntry> _filteredTracksCached = const <UnraidFileEntry>[];
  /// Pre-lowercased name+album haystacks so typing does not re-walk paths.
  List<UnraidFileEntry>? _haystackTracksRef;
  String? _haystackRootRef;
  List<String> _searchHaystacks = const <String>[];

  String get _cacheKey {
    final client = _client;
    if (client == null) {
      return _rootPath;
    }
    return '${client.baseUrl}|$_rootPath';
  }

  void _ensureTrackStats() {
    if (identical(_statsTracksRef, _tracks) && _statsRootRef == _rootPath) {
      return;
    }
    _statsTracksRef = _tracks;
    _statsRootRef = _rootPath;
    final albums = <String>{};
    var lossless = 0;
    for (final track in _tracks) {
      albums.add(_albumName(track.path, _rootPath));
      if (track.isLossless) {
        lossless += 1;
      }
    }
    _albumCountCached = albums.length;
    _losslessCountCached = lossless;
  }

  void _ensureSearchHaystacks() {
    if (identical(_haystackTracksRef, _tracks) &&
        _haystackRootRef == _rootPath) {
      return;
    }
    _haystackTracksRef = _tracks;
    _haystackRootRef = _rootPath;
    _searchHaystacks = [
      for (final track in _tracks)
        '${track.nameLower} ${_albumName(track.path, _rootPath).toLowerCase()}',
    ];
  }

  List<UnraidFileEntry> _filteredTracksFor(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (identical(_filterTracksRef, _tracks) &&
        _filterRootRef == _rootPath &&
        _filterQueryRef == query) {
      return _filteredTracksCached;
    }
    _filterTracksRef = _tracks;
    _filterRootRef = _rootPath;
    _filterQueryRef = query;
    if (query.isEmpty) {
      _filteredTracksCached = _tracks;
      return _filteredTracksCached;
    }
    _ensureSearchHaystacks();
    final filtered = <UnraidFileEntry>[];
    for (var i = 0; i < _tracks.length; i++) {
      if (_searchHaystacks[i].contains(query)) {
        filtered.add(_tracks[i]);
      }
    }
    _filteredTracksCached = filtered;
    return _filteredTracksCached;
  }

  int get _albumCount {
    _ensureTrackStats();
    return _albumCountCached;
  }

  int get _losslessCount {
    _ensureTrackStats();
    return _losslessCountCached;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _loadState.dispose();
    _query.dispose();
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
      _loadState.value = const _MusicLoadState(
        loading: false,
        error: '缺少连接参数，请从主页应用入口打开音乐',
      );
    }
  }

  Future<void> _loadTracks({bool force = false}) async {
    final client = _client;
    if (client == null) {
      return;
    }

    if (!force) {
      final cached = _readMusicLibraryCache(_cacheKey);
      if (cached != null) {
        setState(() {
          _rootPath = cached.rootPath;
          _tracks = cached.tracks;
          _currentTrack ??= cached.tracks.isEmpty ? null : cached.tracks.first;
        });
        _loadState.value = const _MusicLoadState(loading: false);
        return;
      }
      if (_loadingTracks) {
        return;
      }
    }

    final generation = ++_loadGeneration;
    _loadingTracks = true;
    _loadState.value = const _MusicLoadState(loading: true);

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
        if (!mounted || generation != _loadGeneration) {
          return;
        }
        if (found.isNotEmpty) {
          tracks = found;
          usedRoot = root;
          break;
        }
        if (tracks.isEmpty) {
          usedRoot = root;
        }
      }

      if (!mounted || generation != _loadGeneration) {
        return;
      }

      final cacheKey = '${client.baseUrl}|$usedRoot';
      final entry = _MusicLibraryCacheEntry(
        rootPath: usedRoot,
        tracks: tracks,
        fetchedAt: DateTime.now(),
      );
      _storeMusicLibraryCache(cacheKey, entry);
      // Also key by the original requested root so first open hits cache.
      if (cacheKey != _cacheKey) {
        _storeMusicLibraryCache(_cacheKey, entry);
      }

      setState(() {
        _rootPath = usedRoot;
        _tracks = tracks;
        _currentTrack ??= tracks.isEmpty ? null : tracks.first;
      });
      _loadState.value = const _MusicLoadState(loading: false);
    } on UnraidClientException catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      _loadState.value = _MusicLoadState(loading: false, error: error.message);
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      _loadState.value = _MusicLoadState(
        loading: false,
        error: '加载音乐库失败：$error',
      );
    } finally {
      if (generation == _loadGeneration) {
        _loadingTracks = false;
      }
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      _query.value = value;
    });
  }

  void _openTracksPage() {
    final client = _client;
    if (client == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MusicTracksPage(
          tracks: _tracks,
          rootPath: _rootPath,
          currentTrack: _currentTrack,
          onSelect: (track) {
            setState(() => _currentTrack = track);
            unawaited(_playAndOpen(client, track));
          },
        ),
      ),
    );
  }

  Future<void> _playAndOpen(UnraidClient client, UnraidFileEntry track) async {
    await MusicPlayerService.instance.playQueue(
      client: client,
      tracks: _tracks,
      initial: track,
      rootPath: _rootPath,
    );
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => const MusicPlayerPage(),
      ),
    );
  }

  void _openPlayer([UnraidFileEntry? track]) {
    final client = _client;
    final selected = track ??
        _currentTrack ??
        MusicPlayerService.instance.current;
    if (client == null || selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('音乐库中暂无歌曲')),
      );
      return;
    }
    setState(() => _currentTrack = selected);
    // If the same track is already loaded, just open the player sheet.
    final service = MusicPlayerService.instance;
    if (service.hasSession &&
        service.current?.path == selected.path &&
        identical(service.client, client)) {
      unawaited(
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (context) => const MusicPlayerPage(),
          ),
        ),
      );
      return;
    }
    unawaited(_playAndOpen(client, selected));
  }

  @override
  Widget build(BuildContext context) {
    final service = MusicPlayerService.instance;
    final current = service.current ?? _currentTrack;

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
          AnimatedBuilder(
            animation: service,
            builder: (context, _) {
              final playing = service.current ?? current;
              return _NowPlayingCard(
                title: playing?.name ?? '暂无播放',
                subtitle: playing == null
                    ? '从下方选择一首歌曲'
                    : service.loading
                        ? '正在流式缓冲…'
                        : _albumName(playing.path, _rootPath),
                enabled: playing != null,
                onTap: () => _openPlayer(playing),
              );
            },
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
          ValueListenableBuilder<_MusicLoadState>(
            valueListenable: _loadState,
            builder: (context, loadState, _) {
              if (loadState.loading) {
                return const _MusicLoading(label: '正在扫描 Unraid 音乐库…');
              }
              if (loadState.error != null) {
                return _MusicState(
                  icon: Icons.library_music_outlined,
                  title: '音乐库读取失败',
                  detail: loadState.error!,
                  actionLabel: '重试',
                  onAction: () => _loadTracks(force: true),
                );
              }
              return ValueListenableBuilder<String>(
                valueListenable: _query,
                builder: (context, query, __) {
                  final tracks = _filteredTracksFor(query);
                  if (tracks.isEmpty) {
                    return _MusicState(
                      icon: Icons.queue_music,
                      title: query.trim().isEmpty ? '暂无音频文件' : '没有匹配的歌曲',
                      detail: query.trim().isEmpty
                          ? '请在 $_rootPath 或其常见子目录中放入 mp3 / flac 等音频文件后刷新。'
                          : '试试其他关键词',
                      actionLabel: query.trim().isEmpty ? '刷新' : null,
                      onAction: query.trim().isEmpty
                          ? () => _loadTracks(force: true)
                          : null,
                    );
                  }
                  return Column(
                    children: [
                      for (final track in tracks.take(20))
                        RepaintBoundary(
                          key: ValueKey<String>(track.path),
                          child: _TrackTile(
                            track: track,
                            album: _albumName(track.path, _rootPath),
                            selected: current?.path == track.path,
                            onTap: () => _openPlayer(track),
                          ),
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
                  );
                },
              );
            },
          ),
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
  final ValueNotifier<String> _query = ValueNotifier<String>('');
  Timer? _searchDebounce;
  String _filterQueryRef = '';
  List<UnraidFileEntry>? _filterTracksRef;
  String? _filterRootRef;
  List<UnraidFileEntry> _filteredCached = const <UnraidFileEntry>[];
  List<UnraidFileEntry>? _haystackTracksRef;
  String? _haystackRootRef;
  List<String> _searchHaystacks = const <String>[];

  void _ensureSearchHaystacks() {
    if (identical(_haystackTracksRef, widget.tracks) &&
        _haystackRootRef == widget.rootPath) {
      return;
    }
    _haystackTracksRef = widget.tracks;
    _haystackRootRef = widget.rootPath;
    _searchHaystacks = [
      for (final track in widget.tracks)
        '${track.nameLower} ${_albumName(track.path, widget.rootPath).toLowerCase()}',
    ];
  }

  List<UnraidFileEntry> _filteredFor(String rawQuery) {
    final query = rawQuery.trim().toLowerCase();
    if (identical(_filterTracksRef, widget.tracks) &&
        _filterRootRef == widget.rootPath &&
        _filterQueryRef == query) {
      return _filteredCached;
    }
    _filterTracksRef = widget.tracks;
    _filterRootRef = widget.rootPath;
    _filterQueryRef = query;
    if (query.isEmpty) {
      _filteredCached = widget.tracks;
      return _filteredCached;
    }
    _ensureSearchHaystacks();
    final filtered = <UnraidFileEntry>[];
    for (var i = 0; i < widget.tracks.length; i++) {
      if (_searchHaystacks[i].contains(query)) {
        filtered.add(widget.tracks[i]);
      }
    }
    _filteredCached = filtered;
    return _filteredCached;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      _query.value = value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return _MusicScaffold(
      title: '歌曲',
      // Virtualized body: large libraries must not expand inside a
      // SingleChildScrollView or every tile is built up front.
      body: FadeSlide(
        animate: false,
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
                  ValueListenableBuilder<String>(
                    valueListenable: _query,
                    builder: (context, query, _) {
                      final tracks = _filteredFor(query);
                      return Text(
                        '全部歌曲 · ${tracks.length}',
                        style: const TextStyle(
                          color: AppTheme.textDark,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _query,
                builder: (context, query, _) {
                  final tracks = _filteredFor(query);
                  if (tracks.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 30),
                      child: _MusicState(
                        icon: Icons.search_off,
                        title: '没有匹配的歌曲',
                        detail: '试试其他关键词',
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(30, 0, 30, 30),
                    itemCount: tracks.length,
                    itemBuilder: (context, index) {
                      final track = tracks[index];
                      return RepaintBoundary(
                        key: ValueKey<String>(track.path),
                        child: _TrackTile(
                          track: track,
                          album: _albumName(track.path, widget.rootPath),
                          selected: widget.currentTrack?.path == track.path,
                          onTap: () => widget.onSelect(track),
                        ),
                      );
                    },
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

class MusicPlayerPage extends StatefulWidget {
  const MusicPlayerPage({super.key});

  static const routeName = '/music-player';

  @override
  State<MusicPlayerPage> createState() => _MusicPlayerPageState();
}

class _MusicPlayerPageState extends State<MusicPlayerPage> {
  @override
  void initState() {
    super.initState();
    MusicPlayerService.instance.enterFullPlayer();
  }

  @override
  void dispose() {
    MusicPlayerService.instance.leaveFullPlayer();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = MusicPlayerService.instance;
    return PhoneFrame(
      maxContentWidth: 900,
      child: AnimatedBuilder(
        animation: service,
        builder: (context, _) {
          final track = service.current;
          if (track == null) {
            return Column(
              children: [
                _PlayerTopBar(
                  onClose: () => Navigator.of(context).maybePop(),
                ),
                const Expanded(
                  child: Center(
                    child: Text(
                      '当前没有播放会话',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
              ],
            );
          }

          final title = _displayTitle(track.name);
          final album = _albumName(track.path, service.rootPath);
          final canSkip = service.canSkip;
          final loading = service.loading;
          final error = service.error;
          final player = service.player;

          return Column(
            children: [
              _PlayerTopBar(
                onClose: () => Navigator.of(context).maybePop(),
                onQueue: service.queue.length > 1
                    ? () => _showQueueSheet(context, service)
                    : null,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(30, 20, 30, 34),
                  child: FadeSlide(
                    animate: false,
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
                                  colors: [
                                    Color(0xFF3498DB),
                                    Color(0xFF52C41A)
                                  ],
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
                              child: loading
                                  ? const Center(
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                      ),
                                    )
                                  : Icon(
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
                          track.size.isEmpty
                              ? track.path
                              : '${track.size} · ${track.path}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.55),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 26),
                        if (error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Text(
                              error,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Color(0xFFFFCDD2),
                                fontSize: 13,
                                height: 1.35,
                              ),
                            ),
                          )
                        else
                          _PlayerProgress(player: player),
                        const SizedBox(height: 24),
                        _PlayerControls(
                          player: player,
                          enabled: !loading && error == null,
                          canSkip: canSkip,
                          shuffle: service.shuffle,
                          repeatMode: service.repeatMode,
                          onToggleShuffle: service.toggleShuffle,
                          onCycleRepeat: service.cycleRepeatMode,
                          onPrevious: () => unawaited(service.skip(-1)),
                          onNext: () => unawaited(service.skip(1)),
                          onPlayPause: () =>
                              unawaited(service.togglePlayPause()),
                          onRetry: error == null
                              ? null
                              : () => unawaited(service.retry()),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          loading
                              ? '正在按需流式缓冲…'
                              : error != null
                                  ? '流式读取或解码失败，可重试'
                                  : _playerStatusLine(service),
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
          );
        },
      ),
    );
  }

  void _showQueueSheet(BuildContext context, MusicPlayerService service) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF152033),
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return AnimatedBuilder(
          animation: service,
          builder: (context, _) {
            final ordered = service.orderedQueue;
            final currentPath = service.current?.path;
            return SafeArea(
              child: SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.55,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                      child: Text(
                        '播放队列 · ${ordered.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: ordered.length,
                        itemBuilder: (context, i) {
                          final item = ordered[i];
                          final selected = item.path == currentPath;
                          return ListTile(
                            dense: true,
                            selected: selected,
                            selectedTileColor:
                                Colors.white.withValues(alpha: 0.08),
                            leading: Icon(
                              selected
                                  ? Icons.equalizer
                                  : Icons.music_note_outlined,
                              color: selected
                                  ? const Color(0xFF52C41A)
                                  : Colors.white70,
                            ),
                            title: Text(
                              _displayTitle(item.name),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            subtitle: Text(
                              _albumName(item.path, service.rootPath),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54),
                            ),
                            trailing: Text(
                              item.size,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                            onTap: () {
                              final queueIndex = service.queue
                                  .indexWhere((t) => t.path == item.path);
                              if (queueIndex >= 0) {
                                unawaited(
                                  service.playTrackAt(queueIndex),
                                );
                              }
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

String _playerStatusLine(MusicPlayerService service) {
  final mode = switch (service.repeatMode) {
    MusicRepeatMode.off => '顺序',
    MusicRepeatMode.all => '列表循环',
    MusicRepeatMode.one => '单曲循环',
  };
  final shuffle = service.shuffle ? ' · 随机' : '';
  final pos = service.index < 0
      ? ''
      : ' · ${service.index + 1}/${service.queue.length}';
  return '后台常驻 · $mode$shuffle$pos · SFTP/SMB 流式';
}

class _PlayerTopBar extends StatelessWidget {
  const _PlayerTopBar({
    required this.onClose,
    this.onQueue,
  });

  final VoidCallback onClose;
  final VoidCallback? onQueue;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 68,
      child: Stack(
        children: [
          Positioned(
            left: 12,
            top: 10,
            child: TextButton.icon(
              onPressed: onClose,
              icon: const Icon(
                Icons.keyboard_arrow_down,
                color: Colors.white,
              ),
              label: const Text(
                '收起',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ),
          if (onQueue != null)
            Positioned(
              right: 12,
              top: 10,
              child: IconButton(
                tooltip: '播放队列',
                onPressed: onQueue,
                icon: const Icon(Icons.queue_music, color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }
}

