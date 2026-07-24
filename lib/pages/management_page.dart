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
}

class _ManagementPage extends StatefulWidget {
  const _ManagementPage({
    super.key,
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
  final Set<String> _submittingIds = {};
  Timer? _searchDebounce;
  String _query = '';

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      setState(() => _query = value.trim().toLowerCase());
    });
  }

  @override
  Widget build(BuildContext context) {
    final filteredItems = widget.items.where((item) {
      if (_query.isEmpty) {
        return true;
      }
      return [
        item.title,
        item.status,
        item.description,
        ...item.tags,
      ].join(' ').toLowerCase().contains(_query);
    }).toList(growable: false);

    // Virtualized list: large Docker/share fleets must not build every card
    // inside a SingleChildScrollView.
    return FadeSlide(
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ManagementStats(
                    type: widget.type,
                    dashboard: widget.dashboard,
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
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 12),
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
            ),
          ),
          if (widget.items.isEmpty)
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
            )
          else if (filteredItems.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 86),
                child: _StateMessage(
                  icon: Icons.search_off,
                  title: '没有匹配项',
                  message: '换一个关键词试试。',
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 86),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final item = filteredItems[index];
                    return _ManagementCard(
                      item: item,
                      isSubmitting: _submittingIds.contains(item.id),
                      onTap: () => _openDetail(item),
                      onAction: item.type == ManagementItemType.share
                          ? null
                          : (action) => _runAction(item, action),
                    );
                  },
                  childCount: filteredItems.length,
                ),
              ),
            ),
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

    setState(() => _submittingIds.add(item.id));
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
        setState(() => _submittingIds.remove(item.id));
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

class _ManagementStats extends StatelessWidget {
  const _ManagementStats({
    required this.type,
    required this.dashboard,
  });

  final String type;
  final UnraidDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    final items = switch (type) {
      'Docker' => dashboard.dockerItems,
      '虚拟机' => dashboard.vmItems,
      _ => dashboard.shareItems,
    };
    final running = items.where((item) => _isRunningStatus(item.status)).length;
    final secondary = switch (type) {
      'Docker' => dashboard.dockerNetworkSummary,
      '虚拟机' => '$running 运行中 · ${items.length - running} 未运行',
      _ => '阵列 ${dashboard.arrayUsage}',
    };
    final icon = switch (type) {
      'Docker' => Icons.layers,
      '虚拟机' => Icons.computer,
      _ => Icons.folder_shared,
    };
    final secondIcon = switch (type) {
      'Docker' => Icons.hub,
      '虚拟机' => Icons.memory,
      _ => Icons.move_down,
    };
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.72,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _StatCard(
          icon: icon,
          label: type,
          value: items.length.toString(),
          subtitle: '$running 运行中',
          progress: items.isEmpty ? 0 : running / items.length,
          severity: running == 0 && items.isNotEmpty
              ? InfoSeverity.warning
              : InfoSeverity.normal,
        ),
        _StatCard(
          icon: secondIcon,
          label: type == '共享' ? 'Mover' : '概览',
          value: type == '共享' ? '02:00' : running.toString(),
          subtitle: secondary,
          progress: dashboard.arrayPercent,
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
    final running = _isRunningStatus(item.status);
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
                const SizedBox(height: 12),
                if (onAction == null)
                  Row(
                    children: [
                      Expanded(
                        child: _CompactActionButton(
                          icon: Icons.folder_open,
                          label: '浏览',
                          onPressed: onTap,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _CompactActionButton(
                          icon: Icons.tune,
                          label: '设置',
                          onPressed: onTap,
                        ),
                      ),
                    ],
                  )
                else
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
            ),
          ),
        ),
      ),
    );
  }
}

bool _isRunningStatus(String value) {
  return value.contains('运行') ||
      value.contains('在线') ||
      value.toLowerCase().contains('running') ||
      value.toLowerCase().contains('online') ||
      value.toLowerCase().contains('started');
}

String _actionLabel(ManagementAction action) {
  return switch (action) {
    ManagementAction.start => '启动',
    ManagementAction.stop => '停止',
    ManagementAction.restart => '重启',
  };
}

