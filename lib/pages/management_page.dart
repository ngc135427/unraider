part of 'main_shell_page.dart';

class ManagementData {
  const ManagementData({
    required this.id,
    required this.icon,
    required this.title,
    required this.status,
    required this.description,
    required this.type,
    required this.progress,
    required this.tags,
    required this.details,
    required this.isRunning,
  });

  factory ManagementData.fromClient(UnraidManagementItem item, IconData icon) {
    return ManagementData(
      id: item.id,
      icon: icon,
      title: item.title,
      status: item.status,
      description: item.description,
      type: item.type,
      progress: item.progress,
      tags: item.tags,
      details: item.details,
      // Resolve once at map time so list cards/stats skip status string scans.
      isRunning: _isRunningStatus(item.status),
    );
  }

  final String id;
  final IconData icon;
  final String title;
  final String status;
  final String description;
  final ManagementItemType type;
  final double progress;
  final List<String> tags;
  final List<UnraidInfoItem> details;
  final bool isRunning;
}

class _ManagementPage extends StatefulWidget {
  const _ManagementPage({
    required this.type,
    required this.dashboard,
    required this.items,
    required this.unraidClient,
    this.onRefresh,
  });

  final String type;
  final UnraidDashboard dashboard;
  final List<ManagementData> items;
  final UnraidClient? unraidClient;
  final VoidCallback? onRefresh;

  @override
  State<_ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<_ManagementPage> {
  final _searchController = TextEditingController();
  /// Submitting ids drive only card busy state via [ValueNotifier].
  final ValueNotifier<Set<String>> _submittingIds =
      ValueNotifier<Set<String>>(const <String>{});
  Timer? _searchDebounce;
  /// Search query is isolated so typing does not rebuild stats/header chrome.
  final ValueNotifier<String> _query = ValueNotifier<String>('');
  List<ManagementData>? _filterItemsRef;
  String _filterQueryRef = '';
  List<ManagementData> _filteredItemsCached = const <ManagementData>[];
  Map<String, int> _filteredIndexById = const <String, int>{};
  /// Pre-lowercased haystacks so typing does not re-join tags every keystroke.
  List<ManagementData>? _haystackItemsRef;
  List<String> _searchHaystacks = const <String>[];

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _submittingIds.dispose();
    _query.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      _query.value = value.trim().toLowerCase();
    });
  }

  void _ensureSearchHaystacks() {
    if (identical(_haystackItemsRef, widget.items)) {
      return;
    }
    _haystackItemsRef = widget.items;
    _searchHaystacks = [
      for (final item in widget.items)
        [
          item.title,
          item.status,
          item.description,
          ...item.tags,
        ].join(' ').toLowerCase(),
    ];
  }

  List<ManagementData> _filteredItemsFor(String query) {
    if (identical(_filterItemsRef, widget.items) &&
        _filterQueryRef == query) {
      return _filteredItemsCached;
    }
    _filterItemsRef = widget.items;
    _filterQueryRef = query;
    if (query.isEmpty) {
      _filteredItemsCached = widget.items;
      _filteredIndexById = {
        for (var i = 0; i < widget.items.length; i++) widget.items[i].id: i,
      };
      return _filteredItemsCached;
    }
    _ensureSearchHaystacks();
    final filtered = <ManagementData>[];
    final indexById = <String, int>{};
    for (var i = 0; i < widget.items.length; i++) {
      if (_searchHaystacks[i].contains(query)) {
        final item = widget.items[i];
        indexById[item.id] = filtered.length;
        filtered.add(item);
      }
    }
    _filteredItemsCached = filtered;
    _filteredIndexById = indexById;
    return _filteredItemsCached;
  }

  @override
  Widget build(BuildContext context) {
    // Stats + search field stay outside the query listener so typing only
    // rebuilds the virtualized result list below.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ManagementStats(
            type: widget.type,
            dashboard: widget.dashboard,
            items: widget.items,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  decoration: InputDecoration(
                    hintText: '搜索${widget.type}项目',
                    prefixIcon: const Icon(Icons.search),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _CompactActionButton(
                icon: Icons.sync,
                label: '刷新',
                onPressed: widget.onRefresh ??
                    () => _showMessage('${widget.type}刷新已提交'),
              ),
            ],
          ),
          const SizedBox(height: 14),
        ],
      ),
    );

    final results = ValueListenableBuilder<String>(
      valueListenable: _query,
      builder: (context, query, _) {
        Widget body;
        if (widget.items.isEmpty) {
          body = CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverFillRemaining(
                hasScrollBody: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 86),
                  child: _StateMessage(
                    icon: Icons.inbox_outlined,
                    title: '${widget.type}为空',
                    message: '服务器当前没有返回${widget.type}项目。',
                  ),
                ),
              ),
            ],
          );
        } else {
          final filteredItems = _filteredItemsFor(query);
          if (filteredItems.isEmpty) {
            body = CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: const [
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 86),
                    child: _StateMessage(
                      icon: Icons.search_off,
                      title: '没有匹配项',
                      message: '换一个关键词试试。',
                    ),
                  ),
                ),
              ],
            );
          } else {
            body = ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 86),
              itemCount: filteredItems.length,
              findChildIndexCallback: (Key key) {
                if (key is! ValueKey<String>) {
                  return null;
                }
                return _filteredIndexById[key.value];
              },
              itemBuilder: (context, index) {
                final item = filteredItems[index];
                return RepaintBoundary(
                  key: ValueKey<String>(item.id),
                  child: ValueListenableBuilder<Set<String>>(
                    valueListenable: _submittingIds,
                    builder: (context, submitting, _) {
                      return _ManagementCard(
                        item: item,
                        isSubmitting: submitting.contains(item.id),
                        onTap: () => _openDetail(item),
                        onAction: item.type == ManagementItemType.share
                            ? null
                            : (action) => _runAction(item, action),
                      );
                    },
                  ),
                );
              },
            );
          }
        }

        if (widget.onRefresh == null) {
          return body;
        }
        return RefreshIndicator(
          onRefresh: () async => widget.onRefresh!(),
          child: body,
        );
      },
    );

    // No entrance animation: management lists rebuild on search/refresh.
    return FadeSlide(
      animate: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Expanded(child: results),
        ],
      ),
    );
  }

  void _openDetail(ManagementData item) {
    Navigator.of(context).pushNamed(
      ManagementDetailPage.routeName,
      arguments: ManagementDetailArgs(
        type: widget.type,
        data: item,
        unraidClient: widget.unraidClient,
      ),
    );
  }

  Future<void> _runAction(
    ManagementData item,
    ManagementAction action,
  ) async {
    final client = widget.unraidClient;
    if (client == null || item.id.isEmpty) {
      _showMessage('缺少服务器连接或项目 ID');
      return;
    }

    _submittingIds.value = {..._submittingIds.value, item.id};
    try {
      await client.runManagementAction(
        type: item.type,
        id: item.id,
        action: action,
      );
      if (!mounted) {
        return;
      }
      _showMessage('${item.title} ${_actionLabel(action)}操作已提交');
      // Pull fresh status after lifecycle actions, without blocking the snackbar.
      widget.onRefresh?.call();
    } on UnraidClientException catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage(error.message);
    } finally {
      if (mounted) {
        final next = Set<String>.from(_submittingIds.value)..remove(item.id);
        _submittingIds.value = next;
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

class ManagementDetailArgs {
  const ManagementDetailArgs({
    required this.type,
    required this.data,
    required this.unraidClient,
  });

  final String type;
  final ManagementData data;
  final UnraidClient? unraidClient;
}

class _ManagementStats extends StatefulWidget {
  const _ManagementStats({
    required this.type,
    required this.dashboard,
    required this.items,
  });

  final String type;
  final UnraidDashboard dashboard;
  final List<ManagementData> items;

  @override
  State<_ManagementStats> createState() => _ManagementStatsState();
}

class _ManagementStatsState extends State<_ManagementStats> {
  List<ManagementData>? _itemsRef;
  int _runningCached = 0;
  int _totalCached = 0;

  void _ensureRunningStats() {
    if (identical(_itemsRef, widget.items)) {
      return;
    }
    _itemsRef = widget.items;
    _totalCached = widget.items.length;
    var running = 0;
    for (final item in widget.items) {
      if (item.isRunning) {
        running += 1;
      }
    }
    _runningCached = running;
  }

  @override
  Widget build(BuildContext context) {
    _ensureRunningStats();
    final running = _runningCached;
    final total = _totalCached;
    final secondary = switch (widget.type) {
      'Docker' => widget.dashboard.dockerNetworkSummary,
      '虚拟机' => '$running 运行中 · ${total - running} 未运行',
      _ => '阵列 ${widget.dashboard.arrayUsage}',
    };
    final icon = switch (widget.type) {
      'Docker' => Icons.layers,
      '虚拟机' => Icons.computer,
      _ => Icons.folder_shared,
    };
    final secondIcon = switch (widget.type) {
      'Docker' => Icons.hub,
      '虚拟机' => Icons.memory,
      _ => Icons.move_down,
    };
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.34,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _StatCard(
          icon: icon,
          label: widget.type,
          value: total.toString(),
          subtitle: '$running 运行中',
          progress: total == 0 ? 0 : running / total,
          severity: running == 0 && total > 0
              ? InfoSeverity.warning
              : InfoSeverity.normal,
        ),
        _StatCard(
          icon: secondIcon,
          label: widget.type == '共享' ? 'Mover' : '概览',
          value: widget.type == '共享' ? '02:00' : running.toString(),
          subtitle: secondary,
          progress: widget.dashboard.arrayPercent,
        ),
      ],
    );
  }
}

class _ManagementCard extends StatelessWidget {
  const _ManagementCard({
    required this.item,
    required this.isSubmitting,
    required this.onTap,
    required this.onAction,
  });

  final ManagementData item;
  final bool isSubmitting;
  final VoidCallback onTap;
  final ValueChanged<ManagementAction>? onAction;

  @override
  Widget build(BuildContext context) {
    final running = item.isRunning;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: _SurfaceCard(
            padding: const EdgeInsets.all(13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _IconBadge(
                      icon: item.icon,
                      severity:
                          running ? InfoSeverity.success : InfoSeverity.warning,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textDark,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            item.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textLight,
                              fontSize: 12,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _StatusChip(
                      label: item.status,
                      severity:
                          running ? InfoSeverity.success : InfoSeverity.warning,
                    ),
                  ],
                ),
                if (item.progress > 0) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 6,
                      value: item.progress.clamp(0, 1).toDouble(),
                      backgroundColor: AppTheme.softLine,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _progressColor(item.progress),
                      ),
                    ),
                  ),
                ],
                if (item.tags.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in item.tags.take(4))
                        _StatusChip(label: tag),
                    ],
                  ),
                ],
                if (onAction != null) ...[
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _CompactActionButton(
                          icon: running ? Icons.restart_alt : Icons.play_arrow,
                          label: running ? '重启' : '启动',
                          onPressed: isSubmitting
                              ? null
                              : () => onAction!(
                                    running
                                        ? ManagementAction.restart
                                        : ManagementAction.start,
                                  ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _CompactActionButton(
                          icon: Icons.stop,
                          label: '停止',
                          color: AppTheme.danger,
                          onPressed: isSubmitting
                              ? null
                              : () => onAction!(ManagementAction.stop),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _CompactActionButton(
                          icon: Icons.visibility,
                          label: '详情',
                          onPressed: onTap,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

bool _isRunningStatus(String value) {
  if (value.contains('运行') || value.contains('在线')) {
    return true;
  }
  final lower = value.toLowerCase();
  return lower.contains('running') ||
      lower.contains('online') ||
      lower.contains('started');
}

String _actionLabel(ManagementAction action) {
  return switch (action) {
    ManagementAction.start => '启动',
    ManagementAction.stop => '停止',
    ManagementAction.restart => '重启',
  };
}

