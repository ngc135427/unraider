part of 'main_shell_page.dart';

class ManagementDetailPage extends StatefulWidget {
  const ManagementDetailPage({super.key});

  static const routeName = '/management-detail';

  @override
  State<ManagementDetailPage> createState() => _ManagementDetailPageState();
}

class _ManagementDetailPageState extends State<ManagementDetailPage> {
  bool _isSubmitting = false;
  bool _shareBrowserReady = false;
  /// Spinner-only flag so soft directory refresh does not rebuild the file list.
  final ValueNotifier<bool> _shareLoading = ValueNotifier<bool>(false);
  String? _sharePath;
  Future<List<UnraidFileEntry>>? _shareFuture;
  List<UnraidFileEntry> _shareEntries = const <UnraidFileEntry>[];
  Object? _shareError;
  final TextEditingController _shareSearchController = TextEditingController();
  Timer? _shareSearchDebounce;
  /// Search query is isolated so typing does not rebuild the share header chrome.
  final ValueNotifier<String> _shareQuery = ValueNotifier<String>('');
  int _shareLoadGeneration = 0;

  // Memoized projections for search filter + image gallery source.
  List<UnraidFileEntry>? _shareFilterEntriesRef;
  String _shareFilterQueryRef = '';
  List<UnraidFileEntry> _shareFilteredCached = const <UnraidFileEntry>[];
  Map<String, int> _shareFilteredIndexByPath = const <String, int>{};
  List<UnraidFileEntry>? _shareHaystackEntriesRef;
  List<String> _shareSearchHaystacks = const <String>[];
  List<UnraidFileEntry>? _shareImageEntriesRef;
  List<UnraidFileEntry> _shareImageEntriesCached = const <UnraidFileEntry>[];

  @override
  void dispose() {
    _shareSearchDebounce?.cancel();
    _shareSearchController.dispose();
    _shareLoading.dispose();
    _shareQuery.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize share browser once after route args are available — never
    // kick off network work from build().
    if (_shareBrowserReady) {
      return;
    }
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is! ManagementDetailArgs) {
      return;
    }
    if (args.data.type != ManagementItemType.share) {
      _shareBrowserReady = true;
      return;
    }
    _shareBrowserReady = true;
    _ensureShareBrowser(args);
  }

  void _onShareSearchChanged(String value) {
    _shareSearchDebounce?.cancel();
    _shareSearchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      _shareQuery.value = value.trim().toLowerCase();
    });
  }

  ManagementDetailArgs get _detailArgs {
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is ManagementDetailArgs) {
      return args;
    }
    return ManagementDetailArgs(
      type: '项目',
      data: ManagementData(
        id: '',
        icon: Icons.info,
        title: '未知项目',
        status: '未知',
        description: '暂无信息',
        type: ManagementItemType.share,
        progress: 0,
        tags: const [],
        details: const [],
        isRunning: false,
      ),
      unraidClient: null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailArgs = _detailArgs;

    if (detailArgs.data.type == ManagementItemType.share) {
      return _buildShareBrowser(detailArgs);
    }

    return PhoneFrame(
      maxContentWidth: 900,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(30, 8, 30, 30),
          child: FadeSlide(
            animate: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextButton.icon(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('返回'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        detailArgs.data.icon,
                        color: AppTheme.primary,
                        size: 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            detailArgs.data.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textDark,
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            detailArgs.type,
                            style: const TextStyle(
                              color: AppTheme.textMedium,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                _DetailPanel(
                  children: [
                    _DetailInfoRow(
                      icon: Icons.info_outline,
                      label: '状态',
                      value: detailArgs.data.status,
                    ),
                    _DetailInfoRow(
                      icon: Icons.description_outlined,
                      label: '说明',
                      value: detailArgs.data.description,
                    ),
                    _DetailInfoRow(
                      icon: Icons.storage,
                      label: '位置',
                      value: detailArgs.data.type == ManagementItemType.share
                          ? '/mnt/user/${detailArgs.data.title}'
                          : detailArgs.data.title,
                    ),
                    for (final detail in detailArgs.data.details)
                      _DetailInfoRow(
                        icon: _iconForInfoSeverity(detail.severity),
                        label: detail.title,
                        value: detail.value.isEmpty
                            ? detail.description
                            : '${detail.value} · ${detail.description}',
                      ),
                  ],
                ),
                if (detailArgs.data.tags.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in detailArgs.data.tags)
                        _StatusChip(label: tag),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                _DetailPanel(
                  children: [
                    _ManagementActionButton(
                      icon: Icons.play_arrow,
                      label: '启动',
                      color: AppTheme.success,
                      onPressed: _isSubmitting
                          ? null
                          : () => _runAction(
                                detailArgs,
                                ManagementAction.start,
                                '启动',
                              ),
                    ),
                    const SizedBox(height: 10),
                    _ManagementActionButton(
                      icon: Icons.stop,
                      label: '停止',
                      color: AppTheme.danger,
                      onPressed: _isSubmitting
                          ? null
                          : () => _runAction(
                                detailArgs,
                                ManagementAction.stop,
                                '停止',
                              ),
                    ),
                    const SizedBox(height: 10),
                    _ManagementActionButton(
                      icon: Icons.refresh,
                      label: '重启',
                      color: const Color(0xFF3498DB),
                      onPressed: _isSubmitting
                          ? null
                          : () => _runAction(
                                detailArgs,
                                ManagementAction.restart,
                                '重启',
                              ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildShareBrowser(ManagementDetailArgs args) {
    final currentPath = _sharePath ?? _shareRoot(args);
    return PhoneFrame(
      maxContentWidth: 900,
      child: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('返回'),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '刷新',
                    onPressed: () =>
                        _openSharePath(currentPath, forceRefresh: true),
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(30, 0, 30, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: AppTheme.primary.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.folder_shared,
                          color: AppTheme.primary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              args.data.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textDark,
                                fontSize: 22,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              currentPath,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textMedium,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<String>(
                    valueListenable: _shareQuery,
                    builder: (context, query, _) {
                      return TextField(
                        controller: _shareSearchController,
                        onChanged: _onShareSearchChanged,
                        decoration: InputDecoration(
                          hintText: '搜索当前目录',
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清除',
                                  onPressed: () {
                                    _shareSearchController.clear();
                                    _shareQuery.value = '';
                                  },
                                  icon: const Icon(Icons.clear),
                                ),
                          contentPadding:
                              const EdgeInsets.symmetric(horizontal: 12),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _shareQuery,
                builder: (context, _, __) {
                  return _buildShareEntriesBody(args, currentPath);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _runAction(
    ManagementDetailArgs args,
    ManagementAction action,
    String label,
  ) async {
    final client = args.unraidClient;
    if (client == null || args.data.id.isEmpty) {
      _showMessage('缺少服务器连接或项目 ID');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      await client.runManagementAction(
        type: args.data.type,
        id: args.data.id,
        action: action,
      );
      if (!mounted) {
        return;
      }
      _showMessage('$label 操作已提交');
    } on UnraidClientException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(error.message);
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  List<UnraidFileEntry> get _shareImageEntries {
    if (identical(_shareImageEntriesRef, _shareEntries)) {
      return _shareImageEntriesCached;
    }
    _shareImageEntriesRef = _shareEntries;
    _shareImageEntriesCached = _shareEntries
        .where((entry) => entry.isImage)
        .toList(growable: false);
    return _shareImageEntriesCached;
  }

  void _ensureShareSearchHaystacks() {
    if (identical(_shareHaystackEntriesRef, _shareEntries)) {
      return;
    }
    _shareHaystackEntriesRef = _shareEntries;
    _shareSearchHaystacks = [
      for (final entry in _shareEntries) entry.nameLower,
    ];
  }

  List<UnraidFileEntry> get _shareFilteredEntries {
    final query = _shareQuery.value;
    if (identical(_shareFilterEntriesRef, _shareEntries) &&
        _shareFilterQueryRef == query) {
      return _shareFilteredCached;
    }
    _shareFilterEntriesRef = _shareEntries;
    _shareFilterQueryRef = query;
    if (query.isEmpty) {
      _shareFilteredCached = _shareEntries;
      _shareFilteredIndexByPath = {
        for (var i = 0; i < _shareEntries.length; i++)
          _shareEntries[i].path: i,
      };
      return _shareFilteredCached;
    }
    _ensureShareSearchHaystacks();
    final filtered = <UnraidFileEntry>[];
    final indexByPath = <String, int>{};
    for (var i = 0; i < _shareEntries.length; i++) {
      if (_shareSearchHaystacks[i].contains(query)) {
        final entry = _shareEntries[i];
        indexByPath[entry.path] = filtered.length;
        filtered.add(entry);
      }
    }
    _shareFilteredCached = filtered;
    _shareFilteredIndexByPath = indexByPath;
    return _shareFilteredCached;
  }

  Widget _buildShareEntriesBody(
    ManagementDetailArgs args,
    String currentPath,
  ) {
    if (_shareLoading.value && _shareEntries.isEmpty && _shareError == null) {
      return const _StateMessage(
        icon: Icons.folder_open,
        title: '正在读取目录',
        message: '正在加载共享文件...',
      );
    }

    if (_shareError != null && _shareEntries.isEmpty) {
      return _StateMessage(
        icon: Icons.error_outline,
        title: '读取失败',
        message: _shareError.toString(),
        actionLabel: '重试',
        onAction: () => _openSharePath(currentPath, forceRefresh: true),
      );
    }

    final allEntries = _shareEntries;
    final imageEntries = _shareImageEntries;
    if (!_shareLoading.value && allEntries.isEmpty && _shareError == null) {
      return RefreshIndicator(
        onRefresh: () async {
          _openSharePath(currentPath, forceRefresh: true);
          await _shareFuture;
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 120),
            _StateMessage(
              icon: Icons.inbox_outlined,
              title: '目录为空',
              message: '这里还没有可浏览的文件。',
            ),
          ],
        ),
      );
    }

    final entries = _shareFilteredEntries;
    if (entries.isEmpty && !_shareLoading.value) {
      return const _StateMessage(
        icon: Icons.search_off,
        title: '没有匹配项',
        message: '换一个关键词试试。',
      );
    }

    final canGoUp = _canGoUp(args);
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            _openSharePath(currentPath, forceRefresh: true);
            await _shareFuture;
          },
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(30, 0, 30, 30),
            itemCount: entries.length + (canGoUp ? 1 : 0),
            findChildIndexCallback: (Key key) {
              if (key is! ValueKey<String>) {
                return null;
              }
              final pathIndex = _shareFilteredIndexByPath[key.value];
              if (pathIndex == null) {
                return null;
              }
              return pathIndex + (canGoUp ? 1 : 0);
            },
            itemBuilder: (context, index) {
              if (canGoUp && index == 0) {
                return _FileEntryTile(
                  icon: Icons.drive_folder_upload,
                  title: '上一级',
                  subtitle: _parentPath(currentPath),
                  onTap: () => _openSharePath(_parentPath(currentPath)),
                );
              }
              final entry = entries[index - (canGoUp ? 1 : 0)];
              return RepaintBoundary(
                key: ValueKey<String>(entry.path),
                child: _FileEntryTile(
                  icon: entry.isDirectory
                      ? Icons.folder
                      : entry.isImage
                          ? Icons.image
                          : _isTextPreviewEntry(entry)
                              ? Icons.description_outlined
                              : Icons.insert_drive_file,
                  title: entry.name,
                  subtitle:
                      entry.isDirectory ? '文件夹' : _fileSubtitle(entry),
                  onTap: () {
                    if (entry.isDirectory) {
                      _openSharePath(entry.path);
                    } else if (entry.isImage) {
                      _previewImage(args, entry, imageEntries);
                    } else if (_isTextPreviewEntry(entry)) {
                      _previewText(args, entry);
                    } else {
                      _showMessage('暂不支持预览该文件类型');
                    }
                  },
                ),
              );
            },
          ),
        ),
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: ValueListenableBuilder<bool>(
            valueListenable: _shareLoading,
            builder: (context, loading, _) {
              if (!loading || _shareEntries.isEmpty) {
                return const SizedBox.shrink();
              }
              return const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _ensureShareBrowser(ManagementDetailArgs args) {
    if (_sharePath != null && _shareFuture != null) {
      return;
    }
    final root = _shareRoot(args);
    _sharePath = root;
    _shareFuture = _loadShareDirectory(
      client: args.unraidClient,
      path: root,
    );
  }

  Future<List<UnraidFileEntry>> _loadShareDirectory({
    required UnraidClient? client,
    required String path,
    bool forceRefresh = false,
  }) {
    final generation = ++_shareLoadGeneration;
    if (client == null) {
      _shareError = '缺少服务器连接';
      _shareLoading.value = false;
      return Future<List<UnraidFileEntry>>.error('缺少服务器连接');
    }

    _shareLoading.value = true;
    _shareError = null;
    return () async {
      try {
        final entries =
            await client.fetchDirectory(path, forceRefresh: forceRefresh);
        if (!mounted || generation != _shareLoadGeneration) {
          return entries;
        }
        setState(() {
          _shareEntries = entries;
          _shareError = null;
        });
        _shareLoading.value = false;
        return entries;
      } on Object catch (error) {
        if (mounted && generation == _shareLoadGeneration) {
          setState(() {
            _shareError = error;
          });
          _shareLoading.value = false;
        }
        rethrow;
      }
    }();
  }

  void _openSharePath(String path, {bool forceRefresh = false}) {
    final detailArgs = _detailArgs;
    final client = detailArgs.unraidClient;
    if (client == null) {
      _showMessage('缺少服务器连接');
      return;
    }
    final pathChanged = _sharePath != path;
    setState(() {
      _sharePath = path;
      if (pathChanged) {
        _shareSearchController.clear();
        _shareQuery.value = '';
        // Drop stale entries when navigating to a different folder so we do
        // not flash the previous directory's contents.
        _shareEntries = const <UnraidFileEntry>[];
        _shareError = null;
      }
      _shareFuture = _loadShareDirectory(
        client: client,
        path: path,
        forceRefresh: forceRefresh,
      );
    });
  }

  bool _canGoUp(ManagementDetailArgs args) {
    final current = _sharePath ?? _shareRoot(args);
    return current != _shareRoot(args);
  }

  String _shareRoot(ManagementDetailArgs args) {
    return '/mnt/user/${args.data.title}';
  }

  String _parentPath(String path) {
    final normalized = path.endsWith('/') && path.length > 1
        ? path.substring(0, path.length - 1)
        : path;
    final index = normalized.lastIndexOf('/');
    if (index <= 0) {
      return normalized;
    }
    return normalized.substring(0, index);
  }

  String _fileSubtitle(UnraidFileEntry entry) {
    final parts = [
      if (entry.size.isNotEmpty) entry.size,
      if (entry.modified.isNotEmpty) entry.modified,
    ];
    return parts.isEmpty ? '文件' : parts.join(' · ');
  }

  Future<void> _previewImage(
    ManagementDetailArgs args,
    UnraidFileEntry entry,
    List<UnraidFileEntry> imageEntries,
  ) async {
    final client = args.unraidClient;
    if (client == null) {
      _showMessage('缺少服务器连接');
      return;
    }
    await AppLogger.log(
      'share_preview_tap path=${entry.path} name=${entry.name} '
      'sizeBytes=${entry.sizeBytes} size=${entry.size}',
    );
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        child: _ImagePreview(
          client: client,
          entries:
              imageEntries.isEmpty ? <UnraidFileEntry>[entry] : imageEntries,
          initialIndex:
              imageEntries.indexWhere((item) => item.path == entry.path),
        ),
      ),
    );
  }

  Future<void> _previewText(
    ManagementDetailArgs args,
    UnraidFileEntry entry,
  ) async {
    final client = args.unraidClient;
    if (client == null) {
      _showMessage('缺少服务器连接');
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        child: _TextPreview(client: client, entry: entry),
      ),
    );
  }
}

