import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';

part 'unraid_models.dart';
part 'unraid_client_parsers.dart';
part 'unraid_client_ssh.dart';

class UnraidClientException implements Exception {
  const UnraidClientException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef UnraidClient = UnraidWebGuiClient;

class _DirectoryCacheEntry {
  const _DirectoryCacheEntry({
    required this.entries,
    required this.fetchedAt,
  });

  final List<UnraidFileEntry> entries;
  final DateTime fetchedAt;
}

class _FileBytesCacheEntry {
  const _FileBytesCacheEntry({
    required this.bytes,
    required this.fetchedAt,
  });

  final Uint8List bytes;
  final DateTime fetchedAt;
}

class _DashboardSegmentCache {
  const _DashboardSegmentCache({
    required this.dashboard,
    required this.overviewFetchedAt,
    required this.dockerFetchedAt,
    required this.vmFetchedAt,
    required this.shareFetchedAt,
  });

  final UnraidDashboard dashboard;
  final DateTime overviewFetchedAt;
  final DateTime dockerFetchedAt;
  final DateTime vmFetchedAt;
  final DateTime shareFetchedAt;
}

const _remoteFileChannel = MethodChannel('unraider/remote_file');
const _localMediaChannel = MethodChannel('unraider/local_media');

class UnraidWebGuiClient {
  UnraidWebGuiClient({
    required String baseUrl,
    required String username,
    required String password,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        username = username.trim().isEmpty ? 'root' : username.trim(),
        _password = password,
        _httpClient = httpClient ?? http.Client();

  static const _directoryCacheTtl = Duration(seconds: 20);
  static const _maxDirectoryCacheEntries = 48;
  static const _mediaScanCacheTtl = Duration(seconds: 45);
  static const _maxMediaScanCacheEntries = 16;
  static const _dashboardOverviewTtl = Duration(seconds: 8);
  static const _dashboardListTtl = Duration(seconds: 20);

  /// Shared WebGUI HTTP timeout for ordinary page/API calls.
  static const httpTimeout = Duration(seconds: 20);

  /// Login + CSRF handshake may need a little longer on slow LANs.
  static const loginTimeout = Duration(seconds: 25);

  /// Long-running SSH/SFTP file transfers.
  /// Generous timeout so album/video/music previews can pull larger media.
  static const fileTransferTimeout = Duration(minutes: 3);

  /// Short probes (SSH port discovery, directory existence).
  static const probeTimeout = Duration(seconds: 10);

  /// Idle SSH keep-alive so long album/share sessions do not drop mid-use.
  static const sshKeepAliveInterval = Duration(seconds: 30);

  /// Short TTL for small remote file reads (thumbnails / text previews).
  static const _fileBytesCacheTtl = Duration(seconds: 60);
  static const _maxFileBytesCacheEntries = 24;
  static const _maxCachedFileBytes = 4 * 1024 * 1024;

  final String baseUrl;
  final String username;
  final String _password;
  final http.Client _httpClient;
  final Map<String, String> _cookies = <String, String>{};
  /// Cached Cookie header so every HTTP request does not re-join the map.
  String? _cookieHeaderCache;
  final Map<String, _DirectoryCacheEntry> _directoryCache =
      <String, _DirectoryCacheEntry>{};
  /// In-flight directory reads keyed by normalized path, so concurrent
  /// callers (share list + dashboard shares, double-taps) share one SSH call.
  final Map<String, Future<List<UnraidFileEntry>>> _directoryInflight =
      <String, Future<List<UnraidFileEntry>>>{};
  /// Monotonic generation so a slower soft fetch cannot overwrite a newer
  /// force-refresh result in the directory cache.
  final Map<String, int> _directoryLoadGeneration = <String, int>{};
  final Map<String, _DirectoryCacheEntry> _mediaScanCache =
      <String, _DirectoryCacheEntry>{};
  final Map<String, Future<List<UnraidFileEntry>>> _mediaScanInflight =
      <String, Future<List<UnraidFileEntry>>>{};
  final Map<String, int> _mediaScanLoadGeneration = <String, int>{};
  final Map<String, _FileBytesCacheEntry> _fileBytesCache =
      <String, _FileBytesCacheEntry>{};
  final Map<String, Future<Uint8List>> _fileBytesInflight =
      <String, Future<Uint8List>>{};
  /// In-flight byte-range reads for progressive media streaming.
  final Map<String, Future<Uint8List>> _fileRangeInflight =
      <String, Future<Uint8List>>{};

  /// Shares whose Android SMB transport failed during this session. Further
  /// reads use SFTP directly instead of repeating the same failing handshake.
  final Set<String> _androidSmbUnavailableShares = <String>{};
  String? _csrfToken;
  Future<void>? _csrfTokenFuture;
  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  Future<int>? _sshPortFuture;
  Future<SSHClient>? _sshConnectFuture;
  Future<SftpClient>? _sftpConnectFuture;
  Future<void> _sftpTransferQueue = Future<void>.value();
  Future<void> _sshCommandQueue = Future<void>.value();
  _DashboardSegmentCache? _dashboardSegmentCache;
  Future<UnraidDashboard>? _dashboardInflight;
  bool _dashboardInflightForced = false;

  Future<void> checkConnection() async {
    try {
      await _login().timeout(loginTimeout);
      await _ensureCsrfToken().timeout(httpTimeout);
      await _checkAuth().timeout(httpTimeout);
    } on TimeoutException {
      throw const UnraidClientException('连接服务器超时，请检查地址、协议和网络');
    }
  }

  /// Best-effort SSH handshake so the first share/album open is faster.
  /// Failures are swallowed — WebGUI session remains valid without SSH.
  Future<void> warmSsh() async {
    if (kIsWeb) {
      return;
    }
    try {
      await _ensureSshClient();
    } on Object {
      // SSH may be disabled or firewalled; ignore prewarm failures.
    }
  }

  /// Loads dashboard overview + management lists with independent TTLs.
  ///
  /// Overview (CPU/memory/array) refreshes more often than Docker/VM/share
  /// lists, so a quick home pull does not always re-hit every endpoint.
  Future<UnraidDashboard> fetchDashboard({bool forceRefresh = false}) async {
    final now = DateTime.now();
    final cache = _dashboardSegmentCache;

    final needOverview = forceRefresh ||
        cache == null ||
        now.difference(cache.overviewFetchedAt) >= _dashboardOverviewTtl;
    final needDocker = forceRefresh ||
        cache == null ||
        now.difference(cache.dockerFetchedAt) >= _dashboardListTtl;
    final needVm = forceRefresh ||
        cache == null ||
        now.difference(cache.vmFetchedAt) >= _dashboardListTtl;
    final needShare = forceRefresh ||
        cache == null ||
        now.difference(cache.shareFetchedAt) >= _dashboardListTtl;

    // When every segment is still fresh, need* implies cache is present.
    if (cache != null &&
        !needOverview &&
        !needDocker &&
        !needVm &&
        !needShare) {
      return cache.dashboard;
    }

    // Coalesce concurrent pulls (pull-to-refresh + tab switch, double taps).
    // A forced refresh supersedes a soft in-flight fetch.
    final inflight = _dashboardInflight;
    if (inflight != null && (!forceRefresh || _dashboardInflightForced)) {
      return inflight;
    }

    final future = _fetchDashboardSegments(
      forceRefresh: forceRefresh,
      needOverview: needOverview,
      needDocker: needDocker,
      needVm: needVm,
      needShare: needShare,
      cache: cache,
      now: now,
    );
    _dashboardInflight = future;
    _dashboardInflightForced = forceRefresh;
    try {
      return await future;
    } finally {
      if (identical(_dashboardInflight, future)) {
        _dashboardInflight = null;
        _dashboardInflightForced = false;
      }
    }
  }

  Future<UnraidDashboard> _fetchDashboardSegments({
    required bool forceRefresh,
    required bool needOverview,
    required bool needDocker,
    required bool needVm,
    required bool needShare,
    required _DashboardSegmentCache? cache,
    required DateTime now,
  }) async {
    await _ensureCsrfToken();

    final futures = <Future<Object>>[];
    final kinds = <String>[];
    if (needOverview) {
      futures.add(_send('GET', '/Dashboard'));
      kinds.add('overview');
    }
    if (needDocker) {
      futures.add(_fetchDockerItems());
      kinds.add('docker');
    }
    if (needVm) {
      futures.add(_fetchVmItems());
      kinds.add('vm');
    }
    if (needShare) {
      futures.add(_fetchShareItems());
      kinds.add('share');
    }

    final results =
        futures.isEmpty ? const <Object>[] : await Future.wait<Object>(futures);

    http.Response? overviewResponse;
    List<UnraidManagementItem>? dockerItems;
    List<UnraidManagementItem>? vmItems;
    List<UnraidManagementItem>? shareItems;
    for (var i = 0; i < kinds.length; i++) {
      switch (kinds[i]) {
        case 'overview':
          overviewResponse = results[i] as http.Response;
        case 'docker':
          dockerItems = results[i] as List<UnraidManagementItem>;
        case 'vm':
          vmItems = results[i] as List<UnraidManagementItem>;
        case 'share':
          shareItems = results[i] as List<UnraidManagementItem>;
      }
    }

    final previous = cache?.dashboard;
    var serverName = previous?.serverName ?? 'Unraid';
    var version = previous?.version ?? 'WebGUI';
    var cpuSummary = previous?.cpuSummary ?? '';
    var memoryUsage = previous?.memoryUsage ?? '';
    var arrayState = previous?.arrayState ?? '';
    var arrayUsage = previous?.arrayUsage ?? '';
    var arrayPercent = previous?.arrayPercent ?? 0.0;

    if (overviewResponse != null) {
      // Reuse the single decode already done in [_sendUri] for CSRF/login checks.
      final dashboardHtml = _responseBody(overviewResponse);
      _extractCsrf(dashboardHtml);
      // Heavy HTML scraping runs off the UI isolate for large payloads.
      final overview = await parseDashboardOverviewAsync(dashboardHtml);
      serverName = overview[0] as String;
      version = overview[1] as String;
      cpuSummary = overview[2] as String;
      memoryUsage = overview[3] as String;
      arrayState = overview[4] as String;
      arrayUsage = overview[5] as String;
      arrayPercent = overview[6] as double;
    }

    final resolvedDocker = dockerItems ?? previous?.dockerItems ?? const [];
    final resolvedVm = vmItems ?? previous?.vmItems ?? const [];
    final resolvedShare = shareItems ?? previous?.shareItems ?? const [];

    final dashboard = UnraidDashboard(
      serverName: serverName,
      serverDescription: 'Unraid WebGUI',
      guid: previous?.guid ?? '',
      ownerName: previous?.ownerName ?? '',
      registration: previous?.registration ?? '',
      model: previous?.model ?? '',
      version: version,
      status: '已连接',
      lanIp: Uri.parse(baseUrl).host,
      wanIp: previous?.wanIp ?? '',
      localUrl: baseUrl,
      remoteUrl: previous?.remoteUrl ?? '',
      uptime: previous?.uptime ?? '',
      cpuSummary: cpuSummary,
      cpuPercent: previous?.cpuPercent ?? 0,
      baseboardSummary: previous?.baseboardSummary ?? '',
      osSummary: previous?.osSummary ?? '',
      packagesSummary: previous?.packagesSummary ?? '',
      memoryUsage: memoryUsage,
      memoryPercent: previous?.memoryPercent ?? 0,
      arrayState: arrayState,
      arrayUsage: arrayUsage,
      arrayPercent: arrayPercent,
      paritySummary: previous?.paritySummary ?? '暂无校验任务',
      notificationInfo: previous?.notificationInfo ?? 0,
      notificationWarning: previous?.notificationWarning ?? 0,
      notificationAlert: previous?.notificationAlert ?? 0,
      notificationTotal: previous?.notificationTotal ?? 0,
      notifications: previous?.notifications ?? const <UnraidNotification>[],
      diskItems: previous?.diskItems ?? const <UnraidInfoItem>[],
      networkItems: previous?.networkItems ?? const <UnraidInfoItem>[],
      upsItems: previous?.upsItems ?? const <UnraidInfoItem>[],
      pluginItems: previous?.pluginItems ?? const <UnraidInfoItem>[],
      securityItems: previous?.securityItems ?? const <UnraidInfoItem>[],
      cloudItems: previous?.cloudItems ?? const <UnraidInfoItem>[],
      logItems: previous?.logItems ?? const <UnraidInfoItem>[],
      servicesSummary:
          'Docker ${resolvedDocker.length} 个 / 虚拟机 ${resolvedVm.length} 个 / 共享 ${resolvedShare.length} 个',
      dockerNetworkSummary: previous?.dockerNetworkSummary ?? '',
      dockerConflictSummary: previous?.dockerConflictSummary ?? '',
      dockerItems: resolvedDocker,
      vmItems: resolvedVm,
      shareItems: resolvedShare,
    );

    // need* false means that segment was already fresh on a non-null cache.
    final previousTimestamps = cache;
    _dashboardSegmentCache = _DashboardSegmentCache(
      dashboard: dashboard,
      overviewFetchedAt: needOverview
          ? now
          : previousTimestamps!.overviewFetchedAt,
      dockerFetchedAt:
          needDocker ? now : previousTimestamps!.dockerFetchedAt,
      vmFetchedAt: needVm ? now : previousTimestamps!.vmFetchedAt,
      shareFetchedAt:
          needShare ? now : previousTimestamps!.shareFetchedAt,
    );
    return dashboard;
  }

  Future<void> shutdown() => _postBootCommand('shutdown');

  Future<void> reboot() => _postBootCommand('reboot');

  Future<void> runManagementAction({
    required ManagementItemType type,
    required String id,
    required ManagementAction action,
  }) async {
    switch (type) {
      case ManagementItemType.docker:
        await _runDockerAction(id: id, action: action);
      case ManagementItemType.vm:
        await _runVmAction(id: id, action: action);
      case ManagementItemType.share:
        throw const UnraidClientException('共享项目不支持该操作');
    }
  }

  Future<List<UnraidFileEntry>> fetchDirectory(
    String path, {
    bool forceRefresh = false,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持浏览 Unraid 文件系统');
    }

    final normalized = _normalizeUnraidPath(path);
    if (!forceRefresh) {
      final cached = _readDirectoryCache(normalized);
      if (cached != null) {
        return cached;
      }
      final inflight = _directoryInflight[normalized];
      if (inflight != null) {
        return inflight;
      }
    } else {
      // Concurrent pull-to-refresh on the same path still shares one SSH call.
      final inflight = _directoryInflight[normalized];
      if (inflight != null) {
        return inflight;
      }
    }

    final future = _loadDirectory(normalized);
    _directoryInflight[normalized] = future;
    try {
      return await future;
    } finally {
      if (identical(_directoryInflight[normalized], future)) {
        _directoryInflight.remove(normalized);
      }
    }
  }

  Future<List<UnraidFileEntry>> _loadDirectory(String normalized) async {
    final generation = (_directoryLoadGeneration[normalized] ?? 0) + 1;
    _directoryLoadGeneration[normalized] = generation;
    try {
      // Keep large find output as bytes so utf8 decode can run off-isolate.
      final outputBytes = await _runSshCommandBytes(
        '读取目录',
        _buildSshDirectoryListCommand(normalized),
        timeout: httpTimeout,
      );
      final entries =
          await parseSshDirectoryListingBytesAsync(outputBytes, normalized);
      // Only the newest generation may publish into the shared TTL cache.
      if (_directoryLoadGeneration[normalized] == generation) {
        _storeDirectoryCache(normalized, entries);
      }
      return entries;
    } on TimeoutException {
      throw const UnraidClientException('读取目录超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法读取目录：$error');
    }
  }

  Future<void> ensureDirectory(String path) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持创建 Unraid 目录');
    }

    final normalized = _normalizeUnraidPath(path);
    if (!_isWritableDirectoryPath(normalized)) {
      throw const UnraidClientException('目录必须位于 /mnt 或 /boot 下');
    }

    if (await _sshDirectoryExists(normalized)) {
      return;
    }

    final parts = normalized
        .split('/')
        .where((part) => part.trim().isNotEmpty)
        .toList(growable: false);
    if (parts.isEmpty) {
      return;
    }

    late String current;
    if (parts.first == 'boot') {
      current = '/boot';
    } else if (parts.first == 'mnt' && parts.length >= 3) {
      current = '/mnt/${parts[1]}/${parts[2]}';
    } else {
      throw const UnraidClientException('目标目录必须是 /mnt/<类型>/<共享> 或 /boot 下的路径');
    }

    if (!await _sshDirectoryExists(current)) {
      throw UnraidClientException('基础目录不存在：$current');
    }

    await _runSshCommand(
      '创建目录',
      'mkdir -p -- ${shellQuote(normalized)}',
      timeout: httpTimeout,
    );
    _invalidateDirectoryCache(normalized);
    _invalidateDirectoryCache(_parentPath(normalized));
  }

  Future<void> createDirectory({
    required String parentPath,
    required String name,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持创建 Unraid 目录');
    }

    final trimmedName = name.trim();
    if (!_isValidRemoteName(trimmedName)) {
      throw const UnraidClientException('文件夹名称无效');
    }
    final parent = _normalizeUnraidPath(parentPath);
    if (!_isWritableDirectoryPath(parent)) {
      throw const UnraidClientException('目录必须位于 /mnt 或 /boot 下');
    }
    final target = _joinPath(parent, trimmedName);
    await _runSshCommand(
      '创建目录',
      'mkdir -- ${shellQuote(target)}',
      timeout: httpTimeout,
    );
    _invalidateDirectoryCache(parent);
    _invalidateDirectoryCache(target);
  }

  Future<void> createFile({
    required String parentPath,
    required String name,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持创建 Unraid 文件');
    }

    final trimmedName = name.trim();
    if (!_isValidRemoteName(trimmedName)) {
      throw const UnraidClientException('文件名称无效');
    }
    final parent = _normalizeUnraidPath(parentPath);
    if (!_isWritableDirectoryPath(parent)) {
      throw const UnraidClientException('目录必须位于 /mnt 或 /boot 下');
    }
    final target = _joinPath(parent, trimmedName);
    await _runSshCommand(
      '创建文件',
      'if [ -e ${shellQuote(target)} ]; then '
          "printf '%s\\n' '目标已存在' >&2; exit 17; fi; "
          ': > ${shellQuote(target)}',
      timeout: httpTimeout,
    );
    _invalidateDirectoryCache(parent);
    _invalidateDirectoryCache(target);
  }

  Future<Uint8List> fetchFileBytes(
    String path, {
    bool forceRefresh = false,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持直接读取 Unraid 文件');
    }

    final normalized = _normalizeUnraidPath(path);
    if (!forceRefresh) {
      final cached = _readFileBytesCache(normalized);
      if (cached != null) {
        return cached;
      }
    } else {
      // Drop stale bytes so a force-refresh cannot re-serve the old TTL hit
      // after the new transfer finishes publishing.
      _fileBytesCache.remove(normalized);
    }
    // Soft and forced reads still share one in-flight transfer per path.
    final inflight = _fileBytesInflight[normalized];
    if (inflight != null) {
      return inflight;
    }

    final future = _loadFileBytes(normalized);
    _fileBytesInflight[normalized] = future;
    try {
      final bytes = await future;
      if (bytes.length <= _maxCachedFileBytes) {
        _storeFileBytesCache(normalized, bytes);
      }
      return bytes;
    } finally {
      if (identical(_fileBytesInflight[normalized], future)) {
        _fileBytesInflight.remove(normalized);
      }
    }
  }

  /// Range read for progressive audio/video streaming.
  ///
  /// [offset] is zero-based; [length] is the maximum number of bytes to return.
  /// The returned buffer may be shorter near EOF.
  Future<Uint8List> fetchFileRange(
    String path, {
    required int offset,
    required int length,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持直接读取 Unraid 文件');
    }
    if (offset < 0) {
      throw const UnraidClientException('无效的读取偏移');
    }
    if (length <= 0) {
      return Uint8List(0);
    }

    final normalized = _normalizeUnraidPath(path);
    // Small whole-file cache hits can satisfy range requests without network.
    final cached = _readFileBytesCache(normalized);
    if (cached != null) {
      if (offset >= cached.length) {
        return Uint8List(0);
      }
      final end = offset + length > cached.length
          ? cached.length
          : offset + length;
      return Uint8List.sublistView(cached, offset, end);
    }

    final rangeKey = '$normalized|$offset|$length';
    final inflight = _fileRangeInflight[rangeKey];
    if (inflight != null) {
      return inflight;
    }

    final future = _loadFileRange(
      normalized,
      offset: offset,
      length: length,
    );
    _fileRangeInflight[rangeKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_fileRangeInflight[rangeKey], future)) {
        _fileRangeInflight.remove(rangeKey);
      }
    }
  }

  Uint8List? _readFileBytesCache(String path) {
    final cached = _fileBytesCache[path];
    if (cached == null) {
      return null;
    }
    if (DateTime.now().difference(cached.fetchedAt) >= _fileBytesCacheTtl) {
      _fileBytesCache.remove(path);
      return null;
    }
    // LRU touch for hot thumbnails/previews.
    _fileBytesCache.remove(path);
    _fileBytesCache[path] = cached;
    return cached.bytes;
  }

  void _storeFileBytesCache(String path, Uint8List bytes) {
    _fileBytesCache.remove(path);
    if (_fileBytesCache.length >= _maxFileBytesCacheEntries) {
      _fileBytesCache.remove(_fileBytesCache.keys.first);
    }
    _fileBytesCache[path] = _FileBytesCacheEntry(
      bytes: bytes,
      fetchedAt: DateTime.now(),
    );
  }

  Future<Uint8List> _loadFileBytes(String normalized) async {
    final stopwatch = Stopwatch()..start();
    final smbPath = smbSharePathFromUnraidPath(normalized);
    if (defaultTargetPlatform == TargetPlatform.android &&
        smbPath != null &&
        !_androidSmbUnavailableShares.contains(smbPath.share)) {
      try {
        return await _fetchFileBytesViaAndroidSmb(
          normalizedPath: normalized,
          smbPath: smbPath,
          stopwatch: stopwatch,
        );
      } on Object catch (error, stackTrace) {
        _androidSmbUnavailableShares.add(smbPath.share);
        await AppLogger.log(
          'fetch_file_bytes_smb_fallback_to_sftp share=${smbPath.share} '
          'path=$normalized',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    try {
      final host = Uri.parse(baseUrl).host;
      final port = await _resolveSshPort();
      final sshUsername = username;
      final sshPassword = _password;
      await AppLogger.log('fetch_file_bytes_isolate_start path=$normalized');
      final bytes = await Isolate.run(
        () => _readRemoteFileViaSsh(
          host: host,
          port: port,
          username: sshUsername,
          password: sshPassword,
          path: normalized,
        ),
      ).timeout(fileTransferTimeout);
      await AppLogger.log(
        'fetch_file_bytes_isolate_success path=$normalized bytes=${bytes.length} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return bytes;
    } on TimeoutException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_timeout path=$normalized '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const UnraidClientException('加载文件超时');
    } on UnraidClientException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_client_error path=$normalized '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_error path=$normalized '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException('无法加载文件：$error');
    }
  }

  Future<Uint8List> _loadFileRange(
    String normalized, {
    required int offset,
    required int length,
  }) async {
    final stopwatch = Stopwatch()..start();
    final smbPath = smbSharePathFromUnraidPath(normalized);
    if (defaultTargetPlatform == TargetPlatform.android &&
        smbPath != null &&
        !_androidSmbUnavailableShares.contains(smbPath.share)) {
      try {
        return await _fetchFileRangeViaAndroidSmb(
          normalizedPath: normalized,
          smbPath: smbPath,
          offset: offset,
          length: length,
          stopwatch: stopwatch,
        );
      } on Object catch (error, stackTrace) {
        _androidSmbUnavailableShares.add(smbPath.share);
        await AppLogger.log(
          'fetch_file_range_smb_fallback_to_sftp share=${smbPath.share} '
          'path=$normalized offset=$offset',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    try {
      await AppLogger.log(
        'fetch_file_range_start path=$normalized offset=$offset length=$length',
      );
      final bytes = await _runSftpTransfer(() async {
        SftpFile? file;
        try {
          final sftp = await _ensureSftpClient();
          file = await sftp.open(
            normalized,
            mode: SftpFileOpenMode.read,
          );
          return await file.readBytes(offset: offset, length: length);
        } finally {
          await file?.close();
        }
      }).timeout(fileTransferTimeout);
      await AppLogger.log(
        'fetch_file_range_success path=$normalized bytes=${bytes.length} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return bytes;
    } on TimeoutException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_range_timeout path=$normalized offset=$offset '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const UnraidClientException('流式读取超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_range_error path=$normalized offset=$offset',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException('无法流式读取文件：$error');
    }
  }

  Future<Uint8List> _fetchFileBytesViaAndroidSmb({
    required String normalizedPath,
    required SmbSharePath smbPath,
    required Stopwatch stopwatch,
  }) async {
    try {
      await AppLogger.log(
        'fetch_file_bytes_smb_start path=$normalizedPath '
        'share=${smbPath.share}',
      );
      final bytes = await _remoteFileChannel.invokeMethod<Uint8List>(
        'readSmbFile',
        <String, Object?>{
          'host': Uri.parse(baseUrl).host,
          'username': username,
          'password': _password,
          'share': smbPath.share,
          'relativePath': smbPath.relativePath,
        },
      ).timeout(fileTransferTimeout);
      if (bytes == null) {
        throw const UnraidClientException('SMB 没有返回文件内容');
      }
      await AppLogger.log(
        'fetch_file_bytes_smb_success path=$normalizedPath '
        'bytes=${bytes.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return bytes;
    } on TimeoutException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_smb_timeout path=$normalizedPath '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const UnraidClientException('SMB 加载文件超时');
    } on PlatformException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_smb_error path=$normalizedPath '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException(
        'SMB 读取失败：${error.message ?? error.code}',
      );
    } on UnraidClientException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_smb_client_error path=$normalizedPath '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_bytes_smb_error path=$normalizedPath '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException('SMB 读取失败：$error');
    }
  }

  Future<Uint8List> _fetchFileRangeViaAndroidSmb({
    required String normalizedPath,
    required SmbSharePath smbPath,
    required int offset,
    required int length,
    required Stopwatch stopwatch,
  }) async {
    try {
      await AppLogger.log(
        'fetch_file_range_smb_start path=$normalizedPath '
        'share=${smbPath.share} offset=$offset length=$length',
      );
      final bytes = await _remoteFileChannel.invokeMethod<Uint8List>(
        'readSmbFileRange',
        <String, Object?>{
          'host': Uri.parse(baseUrl).host,
          'username': username,
          'password': _password,
          'share': smbPath.share,
          'relativePath': smbPath.relativePath,
          'offset': offset,
          'length': length,
        },
      ).timeout(fileTransferTimeout);
      if (bytes == null) {
        throw const UnraidClientException('SMB 没有返回文件内容');
      }
      await AppLogger.log(
        'fetch_file_range_smb_success path=$normalizedPath '
        'bytes=${bytes.length} elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return bytes;
    } on TimeoutException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_range_smb_timeout path=$normalizedPath '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      throw const UnraidClientException('SMB 流式读取超时');
    } on PlatformException catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_range_smb_error path=$normalizedPath',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException(
        'SMB 流式读取失败：${error.message ?? error.code}',
      );
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'fetch_file_range_smb_error path=$normalizedPath',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException('SMB 流式读取失败：$error');
    }
  }

  Future<void> uploadFile({
    required String targetPath,
    required int sizeBytes,
    required Future<Uint8List> Function(int offset, int length) readChunk,
    DateTime? modifiedDate,
    int chunkSize = 4 * 1024 * 1024,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持上传文件到 Unraid');
    }
    if (!_isWritableFilePath(targetPath)) {
      throw const UnraidClientException('目标路径必须位于 /mnt 或 /boot 下');
    }

    final normalized = _normalizeUnraidPath(targetPath);
    await ensureDirectory(_parentPath(normalized));
    try {
      await _runSftpTransfer(() async {
        SftpFile? file;
        var offset = 0;
        try {
          final sftp = await _ensureSftpClient();
          file = await sftp.open(
            normalized,
            mode: SftpFileOpenMode.create |
                SftpFileOpenMode.truncate |
                SftpFileOpenMode.write,
          );
          while (offset < sizeBytes || (sizeBytes == 0 && offset == 0)) {
            final remaining = sizeBytes - offset;
            final length = sizeBytes == 0
                ? 0
                : remaining < chunkSize
                    ? remaining
                    : chunkSize;
            final chunk =
                sizeBytes == 0 ? Uint8List(0) : await readChunk(offset, length);
            // Near EOF the provider may return a short final chunk; only treat
            // mid-file short reads as hard failures.
            if (chunk.length < length && offset + chunk.length < sizeBytes) {
              throw UnraidClientException(
                '读取本机媒体文件失败（offset=$offset want=$length got=${chunk.length}）',
              );
            }
            if (chunk.isNotEmpty) {
              await file.writeBytes(chunk, offset: offset);
            }
            offset += chunk.length;
            if (sizeBytes == 0 || chunk.isEmpty) {
              break;
            }
          }
        } finally {
          await file?.close();
        }
      }).timeout(fileTransferTimeout);
      if (modifiedDate != null && modifiedDate.millisecondsSinceEpoch > 0) {
        await _runSshCommand(
          '保留文件时间',
          buildSetModifiedTimeCommand(normalized, modifiedDate),
          timeout: httpTimeout,
        );
      }
      // Parent path invalidation also drops nested media-scan cache keys.
      _invalidateDirectoryCache(_parentPath(normalized));
    } on TimeoutException {
      throw const UnraidClientException('上传文件超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法上传文件：$error');
    }
  }

  /// Upload a local MediaStore item to Unraid over the shared SFTP session.
  ///
  /// Runs on the main isolate (not a background isolate) so the local-media
  /// MethodChannel stays available. Background-isolate uploads previously
  /// failed with channel/plugin "unavailable" errors after the audio-service
  /// activity change.
  Future<void> uploadLocalMediaFile({
    required String targetPath,
    required String sourceUri,
    required int sizeBytes,
    DateTime? modifiedDate,
    int chunkSize = 1024 * 1024,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持上传文件到 Unraid');
    }
    if (sourceUri.trim().isEmpty) {
      throw const UnraidClientException('本机媒体 URI 为空，无法上传');
    }
    if (sizeBytes < 0) {
      throw const UnraidClientException('本机媒体大小无效');
    }

    await AppLogger.log(
      'album_upload_start path=$targetPath sizeBytes=$sizeBytes '
      'uri=$sourceUri',
    );
    try {
      await uploadFile(
        targetPath: targetPath,
        sizeBytes: sizeBytes,
        modifiedDate: modifiedDate,
        chunkSize: chunkSize,
        readChunk: (offset, length) async {
          final bytes = await _readLocalMediaChunk(
            uri: sourceUri,
            offset: offset,
            length: length,
          );
          if (bytes.length < length && offset + bytes.length < sizeBytes) {
            throw UnraidClientException(
              '读取本机媒体不完整（offset=$offset want=$length got=${bytes.length}）',
            );
          }
          return bytes;
        },
      );
      await AppLogger.log('album_upload_success path=$targetPath');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'album_upload_error path=$targetPath',
        error: error,
        stackTrace: stackTrace,
      );
      throw UnraidClientException('无法上传文件：$error');
    }
  }

  Future<Uint8List> _readLocalMediaChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    try {
      final bytes = await _localMediaChannel.invokeMethod<Uint8List>(
        'readChunk',
        <String, Object?>{
          'uri': uri,
          'offset': offset,
          'length': length,
        },
      );
      return bytes ?? Uint8List(0);
    } on MissingPluginException {
      throw const UnraidClientException(
        '本机媒体通道不可用，请确认在 Android 真机/模拟器上运行',
      );
    } on PlatformException catch (error) {
      throw UnraidClientException(
        '读取本机媒体失败：${error.message ?? error.code}',
      );
    }
  }

  Future<void> movePath({
    required String sourcePath,
    required String targetPath,
  }) async {
    final source = _normalizeUnraidPath(sourcePath);
    final target = _normalizeUnraidPath(targetPath);
    if (!_isWritableDirectoryPath(source) || !_isWritableFilePath(target)) {
      throw const UnraidClientException('移动路径必须位于 /mnt 或 /boot 下');
    }
    _throwIfUnsafeDestructivePath(source, '源路径');
    await _runSshCommand(
      '移动文件',
      'mv -- ${shellQuote(source)} ${shellQuote(target)}',
      timeout: const Duration(minutes: 2),
    );
    _invalidateDirectoryCache(source);
    _invalidateDirectoryCache(_parentPath(source));
    _invalidateDirectoryCache(target);
    _invalidateDirectoryCache(_parentPath(target));
  }

  Future<void> renamePath({
    required String path,
    required String newName,
  }) async {
    final trimmedName = newName.trim();
    if (!_isValidRemoteName(trimmedName)) {
      throw const UnraidClientException('新名称无效');
    }
    final source = _normalizeUnraidPath(path);
    final target = _joinPath(_parentPath(source), trimmedName);
    if (source == target) {
      return;
    }
    if (!_isWritableDirectoryPath(source) || !_isWritableFilePath(target)) {
      throw const UnraidClientException('重命名路径必须位于 /mnt 或 /boot 下');
    }
    _throwIfUnsafeDestructivePath(source, '源路径');
    await _runSshCommand(
      '重命名文件',
      'if [ -e ${shellQuote(target)} ]; then '
          "printf '%s\\n' '目标已存在' >&2; exit 17; fi; "
          'mv -- ${shellQuote(source)} ${shellQuote(target)}',
      timeout: const Duration(minutes: 2),
    );
    _invalidateDirectoryCache(source);
    _invalidateDirectoryCache(_parentPath(source));
    _invalidateDirectoryCache(target);
  }

  Future<void> deletePath(String path) async {
    final normalized = _normalizeUnraidPath(path);
    if (!_isWritableDirectoryPath(normalized)) {
      throw const UnraidClientException('删除路径必须位于 /mnt 或 /boot 下');
    }
    _throwIfUnsafeDestructivePath(normalized, '删除路径');
    await _runSshCommand(
      '删除文件',
      'if [ -d ${shellQuote(normalized)} ]; then '
          'rm -rf -- ${shellQuote(normalized)}; else '
          'rm -f -- ${shellQuote(normalized)}; fi',
      timeout: const Duration(minutes: 2),
    );
    _invalidateDirectoryCache(normalized);
    _invalidateDirectoryCache(_parentPath(normalized));
  }

  void _storeDirectoryCache(String path, List<UnraidFileEntry> entries) {
    // Touch existing keys so repeated opens stay hot under FIFO eviction.
    _directoryCache.remove(path);
    if (_directoryCache.length >= _maxDirectoryCacheEntries) {
      _directoryCache.remove(_directoryCache.keys.first);
    }
    _directoryCache[path] = _DirectoryCacheEntry(
      entries: List<UnraidFileEntry>.unmodifiable(entries),
      fetchedAt: DateTime.now(),
    );
  }

  List<UnraidFileEntry>? _readDirectoryCache(String path) {
    final cached = _directoryCache[path];
    if (cached == null) {
      return null;
    }
    if (DateTime.now().difference(cached.fetchedAt) >= _directoryCacheTtl) {
      _directoryCache.remove(path);
      return null;
    }
    // LRU touch: reinsert so frequently browsed folders outlive cold ones.
    _directoryCache.remove(path);
    _directoryCache[path] = cached;
    return cached.entries;
  }

  void _invalidateDirectoryCache(String path) {
    final normalized = _normalizeUnraidPath(path);
    _directoryCache.remove(normalized);
    _directoryInflight.remove(normalized);
    _directoryLoadGeneration.remove(normalized);
    // Drop nested cache keys under this path so tree mutations stay consistent.
    final prefix = normalized == '/' ? '/' : '$normalized/';
    _directoryCache.removeWhere(
      (key, _) => key == normalized || key.startsWith(prefix),
    );
    _directoryInflight.removeWhere(
      (key, _) => key == normalized || key.startsWith(prefix),
    );
    _directoryLoadGeneration.removeWhere(
      (key, _) => key == normalized || key.startsWith(prefix),
    );
    // Media scan keys look like "/mnt/user/photos|6|img=...". Drop any scan
    // whose root path is this path or a descendant.
    bool mediaKeyAffected(String key) {
      final root = key.split('|').first;
      return root == normalized || root.startsWith(prefix);
    }

    _mediaScanCache.removeWhere((key, _) => mediaKeyAffected(key));
    _mediaScanInflight.removeWhere((key, _) => mediaKeyAffected(key));
    _mediaScanLoadGeneration.removeWhere((key, _) => mediaKeyAffected(key));
    _fileBytesCache.removeWhere(
      (key, _) => key == normalized || key.startsWith(prefix),
    );
    _fileBytesInflight.removeWhere(
      (key, _) => key == normalized || key.startsWith(prefix),
    );
  }

  @visibleForTesting
  void clearMediaScanCacheForTest() {
    _mediaScanCache.clear();
    _mediaScanInflight.clear();
    _mediaScanLoadGeneration.clear();
  }

  Future<List<UnraidFileEntry>> fetchMediaFiles(
    String path, {
    int maxDepth = 6,
    bool includeImages = true,
    bool includeVideos = true,
    bool includeAudio = false,
    bool forceRefresh = false,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持浏览 Unraid 文件系统');
    }

    final normalized = _normalizeUnraidPath(path);
    final depth = maxDepth < 0 ? 0 : maxDepth;
    final cacheKey =
        '$normalized|$depth|img=$includeImages|vid=$includeVideos|aud=$includeAudio';

    if (!forceRefresh) {
      final cached = _readMediaScanCache(cacheKey);
      if (cached != null) {
        return cached;
      }
      final inflight = _mediaScanInflight[cacheKey];
      if (inflight != null) {
        return inflight;
      }
    } else {
      final inflight = _mediaScanInflight[cacheKey];
      if (inflight != null) {
        return inflight;
      }
    }

    final future = _scanMediaFiles(
      cacheKey: cacheKey,
      normalized: normalized,
      depth: depth,
      includeImages: includeImages,
      includeVideos: includeVideos,
      includeAudio: includeAudio,
    );
    _mediaScanInflight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_mediaScanInflight[cacheKey], future)) {
        _mediaScanInflight.remove(cacheKey);
      }
    }
  }

  List<UnraidFileEntry>? _readMediaScanCache(String cacheKey) {
    final cached = _mediaScanCache[cacheKey];
    if (cached == null) {
      return null;
    }
    if (DateTime.now().difference(cached.fetchedAt) >= _mediaScanCacheTtl) {
      _mediaScanCache.remove(cacheKey);
      return null;
    }
    // LRU touch so album/music reopen keeps the hot scan.
    _mediaScanCache.remove(cacheKey);
    _mediaScanCache[cacheKey] = cached;
    return cached.entries;
  }

  void _storeMediaScanCache(String cacheKey, List<UnraidFileEntry> results) {
    _mediaScanCache.remove(cacheKey);
    if (_mediaScanCache.length >= _maxMediaScanCacheEntries) {
      _mediaScanCache.remove(_mediaScanCache.keys.first);
    }
    _mediaScanCache[cacheKey] = _DirectoryCacheEntry(
      entries: List<UnraidFileEntry>.unmodifiable(results),
      fetchedAt: DateTime.now(),
    );
  }

  Future<List<UnraidFileEntry>> _scanMediaFiles({
    required String cacheKey,
    required String normalized,
    required int depth,
    required bool includeImages,
    required bool includeVideos,
    required bool includeAudio,
  }) async {
    final generation = (_mediaScanLoadGeneration[cacheKey] ?? 0) + 1;
    _mediaScanLoadGeneration[cacheKey] = generation;
    try {
      // Single remote find avoids N recursive directory round-trips.
      // Decode + parse large media scans off the UI isolate together.
      final outputBytes = await _runSshCommandBytes(
        '扫描媒体文件',
        _buildSshMediaScanCommand(normalized, maxDepth: depth),
        timeout: fileTransferTimeout,
      );
      final results = await parseSshDirectoryListingBytesAsync(
        outputBytes,
        normalized,
        mediaOnly: true,
        includeImages: includeImages,
        includeVideos: includeVideos,
        includeAudio: includeAudio,
      );
      if (_mediaScanLoadGeneration[cacheKey] == generation) {
        _storeMediaScanCache(cacheKey, results);
      }
      return results;
    } on TimeoutException {
      throw const UnraidClientException('扫描媒体文件超时');
    } on UnraidClientException catch (error) {
      // Missing or unreadable roots are common for first-time backup targets.
      final message = error.message.toLowerCase();
      if (message.contains('no such file') ||
          message.contains('not a directory') ||
          message.contains('permission denied')) {
        return const <UnraidFileEntry>[];
      }
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法扫描媒体文件：$error');
    }
  }

  Future<List<UnraidFileEntry>> fetchAudioFiles(
    String path, {
    int maxDepth = 8,
  }) {
    return fetchMediaFiles(
      path,
      maxDepth: maxDepth,
      includeImages: false,
      includeVideos: false,
      includeAudio: true,
    );
  }

  /// Absolute URL that can stream/download a file through the WebGUI session.
  Uri fileStreamUri(String path) => _fileUri(path);

  Map<String, String> get sessionHeaders {
    return <String, String>{
      'Accept': '*/*',
      'Referer': '$baseUrl/',
      'User-Agent': 'unraider-webgui',
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
      if (_csrfToken != null) 'X-CSRF-Token': _csrfToken!,
    };
  }

  /// Maps an Unraid filesystem path onto the WebGUI base URL path segments.
  Uri _fileUri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse(baseUrl).replace(
      pathSegments: normalized.split('/').where((part) => part.isNotEmpty),
    );
  }

  void close() {
    _directoryCache.clear();
    _directoryInflight.clear();
    _directoryLoadGeneration.clear();
    _mediaScanCache.clear();
    _mediaScanInflight.clear();
    _mediaScanLoadGeneration.clear();
    _fileBytesCache.clear();
    _fileBytesInflight.clear();
    _fileRangeInflight.clear();
    _androidSmbUnavailableShares.clear();
    _cookies.clear();
    _cookieHeaderCache = null;
    _dashboardSegmentCache = null;
    _dashboardInflight = null;
    _dashboardInflightForced = false;
    _csrfTokenFuture = null;
    _sshConnectFuture = null;
    _sftpConnectFuture = null;
    _sftpClient?.close();
    _sshClient?.close();
    _httpClient.close();
  }

  Future<SSHClient> _ensureSshClient() async {
    final existing = _sshClient;
    if (existing != null && !existing.isClosed) {
      return existing;
    }

    // Coalesce concurrent warmSsh / fetchDirectory / upload handshakes.
    final inflight = _sshConnectFuture;
    if (inflight != null) {
      return inflight;
    }

    final future = _connectSshClient();
    _sshConnectFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_sshConnectFuture, future)) {
        _sshConnectFuture = null;
      }
    }
  }

  Future<SSHClient> _connectSshClient() async {
    final host = Uri.parse(baseUrl).host;
    final port = await _resolveSshPort();
    try {
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: probeTimeout,
      );
      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => _password,
        ident: 'unraider',
        keepAliveInterval: sshKeepAliveInterval,
      );
      await client.authenticated.timeout(httpTimeout);
      _sshClient = client;
      _sftpClient = null;
      _sftpConnectFuture = null;
      return client;
    } on TimeoutException {
      throw UnraidClientException('SSH 连接超时：$host:$port');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法连接 SSH：$error');
    }
  }

  Future<SftpClient> _ensureSftpClient() async {
    final ssh = await _ensureSshClient();
    final existing = _sftpClient;
    if (existing != null && !ssh.isClosed) {
      return existing;
    }

    final inflight = _sftpConnectFuture;
    if (inflight != null) {
      return inflight;
    }

    final future = _connectSftpClient(ssh);
    _sftpConnectFuture = future;
    try {
      return await future;
    } finally {
      if (identical(_sftpConnectFuture, future)) {
        _sftpConnectFuture = null;
      }
    }
  }

  Future<SftpClient> _connectSftpClient(SSHClient ssh) async {
    try {
      final sftp = await ssh.sftp().timeout(httpTimeout);
      await sftp.handshake.timeout(httpTimeout);
      _sftpClient = sftp;
      return sftp;
    } on TimeoutException {
      throw const UnraidClientException('SFTP 连接超时');
    } on Object catch (error) {
      throw UnraidClientException('无法连接 SFTP：$error');
    }
  }

  Future<T> _runSftpTransfer<T>(Future<T> Function() action) async {
    final previous = _sftpTransferQueue;
    final done = Completer<void>();
    _sftpTransferQueue = done.future;
    try {
      await previous.catchError((Object _) {});
      return await action();
    } finally {
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  Future<int> _resolveSshPort() {
    return _sshPortFuture ??= _loadSshPort();
  }

  Future<int> _loadSshPort() async {
    final config = await _fetchSshConfig();
    if (config != null) {
      if (config.useSsh == false) {
        throw const UnraidClientException('Unraid SSH 服务未启用');
      }
      final port = config.port;
      if (port != null && port > 0 && port <= 65535) {
        return port;
      }
    }
    return 22;
  }

  Future<_SshServiceConfig?> _fetchSshConfig() async {
    try {
      return await _fetchSshConfigFromGraphql() ??
          await _fetchSshConfigFromSettingsPage();
    } on UnraidClientException {
      rethrow;
    } on Object {
      return null;
    }
  }

  Future<_SshServiceConfig?> _fetchSshConfigFromGraphql() async {
    await _ensureCsrfToken();
    const query = '''
query UnraiderSshConfig {
  config {
    vars {
      useSsh
      portssh
    }
  }
}
''';
    for (final path in const <String>['/graphql', '/api/graphql']) {
      try {
        final response = await _sendJsonPost(
          _uri(path),
          <String, Object?>{'query': query},
          timeout: probeTimeout,
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final payload = jsonDecode(_responseBody(response));
        final vars = _findNestedMap(payload, const <String>[
          'data',
          'config',
          'vars',
        ]);
        if (vars == null) {
          continue;
        }
        return _SshServiceConfig(
          useSsh: _parseBoolish(vars['useSsh']),
          port: _parsePort(vars['portssh']),
        );
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<_SshServiceConfig?> _fetchSshConfigFromSettingsPage() async {
    for (final path in const <String>[
      '/Settings/ManagementAccess',
      '/Settings/ManagementAccess.php',
      '/Settings',
    ]) {
      try {
        final response =
            await _send('GET', path).timeout(probeTimeout);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final html = _responseBody(response);
        final port = _parsePort(_htmlInputValue(html, 'portssh'));
        final useSsh = _parseSettingsBool(html, 'useSsh');
        if (port != null || useSsh != null) {
          return _SshServiceConfig(useSsh: useSsh, port: port);
        }
      } on Object {
        continue;
      }
    }
    return null;
  }

  Future<String> _runSshCommand(
    String action,
    String command, {
    Duration timeout = httpTimeout,
  }) async {
    final bytes = await _runSshCommandBytes(
      action,
      command,
      timeout: timeout,
    );
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// Raw stdout for callers that want to decode/parse off the UI isolate.
  Future<Uint8List> _runSshCommandBytes(
    String action,
    String command, {
    Duration timeout = httpTimeout,
  }) {
    // Serialize interactive SSH execs so concurrent directory/media scans do
    // not interleave on one session.
    return _runSshSerialized(() async {
      final client = await _ensureSshClient();
      try {
        final result = await client
            .runWithResult(command, stdout: true, stderr: true)
            .timeout(timeout);
        if (result.exitCode != 0) {
          final error = utf8
              .decode(
                result.stderr.isNotEmpty ? result.stderr : result.stdout,
                allowMalformed: true,
              )
              .trim();
          throw UnraidClientException(
            error.isEmpty
                ? '$action失败：退出码 ${result.exitCode}'
                : '$action失败：$error',
          );
        }
        return Uint8List.fromList(result.stdout);
      } on TimeoutException {
        throw UnraidClientException('$action超时');
      } on UnraidClientException {
        rethrow;
      } on Object catch (error) {
        throw UnraidClientException('$action失败：$error');
      }
    });
  }

  Future<T> _runSshSerialized<T>(Future<T> Function() action) async {
    final previous = _sshCommandQueue;
    final done = Completer<void>();
    _sshCommandQueue = done.future;
    try {
      await previous.catchError((Object _) {});
      return await action();
    } finally {
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  Future<bool> _sshDirectoryExists(String path) {
    return _runSshSerialized(() async {
      try {
        final client = await _ensureSshClient();
        final result = await client
            .runWithResult('test -d ${shellQuote(_normalizeUnraidPath(path))}')
            .timeout(probeTimeout);
        return result.exitCode == 0;
      } on Object {
        return false;
      }
    });
  }

  Future<void> _login() async {
    if (username != 'root') {
      throw const UnraidClientException('Unraid WebGUI 只支持 root 用户登录');
    }

    final response = await _send(
      'POST',
      '/login',
      fields: <String, String>{
        'username': username,
        'password': _password,
      },
      includeCsrf: false,
      allowLoginRedirect: true,
    );

    final redirectedToLogin =
        response.request?.url.path.toLowerCase().contains('/login') ?? false;
    if (redirectedToLogin && response.statusCode == 200) {
      throw const UnraidClientException('用户名或密码无效');
    }
  }

  Future<void> _checkAuth() async {
    final response = await _send('GET', '/auth-request.php');
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const UnraidClientException('WebGUI 会话验证失败');
    }
  }

  Future<void> _ensureCsrfToken() async {
    if (_csrfToken != null) {
      return;
    }
    // Coalesce concurrent first-token fetches (login + warmSsh + dashboard).
    final inflight = _csrfTokenFuture;
    if (inflight != null) {
      return inflight;
    }
    final future = _loadCsrfToken();
    _csrfTokenFuture = future;
    try {
      await future;
    } finally {
      if (identical(_csrfTokenFuture, future)) {
        _csrfTokenFuture = null;
      }
    }
  }

  Future<void> _loadCsrfToken() async {
    final response = await _send('GET', '/Main');
    final html = _responseBody(response);
    _extractCsrf(html);
    if (_csrfToken == null) {
      throw const UnraidClientException('无法从 Unraid WebGUI 获取 csrf_token');
    }
  }

  Future<void> _postBootCommand(String command) async {
    await _ensureCsrfToken();
    final response = await _send(
      'POST',
      '/webGui/include/Boot.php',
      fields: <String, String>{'cmd': command},
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('电源命令失败：HTTP ${response.statusCode}');
    }
  }

  Future<void> _runDockerAction({
    required String id,
    required ManagementAction action,
  }) async {
    await _ensureCsrfToken();
    final response = await _send(
      'POST',
      '/plugins/dynamix.docker.manager/include/Events.php',
      fields: <String, String>{
        'action': _dockerAction(action),
        'container': id,
      },
    );
    _throwForJsonFailure(response, 'Docker 操作失败');
    // Expire docker list segment so the next dashboard pull is fresh.
    final cache = _dashboardSegmentCache;
    if (cache != null) {
      _dashboardSegmentCache = _DashboardSegmentCache(
        dashboard: cache.dashboard,
        overviewFetchedAt: cache.overviewFetchedAt,
        dockerFetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
        vmFetchedAt: cache.vmFetchedAt,
        shareFetchedAt: cache.shareFetchedAt,
      );
    }
  }

  Future<void> _runVmAction({
    required String id,
    required ManagementAction action,
  }) async {
    await _ensureCsrfToken();
    final response = await _send(
      'POST',
      '/plugins/dynamix.vm.manager/include/VMajax.php',
      fields: <String, String>{
        'action': _vmAction(action),
        'uuid': id,
      },
    );
    _throwForJsonFailure(response, '虚拟机操作失败');
    final cache = _dashboardSegmentCache;
    if (cache != null) {
      _dashboardSegmentCache = _DashboardSegmentCache(
        dashboard: cache.dashboard,
        overviewFetchedAt: cache.overviewFetchedAt,
        dockerFetchedAt: cache.dockerFetchedAt,
        vmFetchedAt: DateTime.fromMillisecondsSinceEpoch(0),
        shareFetchedAt: cache.shareFetchedAt,
      );
    }
  }

  Future<List<UnraidManagementItem>> _fetchDockerItems() async {
    try {
      final response = await _send(
        'GET',
        '/plugins/dynamix.docker.manager/include/DockerContainers.php',
      );
      return _parseDockerItemsAsync(_responseBody(response));
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('读取 Docker 列表失败：$error');
    }
  }

  Future<List<UnraidManagementItem>> _fetchVmItems() async {
    try {
      final uri = _uri('/plugins/dynamix.vm.manager/include/VMMachines.php')
          .replace(queryParameters: <String, String>{'show': ''});
      final response = await _sendUri('GET', uri);
      return _parseVmItemsAsync(_responseBody(response));
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('读取虚拟机列表失败：$error');
    }
  }

  Future<List<UnraidManagementItem>> _fetchShareItems() async {
    try {
      final entries = await fetchDirectory('/mnt/user');
      final shares = <UnraidManagementItem>[];
      for (final entry in entries) {
        if (!entry.isDirectory) {
          continue;
        }
        shares.add(
          UnraidManagementItem(
            id: entry.path,
            title: entry.name,
            status: '可浏览',
            description: entry.path,
            type: ManagementItemType.share,
            detail: entry.path,
            tags: const <String>['共享'],
          ),
        );
      }
      return shares;
    } on UnraidClientException {
      rethrow;
    } on Object {
      return const <UnraidManagementItem>[];
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String>? fields,
    bool includeCsrf = true,
    bool allowLoginRedirect = false,
    Duration timeout = httpTimeout,
  }) {
    return _sendUri(
      method,
      _uri(path),
      fields: fields,
      includeCsrf: includeCsrf,
      allowLoginRedirect: allowLoginRedirect,
      timeout: timeout,
    );
  }

  Future<http.Response> _sendUri(
    String method,
    Uri uri, {
    Map<String, String>? fields,
    bool includeCsrf = true,
    bool allowLoginRedirect = false,
    int redirectCount = 0,
    Duration timeout = httpTimeout,
  }) async {
    if (redirectCount > 5) {
      throw const UnraidClientException('服务器重定向次数过多');
    }

    final request = http.Request(method, uri);
    request.followRedirects = false;
    request.headers.addAll(<String, String>{
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Referer': '$baseUrl/',
      'User-Agent': 'unraider-webgui',
      'X-Requested-With': 'XMLHttpRequest',
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
    });

    if (fields != null) {
      final formFields = Map<String, String>.from(fields);
      if (includeCsrf) {
        final csrf = _csrfToken;
        if (csrf == null) {
          throw const UnraidClientException('缺少 csrf_token');
        }
        formFields['csrf_token'] = csrf;
        request.headers['X-CSRF-Token'] = csrf;
      }
      request.headers['Content-Type'] = 'application/x-www-form-urlencoded';
      request.bodyFields = formFields;
    } else if (method == 'POST' && includeCsrf) {
      final csrf = _csrfToken;
      if (csrf == null) {
        throw const UnraidClientException('缺少 csrf_token');
      }
      request.headers['X-CSRF-Token'] = csrf;
      request.bodyFields = <String, String>{'csrf_token': csrf};
    }

    try {
      final streamed = await _httpClient.send(request).timeout(timeout);
      final response = await http.Response.fromStream(streamed).timeout(timeout);
      _storeCookies(response);

      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location == null || location.isEmpty) {
          return response;
        }
        final nextUri = uri.resolve(location);
        if (!allowLoginRedirect && _isLoginPath(nextUri.path)) {
          throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
        }
        return _sendUri(
          'GET',
          nextUri,
          includeCsrf: false,
          allowLoginRedirect: allowLoginRedirect,
          redirectCount: redirectCount + 1,
          timeout: timeout,
        );
      }

      // Decode once per response; callers reuse via [_responseBody].
      final body = _responseBody(response);
      _extractCsrf(body);

      if (!allowLoginRedirect && _looksLikeLoginPage(body)) {
        throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
      }

      if (response.statusCode == 401 || response.statusCode == 403) {
        throw UnraidClientException(
          'WebGUI 拒绝访问：HTTP ${response.statusCode}',
        );
      }
      return response;
    } on TimeoutException {
      throw const UnraidClientException('请求超时，请检查服务器地址和网络');
    }
  }

  Future<http.Response> _sendJsonPost(
    Uri uri,
    Map<String, Object?> payload, {
    Duration timeout = httpTimeout,
  }) async {
    final request = http.Request('POST', uri);
    request.followRedirects = false;
    final csrf = _csrfToken;
    request.headers.addAll(<String, String>{
      'Accept': 'application/json',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Content-Type': 'application/json',
      'Referer': '$baseUrl/',
      'User-Agent': 'unraider-webgui',
      if (csrf != null) 'X-CSRF-Token': csrf,
      'X-Requested-With': 'XMLHttpRequest',
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
    });
    request.body = jsonEncode(payload);
    try {
      final streamed = await _httpClient.send(request).timeout(timeout);
      final response =
          await http.Response.fromStream(streamed).timeout(timeout);
      _storeCookies(response);
      if (_isRedirect(response.statusCode)) {
        final location = response.headers['location'];
        if (location != null && _isLoginPath(uri.resolve(location).path)) {
          throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
        }
      }
      final body = _responseBody(response);
      _extractCsrf(body);
      if (!_isRedirect(response.statusCode) && _looksLikeLoginPage(body)) {
        throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        throw UnraidClientException(
          'WebGUI 拒绝访问：HTTP ${response.statusCode}',
        );
      }
      return response;
    } on TimeoutException {
      throw const UnraidClientException('请求超时，请检查服务器地址和网络');
    }
  }

  Uri _uri(String path) => Uri.parse(baseUrl).resolve(path);

  String get _cookieHeader {
    final cached = _cookieHeaderCache;
    if (cached != null) {
      return cached;
    }
    final header = _cookies.entries
        .map((entry) => '${entry.key}=${entry.value}')
        .join('; ');
    _cookieHeaderCache = header;
    return header;
  }

  /// Process-local decoded body cache so CSRF checks and payload parsers share
  /// one utf8 decode per [http.Response] instance.
  static final Expando<String> _decodedResponseBodies = Expando<String>();

  String _responseBody(http.Response response) {
    final cached = _decodedResponseBodies[response];
    if (cached != null) {
      return cached;
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    _decodedResponseBodies[response] = body;
    return body;
  }

  void _storeCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) {
      return;
    }

    var changed = false;
    for (final rawCookie in _splitSetCookie(setCookie)) {
      final pair = rawCookie.split(';').first;
      final separator = pair.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (value.isEmpty || value.toLowerCase() == 'deleted') {
        if (_cookies.remove(name) != null) {
          changed = true;
        }
      } else if (_cookies[name] != value) {
        _cookies[name] = value;
        changed = true;
      }
    }
    if (changed) {
      _cookieHeaderCache = null;
    }
  }

  static final _csrfTokenAssignRegex =
      RegExp(r'''csrf_token\s*=\s*["']([^"']+)["']''');
  static final _csrfTokenInputRegex =
      RegExp(r'''name=["']csrf_token["'][^>]*value=["']([^"']+)["']''');

  void _extractCsrf(String html) {
    // Reuse compiled patterns — CSRF is checked on nearly every WebGUI response.
    final token = _firstMatch(html, _csrfTokenAssignRegex) ??
        _firstMatch(html, _csrfTokenInputRegex);
    if (token != null && token.isNotEmpty) {
      _csrfToken = token;
    }
  }

  void _throwForJsonFailure(http.Response response, String prefix) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('$prefix：HTTP ${response.statusCode}');
    }

    final body = _responseBody(response).trim();
    if (body.isEmpty) {
      return;
    }

    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) {
        final error = json['error'];
        if (error != null && error.toString().trim().isNotEmpty) {
          throw UnraidClientException('$prefix：$error');
        }
        final success = json['success'];
        if (success == true || success == 'true' || success == null) {
          return;
        }
        throw UnraidClientException('$prefix：$success');
      }
    } on FormatException {
      return;
    }
  }
}
