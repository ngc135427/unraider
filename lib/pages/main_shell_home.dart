part of 'main_shell_page.dart';

class _ServerInfoPage extends StatelessWidget {
  const _ServerInfoPage({
    required this.iconVariant,
    required this.dashboard,
    required this.unraidClient,
    required this.onEditIcon,
    required this.onPowerAction,
    required this.onOpenDetails,
    this.onRefresh,
  });

  final ServerIconVariant iconVariant;
  final UnraidDashboard dashboard;
  final UnraidClient? unraidClient;
  final VoidCallback onEditIcon;
  final ValueChanged<String> onPowerAction;
  final VoidCallback onOpenDetails;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final body = SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 86),
      // Home re-publishes on soft dashboard refresh; skip entrance animation.
      child: FadeSlide(
        animate: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ServerHeroCard(
              dashboard: dashboard,
              iconVariant: iconVariant,
              onEditIcon: onEditIcon,
              onPowerAction: onPowerAction,
            ),
            const SizedBox(height: 18),
            _HomeStatsGrid(dashboard: dashboard),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: GradientButton(
                    label: '查看完整信息',
                    icon: Icons.info_outline,
                    onPressed: onOpenDetails,
                  ),
                ),
                if (onRefresh != null) ...[
                  const SizedBox(width: 10),
                  _CompactActionButton(
                    icon: Icons.sync,
                    label: '刷新',
                    onPressed: onRefresh,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 22),
            _SectionHeader(
              title: '实时指标',
              trailing: 'metrics',
            ),
            const SizedBox(height: 10),
            _MetricPanel(dashboard: dashboard),
            const SizedBox(height: 22),
            _SectionHeader(
              title: '阵列与服务',
              trailing: 'array / services',
            ),
            const SizedBox(height: 10),
            _InfoCard(
              children: [
                _InfoPair(label: '阵列状态', value: dashboard.arrayState),
                _InfoPair(label: '阵列容量', value: dashboard.arrayUsage),
                _InfoPair(
                  label: 'Parity',
                  value: dashboard.paritySummary.isEmpty
                      ? '暂无校验任务'
                      : dashboard.paritySummary,
                ),
                _InfoPair(label: '服务在线', value: dashboard.servicesSummary),
              ],
            ),
            const SizedBox(height: 24),
            const _SectionHeader(
              title: '应用',
              trailing: 'apps',
            ),
            const SizedBox(height: 12),
            _HomeAppShortcuts(unraidClient: unraidClient),
          ],
        ),
      ),
    );

    if (onRefresh == null) {
      return body;
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh!(),
      child: body,
    );
  }
}

class _ServerHeroCard extends StatelessWidget {
  const _ServerHeroCard({
    required this.dashboard,
    required this.iconVariant,
    required this.onEditIcon,
    required this.onPowerAction,
  });

  final UnraidDashboard dashboard;
  final ServerIconVariant iconVariant;
  final VoidCallback onEditIcon;
  final ValueChanged<String> onPowerAction;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'UNRAID SERVER',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      dashboard.serverName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      dashboard.serverDescription,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textMedium,
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        _StatusChip(
                          label: dashboard.status,
                          severity: _severityFromStatus(dashboard.status),
                        ),
                        _StatusChip(label: dashboard.version),
                        if (dashboard.notificationTotal > 0)
                          _StatusChip(
                            label: '${dashboard.notificationTotal} 条提醒',
                            severity: dashboard.notificationAlert > 0
                                ? InfoSeverity.danger
                                : InfoSeverity.warning,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ServerIconView(variant: iconVariant, size: 96),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _CompactActionButton(
                  icon: Icons.palette,
                  label: '编辑',
                  onPressed: onEditIcon,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CompactActionButton(
                  icon: Icons.power_settings_new,
                  label: '关机',
                  color: AppTheme.danger,
                  onPressed: () => onPowerAction('关闭'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _CompactActionButton(
                  icon: Icons.refresh,
                  label: '重启',
                  color: const Color(0xFF3498DB),
                  onPressed: () => onPowerAction('重启'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HomeStatsGrid extends StatelessWidget {
  const _HomeStatsGrid({required this.dashboard});

  final UnraidDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      childAspectRatio: 1.34,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        _StatCard(
          icon: Icons.speed,
          label: 'CPU',
          value: '${(dashboard.cpuPercent * 100).toStringAsFixed(0)}%',
          subtitle: dashboard.cpuSummary,
          progress: dashboard.cpuPercent,
        ),
        _StatCard(
          icon: Icons.memory,
          label: '内存',
          value: dashboard.memoryUsage.split('/').first.trim(),
          subtitle: dashboard.memoryUsage,
          progress: dashboard.memoryPercent,
        ),
        _StatCard(
          icon: Icons.dns,
          label: '阵列',
          value: dashboard.arrayUsage.split('/').first.trim(),
          subtitle: dashboard.arrayUsage,
          progress: dashboard.arrayPercent,
        ),
        _StatCard(
          icon: Icons.campaign,
          label: '通知',
          value: dashboard.notificationTotal.toString(),
          subtitle:
              '${dashboard.notificationWarning} 警告 · ${dashboard.notificationAlert} 严重',
          progress: dashboard.notificationTotal == 0
              ? 0
              : (dashboard.notificationWarning + dashboard.notificationAlert) /
                  dashboard.notificationTotal,
          severity: dashboard.notificationAlert > 0
              ? InfoSeverity.danger
              : dashboard.notificationWarning > 0
                  ? InfoSeverity.warning
                  : InfoSeverity.normal,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.subtitle,
    required this.progress,
    this.severity = InfoSeverity.normal,
  });

  final IconData icon;
  final String label;
  final String value;
  final String subtitle;
  final double progress;
  final InfoSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = severity == InfoSeverity.normal
        ? _progressColor(progress)
        : _severityColor(severity);
    return _SurfaceCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textLight,
                    fontSize: 12,
                  ),
                ),
              ),
              Icon(icon, color: AppTheme.textLight, size: 19),
            ],
          ),
          Text(
            value.isEmpty ? '未知' : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 21,
              fontWeight: FontWeight.w700,
            ),
          ),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 6,
              value: progress.clamp(0, 1).toDouble(),
              backgroundColor: AppTheme.softLine,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textLight,
              fontSize: 11,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    this.trailing,
  });

  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(color: AppTheme.textLight, fontSize: 12),
          ),
      ],
    );
  }
}

class _MetricPanel extends StatelessWidget {
  const _MetricPanel({required this.dashboard});

  final UnraidDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(
        children: [
          _MetricLine(
            icon: Icons.speed,
            label: 'CPU 使用',
            value: '${(dashboard.cpuPercent * 100).toStringAsFixed(1)}%',
            progress: dashboard.cpuPercent,
          ),
          const SizedBox(height: 10),
          _MetricLine(
            icon: Icons.storage,
            label: '内存',
            value: dashboard.memoryUsage,
            progress: dashboard.memoryPercent,
          ),
          const SizedBox(height: 10),
          _MetricLine(
            icon: Icons.dns,
            label: '阵列',
            value: dashboard.arrayUsage,
            progress: dashboard.arrayPercent,
          ),
          const SizedBox(height: 10),
          _InfoLine(
            icon: Icons.developer_board,
            label: '主板',
            value: dashboard.baseboardSummary,
          ),
        ],
      ),
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.child,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.softLine),
        boxShadow: [
          BoxShadow(
            color: AppTheme.primary.withValues(alpha: 0.05),
            blurRadius: 14,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      child: Column(children: children),
    );
  }
}

class _InfoPair extends StatelessWidget {
  const _InfoPair({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '未知' : value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactActionButton extends StatelessWidget {
  const _CompactActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.color = AppTheme.primary,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: const BorderSide(color: AppTheme.line),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    this.severity = InfoSeverity.normal,
  });

  final String label;
  final InfoSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(severity);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Text(
        label.isEmpty ? '未知' : label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: severity == InfoSeverity.normal ? AppTheme.textMedium : color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    this.severity = InfoSeverity.normal,
  });

  final IconData icon;
  final InfoSeverity severity;

  @override
  Widget build(BuildContext context) {
    final color = _severityColor(severity);
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }
}

Color _severityColor(InfoSeverity severity) {
  return switch (severity) {
    InfoSeverity.normal => AppTheme.primary,
    InfoSeverity.success => AppTheme.success,
    InfoSeverity.warning => const Color(0xFFFF8A00),
    InfoSeverity.danger => AppTheme.danger,
  };
}

IconData _iconForInfoSeverity(InfoSeverity severity) {
  return switch (severity) {
    InfoSeverity.normal => Icons.info_outline,
    InfoSeverity.success => Icons.check_circle_outline,
    InfoSeverity.warning => Icons.warning_amber,
    InfoSeverity.danger => Icons.error_outline,
  };
}

InfoSeverity _severityFromStatus(String value) {
  final lower = value.toLowerCase();
  if (lower.contains('在线') ||
      lower.contains('运行') ||
      lower.contains('started') ||
      lower.contains('online')) {
    return InfoSeverity.success;
  }
  if (lower.contains('警告') ||
      lower.contains('停止') ||
      lower.contains('paused')) {
    return InfoSeverity.warning;
  }
  if (lower.contains('错误') || lower.contains('离线') || lower.contains('异常')) {
    return InfoSeverity.danger;
  }
  return InfoSeverity.normal;
}

Color _progressColor(double progress) {
  if (progress >= 0.85) {
    return AppTheme.danger;
  }
  if (progress >= 0.65) {
    return const Color(0xFFFF8A00);
  }
  return AppTheme.primary;
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.primary, size: 18),
        const SizedBox(width: 8),
        SizedBox(
          width: 54,
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.textLight,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textMedium,
              fontSize: 12,
              fontWeight: FontWeight.w500,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricLine extends StatelessWidget {
  const _MetricLine({
    required this.icon,
    required this.label,
    required this.value,
    required this.progress,
  });

  final IconData icon;
  final String label;
  final String value;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final color = progress > 0.85
        ? AppTheme.danger
        : progress > 0.65
            ? const Color(0xFFFF8A00)
            : AppTheme.primary;
    return Row(
      children: [
        Icon(icon, color: AppTheme.primary, size: 18),
        const SizedBox(width: 8),
        SizedBox(
          width: 54,
          child: Text(
            label,
            style: const TextStyle(
              color: AppTheme.textLight,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 7,
              value: progress,
              backgroundColor: AppTheme.softLine,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 74, maxWidth: 100),
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppTheme.textMedium,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

class _HomeAppShortcuts extends StatelessWidget {
  const _HomeAppShortcuts({required this.unraidClient});

  final UnraidClient? unraidClient;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _HomeAppShortcut(
          label: '相册',
          icon: Icons.photo_library,
          colors: const [AppTheme.primary, AppTheme.secondary],
          onTap: () {
            final client = unraidClient;
            if (client == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请先连接服务器')),
              );
              return;
            }
            Navigator.of(context).pushNamed(
              AlbumPage.routeName,
              arguments: AlbumPageArgs(
                unraidClient: client,
                rootPath: '/mnt/user/photos',
              ),
            );
          },
        ),
        const SizedBox(width: 20),
        _HomeAppShortcut(
          label: '音乐',
          icon: Icons.music_note,
          colors: const [Color(0xFF3498DB), Color(0xFF52C41A)],
          onTap: () {
            final client = unraidClient;
            if (client == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请先连接服务器')),
              );
              return;
            }
            Navigator.of(context).pushNamed(
              MusicPage.routeName,
              arguments: MusicPageArgs(
                unraidClient: client,
                rootPath: '/mnt/user/music',
              ),
            );
          },
        ),
        const SizedBox(width: 20),
        _HomeAppShortcut(
          label: '配置',
          icon: Icons.video_settings_outlined,
          colors: const [Color(0xFF8E44AD), Color(0xFF3498DB)],
          onTap: () {
            final client = unraidClient;
            if (client == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请先连接服务器')),
              );
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => VideoStreamSettingsPage(client: client),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _HomeAppShortcut extends StatelessWidget {
  const _HomeAppShortcut({
    required this.label,
    required this.icon,
    required this.colors,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final List<Color> colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Ink(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: colors,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: colors.first.withValues(alpha: 0.25),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(icon, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 7),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
