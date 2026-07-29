part of 'detail_page.dart';

class _DashboardDetailPage extends StatelessWidget {
  const _DashboardDetailPage({required this.dashboard});

  final UnraidDashboard dashboard;

  @override
  Widget build(BuildContext context) {
    return PhoneFrame(
      maxContentWidth: 900,
      child: Column(
        children: [
          SizedBox(
            height: 120,
            child: Stack(
              children: [
                Positioned(
                  left: 12,
                  top: 28,
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    label: const Text(
                      '返回',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        dashboard.serverName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        'server / info / settings / cloud',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.80),
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(30, 30, 30, 30),
                child: FadeSlide(
                  animate: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _DetailSection(
                        icon: Icons.badge,
                        title: '服务器资料',
                        child: Column(
                          children: [
                            _DataRow(label: 'GUID', value: dashboard.guid),
                            _DataRow(
                                label: 'Owner', value: dashboard.ownerName),
                            _DataRow(
                              label: '授权',
                              value: dashboard.registration,
                            ),
                            _DataRow(label: '状态', value: dashboard.status),
                          ],
                        ),
                      ),
                      _DetailSection(
                        icon: Icons.developer_board,
                        title: '硬件与系统',
                        child: Column(
                          children: [
                            _DataRow(label: '型号', value: dashboard.model),
                            _DataRow(label: 'CPU', value: dashboard.cpuSummary),
                            _DataRow(
                              label: '主板',
                              value: dashboard.baseboardSummary,
                            ),
                            _DataRow(label: '系统', value: dashboard.osSummary),
                            _DataRow(
                              label: '包版本',
                              value: dashboard.packagesSummary,
                            ),
                          ],
                        ),
                      ),
                      _DetailSection(
                        icon: Icons.storage,
                        title: '阵列与存储',
                        child: Column(
                          children: [
                            _DataRow(
                              label: '阵列',
                              value:
                                  '${dashboard.arrayState} · ${dashboard.arrayUsage}',
                            ),
                            _DataRow(
                              label: 'Parity',
                              value: dashboard.paritySummary.isEmpty
                                  ? '暂无校验任务'
                                  : dashboard.paritySummary,
                            ),
                            _DataRow(
                              label: '磁盘',
                              value: '${dashboard.diskItems.length} 个',
                            ),
                            _DataRow(
                              label: '共享',
                              value: '${dashboard.shareItems.length} 个',
                            ),
                          ],
                        ),
                      ),
                      _DetailSection(
                        icon: Icons.language,
                        title: '网络与连接',
                        child: Column(
                          children: [
                            _DataRow(label: 'LAN', value: dashboard.lanIp),
                            _DataRow(label: 'WAN', value: dashboard.wanIp),
                            _DataRow(
                                label: '本地 URL', value: dashboard.localUrl),
                            _DataRow(
                                label: '远程 URL', value: dashboard.remoteUrl),
                            _DataRow(
                              label: 'Docker 网络',
                              value: dashboard.dockerNetworkSummary,
                            ),
                            _DataRow(
                              label: '端口冲突',
                              value: dashboard.dockerConflictSummary,
                            ),
                          ],
                        ),
                      ),
                      _DetailSection(
                        icon: Icons.cloud_done,
                        title: 'Cloud / 插件 / 权限',
                        child: Column(
                          children: [
                            _DataRow(
                              label: 'Cloud',
                              value: dashboard.cloudItems
                                  .map((item) => '${item.title} ${item.value}')
                                  .take(2)
                                  .join(' · '),
                            ),
                            _DataRow(
                              label: '插件',
                              value: '${dashboard.pluginItems.length} 条记录',
                            ),
                            _DataRow(
                              label: '权限',
                              value: dashboard.securityItems
                                  .map((item) => '${item.title} ${item.value}')
                                  .join(' · '),
                            ),
                            _DataRow(
                              label: '日志',
                              value: '${dashboard.logItems.length} 个文件',
                            ),
                          ],
                        ),
                      ),
                      GradientButton(
                        label: '返回主页',
                        icon: Icons.home,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  const _DataRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.softLine)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textLight, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '未知' : value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textDark,
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

const _bodyStyle = TextStyle(
  color: AppTheme.textMedium,
  fontSize: 15,
  height: 1.6,
);

class _DetailSection extends StatelessWidget {
  const _DetailSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 25),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.primary),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: AppTheme.textDark,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          child,
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.softLine)),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppTheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textMedium, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.title,
    required this.text,
  });

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: AppTheme.inputBackground,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textDark,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            text,
            style: const TextStyle(
              color: AppTheme.textMedium,
              fontSize: 14,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
