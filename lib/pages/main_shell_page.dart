import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../services/app_logger.dart';
import '../services/media_cache.dart';
import '../services/music_player_service.dart';
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

const _maxImagePreviewDecodeExtent = 2400;
const _maxTextPreviewBytes = 1024 * 1024;
/// Soft guidance only — PDF still streams to disk; very large docs may be slow.
const _maxPdfPreviewHintBytes = 80 * 1024 * 1024;

/// Process-local cache for share browser image previews (path -> File).
/// Full-resolution stills stream to disk; no hard byte-size reject.
final Map<String, Future<File>> _sharePreviewFileCache =
    <String, Future<File>>{};
const _maxSharePreviewCacheEntries = 16;

/// Process-local cache for share browser text previews (path -> decoded text).
final Map<String, Future<String>> _sharePreviewTextCache =
    <String, Future<String>>{};
const _maxSharePreviewTextCacheEntries = 12;

class MainShellPage extends StatefulWidget {
  const MainShellPage({super.key});

  static const routeName = '/home';

  @override
  State<MainShellPage> createState() => _MainShellPageState();
}

class _MainShellPageState extends State<MainShellPage>
    with WidgetsBindingObserver {
  static const _dashboardMinRefreshInterval = Duration(seconds: 8);
  /// Soft re-fetch after returning from background so CPU/array stats feel live
  /// without hammering WebGUI on every brief app switch.
  static const _resumeSoftRefreshMinInterval = Duration(seconds: 20);

  /// Bottom-nav index is isolated so tab switches do not rebuild PhoneFrame chrome.
  final ValueNotifier<int> _currentIndex = ValueNotifier<int>(0);
  /// Only build bottom-nav pages after first visit so Docker/VM/share lists
  /// are not constructed while the user stays on Home.
  final Set<int> _visitedTabs = <int>{0};
  /// Bumped when a lazy tab is first visited so IndexedStack children update.
  final ValueNotifier<int> _visitedTabsVersion = ValueNotifier<int>(0);
  ServerIconVariant _serverIcon = ServerIconVariant.defaultIcon;
  UnraidClient? _unraidClient;
  UnraidDashboard? _lastDashboard;
  DateTime? _lastDashboardFetchAt;
  Object? _dashboardError;
  /// Published dashboard data — soft refreshes that return the same instance
  /// do not rebuild tab trees.
  final ValueNotifier<UnraidDashboard?> _dashboard =
      ValueNotifier<UnraidDashboard?>(null);
  /// Spinner-only notifier so soft refresh flags do not rebuild every tab page.
  final ValueNotifier<bool> _dashboardRefreshing = ValueNotifier<bool>(false);

  // Memoized ManagementData projections keyed by the source list identity so
  // tab rebuilds after soft dashboard refreshes avoid remapping every item.
  List<UnraidManagementItem>? _dockerSourceRef;
  List<UnraidManagementItem>? _vmSourceRef;
  List<UnraidManagementItem>? _shareSourceRef;
  List<ManagementData> _mappedDocker = const <ManagementData>[];
  List<ManagementData> _mappedVm = const <ManagementData>[];
  List<ManagementData> _mappedShare = const <ManagementData>[];

  static const _navItems = [
    BottomNavItem(icon: Icons.home, label: '主页'),
    BottomNavItem(icon: Icons.apps, label: 'Docker'),
    BottomNavItem(icon: Icons.computer, label: '虚拟机'),
    BottomNavItem(icon: Icons.folder_shared, label: '共享'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _currentIndex.dispose();
    _visitedTabsVersion.dispose();
    _dashboard.dispose();
    _dashboardRefreshing.dispose();
    // Stop background music when leaving the shell (logout / reconnect).
    unawaited(MusicPlayerService.instance.stopAndClear());
    _unraidClient?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    if (_unraidClient == null || _lastDashboard == null) {
      return;
    }
    final lastFetch = _lastDashboardFetchAt;
    if (lastFetch != null &&
        DateTime.now().difference(lastFetch) < _resumeSoftRefreshMinInterval) {
      return;
    }
    // Soft refresh reuses segment TTLs — only stale overview/lists hit network.
    _refreshDashboard(force: false);
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
      // Join any login-time prewarm (SSH + dashboard) instead of starting
      // cold; force still coalesces with an in-flight forced fetch.
      unawaited(args.warmSsh());
      unawaited(_loadDashboard(force: true));
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
                    // Avoid AnimatedSwitcher here: dashboard refresh rebuilds
                    // the FutureBuilder frequently and a 250ms cross-fade on
                    // every pull is wasted work once tabs are IndexedStacked.
                    child: _buildContent(),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ValueListenableBuilder<int>(
                    valueListenable: _currentIndex,
                    builder: (context, index, _) {
                      return AppBottomNav(
                        items: _navItems,
                        currentIndex: index,
                        onChanged: _selectTab,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _selectTab(int index) {
    final alreadyVisited = _visitedTabs.contains(index);
    if (_currentIndex.value == index && alreadyVisited) {
      return;
    }
    final isNewVisit = _visitedTabs.add(index);
    _currentIndex.value = index;
    if (isNewVisit) {
      _visitedTabsVersion.value += 1;
    }
  }

  Widget _buildContent() {
    if (_unraidClient == null) {
      return const _StateMessage(
        icon: Icons.link_off,
        title: '未连接服务器',
        message: '请返回登录页重新连接。',
      );
    }

    // ValueNotifier keeps tab bodies stable across soft refreshes that return
    // the same dashboard instance (segment TTL hits).
    return ValueListenableBuilder<UnraidDashboard?>(
      valueListenable: _dashboard,
      builder: (context, dashboard, _) {
        final resolved = dashboard ?? _lastDashboard;
        if (resolved != null) {
          return Stack(
            children: [
              // Lazy + sticky tabs: first visit builds the page; later switches
              // keep search text / scroll without building unused tabs on boot.
              // Tab index / first-visit are notifiers so switches skip setState.
              ValueListenableBuilder<int>(
                valueListenable: _visitedTabsVersion,
                builder: (context, _, __) {
                  return ValueListenableBuilder<int>(
                    valueListenable: _currentIndex,
                    builder: (context, index, ___) {
                      return IndexedStack(
                        index: index,
                        children: [
                          for (var i = 0; i < _navItems.length; i++)
                            _visitedTabs.contains(i)
                                ? KeyedSubtree(
                                    key: ValueKey<String>('shell-tab-$i'),
                                    child: _buildTabPage(i, resolved),
                                  )
                                : const SizedBox.shrink(),
                        ],
                      );
                    },
                  );
                },
              ),
              // Isolate spinner rebuilds from tab content rebuilds.
              Positioned(
                top: 10,
                left: 0,
                right: 0,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _dashboardRefreshing,
                  builder: (context, refreshing, _) {
                    if (!refreshing) {
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

        if (_dashboardError != null) {
          return _StateMessage(
            icon: Icons.error_outline,
            title: '读取失败',
            message: _dashboardError.toString(),
            actionLabel: '重试',
            onAction: () => _refreshDashboard(force: true),
          );
        }

        return const _StateMessage(
          icon: Icons.cloud_sync,
          title: '正在读取服务器',
          message: '正在读取 Unraid WebGUI...',
        );
      },
    );
  }

  void _ensureMappedManagementItems(UnraidDashboard dashboard) {
    if (!identical(_dockerSourceRef, dashboard.dockerItems)) {
      _dockerSourceRef = dashboard.dockerItems;
      _mappedDocker = dashboard.dockerItems
          .map((item) => ManagementData.fromClient(item, Icons.layers))
          .toList(growable: false);
    }
    if (!identical(_vmSourceRef, dashboard.vmItems)) {
      _vmSourceRef = dashboard.vmItems;
      _mappedVm = dashboard.vmItems
          .map((item) => ManagementData.fromClient(item, Icons.computer))
          .toList(growable: false);
    }
    if (!identical(_shareSourceRef, dashboard.shareItems)) {
      _shareSourceRef = dashboard.shareItems;
      _mappedShare = dashboard.shareItems
          .map(
            (item) => ManagementData.fromClient(item, Icons.folder_shared),
          )
          .toList(growable: false);
    }
  }

  Widget _buildTabPage(int index, UnraidDashboard dashboard) {
    _ensureMappedManagementItems(dashboard);
    switch (index) {
      case 1:
        return _ManagementPage(
          type: 'Docker',
          dashboard: dashboard,
          items: _mappedDocker,
          unraidClient: _unraidClient,
          onRefresh: () => _refreshDashboard(force: true),
        );
      case 2:
        return _ManagementPage(
          type: '虚拟机',
          dashboard: dashboard,
          items: _mappedVm,
          unraidClient: _unraidClient,
          onRefresh: () => _refreshDashboard(force: true),
        );
      case 3:
        return _ManagementPage(
          type: '共享',
          dashboard: dashboard,
          items: _mappedShare,
          unraidClient: _unraidClient,
          onRefresh: () => _refreshDashboard(force: true),
        );
      default:
        return _ServerInfoPage(
          iconVariant: _serverIcon,
          dashboard: dashboard,
          unraidClient: _unraidClient,
          onEditIcon: _showIconPicker,
          onPowerAction: _showPowerDialog,
          onOpenDetails: () => _openDashboardDetails(dashboard),
          onRefresh: () => _refreshDashboard(force: true),
        );
    }
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

    _dashboardRefreshing.value = true;
    try {
      final dashboard = await client.fetchDashboard(forceRefresh: force);
      _lastDashboard = dashboard;
      _lastDashboardFetchAt = DateTime.now();
      _dashboardError = null;
      // Skip notification when segment TTL returns the same cached instance.
      if (!identical(_dashboard.value, dashboard)) {
        _dashboard.value = dashboard;
      } else if (_dashboard.value == null) {
        _dashboard.value = dashboard;
      }
      return dashboard;
    } on Object catch (error) {
      if (_lastDashboard == null) {
        _dashboardError = error;
        if (mounted) {
          setState(() {});
        }
      }
      rethrow;
    } finally {
      _dashboardRefreshing.value = false;
    }
  }

  void _refreshDashboard({bool force = false}) {
    final client = _unraidClient;
    if (client == null) {
      return;
    }
    if (_dashboardRefreshing.value && !force) {
      return;
    }
    // No setState: spinner + dashboard notifiers drive rebuilds.
    unawaited(_loadDashboard(force: force));
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

