import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'lyrics_service.dart';
import 'media_cache.dart';
import 'streaming_audio_source.dart';
import 'unraid_client.dart';

enum MusicRepeatMode {
  /// Stop after the last track.
  off,

  /// Loop the whole queue.
  all,

  /// Loop the current track.
  one,
}

/// Process-wide music player that outlives individual pages.
///
/// Owns a single [AudioPlayer], queue metadata, and loading state so the mini
/// bar / full-screen player / system notification all share one session.
class MusicPlayerService extends ChangeNotifier {
  MusicPlayerService._() {
    _completionSub = player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) {
        return;
      }
      if (!_hasSession || _loading) {
        return;
      }
      unawaited(_onTrackCompleted());
    });
    _playerEventSub = player.playerStateStream.listen((_) {
      // Keep mini-player play/pause icons in sync without full rebuild storms.
      notifyListeners();
    });
    _sequenceStateSub = player.sequenceStateStream.listen(_syncCurrentSource);
    _playerErrorSub = player.errorStream.listen(_handlePlaybackError);
  }

  static final MusicPlayerService instance = MusicPlayerService._();

  final AudioPlayer player = AudioPlayer();
  final Random _random = Random();
  StreamSubscription<ProcessingState>? _completionSub;
  StreamSubscription<PlayerState>? _playerEventSub;
  StreamSubscription<SequenceState?>? _sequenceStateSub;
  StreamSubscription<PlayerException>? _playerErrorSub;
  bool _sessionReady = false;
  bool _disposed = false;
  int _loadGeneration = 0;

  UnraidClient? _client;
  List<UnraidFileEntry> _queue = const <UnraidFileEntry>[];
  List<UnraidFileEntry> _artworks = const <UnraidFileEntry>[];
  Uri? _defaultArtworkUri;

  /// Playback order indices into [_queue]. Identity order when shuffle is off.
  List<int> _order = const <int>[];
  String _rootPath = '/mnt/user/music';
  int _orderPos = -1;
  UnraidFileEntry? _current;
  bool _loading = false;
  String? _error;
  bool _hasSession = false;
  int _fullPlayerDepth = 0;
  bool _shuffle = false;
  MusicRepeatMode _repeat = MusicRepeatMode.all;
  int _lyricsGeneration = 0;
  LyricsLoadState _lyrics = LyricsLoadState.idle;

  UnraidClient? get client => _client;
  List<UnraidFileEntry> get queue => _queue;
  String get rootPath => _rootPath;
  int get index {
    if (_orderPos < 0 || _orderPos >= _order.length) {
      return -1;
    }
    return _order[_orderPos];
  }

  UnraidFileEntry? get current => _activeQueueTrack ?? _current;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasSession => _hasSession;
  bool get canSkip => _queue.length > 1 || _repeat == MusicRepeatMode.all;
  bool get playing => player.playing;
  bool get shuffle => _shuffle;
  MusicRepeatMode get repeatMode => _repeat;
  LyricsLoadState get lyrics => _lyrics;

  LoopMode get _loopMode => switch (_repeat) {
        MusicRepeatMode.off => LoopMode.off,
        MusicRepeatMode.all => LoopMode.all,
        MusicRepeatMode.one => LoopMode.one,
      };

  /// True while at least one full-screen player route is mounted.
  bool get fullPlayerVisible => _fullPlayerDepth > 0;

  String get currentTitle {
    final track = current;
    if (track == null) {
      return '';
    }
    return displayTitle(track.name);
  }

  String get currentAlbum {
    final track = current;
    if (track == null) {
      return '';
    }
    return albumLabel(track.path, _rootPath);
  }

  /// Resolve the queue entry the audio engine is actually presenting. This
  /// keeps all player surfaces aligned even when source replacement completes
  /// asynchronously after a previous/next action.
  UnraidFileEntry? get _activeQueueTrack {
    if (_loading) {
      return null;
    }
    final tag = player.sequenceState.currentSource?.tag;
    if (tag is! MediaItem) {
      return null;
    }
    final queueIndex = _queue.indexWhere((track) => track.path == tag.id);
    return queueIndex < 0 ? null : _queue[queueIndex];
  }

  void _syncCurrentSource(SequenceState? state) {
    if (_disposed) {
      return;
    }
    final tag = state?.currentSource?.tag;
    if (!_loading && tag is MediaItem) {
      final queueIndex = _queue.indexWhere((track) => track.path == tag.id);
      if (queueIndex >= 0 && _current?.path != tag.id) {
        _current = _queue[queueIndex];
        final playlistIndex = state?.currentIndex;
        if (playlistIndex != null &&
            playlistIndex >= 0 &&
            playlistIndex < _order.length) {
          _orderPos = playlistIndex;
        } else {
          final orderPos = _order.indexOf(queueIndex);
          if (orderPos >= 0) {
            _orderPos = orderPos;
          }
        }
        final client = _client;
        if (client != null) {
          _lyrics = LyricsLoadState.loading;
          unawaited(_loadLyricsFor(client: client, track: _current!));
        }
      }
    }
    notifyListeners();
  }

  void _handlePlaybackError(PlayerException error) {
    if (_disposed || !_hasSession || _loading) {
      return;
    }
    final playlistIndex = error.index;
    if (playlistIndex != null &&
        playlistIndex >= 0 &&
        playlistIndex < _order.length) {
      _orderPos = playlistIndex;
      _current = _queue[_order[playlistIndex]];
    }
    _error = error.message ?? error.code.toString();
    notifyListeners();
    // A queue item may fail only when Android advances to it. Rebuilding with
    // the failed item as the initial source reuses the local-cache fallback.
    unawaited(_loadCurrent(autoplay: true));
  }

  void enterFullPlayer() {
    _fullPlayerDepth += 1;
    notifyListeners();
  }

  void leaveFullPlayer() {
    if (_fullPlayerDepth <= 0) {
      return;
    }
    _fullPlayerDepth -= 1;
    notifyListeners();
  }

  Future<void> ensureSession() async {
    if (_sessionReady || kIsWeb) {
      return;
    }
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    _sessionReady = true;
  }

  /// Start or replace the current queue and begin streaming [initial].
  Future<void> playQueue({
    required UnraidClient client,
    required List<UnraidFileEntry> tracks,
    required UnraidFileEntry initial,
    required String rootPath,
    List<UnraidFileEntry> artworks = const <UnraidFileEntry>[],
  }) async {
    await ensureSession();
    _client = client;
    _rootPath = rootPath;
    _queue = List<UnraidFileEntry>.unmodifiable(tracks);
    _artworks = List<UnraidFileEntry>.unmodifiable(artworks);
    var queueIndex = _queue.indexWhere((item) => item.path == initial.path);
    if (queueIndex < 0) {
      _queue = List<UnraidFileEntry>.unmodifiable(
        <UnraidFileEntry>[initial, ...tracks],
      );
      queueIndex = 0;
    }
    _rebuildOrder(startQueueIndex: queueIndex);
    _current = _queue[queueIndex];
    _hasSession = true;
    _error = null;
    notifyListeners();
    await _loadCurrent(autoplay: true);
  }

  Future<void> playTrackAt(int queueIndex, {bool autoplay = true}) async {
    if (queueIndex < 0 || queueIndex >= _queue.length) {
      return;
    }
    final orderPos = _order.indexOf(queueIndex);
    if (orderPos >= 0) {
      _orderPos = orderPos;
    } else {
      _orderPos = 0;
      _order = <int>[queueIndex, ..._order.where((i) => i != queueIndex)];
    }
    _current = _queue[queueIndex];
    _error = null;
    notifyListeners();
    if (player.sequence.length != _order.length) {
      await _loadCurrent(autoplay: autoplay);
      return;
    }
    await player.seek(Duration.zero, index: _orderPos);
    final client = _client;
    if (client != null) {
      unawaited(_loadLyricsFor(client: client, track: _current!));
    }
    if (autoplay) {
      unawaited(player.play());
    }
  }

  /// Skip relative to the shuffle/order list.
  ///
  /// Pressing previous after 3s restarts the current track (common player UX)
  /// instead of jumping back immediately.
  Future<void> skip(int delta) async {
    if (_queue.isEmpty) {
      return;
    }
    if (_repeat == MusicRepeatMode.one && delta == 0) {
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }
    if (delta < 0 && player.position > const Duration(seconds: 3)) {
      await player.seek(Duration.zero);
      if (!player.playing) {
        unawaited(player.play());
      }
      return;
    }
    if (_order.isEmpty) {
      return;
    }
    if (_order.length == 1) {
      if (_repeat == MusicRepeatMode.off && delta > 0) {
        await player.seek(Duration.zero);
        await player.pause();
        return;
      }
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }
    var next = _orderPos + delta;
    if (next < 0) {
      next = _repeat == MusicRepeatMode.off ? 0 : _order.length - 1;
    } else if (next >= _order.length) {
      if (_repeat == MusicRepeatMode.off) {
        await player.seek(Duration.zero);
        await player.pause();
        return;
      }
      next = 0;
    }
    _orderPos = next;
    _current = _queue[_order[_orderPos]];
    _error = null;
    notifyListeners();
    await player.seek(Duration.zero, index: _orderPos);
    final client = _client;
    if (client != null) {
      unawaited(_loadLyricsFor(client: client, track: _current!));
    }
    if (!player.playing) {
      unawaited(player.play());
    }
  }

  /// Playback-order snapshot for the queue panel (respects shuffle).
  List<UnraidFileEntry> get orderedQueue {
    if (_order.isEmpty) {
      return _queue;
    }
    return [
      for (final i in _order)
        if (i >= 0 && i < _queue.length) _queue[i],
    ];
  }

  int get orderPosition => _orderPos;

  Future<void> togglePlayPause() async {
    if (_loading) {
      return;
    }
    if (_error != null) {
      await retry();
      return;
    }
    if (player.playing) {
      await player.pause();
    } else {
      await player.play();
    }
  }

  void toggleShuffle() {
    final wasPlaying = player.playing;
    final currentQueueIndex = index;
    _shuffle = !_shuffle;
    _rebuildOrder(
        startQueueIndex: currentQueueIndex < 0 ? 0 : currentQueueIndex);
    notifyListeners();
    unawaited(_loadCurrent(autoplay: wasPlaying));
  }

  void cycleRepeatMode() {
    _repeat = switch (_repeat) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    notifyListeners();
    unawaited(player.setLoopMode(_loopMode));
  }

  Future<void> retry() => _loadCurrent(autoplay: true);

  Future<void> stopAndClear() async {
    _loadGeneration += 1;
    _lyricsGeneration += 1;
    _loading = false;
    _error = null;
    _hasSession = false;
    _current = null;
    _orderPos = -1;
    _order = const <int>[];
    _queue = const <UnraidFileEntry>[];
    _artworks = const <UnraidFileEntry>[];
    _lyrics = LyricsLoadState.idle;
    try {
      await player.stop();
    } on Object {
      // Ignore stop failures while tearing down.
    }
    notifyListeners();
  }

  /// Reload sidecar lyrics for the current track (bypasses process cache).
  Future<void> reloadLyrics() async {
    final client = _client;
    final track = _current;
    if (client == null || track == null) {
      return;
    }
    await _loadLyricsFor(client: client, track: track, forceRefresh: true);
  }

  Future<void> _onTrackCompleted() async {
    if (_repeat == MusicRepeatMode.one) {
      await player.seek(Duration.zero);
      unawaited(player.play());
      return;
    }
    if (_queue.length <= 1) {
      if (_repeat == MusicRepeatMode.all) {
        await player.seek(Duration.zero);
        unawaited(player.play());
      }
      return;
    }
    final atEnd = _orderPos >= _order.length - 1;
    if (atEnd && _repeat == MusicRepeatMode.off) {
      await player.seek(Duration.zero);
      await player.pause();
      notifyListeners();
      return;
    }
    await skip(1);
  }

  void _rebuildOrder({required int startQueueIndex}) {
    final n = _queue.length;
    if (n == 0) {
      _order = const <int>[];
      _orderPos = -1;
      return;
    }
    final safeStart = startQueueIndex.clamp(0, n - 1);
    if (!_shuffle) {
      _order = List<int>.generate(n, (i) => i);
      _orderPos = safeStart;
      return;
    }
    final rest = <int>[
      for (var i = 0; i < n; i++)
        if (i != safeStart) i,
    ];
    rest.shuffle(_random);
    _order = <int>[safeStart, ...rest];
    _orderPos = 0;
  }

  Future<void> _loadCurrent({required bool autoplay}) async {
    final client = _client;
    final track = _current;
    if (client == null || track == null || _order.isEmpty) {
      return;
    }

    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    _lyrics = LyricsLoadState.loading;
    notifyListeners();
    // Lyrics load in parallel with audio source setup.
    unawaited(_loadLyricsFor(client: client, track: track));

    try {
      await ensureSession();
      final defaultArtworkUri = await _ensureDefaultArtworkUri();
      final artworkByDirectory = _buildArtworkMap();
      final orderedTracks = orderedQueue;
      final sources = <AudioSource>[
        for (final item in orderedTracks)
          _audioSourceFor(
            client: client,
            entry: item,
            tag: _mediaItemFor(
              client: client,
              track: item,
              artwork: artworkByDirectory[_parentPath(item.path)],
              defaultArtworkUri: defaultArtworkUri,
            ),
          ),
      ];
      try {
        await player.setAudioSources(
          sources,
          initialIndex: _orderPos,
          initialPosition: Duration.zero,
          preload: true,
        );
      } on PlayerException catch (error, stackTrace) {
        // The Android proxy can report a generic source error when a remote
        // range transport fails. Fall back to a complete local cache so the
        // decoder can read a normal file without the proxy in the loop.
        await AppLogger.log(
          'music_stream_source_failed_fallback_to_cache path=${track.path}',
          error: error,
          stackTrace: stackTrace,
        );
        final localFile = await MediaCache.ensureLocalFile(
          client: client,
          remotePath: track.path,
          expectedSizeBytes: track.sizeBytes > 0 ? track.sizeBytes : null,
          fileName: track.name,
        );
        if (generation != _loadGeneration) {
          return;
        }
        sources[_orderPos] = AudioSource.file(
          localFile.path,
          tag: _mediaItemFor(
            client: client,
            track: track,
            artwork: artworkByDirectory[_parentPath(track.path)],
            defaultArtworkUri: defaultArtworkUri,
          ),
        );
        await player.setAudioSources(
          sources,
          initialIndex: _orderPos,
          initialPosition: Duration.zero,
          preload: true,
        );
      }
      if (generation != _loadGeneration) {
        return;
      }
      await player.setLoopMode(_loopMode);
      if (generation != _loadGeneration) {
        return;
      }
      _loading = false;
      _error = null;
      notifyListeners();
      if (autoplay) {
        unawaited(player.play());
      }
    } on Object catch (error) {
      if (generation != _loadGeneration) {
        return;
      }
      _loading = false;
      _error = error.toString();
      notifyListeners();
    }
  }

  AudioSource _audioSourceFor({
    required UnraidClient client,
    required UnraidFileEntry entry,
    required MediaItem tag,
  }) {
    final webDavUri = client.webDavFileUri(entry.path);
    if (webDavUri != null) {
      return AudioSource.uri(
        webDavUri,
        headers: client.webDavHeaders,
        tag: tag,
      );
    }
    return UnraidStreamingAudioSource(
      client: client,
      entry: entry,
      tag: tag,
    );
  }

  MediaItem _mediaItemFor({
    required UnraidClient client,
    required UnraidFileEntry track,
    required UnraidFileEntry? artwork,
    required Uri? defaultArtworkUri,
  }) {
    final album = albumLabel(track.path, _rootPath);
    final webDavArtworkUri =
        artwork == null ? null : client.webDavFileUri(artwork.path);
    return MediaItem(
      id: track.path,
      title: displayTitle(track.name),
      album: album,
      artist: album,
      artUri: artwork == null
          ? defaultArtworkUri
          : webDavArtworkUri ?? client.fileStreamUri(artwork.path),
      artHeaders: artwork == null
          ? null
          : webDavArtworkUri == null
              ? client.sessionHeaders
              : client.webDavHeaders,
      extras: <String, dynamic>{
        'path': track.path,
        'size': track.size,
      },
    );
  }

  Map<String, UnraidFileEntry> _buildArtworkMap() {
    final result = <String, UnraidFileEntry>{};
    final scores = <String, int>{};
    for (final artwork in _artworks) {
      final directory = _parentPath(artwork.path);
      final score = _artworkScore(artwork.name);
      if (!scores.containsKey(directory) || score < scores[directory]!) {
        result[directory] = artwork;
        scores[directory] = score;
      }
    }
    return result;
  }

  static int _artworkScore(String fileName) {
    final base = fileName.toLowerCase().replaceFirst(RegExp(r'\.[^.]+$'), '');
    const preferred = <String>['cover', 'folder', 'front', 'album'];
    final exact = preferred.indexOf(base);
    if (exact >= 0) {
      return exact;
    }
    for (var i = 0; i < preferred.length; i++) {
      if (base.contains(preferred[i])) {
        return 10 + i;
      }
    }
    return 100;
  }

  static String _parentPath(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final slash = normalized.lastIndexOf('/');
    return slash <= 0 ? '/' : normalized.substring(0, slash);
  }

  Future<Uri?> _ensureDefaultArtworkUri() async {
    if (kIsWeb) {
      return null;
    }
    final cached = _defaultArtworkUri;
    if (cached != null) {
      return cached;
    }
    try {
      final directory = await getApplicationSupportDirectory();
      final file = File('${directory.path}/music_notification_cover.png');
      if (!await file.exists()) {
        final data = await rootBundle.load(
          'assets/images/music_notification_cover.png',
        );
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      return _defaultArtworkUri = Uri.file(file.path);
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'music_default_artwork_prepare_failed',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  Future<void> _loadLyricsFor({
    required UnraidClient client,
    required UnraidFileEntry track,
    bool forceRefresh = false,
  }) async {
    final generation = ++_lyricsGeneration;
    if (_lyrics.status != LyricsLoadStatus.loading) {
      _lyrics = LyricsLoadState.loading;
      notifyListeners();
    }
    final result = await LyricsService.loadForTrack(
      client: client,
      track: track,
      forceRefresh: forceRefresh,
    );
    if (_disposed || generation != _lyricsGeneration) {
      return;
    }
    // Ignore stale results if the user already skipped to another track.
    if (_current?.path != track.path) {
      return;
    }
    _lyrics = result;
    notifyListeners();
  }

  static String displayTitle(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) {
      return fileName;
    }
    return fileName.substring(0, dot);
  }

  static String albumLabel(String path, String rootPath) {
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
      final rootName = root.split('/').last;
      return rootName.isEmpty ? '音乐库' : rootName;
    }
    return '音乐库';
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    unawaited(_completionSub?.cancel() ?? Future<void>.value());
    unawaited(_playerEventSub?.cancel() ?? Future<void>.value());
    unawaited(_sequenceStateSub?.cancel() ?? Future<void>.value());
    unawaited(_playerErrorSub?.cancel() ?? Future<void>.value());
    unawaited(player.dispose());
    super.dispose();
  }
}
