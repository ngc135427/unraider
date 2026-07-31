import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

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
  }

  static final MusicPlayerService instance = MusicPlayerService._();

  final AudioPlayer player = AudioPlayer();
  final Random _random = Random();
  StreamSubscription<ProcessingState>? _completionSub;
  StreamSubscription<PlayerState>? _playerEventSub;
  bool _sessionReady = false;
  bool _disposed = false;
  int _loadGeneration = 0;

  UnraidClient? _client;
  List<UnraidFileEntry> _queue = const <UnraidFileEntry>[];
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

  UnraidClient? get client => _client;
  List<UnraidFileEntry> get queue => _queue;
  String get rootPath => _rootPath;
  int get index {
    if (_orderPos < 0 || _orderPos >= _order.length) {
      return -1;
    }
    return _order[_orderPos];
  }

  UnraidFileEntry? get current => _current;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasSession => _hasSession;
  bool get canSkip =>
      _queue.length > 1 || _repeat == MusicRepeatMode.all;
  bool get playing => player.playing;
  bool get shuffle => _shuffle;
  MusicRepeatMode get repeatMode => _repeat;

  /// True while at least one full-screen player route is mounted.
  bool get fullPlayerVisible => _fullPlayerDepth > 0;

  String get currentTitle {
    final track = _current;
    if (track == null) {
      return '';
    }
    return displayTitle(track.name);
  }

  String get currentAlbum {
    final track = _current;
    if (track == null) {
      return '';
    }
    return albumLabel(track.path, _rootPath);
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
  }) async {
    await ensureSession();
    _client = client;
    _rootPath = rootPath;
    _queue = List<UnraidFileEntry>.unmodifiable(tracks);
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
    await _loadCurrent(autoplay: autoplay);
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
    await _loadCurrent(autoplay: true);
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
    final currentQueueIndex = index;
    _shuffle = !_shuffle;
    _rebuildOrder(startQueueIndex: currentQueueIndex < 0 ? 0 : currentQueueIndex);
    notifyListeners();
  }

  void cycleRepeatMode() {
    _repeat = switch (_repeat) {
      MusicRepeatMode.off => MusicRepeatMode.all,
      MusicRepeatMode.all => MusicRepeatMode.one,
      MusicRepeatMode.one => MusicRepeatMode.off,
    };
    notifyListeners();
  }

  Future<void> retry() => _loadCurrent(autoplay: true);

  Future<void> stopAndClear() async {
    _loadGeneration += 1;
    _loading = false;
    _error = null;
    _hasSession = false;
    _current = null;
    _orderPos = -1;
    _order = const <int>[];
    _queue = const <UnraidFileEntry>[];
    try {
      await player.stop();
    } on Object {
      // Ignore stop failures while tearing down.
    }
    notifyListeners();
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
    if (client == null || track == null) {
      return;
    }

    final generation = ++_loadGeneration;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      await ensureSession();
      final title = displayTitle(track.name);
      final album = albumLabel(track.path, _rootPath);
      final source = UnraidStreamingAudioSource(
        client: client,
        entry: track,
        tag: MediaItem(
          id: track.path,
          title: title,
          album: album,
          artist: album,
          extras: <String, dynamic>{
            'path': track.path,
            'size': track.size,
          },
        ),
      );
      await player.setAudioSource(source, preload: true);
      if (generation != _loadGeneration) {
        return;
      }
      // Single-track loop is handled in Dart so shuffle/order stay consistent.
      await player.setLoopMode(LoopMode.off);
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
    unawaited(player.dispose());
    super.dispose();
  }
}
