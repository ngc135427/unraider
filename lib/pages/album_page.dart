import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';

import '../services/album_backup_discovery.dart';
import '../services/album_backup_models.dart';
import '../services/album_backup_path.dart';
import '../services/album_backup_repository.dart';
import '../services/album_background_service.dart';
import '../services/album_management_service.dart';
import '../services/album_transfer_engine.dart';
import '../services/album_preferences.dart';
import '../services/album_preview_cache.dart';
import '../services/app_logger.dart';
import '../services/local_media_store.dart';
import '../services/media_cache.dart';
import '../services/remote_video_stream.dart';
import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/phone_frame.dart';
import '../widgets/video_playback_controls.dart';
import '../widgets/video_wake_lock.dart';

part 'album_widgets.dart';
part 'album_utils.dart';

const _maxAlbumFullscreenDecodeExtent = 2400;
const _maxAlbumTileDecodeExtent = 480;

// Compile-time rollback switches. Keep the legacy page path usable while the
// persistent index, multi-source selection, and legacy import mature.
const _albumPersistentIndexEnabled = true;
const _albumMultiSourceSelectionEnabled = true;
const _albumLegacyImportEnabled = true;

/// Cap tiles per day-section so a huge day does not expand the outer ListView.
const _maxAlbumSectionTiles = 60;

/// Process-local cache for local fullscreen image files (uri -> File).
final Map<String, Future<File>> _localFullscreenFileCache =
    <String, Future<File>>{};
const _maxLocalFullscreenCacheEntries = 12;

/// Process-local cache for remote fullscreen image files (path -> File).
final Map<String, Future<File>> _remoteFullscreenFileCache =
    <String, Future<File>>{};
const _maxRemoteFullscreenCacheEntries = 12;

final AlbumPreviewCache _albumPreviewCache = AlbumPreviewCache();

class AlbumPageArgs {
  const AlbumPageArgs({
    required this.unraidClient,
    required this.rootPath,
  });

  final UnraidClient unraidClient;
  final String rootPath;
}

class AlbumPage extends StatelessWidget {
  const AlbumPage({super.key});

  static const routeName = '/album';

  @override
  Widget build(BuildContext context) {
    return const _PhoAlbumShell(initialTab: _PhoAlbumTab.local);
  }
}

class AlbumGroupsPage extends StatelessWidget {
  const AlbumGroupsPage({super.key});

  static const routeName = '/album-groups';

  @override
  Widget build(BuildContext context) {
    return const _PhoAlbumShell(initialTab: _PhoAlbumTab.remote);
  }
}

class AlbumVideosPage extends StatelessWidget {
  const AlbumVideosPage({super.key});

  static const routeName = '/album-videos';

  @override
  Widget build(BuildContext context) {
    return const _PhoAlbumShell(
      initialTab: _PhoAlbumTab.local,
      videosOnly: true,
    );
  }
}

class AlbumBackupPage extends StatelessWidget {
  const AlbumBackupPage({super.key});

  static const routeName = '/album-backup';

  @override
  Widget build(BuildContext context) {
    return const _PhoAlbumShell(initialTab: _PhoAlbumTab.sync);
  }
}

enum _PhoAlbumTab { local, remote, sync, manage, settings }

class _AlbumFailedItem {
  const _AlbumFailedItem({
    required this.assetId,
    required this.name,
    required this.error,
  });

  final String assetId;
  final String name;
  final String error;
}

class _AlbumSyncProgress {
  const _AlbumSyncProgress({
    this.syncing = false,
    this.uploadedCount = 0,
    this.pendingCount = 0,
    this.message,
  });

  final bool syncing;
  final int uploadedCount;
  final int pendingCount;
  final String? message;

  _AlbumSyncProgress copyWith({
    bool? syncing,
    int? uploadedCount,
    int? pendingCount,
    String? message,
  }) {
    return _AlbumSyncProgress(
      syncing: syncing ?? this.syncing,
      uploadedCount: uploadedCount ?? this.uploadedCount,
      pendingCount: pendingCount ?? this.pendingCount,
      message: message ?? this.message,
    );
  }
}

class _AlbumPaneState {
  const _AlbumPaneState({
    this.loading = true,
    this.error,
  });

  final bool loading;
  final String? error;

  _AlbumPaneState copyWith({
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return _AlbumPaneState(
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class _PhoAlbumShell extends StatefulWidget {
  const _PhoAlbumShell({
    required this.initialTab,
    this.videosOnly = false,
  });

  final _PhoAlbumTab initialTab;
  final bool videosOnly;

  @override
  State<_PhoAlbumShell> createState() => _PhoAlbumShellState();
}

class _PhoAlbumShellState extends State<_PhoAlbumShell> {
  late final ValueNotifier<_PhoAlbumTab> _tab =
      ValueNotifier<_PhoAlbumTab>(widget.initialTab);
  AlbumBackupPreferences _preferences = const AlbumBackupPreferences();
  AlbumBackgroundStatus _backgroundStatus = AlbumBackgroundStatus.fromMap(null);
  Timer? _backgroundStatusTimer;
  List<LocalMediaAsset> _localMedia = const <LocalMediaAsset>[];
  List<UnraidFileEntry> _remoteMedia = const <UnraidFileEntry>[];
  int _remoteMediaCount = 0;
  static const _remotePageSize = 240;
  int _remotePageOffset = 0;
  bool _remoteHasMore = false;
  bool _remoteLoadingMore = false;
  List<LocalMediaBucket> _buckets = const <LocalMediaBucket>[];

  /// Only build tab bodies after first visit so remote thumbnails are not
  /// downloaded while the user is still on the local tab.
  late final Set<_PhoAlbumTab> _visitedTabs = <_PhoAlbumTab>{widget.initialTab};

  /// Bumped when a lazy album tab is first visited.
  final ValueNotifier<int> _visitedTabsVersion = ValueNotifier<int>(0);
  bool _loadingAll = false;
  int _loadGeneration = 0;

  /// Local/remote loading banners are isolated so one side finishing does not
  /// rebuild the other timeline body.
  final ValueNotifier<_AlbumPaneState> _localState =
      ValueNotifier<_AlbumPaneState>(const _AlbumPaneState());
  final ValueNotifier<_AlbumPaneState> _remoteState =
      ValueNotifier<_AlbumPaneState>(const _AlbumPaneState());

  /// Sync progress is published separately so per-file updates do not rebuild
  /// the local/remote timeline tabs.
  final ValueNotifier<_AlbumSyncProgress> _syncProgress =
      ValueNotifier<_AlbumSyncProgress>(const _AlbumSyncProgress());
  AlbumBackupRepository? _backupRepository;
  bool _backupIndexReady = false;
  Set<String> _indexedPendingAssetIds = <String>{};
  Map<String, AlbumBackupRecord> _indexedRecordsByAsset =
      <String, AlbumBackupRecord>{};

  // Memoized visible-media projection for stats + tab bodies.
  List<LocalMediaAsset>? _visibleSourceRef;
  List<String>? _visibleSourceIdsRef;
  bool? _visibleVideosOnlyRef;
  List<LocalMediaAsset> _visibleLocalCached = const <LocalMediaAsset>[];
  int _visiblePhotoCount = 0;
  int _visibleVideoCount = 0;

  // Memoized pending-upload projection for stats + sync batch selection.
  List<LocalMediaAsset>? _pendingLocalRef;
  List<UnraidFileEntry>? _pendingRemoteRef;
  String? _pendingTargetRef;
  List<String>? _pendingSourceIdsRef;
  List<LocalMediaAsset> _pendingUploadsCached = const <LocalMediaAsset>[];

  AlbumPageArgs? get _args {
    final args = ModalRoute.of(context)?.settings.arguments;
    return args is AlbumPageArgs ? args : null;
  }

  UnraidClient? get _client => _args?.unraidClient;

  List<LocalMediaAsset> get _visibleLocalMedia {
    _ensureVisibleLocalMedia();
    return _visibleLocalCached;
  }

  void _ensureVisibleLocalMedia() {
    final sourceIds = _preferences.selectedSourceIds;
    if (identical(_visibleSourceRef, _localMedia) &&
        _listEquals(_visibleSourceIdsRef, sourceIds) &&
        _visibleVideosOnlyRef == widget.videosOnly) {
      return;
    }
    _visibleSourceRef = _localMedia;
    _visibleSourceIdsRef = List<String>.from(sourceIds);
    _visibleVideosOnlyRef = widget.videosOnly;

    final filtered = sourceIds.isEmpty
        ? _localMedia
        : _localMedia
            .where((asset) => sourceIds.contains(asset.bucketId))
            .toList(growable: false);
    final visible = widget.videosOnly
        ? filtered.where((asset) => asset.isVideo).toList(growable: false)
        : filtered;
    _visibleLocalCached = visible;
    var photos = 0;
    var videos = 0;
    for (final asset in visible) {
      if (asset.isVideo) {
        videos += 1;
      } else {
        photos += 1;
      }
    }
    _visiblePhotoCount = photos;
    _visibleVideoCount = videos;
  }

  bool _listEquals(List<String>? a, List<String> b) {
    if (a == null || a.length != b.length) {
      return false;
    }
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  @override
  void dispose() {
    final repository = _backupRepository;
    if (repository != null) {
      unawaited(repository.close());
    }
    _tab.dispose();
    _visitedTabsVersion.dispose();
    _localState.dispose();
    _remoteState.dispose();
    _syncProgress.dispose();
    _backgroundStatusTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAll({bool runAutoSync = true}) async {
    final args = _args;
    if (args == null) {
      _localState.value = const _AlbumPaneState(
        loading: false,
        error: '缺少连接参数，请从主页应用入口打开相册',
      );
      _remoteState.value = const _AlbumPaneState(loading: false);
      return;
    }

    // Auto-sync re-entry should not cancel an in-flight full load by bumping
    // generation and then bailing — only start a new generation when we work.
    if (_loadingAll && runAutoSync) {
      return;
    }
    final generation = ++_loadGeneration;
    _loadingAll = true;

    _localState.value = const _AlbumPaneState(loading: true);
    _remoteState.value = const _AlbumPaneState(loading: true);

    try {
      final preferences = await AlbumPreferences.load();
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() => _preferences = preferences);
      await AlbumBackgroundService.configure(
        client: args.unraidClient,
        preferences: preferences,
      );
      final backgroundStatus = await AlbumBackgroundService.status();
      if (mounted && generation == _loadGeneration) {
        setState(() => _backgroundStatus = backgroundStatus);
      }

      await _ensureBackupRepository();
      await _backupRepository?.requeueInterruptedForeground(
        destinationId: albumDestinationId(preferences.targetDir),
        activeLeasePrefix: _foregroundLeasePrefix,
      );

      // Manual refresh (runAutoSync: false) should bypass short caches.
      final forceRefresh = !runAutoSync;
      if (forceRefresh) {
        LocalMediaStore.invalidateCaches();
      }

      // Load local and remote independently so one side failing does not blank
      // the entire album page.
      await Future.wait<void>([
        _loadLocalMedia(generation: generation),
        _loadRemoteMedia(
          client: args.unraidClient,
          targetDir: preferences.targetDir,
          generation: generation,
          forceRefresh: forceRefresh,
        ),
      ]);

      await _adoptLegacyBackupMatches();

      if (!mounted || generation != _loadGeneration) {
        return;
      }
      final pending = _countPendingUploads();
      final current = _syncProgress.value;
      _syncProgress.value = current.copyWith(pendingCount: pending);

      if (preferences.autoBackup &&
          runAutoSync &&
          _localState.value.error == null) {
        unawaited(_syncPending());
      }
    } finally {
      if (generation == _loadGeneration) {
        _loadingAll = false;
      }
    }
  }

  Future<void> _loadLocalMedia({required int generation}) async {
    try {
      final permissionsGranted = await _requestMediaAccess();
      if (!permissionsGranted) {
        if (!mounted || generation != _loadGeneration) {
          return;
        }
        setState(() {
          _localMedia = const <LocalMediaAsset>[];
          _buckets = const <LocalMediaBucket>[];
        });
        _localState.value = const _AlbumPaneState(
          loading: false,
          error: '需要照片和视频权限。请在系统设置中允许访问相册后重试。',
        );
        return;
      }

      final fullScan = await _hasCompleteMediaAccess();
      final results = await Future.wait<Object>([
        LocalMediaStore.listMedia(),
        LocalMediaStore.listBuckets(),
      ]);
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _localMedia = results[0] as List<LocalMediaAsset>;
        _buckets = results[1] as List<LocalMediaBucket>;
      });
      await _reconcileBackupIndex(fullScan: fullScan);
      _localState.value = const _AlbumPaneState(loading: false);
    } on LocalMediaException catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _localMedia = const <LocalMediaAsset>[];
        _buckets = const <LocalMediaBucket>[];
      });
      _localState.value = _AlbumPaneState(loading: false, error: error.message);
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _localMedia = const <LocalMediaAsset>[];
        _buckets = const <LocalMediaBucket>[];
      });
      _localState.value = _AlbumPaneState(
        loading: false,
        error: '本机相册加载失败：$error',
      );
    }
  }

  Future<void> _loadRemoteMedia({
    required UnraidClient client,
    required String targetDir,
    required int generation,
    bool forceRefresh = false,
  }) async {
    try {
      final remote = await client.fetchMediaFiles(
        targetDir,
        maxDepth: 6,
        includeImages: true,
        includeVideos: true,
        includeAudio: false,
        forceRefresh: forceRefresh,
      );
      await _indexRemoteMedia(remote);
      final page = _backupRepository == null
          ? remote.take(_remotePageSize).toList(growable: false)
          : await _readRemotePage(offset: 0);
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _remoteMedia = page;
        _remoteMediaCount = remote.where((entry) => !entry.isDirectory).length;
        _remotePageOffset = page.length;
        _remoteHasMore = page.length == _remotePageSize;
      });
      _remoteState.value = const _AlbumPaneState(loading: false);
    } on UnraidClientException catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _remoteMedia = const <UnraidFileEntry>[];
        _remoteMediaCount = 0;
      });
      _remoteState.value = _AlbumPaneState(
        loading: false,
        error: error.message,
      );
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _remoteMedia = const <UnraidFileEntry>[];
        _remoteMediaCount = 0;
      });
      _remoteState.value = _AlbumPaneState(
        loading: false,
        error: '云端读取失败：$error',
      );
    }
  }

  Future<void> _reloadRemote() async {
    final client = _client;
    if (client == null) {
      return;
    }
    final generation = ++_loadGeneration;
    _remoteState.value = const _AlbumPaneState(loading: true);
    await _loadRemoteMedia(
      client: client,
      targetDir: _preferences.targetDir,
      generation: generation,
      forceRefresh: true,
    );
    if (!mounted || generation != _loadGeneration) {
      return;
    }
    final pending = _countPendingUploads();
    final current = _syncProgress.value;
    _syncProgress.value = current.copyWith(pendingCount: pending);
  }

  Future<List<UnraidFileEntry>> _readRemotePage({required int offset}) async {
    final repository = _backupRepository;
    if (repository == null) {
      return offset == 0
          ? _remoteMedia.take(_remotePageSize).toList(growable: false)
          : const <UnraidFileEntry>[];
    }
    final rows = await repository.listRemotePage(
      destinationId: albumDestinationId(_preferences.targetDir),
      limit: _remotePageSize,
      offset: offset,
    );
    return rows
        .map(
          (asset) => UnraidFileEntry(
            name: asset.displayName,
            path: asset.path,
            isDirectory: false,
            sizeBytes: asset.sizeBytes,
            size: _formatBytes(asset.sizeBytes),
            modified: asset.modifiedMs <= 0
                ? ''
                : DateTime.fromMillisecondsSinceEpoch(asset.modifiedMs)
                    .toLocal()
                    .toString(),
            modifiedDate: asset.modifiedMs <= 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(asset.modifiedMs),
            durationMs: asset.durationMs,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _loadMoreRemote() async {
    if (!_remoteHasMore || _remoteLoadingMore) return;
    _remoteLoadingMore = true;
    try {
      final page = await _readRemotePage(offset: _remotePageOffset);
      if (!mounted) return;
      setState(() {
        _remoteMedia = <UnraidFileEntry>[..._remoteMedia, ...page];
        _remotePageOffset += page.length;
        _remoteHasMore = page.length == _remotePageSize;
      });
    } finally {
      _remoteLoadingMore = false;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  List<LocalMediaAsset> get _pendingUploads {
    if (_backupIndexReady) {
      return _localMedia
          .where((asset) => _indexedPendingAssetIds.contains(asset.id))
          .toList(growable: false);
    }
    final sourceIds = _preferences.selectedSourceIds;
    if (identical(_pendingLocalRef, _localMedia) &&
        identical(_pendingRemoteRef, _remoteMedia) &&
        _pendingTargetRef == _preferences.targetDir &&
        _listEquals(_pendingSourceIdsRef, sourceIds)) {
      return _pendingUploadsCached;
    }
    _pendingLocalRef = _localMedia;
    _pendingRemoteRef = _remoteMedia;
    _pendingTargetRef = _preferences.targetDir;
    _pendingSourceIdsRef = List<String>.from(sourceIds);
    _pendingUploadsCached = _findPendingUploads(
      local: _localMedia,
      remote: _remoteMedia,
      targetDir: _preferences.targetDir,
      sourceIds: sourceIds,
    );
    return _pendingUploadsCached;
  }

  int _countPendingUploads() => _pendingUploads.length;

  int _syncGeneration = 0;
  static final String _foregroundLeasePrefix =
      'foreground-${DateTime.now().microsecondsSinceEpoch}-';
  bool _syncCancelRequested = false;
  AlbumTransferEngine? _activeTransferEngine;
  bool _syncPaused = false;

  void _cancelSync() {
    if (!_syncProgress.value.syncing) {
      return;
    }
    _syncCancelRequested = true;
    _syncPaused = false;
    _activeTransferEngine?.cancel();
    _syncProgress.value = _syncProgress.value.copyWith(
      message: '正在取消…',
    );
  }

  void _toggleSyncPause() {
    final engine = _activeTransferEngine;
    if (engine == null) return;
    setState(() => _syncPaused = !_syncPaused);
    if (_syncPaused) {
      engine.pause();
      _syncProgress.value =
          _syncProgress.value.copyWith(message: '已暂停；当前文件完成后停止领取新任务');
    } else {
      engine.resume();
      _syncProgress.value = _syncProgress.value.copyWith(message: '正在继续备份…');
    }
  }

  Future<void> _syncPending({bool forceRetry = false}) async {
    final client = _client;
    final repository = _backupRepository;
    if (client == null || repository == null || _syncProgress.value.syncing) {
      return;
    }

    final generation = ++_syncGeneration;
    _syncCancelRequested = false;
    _syncPaused = false;
    _syncProgress.value = _AlbumSyncProgress(
      syncing: true,
      uploadedCount: 0,
      pendingCount: _countPendingUploads(),
      message: '正在领取持久队列',
    );

    try {
      final destinationId = albumDestinationId(_preferences.targetDir);
      await repository.requeueInterruptedForeground(
        destinationId: destinationId,
        activeLeasePrefix: _foregroundLeasePrefix,
      );
      if (forceRetry) {
        await repository.requeueRetryable(destinationId: destinationId);
      }
      final assets = <String, LocalMediaAsset>{
        for (final asset in _localMedia) asset.id: asset,
      };
      final initialPending = _countPendingUploads();
      final processedAssetIds = <String>{};
      var completed = 0;
      var failed = 0;
      var batch = 0;
      var sawJobs = false;
      var cancelled = false;
      String? fallbackNotice;
      String? shownFallbackNotice;

      while (!_syncCancelRequested) {
        final claimed = await repository.claimQueued(
          leaseOwner:
              '$_foregroundLeasePrefix$generation-${DateTime.now().millisecondsSinceEpoch}',
          destinationId: destinationId,
          limit: 100,
          leaseDuration: const Duration(minutes: 30),
        );
        if (claimed.isEmpty) break;
        batch += 1;

        final fresh = <AlbumBackupRecord>[];
        final repeated = <AlbumBackupRecord>[];
        for (final record in claimed) {
          (processedAssetIds.add(record.assetId) ? fresh : repeated)
              .add(record);
        }
        await Future.wait(
          repeated.map(
            (record) => repository.transitionBackupState(
              assetId: record.assetId,
              destinationId: record.destinationId,
              state: AlbumBackupState.failed,
              error: '本轮已经尝试过，留待下次重试',
              nextRetry: DateTime.now().add(const Duration(minutes: 30)),
            ),
          ),
        );
        if (fresh.isEmpty) continue;
        final unavailable = fresh.where(
          (record) => assets[record.assetId]?.uri.isNotEmpty != true,
        );
        await Future.wait(
          unavailable.map(
            (record) => repository.transitionBackupState(
              assetId: record.assetId,
              destinationId: record.destinationId,
              state: AlbumBackupState.missingLocal,
              error: '本地媒体已不存在或当前不可访问',
            ),
          ),
        );
        final jobs = fresh
            .where((record) => assets[record.assetId]?.uri.isNotEmpty == true)
            .map(
              (record) => AlbumTransferJob(
                record: record,
                asset: assets[record.assetId]!,
              ),
            )
            .toList(growable: false);
        if (jobs.isEmpty) continue;
        sawJobs = true;
        final completedBeforeBatch = completed;
        final failedBeforeBatch = failed;
        final engine = AlbumTransferEngine(
          repository: repository,
          client: client,
          remoteRoot: _preferences.targetDir,
          maxConcurrency: _preferences.transferConcurrency,
          onProgress: (progress) {
            if (!mounted || generation != _syncGeneration) return;
            fallbackNotice = progress.fallbackNotice ?? fallbackNotice;
            if (progress.fallbackNotice != null &&
                progress.fallbackNotice != shownFallbackNotice) {
              shownFallbackNotice = progress.fallbackNotice;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(progress.fallbackNotice!)),
              );
            }
            final cumulativeCompleted =
                completedBeforeBatch + progress.completed;
            final cumulativeFailed = failedBeforeBatch + progress.failed;
            final speed = progress.bytesPerSecond <= 0
                ? ''
                : ' · ${_formatByteRate(progress.bytesPerSecond)}';
            _syncProgress.value = _AlbumSyncProgress(
              syncing: true,
              uploadedCount: cumulativeCompleted,
              pendingCount:
                  (initialPending - cumulativeCompleted - cumulativeFailed)
                      .clamp(0, initialPending),
              message: progress.lastError != null
                  ? '第 $batch 批部分失败：${progress.lastError}'
                  : progress.fallbackNotice != null
                      ? '${progress.fallbackNotice} · 第 $batch 批 · '
                          '${progress.active} 个并发$speed'
                      : '第 $batch 批 · ${progress.active} 个并发 · '
                          '${progress.currentName ?? '准备中'}$speed',
            );
          },
        );
        _activeTransferEngine = engine;
        final result = await engine.run(jobs);
        _activeTransferEngine = null;
        _syncPaused = false;
        completed += result.completed;
        failed += result.failed;
        fallbackNotice = result.fallbackNotice ?? fallbackNotice;
        cancelled = _syncCancelRequested || result.cancelled;
        if (cancelled) break;
        if (mounted && generation == _syncGeneration) {
          _syncProgress.value = _syncProgress.value.copyWith(
            uploadedCount: completed,
            pendingCount:
                (initialPending - completed - failed).clamp(0, initialPending),
            message: '第 $batch 批完成，正在领取下一批',
          );
        }
      }

      if (mounted && generation == _syncGeneration) {
        _syncProgress.value = _syncProgress.value.copyWith(
          message: '上传完成，正在整理队列',
        );
      }
      try {
        await _refreshIndexedPending().timeout(const Duration(seconds: 5));
      } on TimeoutException catch (error, stackTrace) {
        await AppLogger.log(
          'album_sync_pending_refresh_timeout',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!mounted || generation != _syncGeneration) return;
      final stillPending = _countPendingUploads();
      _syncCancelRequested = false;
      _syncProgress.value = _AlbumSyncProgress(
        syncing: false,
        uploadedCount: completed,
        pendingCount: stillPending,
        message: cancelled
            ? '已取消：完成 $completed 个，失败 $failed 个'
            : failed > 0
                ? '完成 $completed 个，失败 $failed 个，可稍后重试'
                : fallbackNotice != null
                    ? '$fallbackNotice；已安全提交 $completed 个照片/视频'
                    : !sawJobs
                        ? '当前没有到期的备份任务'
                        : '已安全提交 $completed 个照片/视频',
      );
      if (!cancelled && completed > 0) {
        unawaited(_reloadRemote());
      }
    } on Object catch (error) {
      if (!mounted || generation != _syncGeneration) {
        return;
      }
      _syncCancelRequested = false;
      _activeTransferEngine = null;
      _syncPaused = false;
      _syncProgress.value = _syncProgress.value.copyWith(
        syncing: false,
        message: '同步失败：$error',
      );
    }
  }

  Future<void> _retryAsset(String assetId) async {
    final repository = _backupRepository;
    if (repository == null || _syncProgress.value.syncing) return;
    final destinationId = albumDestinationId(_preferences.targetDir);
    final changed = await repository.requeueRetryable(
      destinationId: destinationId,
      assetId: assetId,
    );
    if (changed == 0) return;
    await _refreshIndexedPending();
    if (mounted) setState(() {});
    await _syncPending();
  }

  String _formatByteRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSecond / 1024).toStringAsFixed(0)} KB/s';
  }

  Future<void> _savePreferences(AlbumBackupPreferences preferences) async {
    await AlbumPreferences.save(preferences);
    final client = _client;
    if (client != null) {
      await AlbumBackgroundService.configure(
        client: client,
        preferences: preferences,
      );
    }
    if (!mounted) {
      return;
    }
    setState(() => _preferences = preferences);
    await _loadAll(runAutoSync: false);
  }

  Future<void> _runFocusedBackup() async {
    final client = _client;
    if (client == null) return;
    await AlbumBackgroundService.configure(
      client: client,
      preferences: _preferences,
    );
    await AlbumBackgroundService.runNow();
    _backgroundStatusTimer?.cancel();
    _backgroundStatusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refreshBackgroundStatus());
    });
    await _refreshBackgroundStatus();
  }

  Future<void> _refreshBackgroundStatus() async {
    final status = await AlbumBackgroundService.status();
    if (!mounted) return;
    setState(() => _backgroundStatus = status);
    if (const <String>{'completed', 'partial_failure', 'failed', 'blocked'}
        .contains(status.stage)) {
      _backgroundStatusTimer?.cancel();
      _backgroundStatusTimer = null;
      await _refreshIndexedPending();
    }
  }

  Future<void> _chooseSource() async {
    final selectedIds = _preferences.selectedSourceIds.toSet();
    final selected = await showModalBottomSheet<AlbumBackupPreferences>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final allSelected = selectedIds.isEmpty;
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  CheckboxListTile(
                    value: allSelected,
                    secondary: const Icon(Icons.photo_library_outlined),
                    title: const Text('本机所有照片和视频'),
                    subtitle: const Text('保留每个媒体文件夹的原始层级'),
                    onChanged: (_) => setModalState(selectedIds.clear),
                  ),
                  for (final bucket in _buckets)
                    CheckboxListTile(
                      value: selectedIds.contains(bucket.id),
                      secondary: const Icon(Icons.folder_copy_outlined),
                      title: Text(bucket.name),
                      subtitle:
                          Text('${bucket.relativePath} · ${bucket.count} 个项目'),
                      onChanged: (checked) {
                        setModalState(() {
                          if (checked == true) {
                            if (!_albumMultiSourceSelectionEnabled) {
                              selectedIds.clear();
                            }
                            selectedIds.add(bucket.id);
                          } else {
                            selectedIds.remove(bucket.id);
                          }
                        });
                      },
                    ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      final names = _buckets
                          .where((bucket) => selectedIds.contains(bucket.id))
                          .map((bucket) => bucket.name)
                          .toList(growable: false);
                      Navigator.of(context).pop(
                        AlbumBackupPreferences(
                          autoBackup: _preferences.autoBackup,
                          targetDir: _preferences.targetDir,
                          sourceIds: selectedIds.toList(growable: false),
                          sourceName: names.isEmpty
                              ? '本机所有照片'
                              : names.length <= 2
                                  ? names.join('、')
                                  : '${names.length} 个文件夹',
                          initialBackupMode: _preferences.initialBackupMode,
                          deviceId: _preferences.deviceId,
                          deviceName: _preferences.deviceName,
                          wifiOnly: _preferences.wifiOnly,
                          chargingOnly: _preferences.chargingOnly,
                          transferConcurrency: _preferences.transferConcurrency,
                        ),
                      );
                    },
                    child: const Text('确认备份来源'),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (selected != null) {
      await _savePreferences(selected);
      if (_preferences.autoBackup) {
        unawaited(_syncPending());
      }
    }
  }

  Future<void> _ensureBackupRepository() async {
    if (!_albumPersistentIndexEnabled) {
      _backupIndexReady = false;
      return;
    }
    if (_backupRepository != null) {
      return;
    }
    try {
      _backupRepository = await AlbumBackupRepository.open();
    } on Object catch (error) {
      _backupIndexReady = false;
      await AppLogger.log('album_index_open_error error=$error');
    }
  }

  Future<void> _reconcileBackupIndex({required bool fullScan}) async {
    final repository = _backupRepository;
    if (repository == null) {
      return;
    }
    try {
      await AlbumBackupDiscovery(repository).reconcile(
        media: _localMedia,
        buckets: _buckets,
        preferences: _preferences,
        fullScan: fullScan,
      );
      await _refreshIndexedPending();
    } on Object catch (error) {
      _backupIndexReady = false;
      await AppLogger.log('album_index_reconcile_error error=$error');
    }
  }

  Future<void> _refreshIndexedPending() async {
    final repository = _backupRepository;
    if (repository == null) {
      return;
    }
    final destinationId = albumDestinationId(_preferences.targetDir);
    final records = await repository.listBackupRecords(
      states: const <AlbumBackupState>{
        AlbumBackupState.queued,
        AlbumBackupState.failed,
      },
      limit: 5000,
    );
    final activeSources = await repository.listSourceFolders(enabledOnly: true);
    final activeSourceIds = activeSources.map((source) => source.id).toSet();
    final current = records
        .where(
          (record) =>
              record.destinationId == destinationId &&
              activeSourceIds.contains(record.sourceFolderId),
        )
        .toList(growable: false);
    _indexedRecordsByAsset = <String, AlbumBackupRecord>{
      for (final record in current) record.assetId: record,
    };
    _indexedPendingAssetIds = _indexedRecordsByAsset.keys.toSet();
    _backupIndexReady = true;
  }

  Future<void> _indexRemoteMedia(List<UnraidFileEntry> remote) async {
    final repository = _backupRepository;
    if (repository == null || remote.isEmpty) {
      return;
    }
    final destinationId = albumDestinationId(_preferences.targetDir);
    try {
      await repository.upsertRemoteAssets(
        remote
            .where((entry) => !entry.isDirectory)
            .map(
              (entry) => AlbumRemoteAsset(
                destinationId: destinationId,
                path: entry.path,
                displayName: entry.name,
                mediaKind:
                    entry.isVideo ? AlbumMediaKind.video : AlbumMediaKind.image,
                sizeBytes: entry.sizeBytes,
                modifiedMs: entry.modifiedDate?.millisecondsSinceEpoch ?? 0,
                captureTimeMs: entry.modifiedDate?.millisecondsSinceEpoch,
                versionKey:
                    '${entry.sizeBytes}:${entry.modifiedDate?.millisecondsSinceEpoch ?? 0}',
                origin: 'imported-existing',
              ),
            )
            .toList(growable: false),
      );
    } on Object catch (error) {
      await AppLogger.log('album_remote_index_error error=$error');
    }
  }

  Future<void> _adoptLegacyBackupMatches() async {
    if (!_albumLegacyImportEnabled) {
      return;
    }
    final repository = _backupRepository;
    if (repository == null || _localMedia.isEmpty || _remoteMedia.isEmpty) {
      return;
    }
    final remoteSizes = <String, int>{
      for (final entry in _remoteMedia)
        if (!entry.isDirectory) entry.path.toLowerCase(): entry.sizeBytes,
    };
    final matches = <String>{};
    for (final asset in _localMedia) {
      final legacyPath =
          _legacyDateTargetPathFor(_preferences.targetDir, asset).toLowerCase();
      if (remoteSizes[legacyPath] == asset.sizeBytes) {
        matches.add(asset.id);
      }
    }
    if (matches.isEmpty) {
      return;
    }
    try {
      final updated = await repository.markLegacyExistingAssets(
        destinationId: albumDestinationId(_preferences.targetDir),
        assetIds: matches,
      );
      if (updated > 0) {
        await _refreshIndexedPending();
        _syncProgress.value = _syncProgress.value.copyWith(
          message: '已识别 $updated 个旧日期目录备份，原文件保持不变',
        );
        await AppLogger.log(
          'album_legacy_import_success matched=${matches.length} updated=$updated',
        );
      }
    } on Object catch (error) {
      await AppLogger.log('album_legacy_import_error error=$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final local = _visibleLocalMedia;
    final localPhotos = _visiblePhotoCount;
    final localVideos = _visibleVideoCount;

    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          _AlbumHeader(
            onBack: () => Navigator.of(context).maybePop(),
            onRefresh: () => _loadAll(runAutoSync: false),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(28),
                  topRight: Radius.circular(28),
                ),
              ),
              // Skip entrance animation: album rebuilds on load/sync often.
              child: FadeSlide(
                animate: false,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: Column(
                        children: [
                          ValueListenableBuilder<_AlbumSyncProgress>(
                            valueListenable: _syncProgress,
                            builder: (context, progress, _) {
                              return _AlbumStats(
                                localPhotos: localPhotos,
                                localVideos: localVideos,
                                remoteCount: _remoteMediaCount,
                                pendingCount: progress.pendingCount,
                                syncing: progress.syncing,
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          ValueListenableBuilder<_PhoAlbumTab>(
                            valueListenable: _tab,
                            builder: (context, tab, _) {
                              return _AlbumTabs(
                                current: tab,
                                videosOnly: widget.videosOnly,
                                onChanged: _selectTab,
                              );
                            },
                          ),
                          const SizedBox(height: 18),
                        ],
                      ),
                    ),
                    Expanded(
                      // Lazy + sticky tab bodies: first visit builds the page,
                      // later switches keep scroll / decoded thumbs without
                      // preloading every remote tile on open.
                      // Tab index is a notifier so switches skip full setState.
                      child: ValueListenableBuilder<int>(
                        valueListenable: _visitedTabsVersion,
                        builder: (context, _, __) {
                          return ValueListenableBuilder<_PhoAlbumTab>(
                            valueListenable: _tab,
                            builder: (context, tab, ___) {
                              return IndexedStack(
                                index: tab.index,
                                sizing: StackFit.expand,
                                children: [
                                  for (final value in _PhoAlbumTab.values)
                                    _visitedTabs.contains(value)
                                        ? _buildTabBody(value, local)
                                        : const SizedBox.shrink(),
                                ],
                              );
                            },
                          );
                        },
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

  void _selectTab(_PhoAlbumTab tab) {
    final alreadyVisited = _visitedTabs.contains(tab);
    if (_tab.value == tab && alreadyVisited) {
      return;
    }
    final isNewVisit = _visitedTabs.add(tab);
    _tab.value = tab;
    if (isNewVisit) {
      _visitedTabsVersion.value += 1;
    }
  }

  Widget _buildTabBody(_PhoAlbumTab tab, List<LocalMediaAsset> local) {
    final padding = const EdgeInsets.fromLTRB(20, 0, 20, 28);
    return switch (tab) {
      // Local/remote use CustomScrollView so day sections are virtualized
      // instead of expanding every grid inside one unbounded ListView.
      _PhoAlbumTab.local => ValueListenableBuilder<_AlbumPaneState>(
          valueListenable: _localState,
          builder: (context, localState, _) {
            return RefreshIndicator(
              onRefresh: () => _loadAll(runAutoSync: false),
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (localState.error != null)
                    SliverPadding(
                      padding: padding,
                      sliver: SliverToBoxAdapter(
                        child: _InlineState(
                          icon: Icons.error_outline,
                          title: '本机相册读取失败',
                          detail: localState.error!,
                          actionLabel: '重试',
                          onAction: () => _loadAll(runAutoSync: false),
                        ),
                      ),
                    )
                  else
                    _LocalTimeline(
                      loading: localState.loading,
                      media: local,
                      gallery: local,
                      videosOnly: widget.videosOnly,
                      padding: padding,
                    ),
                ],
              ),
            );
          },
        ),
      _PhoAlbumTab.remote => ValueListenableBuilder<_AlbumPaneState>(
          valueListenable: _remoteState,
          builder: (context, remoteState, _) {
            return RefreshIndicator(
              onRefresh: _reloadRemote,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  _RemoteTimeline(
                    loading: remoteState.loading,
                    error: remoteState.error,
                    client: _client,
                    remoteRoot: _preferences.targetDir,
                    hasMore: _remoteHasMore,
                    onLoadMore: _loadMoreRemote,
                    entries: _remoteMedia,
                    gallery: _remoteMedia,
                    onRetry: _reloadRemote,
                    padding: padding,
                  ),
                ],
              ),
            );
          },
        ),
      _PhoAlbumTab.sync => ListView(
          padding: padding,
          children: [
            ValueListenableBuilder<_AlbumSyncProgress>(
              valueListenable: _syncProgress,
              builder: (context, progress, _) {
                final localById = <String, LocalMediaAsset>{
                  for (final asset in local) asset.id: asset,
                };
                final failedItems = _indexedRecordsByAsset.values
                    .where((record) => record.state == AlbumBackupState.failed)
                    .map(
                      (record) => _AlbumFailedItem(
                        assetId: record.assetId,
                        name: localById[record.assetId]?.name ?? record.assetId,
                        error: record.lastError ?? '上传失败',
                      ),
                    )
                    .toList(growable: false);
                return _SyncPanel(
                  preferences: _preferences,
                  localCount: local.length,
                  remoteCount: _remoteMediaCount,
                  pendingCount: progress.pendingCount,
                  uploadedCount: progress.uploadedCount,
                  syncing: progress.syncing,
                  message: progress.message,
                  backgroundStatus: _backgroundStatus,
                  failedItems: failedItems,
                  paused: _syncPaused,
                  onSync: () => _syncPending(forceRetry: true),
                  onBackgroundSync: _runFocusedBackup,
                  onPauseResume: _toggleSyncPause,
                  onCancel: _cancelSync,
                  onRetryAsset: _retryAsset,
                  onSettings: () => _selectTab(_PhoAlbumTab.settings),
                );
              },
            ),
          ],
        ),
      _PhoAlbumTab.manage => _AlbumManagementPanel(
          repository: _backupRepository,
          onLibraryChanged: () => _loadAll(runAutoSync: false),
        ),
      _PhoAlbumTab.settings => ListView(
          padding: padding,
          children: [
            _SettingsPanel(
              preferences: _preferences,
              buckets: _buckets,
              onSave: _savePreferences,
              onChooseSource: _chooseSource,
            ),
          ],
        ),
    };
  }
}
