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
    final sourceId = _preferences.sourceId;
    final filtered = sourceId.isEmpty
        ? _localMedia
        : _localMedia
            .where((asset) => asset.bucketId == sourceId)
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

    setState(() {
      _loadingLocal = true;
      _loadingRemote = true;
      _error = null;
      _remoteError = null;
    });

    final preferences = await AlbumPreferences.load();
    if (!mounted) {
      return;
    }
    setState(() => _preferences = preferences);

    // Load local and remote independently so one side failing does not blank
    // the entire album page.
    await Future.wait<void>([
      _loadLocalMedia(),
      _loadRemoteMedia(client: args.unraidClient, targetDir: preferences.targetDir),
    ]);

    if (!mounted) {
      return;
    }
    setState(() {
      _pendingCount = _findPendingUploads(
        local: _localMedia,
        remote: _remoteMedia,
        targetDir: _preferences.targetDir,
        sourceId: _preferences.sourceId,
      ).length;
    });

    if (preferences.autoBackup && runAutoSync && _error == null) {
      unawaited(_syncPending());
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
    } catch (error) {
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
  }) async {
    try {
      final remote = await client.fetchMediaFiles(
        targetDir,
        maxDepth: 6,
        includeImages: true,
        includeVideos: true,
        includeAudio: false,
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
    } catch (error) {
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
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _pendingCount = _findPendingUploads(
        local: _localMedia,
        remote: _remoteMedia,
        targetDir: _preferences.targetDir,
        sourceId: _preferences.sourceId,
      ).length;
    });
  }

  Future<void> _syncPending() async {
    final client = _client;
    if (client == null || _syncing) {
      return;
    }

    final pending = _findPendingUploads(
      local: _localMedia,
      remote: _remoteMedia,
      targetDir: _preferences.targetDir,
      sourceId: _preferences.sourceId,
    );
    if (pending.isEmpty) {
      setState(() {
        _pendingCount = 0;
        _syncMessage = '已同步';
      });
      return;
    }

    setState(() {
      _syncing = true;
      _uploadedCount = 0;
      _pendingCount = pending.length;
      _syncMessage = '准备同步';
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
          _syncMessage = '创建目录 ${_relativePath(_preferences.targetDir, targetDir)}';
        });
        await client.ensureDirectory(targetDir);

        if (!mounted) {
          return;
        }
        setState(() {
          _syncMessage = '上传 ${uploaded + 1}/${pending.length}：${asset.name}';
        });
        await client.uploadFile(
          targetPath: targetPath,
          sizeBytes: asset.sizeBytes,
          readChunk: (offset, length) {
            return LocalMediaStore.readChunk(
              uri: asset.uri,
              offset: offset,
              length: length,
            );
          },
        );
        uploaded += 1;
        if (!mounted) {
          return;
        }
        setState(() {
          _uploadedCount = uploaded;
          _pendingCount = pending.length - uploaded;
        });
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _syncing = false;
        _syncMessage = '已上传 $uploaded 个照片/视频';
      });
      await _reloadRemote();
    } catch (error) {
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

class _AlbumHeader extends StatelessWidget {
  const _AlbumHeader({
    required this.onBack,
    required this.onRefresh,
  });

  final VoidCallback onBack;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 14),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
          ),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '相册',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: '刷新',
            onPressed: onRefresh,
            icon: const Icon(Icons.refresh, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _AlbumStats extends StatelessWidget {
  const _AlbumStats({
    required this.localPhotos,
    required this.localVideos,
    required this.remoteCount,
    required this.pendingCount,
    required this.syncing,
  });

  final int localPhotos;
  final int localVideos;
  final int remoteCount;
  final int pendingCount;
  final bool syncing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.inputBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Row(
        children: [
          Expanded(
            child: _StatItem(
              label: '本机',
              value: '${localPhotos + localVideos}',
              detail: '$localPhotos 照片 / $localVideos 视频',
            ),
          ),
          Expanded(
            child: _StatItem(
              label: '云端',
              value: '$remoteCount',
              detail: 'Unraid',
            ),
          ),
          Expanded(
            child: _StatItem(
              label: syncing ? '同步中' : '待同步',
              value: '$pendingCount',
              detail: syncing ? '正在上传' : '增量',
            ),
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  const _StatItem({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: AppTheme.textLight)),
        const SizedBox(height: 6),
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textDark,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.textMedium),
        ),
      ],
    );
  }
}

class _AlbumTabs extends StatelessWidget {
  const _AlbumTabs({
    required this.current,
    required this.onChanged,
    required this.videosOnly,
  });

  final _PhoAlbumTab current;
  final ValueChanged<_PhoAlbumTab> onChanged;
  final bool videosOnly;

  @override
  Widget build(BuildContext context) {
    final items = <(_PhoAlbumTab, IconData, String)>[
      (_PhoAlbumTab.local, videosOnly ? Icons.video_library : Icons.photo_library, '本机'),
      (_PhoAlbumTab.remote, Icons.cloud_outlined, '云端'),
      (_PhoAlbumTab.sync, Icons.sync, '同步'),
      (_PhoAlbumTab.settings, Icons.tune, '设置'),
    ];

    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppTheme.inputBackground,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          for (final item in items)
            Expanded(
              child: _TabButton(
                icon: item.$2,
                label: item.$3,
                selected: current == item.$1,
                onTap: () => onChanged(item.$1),
              ),
            ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x16000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: selected ? AppTheme.primary : AppTheme.textLight,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppTheme.textDark : AppTheme.textLight,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LocalTimeline extends StatelessWidget {
  const _LocalTimeline({
    required this.loading,
    required this.media,
    required this.videosOnly,
  });

  final bool loading;
  final List<LocalMediaAsset> media;
  final bool videosOnly;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _LoadingState(label: '正在读取本机相册');
    }
    if (media.isEmpty) {
      return _InlineState(
        icon: videosOnly ? Icons.video_library_outlined : Icons.photo_outlined,
        title: videosOnly ? '没有视频' : '没有照片或视频',
        detail: '请检查系统媒体权限',
      );
    }

    final sections = _groupLocalByDate(media);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          _SectionTitle(title: section.title, count: section.items.length),
          const SizedBox(height: 10),
          _LocalGrid(items: section.items),
          const SizedBox(height: 22),
        ],
      ],
    );
  }
}

class _RemoteTimeline extends StatelessWidget {
  const _RemoteTimeline({
    required this.loading,
    required this.entries,
    required this.client,
    this.error,
    this.onRetry,
  });

  final bool loading;
  final String? error;
  final UnraidClient? client;
  final List<UnraidFileEntry> entries;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const _LoadingState(label: '正在读取 Unraid 相册');
    }
    if (error != null) {
      return _InlineState(
        icon: Icons.cloud_off_outlined,
        title: '云端读取失败',
        detail: error!,
        actionLabel: '重试',
        onAction: onRetry,
      );
    }
    if (entries.isEmpty) {
      return const _InlineState(
        icon: Icons.cloud_queue,
        title: '云端暂无媒体',
        detail: '同步后会出现在这里',
      );
    }

    final sections = _groupRemoteByDate(entries);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          _SectionTitle(title: section.title, count: section.items.length),
          const SizedBox(height: 10),
          _RemoteGrid(client: client, items: section.items),
          const SizedBox(height: 22),
        ],
      ],
    );
  }
}

class _SyncPanel extends StatelessWidget {
  const _SyncPanel({
    required this.preferences,
    required this.localCount,
    required this.remoteCount,
    required this.pendingCount,
    required this.uploadedCount,
    required this.syncing,
    required this.onSync,
    required this.onSettings,
    this.message,
  });

  final AlbumBackupPreferences preferences;
  final int localCount;
  final int remoteCount;
  final int pendingCount;
  final int uploadedCount;
  final bool syncing;
  final String? message;
  final VoidCallback onSync;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final total = uploadedCount + pendingCount;
    final progress = total == 0 ? 0.0 : uploadedCount / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoCard(
          icon: Icons.sync,
          title: syncing ? '正在同步' : '同步',
          subtitle: message ?? (pendingCount == 0 ? '已同步' : '$pendingCount 个待上传'),
          child: syncing
              ? Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: LinearProgressIndicator(value: progress),
                )
              : null,
        ),
        const SizedBox(height: 12),
        _KeyValueCard(
          rows: [
            ('备份源', preferences.sourceName),
            ('目标目录', preferences.targetDir),
            ('本机项目', '$localCount'),
            ('云端项目', '$remoteCount'),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: syncing ? null : onSync,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('立即同步'),
              ),
            ),
            const SizedBox(width: 12),
            IconButton.outlined(
              tooltip: '同步设置',
              onPressed: onSettings,
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
      ],
    );
  }
}

class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({
    required this.preferences,
    required this.buckets,
    required this.onSave,
    required this.onChooseSource,
  });

  final AlbumBackupPreferences preferences;
  final List<LocalMediaBucket> buckets;
  final Future<void> Function(AlbumBackupPreferences preferences) onSave;
  final VoidCallback onChooseSource;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late final TextEditingController _targetController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _targetController = TextEditingController(
      text: widget.preferences.targetDir,
    );
  }

  @override
  void didUpdateWidget(covariant _SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences.targetDir != widget.preferences.targetDir) {
      _targetController.text = widget.preferences.targetDir;
    }
  }

  @override
  void dispose() {
    _targetController.dispose();
    super.dispose();
  }

  Future<void> _save({bool? autoBackup}) async {
    final target = _normalizeLocalPath(_targetController.text);
    if (target.isEmpty || (!target.startsWith('/mnt/') && !target.startsWith('/boot'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目标目录必须位于 /mnt 或 /boot 下')),
      );
      return;
    }
    setState(() => _saving = true);
    await widget.onSave(
      AlbumBackupPreferences(
        autoBackup: autoBackup ?? widget.preferences.autoBackup,
        targetDir: target,
        sourceId: widget.preferences.sourceId,
        sourceName: widget.preferences.sourceName,
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('相册配置已保存')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoCard(
          icon: Icons.folder_copy_outlined,
          title: '备份源',
          subtitle: widget.preferences.sourceName,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: widget.onChooseSource,
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('选择来源'),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _targetController,
          decoration: const InputDecoration(
            labelText: '目标目录',
            prefixIcon: Icon(Icons.cloud_queue),
          ),
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('自动同步'),
          subtitle: const Text('进入相册时上传新增照片和视频'),
          value: widget.preferences.autoBackup,
          onChanged: (value) => _save(autoBackup: value),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _saving ? null : () => _save(),
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('保存配置'),
          ),
        ),
      ],
    );
  }
}

class _LocalGrid extends StatelessWidget {
  const _LocalGrid({required this.items});

  final List<LocalMediaAsset> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemBuilder: (context, index) {
        return _LocalTile(asset: items[index]);
      },
    );
  }
}

class _RemoteGrid extends StatelessWidget {
  const _RemoteGrid({
    required this.client,
    required this.items,
  });

  final UnraidClient? client;
  final List<UnraidFileEntry> items;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 6,
        crossAxisSpacing: 6,
      ),
      itemBuilder: (context, index) {
        return _RemoteTile(client: client, entry: items[index]);
      },
    );
  }
}

class _LocalTile extends StatelessWidget {
  const _LocalTile({required this.asset});

  final LocalMediaAsset asset;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: LocalMediaStore.loadThumbnail(asset.uri),
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null || bytes.isEmpty) {
                return const ColoredBox(
                  color: AppTheme.inputBackground,
                  child: Icon(Icons.image_outlined, color: AppTheme.textLight),
                );
              }
              return Image.memory(bytes, fit: BoxFit.cover);
            },
          ),
          if (asset.isVideo)
            const Positioned(
              right: 6,
              bottom: 6,
              child: _MediaBadge(icon: Icons.play_arrow),
            ),
        ],
      ),
    );
  }
}

class _RemoteTile extends StatelessWidget {
  const _RemoteTile({
    required this.client,
    required this.entry,
  });

  final UnraidClient? client;
  final UnraidFileEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.isVideo || client == null) {
      return _RemotePlaceholder(entry: entry);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FutureBuilder<Uint8List>(
        future: client!.fetchFileBytes(entry.path),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return _RemotePlaceholder(entry: entry);
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _RemotePlaceholder(entry: entry),
          );
        },
      ),
    );
  }
}

class _RemotePlaceholder extends StatelessWidget {
  const _RemotePlaceholder({required this.entry});

  final UnraidFileEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.inputBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Icon(
            entry.isVideo ? Icons.movie_outlined : Icons.image_outlined,
            color: AppTheme.textLight,
          ),
          Positioned(
            left: 6,
            right: 6,
            bottom: 6,
            child: Text(
              entry.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textMedium,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MediaBadge extends StatelessWidget {
  const _MediaBadge({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white, size: 17),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    required this.title,
    required this.count,
  });

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(color: AppTheme.textLight),
        ),
      ],
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.child,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: AppTheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textMedium),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (child != null) child!,
        ],
      ),
    );
  }
}

class _KeyValueCard extends StatelessWidget {
  const _KeyValueCard({required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.inputBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Column(
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 76,
                    child: Text(
                      row.$1,
                      style: const TextStyle(color: AppTheme.textLight),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.$2,
                      textAlign: TextAlign.right,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 56),
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

class _InlineState extends StatelessWidget {
  const _InlineState({
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
      padding: const EdgeInsets.symmetric(vertical: 42),
      child: Column(
        children: [
          Icon(icon, size: 42, color: AppTheme.primary),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 19,
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

class _LocalSection {
  const _LocalSection({
    required this.title,
    required this.items,
  });

  final String title;
  final List<LocalMediaAsset> items;
}

class _RemoteSection {
  const _RemoteSection({
    required this.title,
    required this.items,
  });

  final String title;
  final List<UnraidFileEntry> items;
}

Future<bool> _requestMediaAccess() async {
  // Desktop/web: local media MethodChannel is Android-only; open the page and
  // let the store return an empty list instead of blocking the whole feature.
  final isMobile = defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
  if (kIsWeb || !isMobile) {
    return true;
  }

  // Android 13+ uses granular media permissions; older releases use storage.
  // Limited / partial access is treated as usable so the album can still open.
  try {
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();
    if (photos.isGranted ||
        photos.isLimited ||
        videos.isGranted ||
        videos.isLimited) {
      return true;
    }
  } catch (_) {
    // Some platforms do not expose photos/videos permissions.
  }

  try {
    final storage = await Permission.storage.request();
    if (storage.isGranted || storage.isLimited) {
      return true;
    }
  } catch (_) {
    // Fall through to denied.
  }

  return false;
}

List<LocalMediaAsset> _findPendingUploads({
  required List<LocalMediaAsset> local,
  required List<UnraidFileEntry> remote,
  required String targetDir,
  required String sourceId,
}) {
  final remotePaths = remote
      .map((entry) => _relativePath(targetDir, entry.path).toLowerCase())
      .toSet();
  return local
      .where((asset) => sourceId.isEmpty || asset.bucketId == sourceId)
      .where((asset) {
        final relative = _relativePath(targetDir, _targetPathFor(targetDir, asset));
        return !remotePaths.contains(relative.toLowerCase());
      })
      .toList(growable: false);
}

List<_LocalSection> _groupLocalByDate(List<LocalMediaAsset> media) {
  final buckets = <String, List<LocalMediaAsset>>{};
  for (final asset in media) {
    final title = _dateTitle(asset.dateModified);
    buckets.putIfAbsent(title, () => <LocalMediaAsset>[]).add(asset);
  }
  return buckets.entries
      .map((entry) => _LocalSection(title: entry.key, items: entry.value))
      .toList(growable: false);
}

List<_RemoteSection> _groupRemoteByDate(List<UnraidFileEntry> entries) {
  final buckets = <String, List<UnraidFileEntry>>{};
  for (final entry in entries) {
    final date = entry.modifiedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    final title = date.millisecondsSinceEpoch == 0 ? '未知日期' : _dateTitle(date);
    buckets.putIfAbsent(title, () => <UnraidFileEntry>[]).add(entry);
  }
  return buckets.entries
      .map((entry) => _RemoteSection(title: entry.key, items: entry.value))
      .toList(growable: false);
}

String _targetPathFor(String targetDir, LocalMediaAsset asset) {
  final base = _trimSlash(_normalizeLocalPath(targetDir));
  final date = asset.dateModified;
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$base/$year/$month/$day/${_safeRemoteName(asset.name)}';
}

String _dateTitle(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final value = DateTime(date.year, date.month, date.day);
  if (value == today) {
    return '今天';
  }
  if (value == today.subtract(const Duration(days: 1))) {
    return '昨天';
  }
  return '${date.year}年${date.month.toString().padLeft(2, '0')}月${date.day.toString().padLeft(2, '0')}日';
}

String _safeRemoteName(String name) {
  final sanitized = name
      .replaceAll('/', '_')
      .replaceAll(r'\', '_')
      .replaceAll(RegExp(r'[\x00-\x1F]'), '_')
      .trim();
  if (sanitized.isEmpty) {
    return 'media_${DateTime.now().millisecondsSinceEpoch}';
  }
  return sanitized;
}

String _relativePath(String base, String path) {
  final normalizedBase = _trimSlash(_normalizeLocalPath(base));
  final normalizedPath = _normalizeLocalPath(path);
  if (normalizedPath == normalizedBase) {
    return '';
  }
  if (normalizedPath.startsWith('$normalizedBase/')) {
    return normalizedPath.substring(normalizedBase.length + 1);
  }
  return normalizedPath;
}

String _parentPath(String path) {
  final normalized = _normalizeLocalPath(path);
  final slash = normalized.lastIndexOf('/');
  if (slash <= 0) {
    return '/';
  }
  return normalized.substring(0, slash);
}

String _trimSlash(String path) {
  var value = path;
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _normalizeLocalPath(String path) {
  var normalized = path.trim().replaceAll(r'\', '/');
  if (normalized.isEmpty) {
    return '';
  }
  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }
  return _trimSlash(normalized.replaceAll(RegExp(r'/+'), '/'));
}
