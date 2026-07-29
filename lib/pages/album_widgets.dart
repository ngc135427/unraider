part of 'album_page.dart';

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

class _LocalTimeline extends StatefulWidget {
  const _LocalTimeline({
    required this.loading,
    required this.media,
    required this.videosOnly,
    required this.padding,
  });

  final bool loading;
  final List<LocalMediaAsset> media;
  final bool videosOnly;
  final EdgeInsets padding;

  @override
  State<_LocalTimeline> createState() => _LocalTimelineState();
}

class _LocalTimelineState extends State<_LocalTimeline> {
  List<LocalMediaAsset>? _mediaRef;
  List<_LocalSection> _sections = const <_LocalSection>[];

  List<_LocalSection> get _groupedSections {
    if (identical(_mediaRef, widget.media)) {
      return _sections;
    }
    _mediaRef = widget.media;
    _sections = _groupLocalByDate(widget.media);
    return _sections;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return SliverPadding(
        padding: widget.padding,
        sliver: const SliverToBoxAdapter(
          child: _LoadingState(label: '正在读取本机相册'),
        ),
      );
    }
    if (widget.media.isEmpty) {
      return SliverPadding(
        padding: widget.padding,
        sliver: SliverToBoxAdapter(
          child: _InlineState(
            icon: widget.videosOnly
                ? Icons.video_library_outlined
                : Icons.photo_outlined,
            title: widget.videosOnly ? '没有视频' : '没有照片或视频',
            detail: '请检查系统媒体权限',
          ),
        ),
      );
    }

    final sections = _groupedSections;
    // One sliver per day: off-screen day grids are not built until scrolled.
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final section = sections[index];
            final visible = section.items.length <= _maxAlbumSectionTiles
                ? section.items
                : section.items
                    .take(_maxAlbumSectionTiles)
                    .toList(growable: false);
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == sections.length - 1 ? 0 : 22,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(
                    title: section.title,
                    count: section.items.length,
                  ),
                  const SizedBox(height: 10),
                  _LocalGrid(items: visible),
                  if (section.items.length > _maxAlbumSectionTiles) ...[
                    const SizedBox(height: 8),
                    Text(
                      '该日共 ${section.items.length} 项，仅显示前 $_maxAlbumSectionTiles 项',
                      style: const TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
          childCount: sections.length,
          addAutomaticKeepAlives: false,
        ),
      ),
    );
  }
}

class _RemoteTimeline extends StatefulWidget {
  const _RemoteTimeline({
    required this.loading,
    required this.entries,
    required this.client,
    required this.padding,
    this.error,
    this.onRetry,
  });

  final bool loading;
  final String? error;
  final UnraidClient? client;
  final List<UnraidFileEntry> entries;
  final VoidCallback? onRetry;
  final EdgeInsets padding;

  @override
  State<_RemoteTimeline> createState() => _RemoteTimelineState();
}

class _RemoteTimelineState extends State<_RemoteTimeline> {
  List<UnraidFileEntry>? _entriesRef;
  List<_RemoteSection> _sections = const <_RemoteSection>[];

  List<_RemoteSection> get _groupedSections {
    if (identical(_entriesRef, widget.entries)) {
      return _sections;
    }
    _entriesRef = widget.entries;
    _sections = _groupRemoteByDate(widget.entries);
    return _sections;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return SliverPadding(
        padding: widget.padding,
        sliver: const SliverToBoxAdapter(
          child: _LoadingState(label: '正在读取 Unraid 相册'),
        ),
      );
    }
    if (widget.error != null) {
      return SliverPadding(
        padding: widget.padding,
        sliver: SliverToBoxAdapter(
          child: _InlineState(
            icon: Icons.cloud_off_outlined,
            title: '云端读取失败',
            detail: widget.error!,
            actionLabel: '重试',
            onAction: widget.onRetry,
          ),
        ),
      );
    }
    if (widget.entries.isEmpty) {
      return SliverPadding(
        padding: widget.padding,
        sliver: const SliverToBoxAdapter(
          child: _InlineState(
            icon: Icons.cloud_queue,
            title: '云端暂无媒体',
            detail: '同步后会出现在这里',
          ),
        ),
      );
    }

    final sections = _groupedSections;
    return SliverPadding(
      padding: widget.padding,
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final section = sections[index];
            final visible = section.items.length <= _maxAlbumSectionTiles
                ? section.items
                : section.items
                    .take(_maxAlbumSectionTiles)
                    .toList(growable: false);
            return Padding(
              padding: EdgeInsets.only(
                bottom: index == sections.length - 1 ? 0 : 22,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionTitle(
                    title: section.title,
                    count: section.items.length,
                  ),
                  const SizedBox(height: 10),
                  _RemoteGrid(client: widget.client, items: visible),
                  if (section.items.length > _maxAlbumSectionTiles) ...[
                    const SizedBox(height: 8),
                    Text(
                      '该日共 ${section.items.length} 项，仅显示前 $_maxAlbumSectionTiles 项',
                      style: const TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
          childCount: sections.length,
          addAutomaticKeepAlives: false,
        ),
      ),
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
        return RepaintBoundary(
          child: _LocalTile(asset: items[index]),
        );
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
        return RepaintBoundary(
          child: _RemoteTile(client: client, entry: items[index]),
        );
      },
    );
  }
}

class _LocalTile extends StatefulWidget {
  const _LocalTile({required this.asset});

  final LocalMediaAsset asset;

  @override
  State<_LocalTile> createState() => _LocalTileState();
}

class _LocalTileState extends State<_LocalTile> {
  late final Future<Uint8List?> _thumbnailFuture =
      LocalMediaStore.loadThumbnail(widget.asset.uri);

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _thumbnailFuture,
            builder: (context, snapshot) {
              final bytes = snapshot.data;
              if (bytes == null || bytes.isEmpty) {
                return const ColoredBox(
                  color: AppTheme.inputBackground,
                  child: Icon(Icons.image_outlined, color: AppTheme.textLight),
                );
              }
              return Image.memory(
                bytes,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                cacheWidth: _maxAlbumTileDecodeExtent,
                cacheHeight: _maxAlbumTileDecodeExtent,
              );
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

class _RemoteTile extends StatefulWidget {
  const _RemoteTile({
    required this.client,
    required this.entry,
  });

  final UnraidClient? client;
  final UnraidFileEntry entry;

  @override
  State<_RemoteTile> createState() => _RemoteTileState();
}

class _RemoteTileState extends State<_RemoteTile> {
  Future<Uint8List?>? _bytesFuture;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _RemoteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.client != widget.client) {
      _bytesFuture = _loadThumbnail();
    }
  }

  Future<Uint8List?> _loadThumbnail() {
    final client = widget.client;
    final entry = widget.entry;
    if (client == null || entry.isVideo) {
      return Future<Uint8List?>.value();
    }
    if (entry.sizeBytes > _maxAlbumPreviewBytes) {
      return Future<Uint8List?>.value();
    }

    final cached = _remoteThumbnailCache.remove(entry.path);
    if (cached != null) {
      // LRU touch: reinsert so hot tiles outlive cold ones under the cap.
      _remoteThumbnailCache[entry.path] = cached;
      return cached;
    }

    final future = _withRemoteThumbnailSlot(() async {
      try {
        final bytes = await client.fetchFileBytes(entry.path);
        if (bytes.isEmpty) {
          return null;
        }
        return bytes;
      } on Object {
        return null;
      }
    });

    if (_remoteThumbnailCache.length >= _maxRemoteThumbnailCacheEntries) {
      _remoteThumbnailCache.remove(_remoteThumbnailCache.keys.first);
    }
    _remoteThumbnailCache[entry.path] = future;
    return future;
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    if (entry.isVideo || widget.client == null) {
      return _RemotePlaceholder(entry: entry);
    }
    if (entry.sizeBytes > _maxAlbumPreviewBytes) {
      return _RemotePlaceholder(entry: entry);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: FutureBuilder<Uint8List?>(
        future: _bytesFuture,
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const ColoredBox(
                color: AppTheme.inputBackground,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              );
            }
            return _RemotePlaceholder(entry: entry);
          }
          return Image.memory(
            bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            cacheWidth: _maxAlbumTileDecodeExtent,
            cacheHeight: _maxAlbumTileDecodeExtent,
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

