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
import '../services/album_preferences.dart';
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

/// Skip full-resolution remote downloads above this size for album *tiles*
/// only — fullscreen stills stream to disk with no size ceiling.
const _maxAlbumPreviewBytes = 8 * 1024 * 1024;
const _maxAlbumFullscreenDecodeExtent = 2400;
const _maxSyncBatchSize = 10;
const _maxAlbumTileDecodeExtent = 480;

// Compile-time rollback switches. Keep the legacy page path usable while the
// persistent index, multi-source selection, and legacy import mature.
const _albumPersistentIndexEnabled = true;
const _albumMultiSourceSelectionEnabled = true;
const _albumLegacyImportEnabled = true;
const _albumFolderMappingEnabled = true;

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

/// In-memory LRU-ish cache for remote album thumbnails within one process.
final Map<String, Future<Uint8List?>> _remoteThumbnailCache =
    <String, Future<Uint8List?>>{};
const _maxRemoteThumbnailCacheEntries = 64;
const _maxRemoteThumbnailInflight = 3;
int _remoteThumbnailInflight = 0;
final List<Completer<void>> _remoteThumbnailWaiters = <Completer<void>>[];

Future<T> _withRemoteThumbnailSlot<T>(Future<T> Function() action) async {
  while (_remoteThumbnailInflight >= _maxRemoteThumbnailInflight) {
    final gate = Completer<void>();
    _remoteThumbnailWaiters.add(gate);
    await gate.future;
  }
  _remoteThumbnailInflight += 1;
  try {
    return await action();
  } finally {
    _remoteThumbnailInflight -= 1;
    if (_remoteThumbnailWaiters.isNotEmpty) {
      _remoteThumbnailWaiters.removeAt(0).complete();
    }
  }
}

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

enum _PhoAlbumTab { local, remote, sync, settings }

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
  List<LocalMediaAsset> _localMedia = const <LocalMediaAsset>[];
  List<UnraidFileEntry> _remoteMedia = const <UnraidFileEntry>[];
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

      await _ensureBackupRepository();

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
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _remoteMedia = remote;
      });
      await _indexRemoteMedia(remote);
      _remoteState.value = const _AlbumPaneState(loading: false);
    } on UnraidClientException catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _remoteMedia = const <UnraidFileEntry>[];
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
  bool _syncCancelRequested = false;

  void _cancelSync() {
    if (!_syncProgress.value.syncing) {
      return;
    }
    _syncCancelRequested = true;
    _syncProgress.value = _syncProgress.value.copyWith(
      message: '正在取消…',
    );
  }

  Future<void> _syncPending() async {
    final client = _client;
    if (client == null || _syncProgress.value.syncing) {
      return;
    }

    final generation = ++_syncGeneration;
    _syncCancelRequested = false;

    var totalUploaded = 0;
    var totalFailed = 0;
    Object? lastError;
    final ensuredDirs = <String>{};

    _syncProgress.value = _AlbumSyncProgress(
      syncing: true,
      uploadedCount: 0,
      pendingCount: _countPendingUploads(),
      message: '准备同步',
    );

    try {
      // Drain the backlog in bounded batches so the UI stays responsive and
      // remote listings refresh between waves.
      while (
          mounted && generation == _syncGeneration && !_syncCancelRequested) {
        // Recompute pending each wave so successful uploads drop out.
        final allPending = _pendingUploads;
        if (allPending.isEmpty) {
          break;
        }
        final pending =
            allPending.take(_maxSyncBatchSize).toList(growable: false);
        final remainingAfterBatch = allPending.length - pending.length;

        _syncProgress.value = _syncProgress.value.copyWith(
          pendingCount: allPending.length,
          message: remainingAfterBatch > 0
              ? '本批 ${pending.length} / 剩余 ${allPending.length}'
              : '上传 ${pending.length} 个',
        );

        var batchUploaded = 0;
        for (final asset in pending) {
          if (!mounted ||
              generation != _syncGeneration ||
              _syncCancelRequested) {
            break;
          }
          if (asset.uri.isEmpty) {
            totalFailed += 1;
            lastError = '媒体 URI 为空：${asset.name}';
            continue;
          }
          final indexedRecord = _indexedRecordsByAsset[asset.id];
          final targetPath = _albumFolderMappingEnabled
              ? indexedRecord?.remotePath ??
                  _folderTargetPathFor(
                    targetDir: _preferences.targetDir,
                    asset: asset,
                    preferences: _preferences,
                    buckets: _buckets,
                  )
              : _legacyDateTargetPathFor(_preferences.targetDir, asset);
          final targetDir = _parentPath(targetPath);
          if (ensuredDirs.add(targetDir)) {
            _syncProgress.value = _syncProgress.value.copyWith(
              message:
                  '创建目录 ${_relativePath(_preferences.targetDir, targetDir)}',
            );
            await client.ensureDirectory(targetDir);
          }

          if (!mounted ||
              generation != _syncGeneration ||
              _syncCancelRequested) {
            break;
          }
          _syncProgress.value = _syncProgress.value.copyWith(
            message: '上传 ${totalUploaded + batchUploaded + 1}：${asset.name}',
          );
          try {
            if (indexedRecord != null) {
              await _backupRepository?.transitionBackupState(
                assetId: asset.id,
                destinationId: indexedRecord.destinationId,
                state: AlbumBackupState.uploading,
              );
            }
            await client.uploadLocalMediaFile(
              targetPath: targetPath,
              sourceUri: asset.uri,
              sizeBytes: asset.sizeBytes,
              modifiedDate: asset.dateModified,
            );
            if (indexedRecord != null) {
              await _backupRepository?.transitionBackupState(
                assetId: asset.id,
                destinationId: indexedRecord.destinationId,
                state: AlbumBackupState.verifying,
                uploadedBytes: asset.sizeBytes,
              );
              await _backupRepository?.transitionBackupState(
                assetId: asset.id,
                destinationId: indexedRecord.destinationId,
                state: AlbumBackupState.completed,
                uploadedBytes: asset.sizeBytes,
                remoteSize: asset.sizeBytes,
                remoteModifiedMs: asset.dateModified.millisecondsSinceEpoch,
              );
              _indexedPendingAssetIds.remove(asset.id);
              _indexedRecordsByAsset.remove(asset.id);
            }
            batchUploaded += 1;
            totalUploaded += 1;
          } on Object catch (error) {
            if (indexedRecord != null) {
              try {
                await _backupRepository?.transitionBackupState(
                  assetId: asset.id,
                  destinationId: indexedRecord.destinationId,
                  state: AlbumBackupState.failed,
                  error: error.toString(),
                  nextRetry: DateTime.now().add(const Duration(minutes: 1)),
                );
              } on Object catch (indexError) {
                await AppLogger.log(
                  'album_index_transition_error asset=${asset.id} '
                  'error=$indexError',
                );
              }
            }
            totalFailed += 1;
            lastError = error;
            if (!mounted) {
              return;
            }
            _syncProgress.value = _syncProgress.value.copyWith(
              message: '跳过 ${asset.name}：$error',
            );
            await Future<void>.delayed(const Duration(milliseconds: 350));
            continue;
          }
          if (!mounted) {
            return;
          }
          _syncProgress.value = _syncProgress.value.copyWith(
            uploadedCount: totalUploaded,
            pendingCount: allPending.length - batchUploaded,
          );
        }

        if (_syncCancelRequested) {
          break;
        }
        // Stop when this wave uploaded nothing useful and failures remain —
        // otherwise a permanent bad file would loop forever.
        if (batchUploaded == 0) {
          break;
        }
      }

      if (!mounted || generation != _syncGeneration) {
        return;
      }
      if (totalUploaded > 0) {
        LocalMediaStore.invalidateCaches();
        await _reloadRemote();
      }
      final stillPending = _countPendingUploads();
      final cancelled = _syncCancelRequested;
      _syncCancelRequested = false;
      _syncProgress.value = _AlbumSyncProgress(
        syncing: false,
        uploadedCount: totalUploaded,
        pendingCount: stillPending,
        message: cancelled
            ? '已取消：上传 $totalUploaded 个'
                '${totalFailed > 0 ? '，失败 $totalFailed 个' : ''}'
                '${stillPending > 0 ? '，剩余 $stillPending 个' : ''}'
            : totalFailed > 0
                ? '已上传 $totalUploaded 个，失败 $totalFailed 个'
                    '${lastError == null ? '' : '（$lastError）'}'
                    '${stillPending > 0 ? '，剩余 $stillPending 个' : ''}'
                : stillPending > 0
                    ? '已上传 $totalUploaded 个，剩余 $stillPending 个'
                    : totalUploaded > 0
                        ? '已上传 $totalUploaded 个照片/视频'
                        : '已同步',
      );
    } on Object catch (error) {
      if (!mounted || generation != _syncGeneration) {
        return;
      }
      _syncCancelRequested = false;
      _syncProgress.value = _syncProgress.value.copyWith(
        syncing: false,
        message: '同步失败：$error',
      );
    }
  }

  Future<void> _savePreferences(AlbumBackupPreferences preferences) async {
    await AlbumPreferences.save(preferences);
    if (!mounted) {
      return;
    }
    setState(() => _preferences = preferences);
    await _loadAll(runAutoSync: false);
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
                                remoteCount: _remoteMedia.length,
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
                return _SyncPanel(
                  preferences: _preferences,
                  localCount: local.length,
                  remoteCount: _remoteMedia.length,
                  pendingCount: progress.pendingCount,
                  uploadedCount: progress.uploadedCount,
                  syncing: progress.syncing,
                  message: progress.message,
                  onSync: _syncPending,
                  onCancel: _cancelSync,
                  onSettings: () => _selectTab(_PhoAlbumTab.settings),
                );
              },
            ),
          ],
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
