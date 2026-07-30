import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'streaming_audio_source.dart';
import 'unraid_client.dart';

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
      if (!_hasSession || _queue.length <= 1 || _loading) {
        return;
      }
      unawaited(skip(1));
    });
    _playerEventSub = player.playerStateStream.listen((_) {
      // Keep mini-player play/pause icons in sync without full rebuild storms.
      notifyListeners();
    });
  }

  static final MusicPlayerService instance = MusicPlayerService._();

  final AudioPlayer player = AudioPlayer();
  StreamSubscription<ProcessingState>? _completionSub;
  StreamSubscription<PlayerState>? _playerEventSub;
  bool _sessionReady = false;
  bool _disposed = false;
  int _loadGeneration = 0;

  UnraidClient? _client;
  List<UnraidFileEntry> _queue = const <UnraidFileEntry>[];
  String _rootPath = '/mnt/user/music';
  int _index = -1;
  UnraidFileEntry? _current;
  bool _loading = false;
  String? _error;
  bool _hasSession = false;
  int _fullPlayerDepth = 0;

  UnraidClient? get client => _client;
  List<UnraidFileEntry> get queue => _queue;
  String get rootPath => _rootPath;
  int get index => _index;
  UnraidFileEntry? get current => _current;
  bool get loading => _loading;
  String? get error => _error;
  bool get hasSession => _hasSession;
  bool get canSkip => _queue.length > 1;
  bool get playing => player.playing;
  /// True while at least one full-screen player route is mounted.
  bool get fullPlayerVisible => _fullPlayerDepth > 0;

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
    var index = _queue.indexWhere((item) => item.path == initial.path);
    if (index < 0) {
      _queue = List<UnraidFileEntry>.unmodifiable(
        <UnraidFileEntry>[initial, ...tracks],
      );
      index = 0;
    }
    _index = index;
    _current = _queue[index];
    _hasSession = true;
    _error = null;
    notifyListeners();
    await _loadCurrent(autoplay: true);
  }

  Future<void> playTrackAt(int index, {bool autoplay = true}) async {
    if (index < 0 || index >= _queue.length) {
      return;
    }
    _index = index;
    _current = _queue[index];
    _error = null;
    notifyListeners();
    await _loadCurrent(autoplay: autoplay);
  }

  Future<void> skip(int delta) async {
    if (_queue.isEmpty) {
      return;
    }
    final next = (_index + delta) % _queue.length;
    final normalized = next < 0 ? next + _queue.length : next;
    await playTrackAt(normalized);
  }

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

  Future<void> retry() => _loadCurrent(autoplay: true);

  Future<void> stopAndClear() async {
    _loadGeneration += 1;
    _loading = false;
    _error = null;
    _hasSession = false;
    _current = null;
    _index = -1;
    _queue = const <UnraidFileEntry>[];
    try {
      await player.stop();
    } on Object {
      // Ignore stop failures while tearing down.
    }
    notifyListeners();
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
      final title = _displayTitle(track.name);
      final album = _albumLabel(track.path, _rootPath);
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

  static String _displayTitle(String fileName) {
    final dot = fileName.lastIndexOf('.');
    if (dot <= 0) {
      return fileName;
    }
    return fileName.substring(0, dot);
  }

  static String _albumLabel(String path, String rootPath) {
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
