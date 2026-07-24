import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/app_logger.dart';
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

part 'main_shell_home.dart';
part 'management_page.dart';
part 'management_detail_page.dart';
part 'management_detail_widgets.dart';

const _maxImagePreviewBytes = 32 * 1024 * 1024;
const _maxImagePreviewDecodeExtent = 2400;
const _maxTextPreviewBytes = 1024 * 1024;

class MainShellPage extends StatefulWidget {
  const MainShellPage({super.key});

  static const routeName = '/home';

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage> {
  static const _dashboardMinRefreshInterval = Duration(seconds: 8);

  int _currentIndex = 0;
  ServerIconVariant _serverIcon = ServerIconVariant.defaultIcon;
  UnraidClient? _unraidClient;
  Future<UnraidDashboard>? _dashboardFuture;
  UnraidDashboard? _lastDashboard;
  DateTime? _lastDashboardFetchAt;
  bool _dashboardRefreshing = false;

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
      // Keep SSH warm in the background after login for faster file ops.
      unawaited(args.warmSsh());
      _dashboardFuture = _loadDashboard(force: true);
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
        // Keep the previous dashboard visible while a background refresh runs.
        final dashboard = snapshot.data ?? _lastDashboard;
        if (dashboard != null) {
          final isRefreshing = _dashboardRefreshing ||
              snapshot.connectionState != ConnectionState.done;
          return Stack(
            children: [
              // Keep tab subtrees alive so search text / scroll offsets survive
              // bottom-nav switches without rebuilding management pages.
              IndexedStack(
                index: _currentIndex,
                children: [
                  _ServerInfoPage(
                    key: const ValueKey('server'),
                    iconVariant: _serverIcon,
                    dashboard: dashboard,
                    unraidClient: _unraidClient,
                    onEditIcon: _showIconPicker,
                    onPowerAction: _showPowerDialog,
                    onOpenDetails: () => _openDashboardDetails(dashboard),
                    onRefresh: () => _refreshDashboard(force: true),
                  ),
                  _ManagementPage(
                    key: const ValueKey('docker'),
                    type: 'Docker',
                    dashboard: dashboard,
                    items: dashboard.dockerItems
                        .map(
                          (item) =>
                              ManagementData.fromClient(item, Icons.layers),
                        )
                        .toList(growable: false),
                    unraidClient: _unraidClient,
                    onRefresh: () => _refreshDashboard(force: true),
                  ),
                  _ManagementPage(
                    key: const ValueKey('vm'),
                    type: '虚拟机',
                    dashboard: dashboard,
                    items: dashboard.vmItems
                        .map(
                          (item) =>
                              ManagementData.fromClient(item, Icons.computer),
                        )
                        .toList(growable: false),
                    unraidClient: _unraidClient,
                    onRefresh: () => _refreshDashboard(force: true),
                  ),
                  _ManagementPage(
                    key: const ValueKey('share'),
                    type: '共享',
                    dashboard: dashboard,
                    items: dashboard.shareItems
                        .map(
                          (item) => ManagementData.fromClient(
                            item,
                            Icons.folder_shared,
                          ),
                        )
                        .toList(growable: false),
                    unraidClient: _unraidClient,
                    onRefresh: () => _refreshDashboard(force: true),
                  ),
                ],
              ),
              if (isRefreshing)
                const Positioned(
                  top: 10,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
            ],
          );
        }

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
            onAction: () => _refreshDashboard(force: true),
          );
        }

        return const _StateMessage(
          icon: Icons.inbox_outlined,
          title: '暂无数据',
          message: '服务器没有返回可显示的数据。',
        );
      },
    );
  }

  Future<UnraidDashboard> _loadDashboard({bool force = false}) async {
    final client = _unraidClient;
    if (client == null) {
      throw const UnraidClientException('未连接服务器');
    }

    final lastFetch = _lastDashboardFetchAt;
    if (!force &&
        lastFetch != null &&
        DateTime.now().difference(lastFetch) < _dashboardMinRefreshInterval &&
        _lastDashboard != null) {
      return _lastDashboard!;
    }

    if (mounted) {
      setState(() => _dashboardRefreshing = true);
    } else {
      _dashboardRefreshing = true;
    }
    try {
      final dashboard = await client.fetchDashboard(forceRefresh: force);
      _lastDashboard = dashboard;
      _lastDashboardFetchAt = DateTime.now();
      return dashboard;
    } finally {
      if (mounted) {
        setState(() => _dashboardRefreshing = false);
      } else {
        _dashboardRefreshing = false;
      }
    }
  }

  void _refreshDashboard({bool force = false}) {
    final client = _unraidClient;
    if (client == null) {
      return;
    }
    if (_dashboardRefreshing && !force) {
      return;
    }
    setState(() {
      _dashboardFuture = _loadDashboard(force: force);
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

