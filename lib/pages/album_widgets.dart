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

class _AlbumManagementPanel extends StatefulWidget {
  const _AlbumManagementPanel({
    required this.repository,
    required this.onLibraryChanged,
  });

  final AlbumBackupRepository? repository;
  final Future<void> Function() onLibraryChanged;

  @override
  State<_AlbumManagementPanel> createState() => _AlbumManagementPanelState();
}

class _AlbumManagementPanelState extends State<_AlbumManagementPanel> {
  final TextEditingController _searchController = TextEditingController();
  List<AlbumMediaAsset> _results = const <AlbumMediaAsset>[];
  List<AlbumLogicalAlbum> _albums = const <AlbumLogicalAlbum>[];
  List<AlbumDuplicateGroup> _duplicates = const <AlbumDuplicateGroup>[];
  final Set<String> _selectedAssetIds = <String>{};
  AlbumMediaKind? _kind;
  DateTimeRange? _dateRange;
  bool _loading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant _AlbumManagementPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.repository != widget.repository) unawaited(_reload());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final repository = widget.repository;
    if (repository == null) return;
    setState(() => _loading = true);
    try {
      final values = await Future.wait<Object>([
        repository.searchMedia(
          query: _searchController.text,
          kind: _kind,
          fromMs: _dateRange?.start.millisecondsSinceEpoch,
          toMs: _dateRange == null
              ? null
              : DateTime(_dateRange!.end.year, _dateRange!.end.month,
                          _dateRange!.end.day + 1)
                      .millisecondsSinceEpoch -
                  1,
        ),
        repository.listLogicalAlbums(),
      ]);
      if (!mounted) return;
      setState(() {
        _results = values[0] as List<AlbumMediaAsset>;
        _albums = values[1] as List<AlbumLogicalAlbum>;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _createAlbum() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建逻辑相册'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '相册名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await widget.repository?.createLogicalAlbum(name);
    await _reload();
  }

  Future<void> _addSelectionToAlbum(AlbumLogicalAlbum album) async {
    if (_selectedAssetIds.isEmpty) return;
    await widget.repository?.addAssetsToLogicalAlbum(
      albumId: album.id,
      assetIds: _selectedAssetIds,
    );
    if (!mounted) return;
    setState(() {
      _message = '已将 ${_selectedAssetIds.length} 项加入“${album.name}”';
      _selectedAssetIds.clear();
    });
    await _reload();
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 1),
      initialDateRange: _dateRange,
    );
    if (selected == null || !mounted) return;
    setState(() => _dateRange = selected);
    await _reload();
  }

  Future<void> _openAlbum(AlbumLogicalAlbum album) async {
    final repository = widget.repository;
    if (repository == null) return;
    final assets = await repository.listLogicalAlbumAssets(albumId: album.id);
    if (!mounted) return;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(album.name),
        content: SizedBox(
          width: 520,
          child: assets.isEmpty
              ? const Text('这个逻辑相册还没有项目。')
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: assets.length,
                  itemBuilder: (context, index) {
                    final asset = assets[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        asset.kind == AlbumMediaKind.video
                            ? Icons.videocam_outlined
                            : Icons.image_outlined,
                      ),
                      title: Text(asset.displayName),
                      subtitle: Text(asset.relativePath),
                    );
                  },
                ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.of(context).pop('delete'),
            icon: const Icon(Icons.delete_outline),
            label: const Text('删除逻辑相册'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (action != 'delete' || !mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除逻辑相册？'),
        content: Text('只删除“${album.name}”的引用，不会删除任何照片或视频原件。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('删除相册'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.deleteLogicalAlbum(album.id);
    await _reload();
  }

  Future<void> _editMetadata(AlbumMediaAsset asset) async {
    final repository = widget.repository;
    if (repository == null) return;
    final metadata = await repository.assetMetadata(asset.id);
    if (!mounted) return;
    var favorite = metadata.favorite;
    var archived = metadata.archived;
    var rating = metadata.rating;
    final tags = TextEditingController(text: metadata.tags.join(', '));
    final description = TextEditingController(text: metadata.description);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('编辑 ${asset.displayName}'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SwitchListTile(
                    value: favorite,
                    title: const Text('收藏'),
                    onChanged: (value) =>
                        setDialogState(() => favorite = value),
                  ),
                  SwitchListTile(
                    value: archived,
                    title: const Text('归档'),
                    onChanged: (value) =>
                        setDialogState(() => archived = value),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: rating,
                    decoration: const InputDecoration(labelText: '评分'),
                    items: List.generate(
                      6,
                      (value) => DropdownMenuItem(
                        value: value,
                        child: Text(value == 0 ? '未评分' : '$value 星'),
                      ),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => rating = value ?? 0),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tags,
                    decoration: const InputDecoration(
                      labelText: '标签',
                      hintText: '多个标签用逗号分隔',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: description,
                    maxLines: 3,
                    decoration: const InputDecoration(labelText: '描述'),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      await repository.updateAssetMetadata(
        assetId: asset.id,
        favorite: favorite,
        archived: archived,
        tags: tags.text.split(RegExp(r'[,，]')),
        description: description.text,
        rating: rating,
      );
      await _reload();
    }
    tags.dispose();
    description.dispose();
  }

  Future<void> _reviewDuplicateGroup(AlbumDuplicateGroup group) async {
    final repository = widget.repository;
    if (repository == null) return;
    final preview = await AlbumManagementService(repository).freeSpacePreview();
    final verifiedIds = preview.assets.map((asset) => asset.id).toSet();
    final candidates = group.assets
        .where((asset) => verifiedIds.contains(asset.id))
        .toList(growable: false);
    if (!mounted) return;
    if (candidates.isEmpty) {
      setState(() => _message = '这组重复项尚无远端已验证副本，不能安全删除');
      return;
    }
    final selected = <String>{};
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('复核精确重复项'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('只允许选择远端原件已验证的项目，并且至少保留一个本地副本。'),
                const SizedBox(height: 8),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final asset in group.assets)
                        CheckboxListTile(
                          value: selected.contains(asset.id),
                          title: Text(asset.displayName),
                          subtitle: Text(
                            verifiedIds.contains(asset.id)
                                ? asset.relativePath
                                : '${asset.relativePath} · 尚未验证，禁止删除',
                          ),
                          onChanged: !verifiedIds.contains(asset.id)
                              ? null
                              : (checked) {
                                  setDialogState(() {
                                    if (checked == true) {
                                      selected.add(asset.id);
                                    } else {
                                      selected.remove(asset.id);
                                    }
                                  });
                                },
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton.icon(
              onPressed:
                  selected.isEmpty || selected.length >= group.assets.length
                      ? null
                      : () => Navigator.of(context).pop(true),
              icon: const Icon(Icons.delete_outline),
              label: const Text('交由系统确认删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    final requested = candidates
        .where((asset) => selected.contains(asset.id))
        .toList(growable: false);
    final result = await AlbumManagementService(repository)
        .releaseVerifiedAssets(requested);
    if (!mounted) return;
    setState(() {
      _message = result.cancelled
          ? '用户取消了系统删除确认'
          : '重复项已删除 ${result.deleted}/${result.requested} 项';
    });
    if (result.deleted > 0) await widget.onLibraryChanged();
  }

  Future<void> _scanDuplicates() async {
    final repository = widget.repository;
    if (repository == null || _loading) return;
    setState(() {
      _loading = true;
      _message = '正在计算候选文件 SHA-256…';
    });
    try {
      final groups =
          await AlbumManagementService(repository).scanExactDuplicates(
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _message = '重复项强校验 ${progress.completed}/${progress.total}';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _duplicates = groups;
        _message = groups.isEmpty ? '没有发现精确重复项' : '发现 ${groups.length} 组精确重复项';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _releaseSpace() async {
    final repository = widget.repository;
    if (repository == null || _loading) return;
    setState(() {
      _loading = true;
      _message = '正在核对远端已验证状态…';
    });
    try {
      final service = AlbumManagementService(repository);
      final preview = await service.freeSpacePreview();
      if (!mounted) return;
      if (preview.assets.isEmpty) {
        setState(() => _message = '没有可安全释放的项目');
        return;
      }
      final selected = preview.assets.map((asset) => asset.id).toSet();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('释放手机空间'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '仅列出远端原件大小已验证的媒体。已选 ${selected.length} 项，'
                    '约 ${_formatManagementBytes(preview.assets.where((asset) => selected.contains(asset.id)).fold<int>(0, (sum, asset) => sum + asset.sizeBytes))}。',
                  ),
                  const SizedBox(height: 10),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: preview.assets.length,
                      itemBuilder: (context, index) {
                        final asset = preview.assets[index];
                        return CheckboxListTile(
                          value: selected.contains(asset.id),
                          title: Text(asset.displayName),
                          subtitle: Text(
                            '${asset.relativePath} · ${_formatManagementBytes(asset.sizeBytes)}',
                          ),
                          onChanged: (checked) {
                            setDialogState(() {
                              if (checked == true) {
                                selected.add(asset.id);
                              } else {
                                selected.remove(asset.id);
                              }
                            });
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: selected.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('交由系统确认删除'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true || !mounted) return;
      final requested = preview.assets
          .where((asset) => selected.contains(asset.id))
          .toList(growable: false);
      final result = await service.releaseVerifiedAssets(requested);
      if (!mounted) return;
      setState(() {
        _message = result.cancelled
            ? '用户取消了系统删除确认'
            : '已释放 ${result.deleted}/${result.requested} 项';
      });
      if (result.deleted > 0) await widget.onLibraryChanged();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.repository == null) {
      return const Center(child: Text('相册索引不可用，无法打开管理功能'));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
      children: [
        TextField(
          controller: _searchController,
          decoration: InputDecoration(
            labelText: '按文件名、目录、标签或描述搜索',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: IconButton(
              onPressed: _reload,
              icon: const Icon(Icons.arrow_forward),
            ),
          ),
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _reload(),
        ),
        const SizedBox(height: 10),
        SegmentedButton<AlbumMediaKind?>(
          segments: const [
            ButtonSegment(value: null, label: Text('全部')),
            ButtonSegment(value: AlbumMediaKind.image, label: Text('照片')),
            ButtonSegment(value: AlbumMediaKind.video, label: Text('视频')),
          ],
          selected: <AlbumMediaKind?>{_kind},
          onSelectionChanged: (value) {
            setState(() => _kind = value.single);
            unawaited(_reload());
          },
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _loading ? null : _pickDateRange,
              icon: const Icon(Icons.date_range_outlined),
              label: Text(
                _dateRange == null
                    ? '按日期筛选'
                    : '${_dateRange!.start.year}-${_dateRange!.start.month}-${_dateRange!.start.day} 至 '
                        '${_dateRange!.end.year}-${_dateRange!.end.month}-${_dateRange!.end.day}',
              ),
            ),
            if (_dateRange != null) ...[
              IconButton.outlined(
                tooltip: '清除日期筛选',
                onPressed: _loading
                    ? null
                    : () {
                        setState(() => _dateRange = null);
                        unawaited(_reload());
                      },
                icon: const Icon(Icons.close),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _loading ? null : _createAlbum,
              icon: const Icon(Icons.create_new_folder_outlined),
              label: const Text('新建逻辑相册'),
            ),
            OutlinedButton.icon(
              onPressed: _loading ? null : _scanDuplicates,
              icon: const Icon(Icons.content_copy_outlined),
              label: const Text('复核重复项'),
            ),
            OutlinedButton.icon(
              onPressed: _loading ? null : _releaseSpace,
              icon: const Icon(Icons.cleaning_services_outlined),
              label: const Text('安全释放空间'),
            ),
          ],
        ),
        if (_loading) ...[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          Text(_message!, style: const TextStyle(color: AppTheme.textMedium)),
        ],
        if (_albums.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text('逻辑相册', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final album in _albums)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.photo_album_outlined),
              title: Text(album.name),
              subtitle: Text('${album.itemCount} 项 · 不复制原始文件'),
              onTap: () => _openAlbum(album),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_selectedAssetIds.isNotEmpty)
                    TextButton(
                      onPressed: () => _addSelectionToAlbum(album),
                      child: const Text('加入所选'),
                    ),
                  IconButton(
                    tooltip: '查看逻辑相册',
                    onPressed: () => _openAlbum(album),
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ),
        ],
        if (_duplicates.isNotEmpty) ...[
          const SizedBox(height: 18),
          const Text('精确重复项', style: TextStyle(fontWeight: FontWeight.w700)),
          for (final group in _duplicates)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy_all_outlined),
              title: Text('${group.assets.length} 个字节级相同文件'),
              subtitle: Text(
                '${_formatManagementBytes(group.sizeBytes)} · SHA-256 ${group.sha256.substring(0, 12)}…\n'
                '${group.assets.map((asset) => asset.displayName).join('、')}',
              ),
              isThreeLine: true,
              onTap: () => _reviewDuplicateGroup(group),
              trailing: const Icon(Icons.fact_check_outlined),
            ),
        ],
        const SizedBox(height: 18),
        Text('搜索结果（${_results.length}）',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        for (final asset in _results)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _selectedAssetIds.contains(asset.id),
            title: Text(asset.displayName),
            subtitle: Text(
              '${asset.relativePath} · ${asset.kind == AlbumMediaKind.video ? '视频' : '照片'} · '
              '${_formatManagementBytes(asset.sizeBytes)}',
            ),
            secondary: IconButton(
              tooltip: '收藏、标签、评分和描述',
              onPressed: () => _editMetadata(asset),
              icon: const Icon(Icons.edit_note_outlined),
            ),
            onChanged: (checked) {
              setState(() {
                if (checked == true) {
                  _selectedAssetIds.add(asset.id);
                } else {
                  _selectedAssetIds.remove(asset.id);
                }
              });
            },
          ),
      ],
    );
  }
}

String _formatManagementBytes(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024).toStringAsFixed(0)} KB';
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
      (
        _PhoAlbumTab.local,
        videosOnly ? Icons.video_library : Icons.photo_library,
        '本机'
      ),
      (_PhoAlbumTab.remote, Icons.cloud_outlined, '云端'),
      (_PhoAlbumTab.sync, Icons.sync, '同步'),
      (_PhoAlbumTab.manage, Icons.collections_bookmark_outlined, '管理'),
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
    required this.gallery,
    required this.videosOnly,
    required this.padding,
  });

  final bool loading;
  final List<LocalMediaAsset> media;

  /// Full visible gallery used for swipe navigation (may exceed section caps).
  final List<LocalMediaAsset> gallery;
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
                  _LocalGrid(items: visible, gallery: widget.gallery),
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
    required this.gallery,
    required this.client,
    required this.remoteRoot,
    required this.hasMore,
    required this.onLoadMore,
    required this.padding,
    this.error,
    this.onRetry,
  });

  final bool loading;
  final String? error;
  final UnraidClient? client;
  final String remoteRoot;
  final bool hasMore;
  final VoidCallback onLoadMore;
  final List<UnraidFileEntry> entries;

  /// Full remote gallery used for swipe navigation.
  final List<UnraidFileEntry> gallery;
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
            if (index == sections.length) {
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: OutlinedButton.icon(
                    onPressed: widget.loading ? null : widget.onLoadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('加载更多'),
                  ),
                ),
              );
            }
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
                  _RemoteGrid(
                    client: widget.client,
                    remoteRoot: widget.remoteRoot,
                    items: visible,
                    gallery: widget.gallery,
                  ),
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
          childCount: sections.length + (widget.hasMore ? 1 : 0),
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
    required this.paused,
    required this.backgroundStatus,
    required this.failedItems,
    required this.onSync,
    required this.onBackgroundSync,
    required this.onPauseResume,
    required this.onCancel,
    required this.onRetryAsset,
    required this.onSettings,
    this.message,
  });

  final AlbumBackupPreferences preferences;
  final int localCount;
  final int remoteCount;
  final int pendingCount;
  final int uploadedCount;
  final bool syncing;
  final bool paused;
  final String? message;
  final AlbumBackgroundStatus backgroundStatus;
  final List<_AlbumFailedItem> failedItems;
  final VoidCallback onSync;
  final VoidCallback onBackgroundSync;
  final VoidCallback onPauseResume;
  final VoidCallback onCancel;
  final ValueChanged<String> onRetryAsset;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final total = uploadedCount + pendingCount;
    final progress =
        total == 0 ? null : (uploadedCount / total).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoCard(
          icon: Icons.sync,
          title: syncing ? '正在同步' : '同步',
          subtitle:
              message ?? (pendingCount == 0 ? '已同步' : '$pendingCount 个待上传'),
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
            if (syncing) ('本轮已传', '$uploadedCount'),
            ('后台阶段', backgroundStatus.stage),
            if (backgroundStatus.lastSuccessMs > 0)
              (
                '最近成功',
                DateTime.fromMillisecondsSinceEpoch(
                  backgroundStatus.lastSuccessMs,
                ).toLocal().toString().substring(0, 16),
              ),
            if (backgroundStatus.lastError.isNotEmpty)
              ('后台诊断', backgroundStatus.actionableDiagnostic),
          ],
        ),
        if (failedItems.isNotEmpty) ...[
          const SizedBox(height: 12),
          _InfoCard(
            icon: Icons.error_outline,
            title: '失败项目（${failedItems.length}）',
            subtitle: '可以单独重试，也可以使用“立即同步”重试全部',
            child: Column(
              children: [
                for (final item in failedItems.take(5))
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(item.name, maxLines: 1),
                    subtitle: Text(item.error, maxLines: 2),
                    trailing: TextButton(
                      onPressed:
                          syncing ? null : () => onRetryAsset(item.assetId),
                      child: const Text('重试'),
                    ),
                  ),
                if (failedItems.length > 5)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('另有 ${failedItems.length - 5} 项，可使用全部重试'),
                  ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: syncing ? null : onSync,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: Text(syncing ? '同步中…' : '立即同步'),
              ),
            ),
            if (syncing) ...[
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onPauseResume,
                icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                label: Text(paused ? '继续' : '暂停'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: onCancel,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('取消'),
              ),
            ],
            const SizedBox(width: 12),
            IconButton.outlined(
              tooltip: '同步设置',
              onPressed: onSettings,
              icon: const Icon(Icons.tune),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: onBackgroundSync,
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('启动前台集中备份'),
          ),
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
    required this.nasHelperStatus,
    required this.nasHelperJob,
    required this.onProbeNasHelper,
    required this.onRunNasHelperRebuild,
    required this.onCancelNasHelperJob,
    required this.onRetryNasHelperJob,
  });

  final AlbumBackupPreferences preferences;
  final List<LocalMediaBucket> buckets;
  final Future<void> Function(AlbumBackupPreferences preferences) onSave;
  final VoidCallback onChooseSource;
  final AlbumNasHelperStatus nasHelperStatus;
  final AlbumNasHelperJob? nasHelperJob;
  final Future<void> Function() onProbeNasHelper;
  final Future<void> Function() onRunNasHelperRebuild;
  final Future<void> Function() onCancelNasHelperJob;
  final Future<void> Function() onRetryNasHelperJob;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  late final TextEditingController _targetController;
  late final TextEditingController _nasHelperUrlController;
  late final TextEditingController _nasHelperTokenController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _targetController = TextEditingController(
      text: widget.preferences.targetDir,
    );
    _nasHelperUrlController = TextEditingController(
      text: widget.preferences.nasHelperUrl,
    );
    _nasHelperTokenController = TextEditingController(
      text: widget.preferences.nasHelperToken,
    );
  }

  @override
  void didUpdateWidget(covariant _SettingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences.targetDir != widget.preferences.targetDir) {
      _targetController.text = widget.preferences.targetDir;
    }
    if (oldWidget.preferences.nasHelperUrl != widget.preferences.nasHelperUrl) {
      _nasHelperUrlController.text = widget.preferences.nasHelperUrl;
    }
    if (oldWidget.preferences.nasHelperToken !=
        widget.preferences.nasHelperToken) {
      _nasHelperTokenController.text = widget.preferences.nasHelperToken;
    }
  }

  @override
  void dispose() {
    _targetController.dispose();
    _nasHelperUrlController.dispose();
    _nasHelperTokenController.dispose();
    super.dispose();
  }

  Future<bool> _save({
    bool? autoBackup,
    AlbumInitialBackupMode? initialBackupMode,
    bool? wifiOnly,
    bool? chargingOnly,
    int? transferConcurrency,
    bool? nasHelperEnabled,
  }) async {
    final target = _normalizeLocalPath(_targetController.text);
    if (target.isEmpty ||
        (!target.startsWith('/mnt/') && !target.startsWith('/boot'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目标目录必须位于 /mnt 或 /boot 下')),
      );
      return false;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        AlbumBackupPreferences(
          autoBackup: autoBackup ?? widget.preferences.autoBackup,
          targetDir: target,
          sourceId: widget.preferences.sourceId,
          sourceIds: widget.preferences.sourceIds,
          sourceName: widget.preferences.sourceName,
          initialBackupMode:
              initialBackupMode ?? widget.preferences.initialBackupMode,
          deviceId: widget.preferences.deviceId,
          deviceName: widget.preferences.deviceName,
          wifiOnly: wifiOnly ?? widget.preferences.wifiOnly,
          chargingOnly: chargingOnly ?? widget.preferences.chargingOnly,
          transferConcurrency:
              transferConcurrency ?? widget.preferences.transferConcurrency,
          nasHelperEnabled:
              nasHelperEnabled ?? widget.preferences.nasHelperEnabled,
          nasHelperUrl: _nasHelperUrlController.text.trim(),
          nasHelperToken: _nasHelperTokenController.text.trim(),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('相册配置已保存')),
        );
      }
      return true;
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('相册配置保存失败：$error')),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
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
        DropdownButtonFormField<AlbumInitialBackupMode>(
          initialValue: widget.preferences.initialBackupMode,
          decoration: const InputDecoration(
            labelText: '首次备份范围',
            prefixIcon: Icon(Icons.history_toggle_off),
          ),
          items: const [
            DropdownMenuItem(
              value: AlbumInitialBackupMode.all,
              child: Text('备份全部现有照片和视频'),
            ),
            DropdownMenuItem(
              value: AlbumInitialBackupMode.newOnly,
              child: Text('从现在开始，仅备份新增'),
            ),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) {
                    _save(initialBackupMode: value);
                  }
                },
        ),
        const SizedBox(height: 14),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('自动同步'),
          subtitle: const Text('由系统后台发现并上传新增照片和视频'),
          value: widget.preferences.autoBackup,
          onChanged: (value) => _save(autoBackup: value),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('仅 Wi-Fi'),
          subtitle: const Text('后台任务只在不计费网络下运行'),
          value: widget.preferences.wifiOnly,
          onChanged: (value) => _save(wifiOnly: value),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('仅充电时'),
          subtitle: const Text('适合首次大批量备份'),
          value: widget.preferences.chargingOnly,
          onChanged: (value) => _save(chargingOnly: value),
        ),
        const SizedBox(height: 10),
        DropdownButtonFormField<int>(
          initialValue: widget.preferences.transferConcurrency,
          decoration: const InputDecoration(
            labelText: '同一目标并发数',
            prefixIcon: Icon(Icons.speed),
          ),
          items: const [
            DropdownMenuItem(value: 1, child: Text('1（兼容）')),
            DropdownMenuItem(value: 2, child: Text('2')),
            DropdownMenuItem(value: 4, child: Text('4')),
            DropdownMenuItem(value: 8, child: Text('8（推荐）')),
            DropdownMenuItem(value: 12, child: Text('12（高速）')),
            DropdownMenuItem(value: 16, child: Text('16（小文件高吞吐）')),
          ],
          onChanged: _saving
              ? null
              : (value) {
                  if (value != null) _save(transferConcurrency: value);
                },
        ),
        const SizedBox(height: 14),
        const Divider(),
        const SizedBox(height: 8),
        const Text(
          '可选 NAS 助手',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        const SizedBox(height: 6),
        const Text(
          '在 Unraid 本地索引历史图库并生成缩略图、视频封面和完整性数据；不可用时自动回退到纯客户端模式。',
          style: TextStyle(color: AppTheme.textMedium),
        ),
        SwitchListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          title: const Text('启用 NAS 助手'),
          subtitle: Text(widget.nasHelperStatus.message),
          value: widget.preferences.nasHelperEnabled,
          onChanged: _saving ? null : (value) => _save(nasHelperEnabled: value),
        ),
        TextField(
          controller: _nasHelperUrlController,
          enabled: widget.preferences.nasHelperEnabled && !_saving,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '助手地址',
            hintText: 'http://unraid:9487',
            prefixIcon: Icon(Icons.dns_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _nasHelperTokenController,
          enabled: widget.preferences.nasHelperEnabled && !_saving,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '助手访问令牌',
            prefixIcon: Icon(Icons.key_outlined),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: !widget.preferences.nasHelperEnabled || _saving
                  ? null
                  : () async {
                      if (await _save()) {
                        await widget.onProbeNasHelper();
                      }
                    },
              icon: const Icon(Icons.wifi_tethering_outlined),
              label: const Text('检测助手'),
            ),
            FilledButton.tonalIcon(
              onPressed: !widget.preferences.nasHelperEnabled ||
                      _saving ||
                      !widget.nasHelperStatus.isReady ||
                      (widget.nasHelperJob != null &&
                          !widget.nasHelperJob!.isFinished)
                  ? null
                  : widget.onRunNasHelperRebuild,
              icon: const Icon(Icons.auto_fix_high_outlined),
              label: const Text('索引并生成历史预览'),
            ),
          ],
        ),
        if (widget.nasHelperJob != null) ...[
          const SizedBox(height: 12),
          _NasHelperJobCard(
            job: widget.nasHelperJob!,
            onCancel: widget.onCancelNasHelperJob,
            onRetry: widget.onRetryNasHelperJob,
          ),
        ],
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

class _NasHelperJobCard extends StatelessWidget {
  const _NasHelperJobCard({
    required this.job,
    required this.onCancel,
    required this.onRetry,
  });

  final AlbumNasHelperJob job;
  final Future<void> Function() onCancel;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final running = job.state == 'queued' || job.state == 'running';
    final failed = job.state == 'failed';
    final label = switch (job.state) {
      'queued' => '等待执行',
      'running' => '正在执行',
      'completed' => '执行完成',
      'failed' => '执行失败',
      'cancelled' => '已取消',
      _ => job.state,
    };
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                failed ? Icons.error_outline : Icons.memory_outlined,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'NAS 作业 · $label',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              if (running)
                TextButton(onPressed: onCancel, child: const Text('取消'))
              else
                TextButton(onPressed: onRetry, child: const Text('重新运行')),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value:
                job.total > 0 ? job.progress.clamp(0, 1) : (running ? null : 1),
          ),
          const SizedBox(height: 8),
          Text(
            job.lastError ??
                job.message ??
                (job.total > 0 ? '${job.processed}/${job.total}' : '正在准备作业'),
            style: const TextStyle(color: AppTheme.textMedium),
          ),
        ],
      ),
    );
  }
}

class _LocalGrid extends StatelessWidget {
  const _LocalGrid({
    required this.items,
    required this.gallery,
  });

  final List<LocalMediaAsset> items;
  final List<LocalMediaAsset> gallery;

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
        final asset = items[index];
        return RepaintBoundary(
          child: _LocalTile(
            asset: asset,
            onTap: () => _openLocalPreview(
              context,
              gallery: gallery,
              asset: asset,
            ),
          ),
        );
      },
    );
  }
}

class _RemoteGrid extends StatelessWidget {
  const _RemoteGrid({
    required this.client,
    required this.remoteRoot,
    required this.items,
    required this.gallery,
  });

  final UnraidClient? client;
  final String remoteRoot;
  final List<UnraidFileEntry> items;
  final List<UnraidFileEntry> gallery;

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
        final entry = items[index];
        return RepaintBoundary(
          child: _RemoteTile(
            client: client,
            remoteRoot: remoteRoot,
            entry: entry,
            onTap: () => _openRemotePreview(
              context,
              client: client,
              gallery: gallery,
              entry: entry,
            ),
          ),
        );
      },
    );
  }
}

class _LocalTile extends StatefulWidget {
  const _LocalTile({
    required this.asset,
    required this.onTap,
  });

  final LocalMediaAsset asset;
  final VoidCallback onTap;

  @override
  State<_LocalTile> createState() => _LocalTileState();
}

class _LocalTileState extends State<_LocalTile> {
  late final Future<Uint8List?> _thumbnailFuture =
      LocalMediaStore.loadThumbnail(widget.asset.uri);

  @override
  Widget build(BuildContext context) {
    final asset = widget.asset;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
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
                      child: Icon(
                        Icons.image_outlined,
                        color: AppTheme.textLight,
                      ),
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
        ),
      ),
    );
  }
}

class _RemoteTile extends StatefulWidget {
  const _RemoteTile({
    required this.client,
    required this.remoteRoot,
    required this.entry,
    required this.onTap,
  });

  final UnraidClient? client;
  final String remoteRoot;
  final UnraidFileEntry entry;
  final VoidCallback onTap;

  @override
  State<_RemoteTile> createState() => _RemoteTileState();
}

class _RemoteTileState extends State<_RemoteTile> {
  Future<Uint8List?>? _bytesFuture;
  AlbumPreviewCancellation? _previewCancellation;

  @override
  void initState() {
    super.initState();
    _bytesFuture = _loadThumbnail();
  }

  @override
  void didUpdateWidget(covariant _RemoteTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path ||
        oldWidget.entry.sizeBytes != widget.entry.sizeBytes ||
        oldWidget.entry.modifiedDate != widget.entry.modifiedDate ||
        oldWidget.entry.thumbnailPath != widget.entry.thumbnailPath ||
        oldWidget.remoteRoot != widget.remoteRoot ||
        oldWidget.client != widget.client) {
      _previewCancellation?.cancel();
      _bytesFuture = _loadThumbnail();
    }
  }

  Future<Uint8List?> _loadThumbnail() {
    final client = widget.client;
    final entry = widget.entry;
    if (client == null) {
      return Future<Uint8List?>.value();
    }
    final versionKey =
        '${entry.sizeBytes}:${entry.modifiedDate?.millisecondsSinceEpoch ?? 0}';
    final cancellation = AlbumPreviewCancellation();
    _previewCancellation = cancellation;
    return _albumPreviewCache.load(
      client: client,
      destinationId: albumDestinationId(widget.remoteRoot),
      remoteRoot: widget.remoteRoot,
      remotePath: entry.path,
      versionKey: versionKey,
      isVideo: entry.isVideo,
      preferredSidecarPath: entry.thumbnailPath,
      cancellation: cancellation,
    );
  }

  @override
  void dispose() {
    _previewCancellation?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    Widget child;
    if (widget.client == null) {
      child = _RemotePlaceholder(entry: entry);
    } else {
      child = ClipRRect(
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

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (entry.isVideo)
              Positioned(
                right: 6,
                bottom: 6,
                child: _MediaBadge(
                  icon: Icons.play_arrow,
                  label: entry.durationMs <= 0
                      ? null
                      : _formatAlbumDuration(entry.durationMs),
                ),
              ),
          ],
        ),
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
  const _MediaBadge({required this.icon, this.label});

  final IconData icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: EdgeInsets.symmetric(horizontal: label == null ? 3 : 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 17),
          if (label != null) ...[
            const SizedBox(width: 2),
            Text(
              label!,
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}

String _formatAlbumDuration(int durationMs) {
  final totalSeconds = durationMs ~/ 1000;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  final seconds = totalSeconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
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

Future<void> _openLocalPreview(
  BuildContext context, {
  required List<LocalMediaAsset> gallery,
  required LocalMediaAsset asset,
}) async {
  final items = gallery.isEmpty ? <LocalMediaAsset>[asset] : gallery;
  var index = items.indexWhere((item) => item.id == asset.id);
  if (index < 0) {
    index = 0;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: _LocalMediaPreview(
        items: items,
        initialIndex: index,
      ),
    ),
  );
}

Future<void> _openRemotePreview(
  BuildContext context, {
  required UnraidClient? client,
  required List<UnraidFileEntry> gallery,
  required UnraidFileEntry entry,
}) async {
  if (client == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('缺少服务器连接')),
    );
    return;
  }
  final items = gallery.isEmpty ? <UnraidFileEntry>[entry] : gallery;
  var index = items.indexWhere((item) => item.path == entry.path);
  if (index < 0) {
    index = 0;
  }
  await showDialog<void>(
    context: context,
    builder: (context) => Dialog.fullscreen(
      child: _RemoteMediaPreview(
        client: client,
        items: items,
        initialIndex: index,
      ),
    ),
  );
}

class _LocalMediaPreview extends StatefulWidget {
  const _LocalMediaPreview({
    required this.items,
    required this.initialIndex,
  });

  final List<LocalMediaAsset> items;
  final int initialIndex;

  @override
  State<_LocalMediaPreview> createState() => _LocalMediaPreviewState();
}

class _LocalMediaPreviewState extends State<_LocalMediaPreview> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next == _index) {
      return;
    }
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.items[_index];
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreviewChrome(
              title: widget.items.length > 1
                  ? '${asset.name}  ${_index + 1}/${widget.items.length}'
                  : asset.name,
              canGoBack: _index > 0,
              canGoForward: _index < widget.items.length - 1,
              onBack: () => _go(-1),
              onForward: () => _go(1),
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.items.length,
                allowImplicitScrolling: false,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final distance = (index - _index).abs();
                  final item = widget.items[index];
                  return item.isVideo
                      ? _LocalVideoPreviewPage(
                          key: ValueKey<String>('lv:${item.id}'),
                          asset: item,
                          active: distance == 0,
                        )
                      : _LocalImagePreviewPage(
                          key: ValueKey<String>('li:${item.id}'),
                          asset: item,
                          active: distance <= 1,
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

class _RemoteMediaPreview extends StatefulWidget {
  const _RemoteMediaPreview({
    required this.client,
    required this.items,
    required this.initialIndex,
  });

  final UnraidClient client;
  final List<UnraidFileEntry> items;
  final int initialIndex;

  @override
  State<_RemoteMediaPreview> createState() => _RemoteMediaPreviewState();
}

class _RemoteMediaPreviewState extends State<_RemoteMediaPreview> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, widget.items.length - 1);
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = (_index + delta).clamp(0, widget.items.length - 1);
    if (next == _index) {
      return;
    }
    _controller.animateToPage(
      next,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.items[_index];
    return ColoredBox(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _PreviewChrome(
              title: widget.items.length > 1
                  ? '${entry.name}  ${_index + 1}/${widget.items.length}'
                  : entry.name,
              canGoBack: _index > 0,
              canGoForward: _index < widget.items.length - 1,
              onBack: () => _go(-1),
              onForward: () => _go(1),
              onClose: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.items.length,
                allowImplicitScrolling: false,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (context, index) {
                  final distance = (index - _index).abs();
                  final item = widget.items[index];
                  return item.isVideo
                      ? _RemoteVideoPreviewPage(
                          key: ValueKey<String>('rv:${item.path}'),
                          client: widget.client,
                          entry: item,
                          active: distance == 0,
                        )
                      : _RemoteImagePreviewPage(
                          key: ValueKey<String>('ri:${item.path}'),
                          client: widget.client,
                          entry: item,
                          active: distance <= 1,
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

class _PreviewChrome extends StatelessWidget {
  const _PreviewChrome({
    required this.title,
    required this.canGoBack,
    required this.canGoForward,
    required this.onBack,
    required this.onForward,
    required this.onClose,
  });

  final String title;
  final bool canGoBack;
  final bool canGoForward;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: Row(
        children: [
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: '上一项',
            onPressed: canGoBack ? onBack : null,
            icon: const Icon(Icons.chevron_left, color: Colors.white),
          ),
          IconButton(
            tooltip: '下一项',
            onPressed: canGoForward ? onForward : null,
            icon: const Icon(Icons.chevron_right, color: Colors.white),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }
}

class _AlbumPreviewMessage extends StatelessWidget {
  const _AlbumPreviewMessage({
    required this.message,
    this.color = Colors.white70,
  });

  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontSize: 15, height: 1.4),
        ),
      ),
    );
  }
}

Future<File> _loadLocalFullscreenFile(LocalMediaAsset asset) {
  final uri = asset.uri;
  final cached = _localFullscreenFileCache.remove(uri);
  if (cached != null) {
    _localFullscreenFileCache[uri] = cached;
    return cached;
  }
  final future = MediaCache.ensureLocalUriFile(
    uri: uri,
    preferredName: asset.name,
    expectedSizeBytes: asset.sizeBytes,
  );
  if (_localFullscreenFileCache.length >= _maxLocalFullscreenCacheEntries) {
    _localFullscreenFileCache.remove(_localFullscreenFileCache.keys.first);
  }
  _localFullscreenFileCache[uri] = future;
  unawaited(
    future.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_localFullscreenFileCache[uri], future)) {
          _localFullscreenFileCache.remove(uri);
        }
      },
    ),
  );
  return future;
}

class _LocalImagePreviewPage extends StatefulWidget {
  const _LocalImagePreviewPage({
    super.key,
    required this.asset,
    required this.active,
  });

  final LocalMediaAsset asset;
  final bool active;

  @override
  State<_LocalImagePreviewPage> createState() => _LocalImagePreviewPageState();
}

class _LocalImagePreviewPageState extends State<_LocalImagePreviewPage> {
  Future<File>? _fileFuture;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _fileFuture = _loadLocalFullscreenFile(widget.asset);
    }
  }

  @override
  void didUpdateWidget(covariant _LocalImagePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        _fileFuture == null &&
        oldWidget.asset.id == widget.asset.id) {
      setState(() {
        _fileFuture = _loadLocalFullscreenFile(widget.asset);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final future = _fileFuture;
    if (future == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(Icons.image_outlined, color: Colors.white24, size: 48),
        ),
      );
    }
    return FutureBuilder<File>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 14),
                Text(
                  widget.asset.sizeBytes > 0
                      ? '正在流式加载… ${formatByteSize(widget.asset.sizeBytes)}'
                      : '正在流式加载…',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return _AlbumPreviewMessage(
            message: snapshot.error?.toString() ?? '图片加载失败',
            color: AppTheme.danger,
          );
        }
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image.file(
              snapshot.data!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              cacheWidth: _maxAlbumFullscreenDecodeExtent,
              cacheHeight: _maxAlbumFullscreenDecodeExtent,
              errorBuilder: (_, __, ___) => const _AlbumPreviewMessage(
                message: '图片格式不支持或文件已损坏',
                color: AppTheme.danger,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RemoteImagePreviewPage extends StatefulWidget {
  const _RemoteImagePreviewPage({
    super.key,
    required this.client,
    required this.entry,
    required this.active,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;
  final bool active;

  @override
  State<_RemoteImagePreviewPage> createState() =>
      _RemoteImagePreviewPageState();
}

class _RemoteImagePreviewPageState extends State<_RemoteImagePreviewPage> {
  Future<File>? _fileFuture;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      _startLoad();
    }
  }

  @override
  void didUpdateWidget(covariant _RemoteImagePreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active &&
        _fileFuture == null &&
        oldWidget.entry.path == widget.entry.path) {
      _startLoad();
    }
  }

  void _startLoad() {
    setState(() {
      _progress = 0;
      _fileFuture = MediaCache.ensureLocalFile(
        client: widget.client,
        remotePath: widget.entry.path,
        expectedSizeBytes: widget.entry.sizeBytes,
        fileName: widget.entry.name,
        onProgress: (value) {
          if (!mounted) {
            return;
          }
          setState(() => _progress = value);
        },
      );
      // Also park in the process cache for swipe re-entry.
      final path = widget.entry.path;
      final future = _fileFuture!;
      final cached = _remoteFullscreenFileCache.remove(path);
      if (cached != null) {
        _remoteFullscreenFileCache[path] = cached;
        _fileFuture = cached;
      } else {
        if (_remoteFullscreenFileCache.length >=
            _maxRemoteFullscreenCacheEntries) {
          _remoteFullscreenFileCache
              .remove(_remoteFullscreenFileCache.keys.first);
        }
        _remoteFullscreenFileCache[path] = future;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final future = _fileFuture;
    if (future == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(Icons.image_outlined, color: Colors.white24, size: 48),
        ),
      );
    }
    return FutureBuilder<File>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          final pct = (_progress * 100).clamp(0, 100).toStringAsFixed(0);
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  value: _progress > 0 && _progress < 1 ? _progress : null,
                ),
                const SizedBox(height: 14),
                Text(
                  '正在流式加载… $pct%'
                  '${widget.entry.size.isEmpty ? '' : ' · ${widget.entry.size}'}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          return _AlbumPreviewMessage(
            message: snapshot.error?.toString() ?? '图片加载失败',
            color: AppTheme.danger,
          );
        }
        return InteractiveViewer(
          minScale: 0.5,
          maxScale: 4,
          child: Center(
            child: Image.file(
              snapshot.data!,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              cacheWidth: _maxAlbumFullscreenDecodeExtent,
              cacheHeight: _maxAlbumFullscreenDecodeExtent,
              errorBuilder: (_, __, ___) => const _AlbumPreviewMessage(
                message: '图片格式不支持或文件已损坏',
                color: AppTheme.danger,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LocalVideoPreviewPage extends StatefulWidget {
  const _LocalVideoPreviewPage({
    super.key,
    required this.asset,
    required this.active,
  });

  final LocalMediaAsset asset;
  final bool active;

  @override
  State<_LocalVideoPreviewPage> createState() => _LocalVideoPreviewPageState();
}

class _LocalVideoPreviewPageState extends State<_LocalVideoPreviewPage> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;
  String? _error;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(_ensurePlayer());
    }
  }

  @override
  void didUpdateWidget(covariant _LocalVideoPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !_started) {
      unawaited(_ensurePlayer());
    } else if (!widget.active && _controller != null) {
      unawaited(_controller!.pause());
    }
  }

  Future<void> _ensurePlayer() async {
    if (_started) {
      return;
    }
    _started = true;
    final future = () async {
      try {
        // Prefer content URI playback on Android (true streaming, no size cap).
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.asset.uri),
        );
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _controller = controller;
          _error = null;
        });
      } on Object {
        // Content URI may fail — stream MediaStore chunks into a temp file.
        final file = await MediaCache.ensureLocalUriFile(
          uri: widget.asset.uri,
          preferredName: widget.asset.name,
          expectedSizeBytes: widget.asset.sizeBytes,
        );
        final controller = VideoPlayerController.file(file);
        await controller.initialize();
        await controller.setLooping(true);
        await controller.play();
        if (!mounted) {
          await controller.dispose();
          return;
        }
        setState(() {
          _controller = controller;
          _error = null;
        });
      }
    }();
    setState(() {
      _initFuture = future;
      _error = null;
    });
    try {
      await future;
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _AlbumPreviewMessage(message: _error!, color: AppTheme.danger);
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              widget.active ? '正在准备视频…' : '等待播放',
              style: const TextStyle(color: Colors.white70),
            ),
            if (_initFuture != null)
              FutureBuilder<void>(
                future: _initFuture,
                builder: (_, __) => const SizedBox.shrink(),
              ),
          ],
        ),
      );
    }
    return _VideoPlayerScaffold(controller: controller);
  }
}

class _RemoteVideoPreviewPage extends StatefulWidget {
  const _RemoteVideoPreviewPage({
    super.key,
    required this.client,
    required this.entry,
    required this.active,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;
  final bool active;

  @override
  State<_RemoteVideoPreviewPage> createState() =>
      _RemoteVideoPreviewPageState();
}

class _RemoteVideoPreviewPageState extends State<_RemoteVideoPreviewPage> {
  VideoPlayerController? _controller;
  Future<void>? _initFuture;
  StreamSubscription<double>? _progressSubscription;
  String? _error;
  bool _started = false;
  bool _usingFallback = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    if (widget.active) {
      unawaited(_ensurePlayer());
    }
  }

  @override
  void didUpdateWidget(covariant _RemoteVideoPreviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active) {
      if (!_started) {
        unawaited(_ensurePlayer());
      } else if (_controller != null) {
        unawaited(_controller!.play());
      }
    } else if (!widget.active && _controller != null) {
      unawaited(_controller!.pause());
    }
  }

  Future<void> _ensurePlayer() async {
    if (_started) {
      return;
    }
    _started = true;
    final future = () async {
      final directController = await RemoteVideoStream.tryOpen(
        client: widget.client,
        entry: widget.entry,
      );
      if (directController != null) {
        await directController.setLooping(true);
        if (widget.active) {
          await directController.play();
        }
        if (!mounted) {
          await directController.dispose();
          return;
        }
        setState(() {
          _controller = directController;
          _error = null;
        });
        return;
      }
      if (mounted) {
        setState(() => _usingFallback = true);
      }
      // Progressive range download with no size ceiling: start after ~1 MB and
      // keep filling so later seeks work as more bytes land on disk.
      final handle = await MediaCache.ensureProgressive(
        client: widget.client,
        remotePath: widget.entry.path,
        expectedSizeBytes: widget.entry.sizeBytes,
        fileName: widget.entry.name,
      );
      _progressSubscription = handle.progress.listen((value) {
        if (!mounted) {
          return;
        }
        setState(() => _progress = value);
      });
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final controller = await RemoteVideoStream.openCached(
        handle: handle,
        entry: widget.entry,
      );
      await controller.setLooping(true);
      if (widget.active) {
        await controller.play();
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _error = null;
      });
    }();
    setState(() {
      _initFuture = future;
      _error = null;
    });
    try {
      await future;
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    }
  }

  @override
  void dispose() {
    unawaited(_progressSubscription?.cancel() ?? Future<void>.value());
    final controller = _controller;
    _controller = null;
    unawaited(controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _AlbumPreviewMessage(message: _error!, color: AppTheme.danger);
    }
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 14),
            Text(
              widget.active
                  ? _usingFallback
                      ? 'WebDAV 不可用，正在流式缓冲… ${(_progress * 100).clamp(0, 100).toStringAsFixed(0)}%'
                      : '正在连接 WebDAV 视频流…'
                  : '等待播放',
              style: const TextStyle(color: Colors.white70),
            ),
            if (_initFuture != null)
              FutureBuilder<void>(
                future: _initFuture,
                builder: (_, __) => const SizedBox.shrink(),
              ),
          ],
        ),
      );
    }
    return _VideoPlayerScaffold(controller: controller);
  }
}

class _VideoPlayerScaffold extends StatelessWidget {
  const _VideoPlayerScaffold({required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Center(
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio == 0
                ? 16 / 9
                : controller.value.aspectRatio,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () {
                if (controller.value.isPlaying) {
                  unawaited(controller.pause());
                } else {
                  unawaited(controller.play());
                }
              },
              child: VideoWakeLock(
                controller: controller,
                child: VideoPlayer(controller),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ColoredBox(
            color: Colors.black.withValues(alpha: 0.45),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                VideoProgressIndicator(
                  controller,
                  allowScrubbing: true,
                  colors: const VideoProgressColors(
                    playedColor: Colors.white,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                ),
                ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: controller,
                  builder: (context, value, _) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: VideoPlaybackControls(
                        controller: controller,
                        value: value,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
