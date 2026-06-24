import 'package:flutter/material.dart';

import '../services/unraid_client.dart';
import '../theme/app_theme.dart';
import '../widgets/bottom_nav.dart';
import '../widgets/fade_slide.dart';
import '../widgets/gradient_button.dart';
import '../widgets/phone_frame.dart';
import '../widgets/server_icon.dart';
import 'album_page.dart';
import 'detail_page.dart';
import 'music_page.dart';

class MainShellPage extends StatefulWidget {
  const MainShellPage({super.key});

  static const routeName = '/home';

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage> {
  int _currentIndex = 0;
  ServerIconVariant _serverIcon = ServerIconVariant.defaultIcon;
  UnraidClient? _unraidClient;
  Future<UnraidDashboard>? _dashboardFuture;

  static const _navItems = [
    BottomNavItem(icon: Icons.home, label: '主页'),
    BottomNavItem(icon: Icons.apps, label: 'Docker'),
    BottomNavItem(icon: Icons.computer, label: '虚拟机'),
    BottomNavItem(icon: Icons.folder_shared, label: '共享'),
  ];

  @override
  void dispose() {
    _unraidClient?.close();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_unraidClient != null) {
      return;
    }
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is UnraidClient) {
      _unraidClient = args;
      _dashboardFuture = args.fetchDashboard();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(25),
                      ),
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: _buildContent(),
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: AppBottomNav(
                    items: _navItems,
                    currentIndex: _currentIndex,
                    onChanged: (value) => setState(() => _currentIndex = value),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final dashboardFuture = _dashboardFuture;
    if (_unraidClient == null || dashboardFuture == null) {
      return const _StateMessage(
        icon: Icons.link_off,
        title: '未连接服务器',
        message: '请返回登录页重新连接。',
      );
    }

    return FutureBuilder<UnraidDashboard>(
      future: dashboardFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const _StateMessage(
            icon: Icons.cloud_sync,
            title: '正在读取服务器',
            message: '正在读取 Unraid WebGUI...',
          );
        }

        if (snapshot.hasError) {
          return _StateMessage(
            icon: Icons.error_outline,
            title: '读取失败',
            message: snapshot.error.toString(),
            actionLabel: '重试',
            onAction: _refreshDashboard,
          );
        }

        final dashboard = snapshot.data;
        if (dashboard == null) {
          return const _StateMessage(
            icon: Icons.inbox_outlined,
            title: '暂无数据',
            message: '服务器没有返回可显示的数据。',
          );
        }

        return _buildCurrentPage(dashboard);
      },
    );
  }

  Widget _buildCurrentPage(UnraidDashboard dashboard) {
    switch (_currentIndex) {
      case 1:
        return _ManagementPage(
          key: const ValueKey('docker'),
          type: 'Docker',
          dashboard: dashboard,
          items: dashboard.dockerItems
              .map((item) => ManagementData.fromClient(item, Icons.layers))
              .toList(),
          unraidClient: _unraidClient,
        );
      case 2:
        return _ManagementPage(
          key: const ValueKey('vm'),
          type: '虚拟机',
          dashboard: dashboard,
          items: dashboard.vmItems
              .map((item) => ManagementData.fromClient(item, Icons.computer))
              .toList(),
          unraidClient: _unraidClient,
        );
      case 3:
        return _ManagementPage(
          key: const ValueKey('share'),
          type: '共享',
          dashboard: dashboard,
          items: dashboard.shareItems
              .map((item) =>
                  ManagementData.fromClient(item, Icons.folder_shared))
              .toList(),
          unraidClient: _unraidClient,
        );
      default:
        return _ServerInfoPage(
          key: const ValueKey('server'),
          iconVariant: _serverIcon,
          dashboard: dashboard,
          unraidClient: _unraidClient,
          onEditIcon: _showIconPicker,
          onPowerAction: _showPowerDialog,
          onOpenDetails: () => _openDashboardDetails(dashboard),
        );
    }
  }

  void _refreshDashboard() {
    final client = _unraidClient;
    if (client == null) {
      return;
    }
    setState(() {
      _dashboardFuture = client.fetchDashboard();
    });
  }

  Future<void> _showIconPicker() async {
    final selected = await showDialog<ServerIconVariant>(
      context: context,
      builder: (context) => _IconPickerDialog(current: _serverIcon),
    );
    if (selected != null) {
      setState(() => _serverIcon = selected);
    }
  }

  Future<void> _showPowerDialog(String action) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('确认$action'),
        content: Text('确定要$action服务器吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }

    final client = _unraidClient;
    if (client == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('未连接服务器')),
      );
      return;
    }

    try {
      if (action == '重启') {
        await client.reboot();
      } else {
        await client.shutdown();
      }
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('服务器正在$action...')),
      );
    } on UnraidClientException catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$action失败：$error')),
      );
    }
  }

  void _openDashboardDetails(UnraidDashboard dashboard) {
    Navigator.of(context).pushNamed(
      DetailPage.routeName,
      arguments: dashboard,
    );
  }
}

class _ServerInfoPage extends StatelessWidget {
  const _ServerInfoPage({
    super.key,
    required this.iconVariant,
    required this.dashboard,
    required this.unraidClient,
    required this.onEditIcon,
    required this.onPowerAction,
    required this.onOpenDetails,
  });

  final ServerIconVariant iconVariant;
  final UnraidDashboard dashboard;
  final UnraidClient? unraidClient;
  final VoidCallback onEditIcon;
  final ValueChanged<String> onPowerAction;
  final VoidCallback onOpenDetails;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 86),
      child: FadeSlide(
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
            GradientButton(
              label: '查看完整信息',
              icon: Icons.info_outline,
              onPressed: onOpenDetails,
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
          onTap: () => Navigator.of(context).pushNamed(MusicPage.routeName),
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
  });

  final String type;
  final UnraidDashboard dashboard;
  final List<ManagementData> items;
  final UnraidClient? unraidClient;

  @override
  State<_ManagementPage> createState() => _ManagementPageState();
}

class _ManagementPageState extends State<_ManagementPage> {
  final _searchController = TextEditingController();
  final Set<String> _submittingIds = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filteredItems = widget.items.where((item) {
      if (query.isEmpty) {
        return true;
      }
      return [
        item.title,
        item.status,
        item.description,
        ...item.tags,
      ].join(' ').toLowerCase().contains(query);
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 86),
      child: FadeSlide(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ManagementStats(type: widget.type, dashboard: widget.dashboard),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    onChanged: (_) => setState(() {}),
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
                  onPressed: () => _showMessage('${widget.type}刷新已提交'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            for (final item in filteredItems)
              _ManagementCard(
                item: item,
                isSubmitting: _submittingIds.contains(item.id),
                onTap: () => _openDetail(item),
                onAction: item.type == ManagementItemType.share
                    ? null
                    : (action) => _runAction(item, action),
              ),
            if (widget.items.isEmpty)
              _StateMessage(
                icon: Icons.inbox_outlined,
                title: '${widget.type}为空',
                message: '服务器当前没有返回${widget.type}项目。',
              ),
            if (widget.items.isNotEmpty && filteredItems.isEmpty)
              _StateMessage(
                icon: Icons.search_off,
                title: '没有匹配项',
                message: '换一个关键词试试。',
              ),
          ],
        ),
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

class ManagementDetailPage extends StatefulWidget {
  const ManagementDetailPage({super.key});

  static const routeName = '/management-detail';

  @override
  State<ManagementDetailPage> createState() => _ManagementDetailPageState();
}

class _ManagementDetailPageState extends State<ManagementDetailPage> {
  bool _isSubmitting = false;
  String? _sharePath;
  Future<List<UnraidFileEntry>>? _shareFuture;

  @override
  Widget build(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final detailArgs = args is ManagementDetailArgs
        ? args
        : ManagementDetailArgs(
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
            ),
            unraidClient: null,
          );

    if (detailArgs.data.type == ManagementItemType.share) {
      _ensureShareBrowser(detailArgs);
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
                    onPressed: () => _openSharePath(currentPath),
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
                ],
              ),
            ),
            Expanded(
              child: FutureBuilder<List<UnraidFileEntry>>(
                future: _shareFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const _StateMessage(
                      icon: Icons.folder_open,
                      title: '正在读取目录',
                      message: '正在加载共享文件...',
                    );
                  }

                  if (snapshot.hasError) {
                    return _StateMessage(
                      icon: Icons.error_outline,
                      title: '读取失败',
                      message: snapshot.error.toString(),
                      actionLabel: '重试',
                      onAction: () => _openSharePath(currentPath),
                    );
                  }

                  final entries = snapshot.data ?? const <UnraidFileEntry>[];
                  if (entries.isEmpty) {
                    return const _StateMessage(
                      icon: Icons.inbox_outlined,
                      title: '目录为空',
                      message: '这里还没有可浏览的文件。',
                    );
                  }

                  return ListView(
                    padding: const EdgeInsets.fromLTRB(30, 0, 30, 30),
                    children: [
                      if (_canGoUp(args))
                        _FileEntryTile(
                          icon: Icons.drive_folder_upload,
                          title: '上一级',
                          subtitle: _parentPath(currentPath),
                          onTap: () => _openSharePath(_parentPath(currentPath)),
                        ),
                      for (final entry in entries)
                        _FileEntryTile(
                          icon: entry.isDirectory
                              ? Icons.folder
                              : entry.isImage
                                  ? Icons.image
                                  : Icons.insert_drive_file,
                          title: entry.name,
                          subtitle:
                              entry.isDirectory ? '文件夹' : _fileSubtitle(entry),
                          onTap: () {
                            if (entry.isDirectory) {
                              _openSharePath(entry.path);
                            } else if (entry.isImage) {
                              _previewImage(args, entry);
                            } else {
                              _showMessage('暂不支持预览该文件类型');
                            }
                          },
                        ),
                    ],
                  );
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

  void _ensureShareBrowser(ManagementDetailArgs args) {
    if (_sharePath != null && _shareFuture != null) {
      return;
    }
    final root = _shareRoot(args);
    _sharePath = root;
    _shareFuture = args.unraidClient?.fetchDirectory(root) ??
        Future<List<UnraidFileEntry>>.error('缺少服务器连接');
  }

  void _openSharePath(String path) {
    final args = ModalRoute.of(context)?.settings.arguments;
    final detailArgs = args is ManagementDetailArgs ? args : null;
    final client = detailArgs?.unraidClient;
    if (client == null) {
      _showMessage('缺少服务器连接');
      return;
    }
    setState(() {
      _sharePath = path;
      _shareFuture = client.fetchDirectory(path);
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
        child: _ImagePreview(client: client, entry: entry),
      ),
    );
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.softLine),
      ),
      child: Column(children: children),
    );
  }
}

class _DetailInfoRow extends StatelessWidget {
  const _DetailInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.primary, size: 20),
          const SizedBox(width: 10),
          SizedBox(
            width: 58,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManagementActionButton extends StatelessWidget {
  const _ManagementActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: const BorderSide(color: AppTheme.line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _FileEntryTile extends StatelessWidget {
  const _FileEntryTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.softLine),
          ),
          child: Row(
            children: [
              Icon(icon, color: AppTheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textDark,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textLight,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Icon(
                icon == Icons.image ? Icons.visibility : Icons.chevron_right,
                color: AppTheme.textLight,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({
    required this.client,
    required this.entry,
  });

  final UnraidClient client;
  final UnraidFileEntry entry;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 860, maxHeight: 720),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textDark,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          Flexible(
            child: FutureBuilder(
              future: client.fetchFileBytes(entry.path),
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(48),
                    child: CircularProgressIndicator(),
                  );
                }

                if (snapshot.hasError || !snapshot.hasData) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snapshot.error?.toString() ?? '图片加载失败',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppTheme.danger,
                        fontSize: 14,
                      ),
                    ),
                  );
                }

                return InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4,
                  child: Image.memory(
                    snapshot.data!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: AppTheme.primary, size: 42),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textMedium,
                fontSize: 14,
                height: 1.4,
              ),
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
      ),
    );
  }
}

class _IconPickerDialog extends StatefulWidget {
  const _IconPickerDialog({required this.current});

  final ServerIconVariant current;

  @override
  State<_IconPickerDialog> createState() => _IconPickerDialogState();
}

class _IconPickerDialogState extends State<_IconPickerDialog> {
  late ServerIconVariant _selected = widget.current;

  @override
  Widget build(BuildContext context) {
    final variants = ServerIconVariant.values;
    return AlertDialog(
      title: const Text('选择服务器图标'),
      content: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final variant in variants)
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _selected = variant),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _selected == variant
                        ? AppTheme.primary
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
                child: ServerIconView(variant: variant, size: 72),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_selected),
          child: const Text('确认'),
        ),
      ],
    );
  }
}
