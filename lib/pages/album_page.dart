import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/album_preferences.dart';
import '../services/local_media_store.dart';
import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/fade_slide.dart';
import '../widgets/phone_frame.dart';

part 'album_widgets.dart';
part 'album_utils.dart';

/// Skip full-resolution remote downloads above this size for album tiles.
const _maxAlbumPreviewBytes = 8 * 1024 * 1024;
const _maxSyncBatchSize = 10;
const _maxAlbumTileDecodeExtent = 480;
/// Cap tiles per day-section so a huge day does not expand the outer ListView.
const _maxAlbumSectionTiles = 60;

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
  late _PhoAlbumTab _tab = widget.initialTab;
  AlbumBackupPreferences _preferences = const AlbumBackupPreferences();
  List<LocalMediaAsset> _localMedia = const <LocalMediaAsset>[];
  List<UnraidFileEntry> _remoteMedia = const <UnraidFileEntry>[];
  List<LocalMediaBucket> _buckets = const <LocalMediaBucket>[];
  bool _loadingLocal = true;
  bool _loadingRemote = true;
  bool _syncing = false;
  bool _loadingAll = false;
  int _loadGeneration = 0;
  int _uploadedCount = 0;
  int _pendingCount = 0;
  String? _error;
  String? _remoteError;
  String? _syncMessage;

  AlbumPageArgs? get _args {
    final args = ModalRoute.of(context)?.settings.arguments;
    return args is AlbumPageArgs ? args : null;
  }

  UnraidClient? get _client => _args?.unraidClient;

  List<LocalMediaAsset> get _visibleLocalMedia {
    final sourceIds = _preferences.selectedSourceIds;
    final filtered = sourceIds.isEmpty
        ? _localMedia
        : _localMedia
            .where((asset) => sourceIds.contains(asset.bucketId))
            .toList(growable: false);
    if (!widget.videosOnly) {
      return filtered;
    }
    return filtered.where((asset) => asset.isVideo).toList(growable: false);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  Future<void> _loadAll({bool runAutoSync = true}) async {
    final args = _args;
    if (args == null) {
      setState(() {
        _error = '缺少连接参数，请从主页应用入口打开相册';
        _loadingLocal = false;
        _loadingRemote = false;
      });
      return;
    }

    // Collapse overlapping refresh taps so concurrent loads do not race
    // setState with stale results.
    final generation = ++_loadGeneration;
    if (_loadingAll && runAutoSync) {
      return;
    }
    _loadingAll = true;

    setState(() {
      _loadingLocal = true;
      _loadingRemote = true;
      _error = null;
      _remoteError = null;
    });

    try {
      final preferences = await AlbumPreferences.load();
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() => _preferences = preferences);

      // Manual refresh (runAutoSync: false) should bypass short caches.
      final forceRefresh = !runAutoSync;
      if (forceRefresh) {
        LocalMediaStore.invalidateCaches();
      }

      // Load local and remote independently so one side failing does not blank
      // the entire album page.
      await Future.wait<void>([
        _loadLocalMedia(),
        _loadRemoteMedia(
          client: args.unraidClient,
          targetDir: preferences.targetDir,
          forceRefresh: forceRefresh,
        ),
      ]);

      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _pendingCount = _countPendingUploads();
      });

      if (preferences.autoBackup && runAutoSync && _error == null) {
        unawaited(_syncPending());
      }
    } finally {
      if (generation == _loadGeneration) {
        _loadingAll = false;
      }
    }
  }

  Future<void> _loadLocalMedia() async {
    try {
      final permissionsGranted = await _requestMediaAccess();
      if (!permissionsGranted) {
        if (!mounted) {
          return;
        }
        setState(() {
          _error = '需要照片和视频权限。请在系统设置中允许访问相册后重试。';
          _localMedia = const <LocalMediaAsset>[];
          _buckets = const <LocalMediaBucket>[];
          _loadingLocal = false;
        });
        return;
      }

      final results = await Future.wait<Object>([
        LocalMediaStore.listMedia(),
        LocalMediaStore.listBuckets(),
      ]);
      if (!mounted) {
        return;
      }
      setState(() {
        _localMedia = results[0] as List<LocalMediaAsset>;
        _buckets = results[1] as List<LocalMediaBucket>;
        _error = null;
        _loadingLocal = false;
      });
    } on LocalMediaException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        _localMedia = const <LocalMediaAsset>[];
        _buckets = const <LocalMediaBucket>[];
        _loadingLocal = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = '本机相册加载失败：$error';
        _localMedia = const <LocalMediaAsset>[];
        _buckets = const <LocalMediaBucket>[];
        _loadingLocal = false;
      });
    }
  }

  Future<void> _loadRemoteMedia({
    required UnraidClient client,
    required String targetDir,
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
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteMedia = remote;
        _remoteError = null;
        _loadingRemote = false;
      });
    } on UnraidClientException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteMedia = const <UnraidFileEntry>[];
        _remoteError = error.message;
        _loadingRemote = false;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _remoteMedia = const <UnraidFileEntry>[];
        _remoteError = '云端读取失败：$error';
        _loadingRemote = false;
      });
    }
  }

  Future<void> _reloadRemote() async {
    final client = _client;
    if (client == null) {
      return;
    }
    setState(() {
      _loadingRemote = true;
      _remoteError = null;
    });
    await _loadRemoteMedia(
      client: client,
      targetDir: _preferences.targetDir,
      forceRefresh: true,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingCount = _countPendingUploads();
    });
  }

  int _countPendingUploads() {
    return _findPendingUploads(
      local: _localMedia,
      remote: _remoteMedia,
      targetDir: _preferences.targetDir,
      sourceIds: _preferences.selectedSourceIds,
    ).length;
  }

  Future<void> _syncPending() async {
    final client = _client;
    if (client == null || _syncing) {
      return;
    }

    final allPending = _findPendingUploads(
      local: _localMedia,
      remote: _remoteMedia,
      targetDir: _preferences.targetDir,
      sourceIds: _preferences.selectedSourceIds,
    );
    if (allPending.isEmpty) {
      setState(() {
        _pendingCount = 0;
        _syncMessage = '已同步';
      });
      return;
    }

    // Keep interactive syncs bounded so a huge backlog does not freeze the UI.
    final pending = allPending.take(_maxSyncBatchSize).toList(growable: false);
    final remainingAfterBatch = allPending.length - pending.length;

    setState(() {
      _syncing = true;
      _uploadedCount = 0;
      _pendingCount = allPending.length;
      _syncMessage = remainingAfterBatch > 0
          ? '准备同步（本批 ${pending.length} / 共 ${allPending.length}）'
          : '准备同步';
    });

    try {
      var uploaded = 0;
      for (final asset in pending) {
        final targetPath = _targetPathFor(_preferences.targetDir, asset);
        final targetDir = _parentPath(targetPath);
        if (!mounted) {
          return;
        }
        setState(() {
          _syncMessage =
              '创建目录 ${_relativePath(_preferences.targetDir, targetDir)}';
        });
        await client.ensureDirectory(targetDir);

        if (!mounted) {
          return;
        }
        setState(() {
          _syncMessage = '上传 ${uploaded + 1}/${pending.length}：${asset.name}';
        });
        await client.uploadLocalMediaFile(
          targetPath: targetPath,
          sourceUri: asset.uri,
          sizeBytes: asset.sizeBytes,
          modifiedDate: asset.dateModified,
        );
        uploaded += 1;
        if (!mounted) {
          return;
        }
        setState(() {
          _uploadedCount = uploaded;
          _pendingCount = allPending.length - uploaded;
        });
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _syncing = false;
        _syncMessage = remainingAfterBatch > 0
            ? '已上传 $uploaded 个，还有 $remainingAfterBatch 个待同步'
            : '已上传 $uploaded 个照片/视频';
      });
      LocalMediaStore.invalidateCaches();
      await _reloadRemote();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _syncing = false;
        _syncMessage = '同步失败：$error';
      });
    }
  }

  Future<void> _savePreferences(AlbumBackupPreferences preferences) async {
    await AlbumPreferences.save(preferences);
    if (!mounted) {
      return;
    }
    setState(() => _preferences = preferences);
    await _reloadRemote();
  }

  Future<void> _chooseSource() async {
    final selected = await showModalBottomSheet<AlbumBackupPreferences>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('本机所有照片和视频'),
                trailing: _preferences.sourceId.isEmpty
                    ? const Icon(Icons.check, color: AppTheme.primary)
                    : null,
                onTap: () {
                  Navigator.of(context).pop(
                    AlbumBackupPreferences(
                      autoBackup: _preferences.autoBackup,
                      targetDir: _preferences.targetDir,
                      sourceId: '',
                      sourceName: '本机所有照片',
                    ),
                  );
                },
              ),
              for (final bucket in _buckets)
                ListTile(
                  leading: const Icon(Icons.folder_copy_outlined),
                  title: Text(bucket.name),
                  subtitle: Text('${bucket.count} 个项目'),
                  trailing: _preferences.sourceId == bucket.id
                      ? const Icon(Icons.check, color: AppTheme.primary)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop(
                      AlbumBackupPreferences(
                        autoBackup: _preferences.autoBackup,
                        targetDir: _preferences.targetDir,
                        sourceId: bucket.id,
                        sourceName: bucket.name,
                      ),
                    );
                  },
                ),
            ],
          ),
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

  @override
  Widget build(BuildContext context) {
    final local = _visibleLocalMedia;
    final localPhotos = local.where((asset) => !asset.isVideo).length;
    final localVideos = local.where((asset) => asset.isVideo).length;

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
              child: FadeSlide(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                  children: [
                    _AlbumStats(
                      localPhotos: localPhotos,
                      localVideos: localVideos,
                      remoteCount: _remoteMedia.length,
                      pendingCount: _pendingCount,
                      syncing: _syncing,
                    ),
                    const SizedBox(height: 16),
                    _AlbumTabs(
                      current: _tab,
                      videosOnly: widget.videosOnly,
                      onChanged: (tab) => setState(() => _tab = tab),
                    ),
                    const SizedBox(height: 18),
                    if (_error != null && _tab == _PhoAlbumTab.local)
                      _InlineState(
                        icon: Icons.error_outline,
                        title: '本机相册读取失败',
                        detail: _error!,
                        actionLabel: '重试',
                        onAction: () => _loadAll(runAutoSync: false),
                      )
                    else
                      _buildTab(local),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTab(List<LocalMediaAsset> local) {
    return switch (_tab) {
      _PhoAlbumTab.local => _LocalTimeline(
          loading: _loadingLocal,
          media: local,
          videosOnly: widget.videosOnly,
        ),
      _PhoAlbumTab.remote => _RemoteTimeline(
          loading: _loadingRemote,
          error: _remoteError,
          client: _client,
          entries: _remoteMedia,
          onRetry: _reloadRemote,
        ),
      _PhoAlbumTab.sync => _SyncPanel(
          preferences: _preferences,
          localCount: _visibleLocalMedia.length,
          remoteCount: _remoteMedia.length,
          pendingCount: _pendingCount,
          uploadedCount: _uploadedCount,
          syncing: _syncing,
          message: _syncMessage,
          onSync: _syncPending,
          onSettings: () => setState(() => _tab = _PhoAlbumTab.settings),
        ),
      _PhoAlbumTab.settings => _SettingsPanel(
          preferences: _preferences,
          buckets: _buckets,
          onSave: _savePreferences,
          onChooseSource: _chooseSource,
        ),
    };
  }
}

