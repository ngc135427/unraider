import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'app_logger.dart';

class UnraidClientException implements Exception {
  const UnraidClientException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef UnraidClient = UnraidWebGuiClient;

const _remoteFileChannel = MethodChannel('unraider/remote_file');

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

  final String baseUrl;
  final String username;
  final String _password;
  final http.Client _httpClient;
  final Map<String, String> _cookies = <String, String>{};
  String? _csrfToken;
  SSHClient? _sshClient;
  SftpClient? _sftpClient;
  Future<int>? _sshPortFuture;
  Future<void> _sftpTransferQueue = Future<void>.value();

  Future<void> checkConnection() async {
    await _login();
    await _ensureCsrfToken();
    await _checkAuth();
  }

  Future<UnraidDashboard> fetchDashboard() async {
    await _ensureCsrfToken();
    final dashboard = await _send('GET', '/Dashboard');
    final dashboardHtml = utf8.decode(
      dashboard.bodyBytes,
      allowMalformed: true,
    );
    _extractCsrf(dashboardHtml);

    final dockerItems = await _fetchDockerItems();
    final vmItems = await _fetchVmItems();
    final shareItems = await _fetchShareItems();
    final dashboardSnapshot = _parseDashboardSnapshot(dashboardHtml);

    return UnraidDashboard(
      serverName: _serverNameFromHtml(dashboardHtml),
      serverDescription: 'Unraid WebGUI',
      guid: '',
      ownerName: '',
      registration: '',
      model: '',
      version: _firstMatch(
            dashboardHtml,
            RegExp(r'Unraid(?: OS)?\s+([0-9][^<\s"]*)', caseSensitive: false),
          ) ??
          'WebGUI',
      status: '已连接',
      lanIp: Uri.parse(baseUrl).host,
      wanIp: '',
      localUrl: baseUrl,
      remoteUrl: '',
      uptime: '',
      cpuSummary: dashboardSnapshot.cpuSummary,
      cpuPercent: 0,
      baseboardSummary: '',
      osSummary: '',
      packagesSummary: '',
      memoryUsage: dashboardSnapshot.memoryUsage,
      memoryPercent: 0,
      arrayState: dashboardSnapshot.arrayState,
      arrayUsage: dashboardSnapshot.arrayUsage,
      arrayPercent: dashboardSnapshot.arrayPercent,
      paritySummary: '暂无校验任务',
      notificationInfo: 0,
      notificationWarning: 0,
      notificationAlert: 0,
      notificationTotal: 0,
      notifications: const <UnraidNotification>[],
      diskItems: const <UnraidInfoItem>[],
      networkItems: const <UnraidInfoItem>[],
      upsItems: const <UnraidInfoItem>[],
      pluginItems: const <UnraidInfoItem>[],
      securityItems: const <UnraidInfoItem>[],
      cloudItems: const <UnraidInfoItem>[],
      logItems: const <UnraidInfoItem>[],
      servicesSummary:
          'Docker ${dockerItems.length} 个 / 虚拟机 ${vmItems.length} 个 / 共享 ${shareItems.length} 个',
      dockerNetworkSummary: '',
      dockerConflictSummary: '',
      dockerItems: dockerItems,
      vmItems: vmItems,
      shareItems: shareItems,
    );
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

  Future<List<UnraidFileEntry>> fetchDirectory(String path) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持浏览 Unraid 文件系统');
    }

    final normalized = _normalizeUnraidPath(path);
    try {
      final output = await _runSshCommand(
        '读取目录',
        _buildSshDirectoryListCommand(normalized),
        timeout: const Duration(seconds: 20),
      );
      return parseSshDirectoryListing(output, normalized);
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
      timeout: const Duration(seconds: 30),
    );
  }

  Future<Uint8List> fetchFileBytes(String path) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持直接读取 Unraid 文件');
    }

    final normalized = _normalizeUnraidPath(path);
    final stopwatch = Stopwatch()..start();
    final smbPath = smbSharePathFromUnraidPath(normalized);
    if (defaultTargetPlatform == TargetPlatform.android && smbPath != null) {
      return _fetchFileBytesViaAndroidSmb(
        normalizedPath: normalized,
        smbPath: smbPath,
        stopwatch: stopwatch,
      );
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
      ).timeout(const Duration(seconds: 45));
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
      ).timeout(const Duration(seconds: 45));
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
            if (chunk.length < length) {
              throw const UnraidClientException('读取本机媒体文件失败');
            }
            if (chunk.isNotEmpty) {
              await file.writeBytes(chunk, offset: offset);
            }
            offset += chunk.length;
            if (sizeBytes == 0) {
              break;
            }
          }
        } finally {
          await file?.close();
        }
      });
      if (modifiedDate != null && modifiedDate.millisecondsSinceEpoch > 0) {
        await _runSshCommand(
          '保留文件时间',
          buildSetModifiedTimeCommand(normalized, modifiedDate),
          timeout: const Duration(seconds: 20),
        );
      }
    } on TimeoutException {
      throw const UnraidClientException('上传文件超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法上传文件：$error');
    }
  }

  Future<void> uploadLocalMediaFile({
    required String targetPath,
    required String sourceUri,
    required int sizeBytes,
    DateTime? modifiedDate,
    int chunkSize = 4 * 1024 * 1024,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持上传文件到 Unraid');
    }
    if (!_isWritableFilePath(targetPath)) {
      throw const UnraidClientException('目标路径必须位于 /mnt 或 /boot 下');
    }
    final rootToken = RootIsolateToken.instance;
    if (rootToken == null) {
      throw const UnraidClientException('后台上传初始化失败');
    }

    final normalized = _normalizeUnraidPath(targetPath);
    await ensureDirectory(_parentPath(normalized));
    final port = await _resolveSshPort();
    try {
      await Isolate.run(
        () => _uploadLocalMediaFileInBackground(
          _LocalMediaUploadRequest(
            rootToken: rootToken,
            host: Uri.parse(baseUrl).host,
            port: port,
            username: username,
            password: _password,
            targetPath: normalized,
            sourceUri: sourceUri,
            sizeBytes: sizeBytes,
            modifiedMs: modifiedDate?.millisecondsSinceEpoch,
            chunkSize: chunkSize,
          ),
        ),
      );
    } on TimeoutException {
      throw const UnraidClientException('上传文件超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('无法上传文件：$error');
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
  }

  Future<void> renamePath({
    required String path,
    required String newName,
  }) async {
    final trimmedName = newName.trim();
    if (!_isValidRemoteName(trimmedName)) {
      throw const UnraidClientException('新名称无效');
    }
    final normalized = _normalizeUnraidPath(path);
    await movePath(
      sourcePath: normalized,
      targetPath: _joinPath(_parentPath(normalized), trimmedName),
    );
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
  }

  Future<List<UnraidFileEntry>> fetchMediaFiles(
    String path, {
    int maxDepth = 6,
    bool includeImages = true,
    bool includeVideos = true,
    bool includeAudio = false,
  }) async {
    final results = <UnraidFileEntry>[];
    final visited = <String>{};

    bool matches(UnraidFileEntry entry) {
      if (includeImages && entry.isImage) {
        return true;
      }
      if (includeVideos && entry.isVideo) {
        return true;
      }
      if (includeAudio && entry.isAudio) {
        return true;
      }
      return false;
    }

    Future<void> walk(String currentPath, int depth) async {
      if (depth > maxDepth || !visited.add(currentPath)) {
        return;
      }

      List<UnraidFileEntry> entries;
      try {
        entries = await fetchDirectory(currentPath);
      } on UnraidClientException {
        // Missing or unreadable directories (common for first-time backup
        // targets and optional music roots) are treated as empty.
        return;
      } on Object {
        return;
      }

      for (final entry in entries) {
        if (entry.isDirectory) {
          await walk(entry.path, depth + 1);
        } else if (matches(entry)) {
          results.add(entry);
        }
      }
    }

    await walk(path, 0);
    results.sort(
      (a, b) => (b.modifiedDate ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.modifiedDate ?? DateTime.fromMillisecondsSinceEpoch(0)),
    );
    return results;
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

  void close() {
    _sftpClient?.close();
    _sshClient?.close();
    _httpClient.close();
  }

  Future<SSHClient> _ensureSshClient() async {
    final existing = _sshClient;
    if (existing != null && !existing.isClosed) {
      return existing;
    }

    final host = Uri.parse(baseUrl).host;
    final port = await _resolveSshPort();
    try {
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );
      final client = SSHClient(
        socket,
        username: username,
        onPasswordRequest: () => _password,
        ident: 'unraider',
      );
      await client.authenticated.timeout(const Duration(seconds: 15));
      _sshClient = client;
      _sftpClient = null;
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

    try {
      final sftp = await ssh.sftp().timeout(const Duration(seconds: 15));
      await sftp.handshake.timeout(const Duration(seconds: 15));
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
          timeout: const Duration(seconds: 10),
        );
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final payload = jsonDecode(
          utf8.decode(response.bodyBytes, allowMalformed: true),
        );
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
            await _send('GET', path).timeout(const Duration(seconds: 10));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          continue;
        }
        final html = utf8.decode(response.bodyBytes, allowMalformed: true);
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
    Duration timeout = const Duration(seconds: 30),
  }) async {
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
      return utf8.decode(result.stdout, allowMalformed: true);
    } on TimeoutException {
      throw UnraidClientException('$action超时');
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('$action失败：$error');
    }
  }

  Future<bool> _sshDirectoryExists(String path) async {
    try {
      final client = await _ensureSshClient();
      final result = await client
          .runWithResult('test -d ${shellQuote(_normalizeUnraidPath(path))}')
          .timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } on Object {
      return false;
    }
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
    final response = await _send('GET', '/Main');
    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
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
  }

  Future<List<UnraidManagementItem>> _fetchDockerItems() async {
    try {
      final response = await _send(
        'GET',
        '/plugins/dynamix.docker.manager/include/DockerContainers.php',
      );
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      return _parseDockerItems(body);
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
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      return _parseVmItems(body);
    } on UnraidClientException {
      rethrow;
    } on Object catch (error) {
      throw UnraidClientException('读取虚拟机列表失败：$error');
    }
  }

  Future<List<UnraidManagementItem>> _fetchShareItems() async {
    try {
      final entries = await fetchDirectory('/mnt/user');
      return entries
          .where((entry) => entry.isDirectory)
          .map(
            (entry) => UnraidManagementItem(
              id: entry.path,
              title: entry.name,
              status: '可浏览',
              description: entry.path,
              type: ManagementItemType.share,
              detail: entry.path,
              tags: const <String>['共享'],
            ),
          )
          .toList(growable: false);
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
  }) {
    return _sendUri(
      method,
      _uri(path),
      fields: fields,
      includeCsrf: includeCsrf,
      allowLoginRedirect: allowLoginRedirect,
    );
  }

  Future<http.Response> _sendUri(
    String method,
    Uri uri, {
    Map<String, String>? fields,
    bool includeCsrf = true,
    bool allowLoginRedirect = false,
    int redirectCount = 0,
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

    final streamed = await _httpClient.send(request);
    final response = await http.Response.fromStream(streamed);
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
      );
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    _extractCsrf(body);

    if (!allowLoginRedirect && _looksLikeLoginPage(body)) {
      throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw UnraidClientException('WebGUI 拒绝访问：HTTP ${response.statusCode}');
    }
    return response;
  }

  Future<http.Response> _sendJsonPost(
    Uri uri,
    Map<String, Object?> payload, {
    Duration timeout = const Duration(seconds: 30),
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
    final streamed = await _httpClient.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    _storeCookies(response);
    if (_isRedirect(response.statusCode)) {
      final location = response.headers['location'];
      if (location != null && _isLoginPath(uri.resolve(location).path)) {
        throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
      }
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    _extractCsrf(body);
    if (!_isRedirect(response.statusCode) && _looksLikeLoginPage(body)) {
      throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw UnraidClientException('WebGUI 拒绝访问：HTTP ${response.statusCode}');
    }
    return response;
  }

  Uri _uri(String path) => Uri.parse(baseUrl).resolve(path);

  String get _cookieHeader =>
      _cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; ');

  void _storeCookies(http.Response response) {
    final setCookie = response.headers['set-cookie'];
    if (setCookie == null || setCookie.isEmpty) {
      return;
    }

    for (final rawCookie in _splitSetCookie(setCookie)) {
      final pair = rawCookie.split(';').first;
      final separator = pair.indexOf('=');
      if (separator <= 0) {
        continue;
      }
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (value.isEmpty || value.toLowerCase() == 'deleted') {
        _cookies.remove(name);
      } else {
        _cookies[name] = value;
      }
    }
  }

  void _extractCsrf(String html) {
    final token = _firstMatch(
          html,
          RegExp(r'''csrf_token\s*=\s*["']([^"']+)["']'''),
        ) ??
        _firstMatch(
          html,
          RegExp(r'''name=["']csrf_token["'][^>]*value=["']([^"']+)["']'''),
        );
    if (token != null && token.isNotEmpty) {
      _csrfToken = token;
    }
  }

  void _throwForJsonFailure(http.Response response, String prefix) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('$prefix：HTTP ${response.statusCode}');
    }

    final body = utf8.decode(response.bodyBytes, allowMalformed: true).trim();
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

enum ManagementItemType { docker, vm, share }

enum ManagementAction { start, stop, restart }

class UnraidDashboard {
  const UnraidDashboard({
    required this.serverName,
    required this.serverDescription,
    required this.guid,
    required this.ownerName,
    required this.registration,
    required this.model,
    required this.version,
    required this.status,
    required this.lanIp,
    required this.wanIp,
    required this.localUrl,
    required this.remoteUrl,
    required this.uptime,
    required this.cpuSummary,
    required this.cpuPercent,
    required this.baseboardSummary,
    required this.osSummary,
    required this.packagesSummary,
    required this.memoryUsage,
    required this.memoryPercent,
    required this.arrayState,
    required this.arrayUsage,
    required this.arrayPercent,
    required this.paritySummary,
    required this.notificationInfo,
    required this.notificationWarning,
    required this.notificationAlert,
    required this.notificationTotal,
    required this.notifications,
    required this.diskItems,
    required this.networkItems,
    required this.upsItems,
    required this.pluginItems,
    required this.securityItems,
    required this.cloudItems,
    required this.logItems,
    required this.servicesSummary,
    required this.dockerNetworkSummary,
    required this.dockerConflictSummary,
    required this.dockerItems,
    required this.vmItems,
    required this.shareItems,
  });

  final String serverName;
  final String serverDescription;
  final String guid;
  final String ownerName;
  final String registration;
  final String model;
  final String version;
  final String status;
  final String lanIp;
  final String wanIp;
  final String localUrl;
  final String remoteUrl;
  final String uptime;
  final String cpuSummary;
  final double cpuPercent;
  final String baseboardSummary;
  final String osSummary;
  final String packagesSummary;
  final String memoryUsage;
  final double memoryPercent;
  final String arrayState;
  final String arrayUsage;
  final double arrayPercent;
  final String paritySummary;
  final int notificationInfo;
  final int notificationWarning;
  final int notificationAlert;
  final int notificationTotal;
  final List<UnraidNotification> notifications;
  final List<UnraidInfoItem> diskItems;
  final List<UnraidInfoItem> networkItems;
  final List<UnraidInfoItem> upsItems;
  final List<UnraidInfoItem> pluginItems;
  final List<UnraidInfoItem> securityItems;
  final List<UnraidInfoItem> cloudItems;
  final List<UnraidInfoItem> logItems;
  final String servicesSummary;
  final String dockerNetworkSummary;
  final String dockerConflictSummary;
  final List<UnraidManagementItem> dockerItems;
  final List<UnraidManagementItem> vmItems;
  final List<UnraidManagementItem> shareItems;
}

class UnraidManagementItem {
  const UnraidManagementItem({
    required this.id,
    required this.title,
    required this.status,
    required this.description,
    required this.type,
    this.detail = '',
    this.progress = 0,
    this.tags = const <String>[],
    this.details = const <UnraidInfoItem>[],
  });

  final String id;
  final String title;
  final String status;
  final String description;
  final String detail;
  final double progress;
  final List<String> tags;
  final List<UnraidInfoItem> details;
  final ManagementItemType type;
}

enum InfoSeverity { normal, success, warning, danger }

class UnraidInfoItem {
  const UnraidInfoItem({
    required this.title,
    required this.value,
    this.description = '',
    this.severity = InfoSeverity.normal,
  });

  final String title;
  final String value;
  final String description;
  final InfoSeverity severity;
}

class UnraidNotification {
  const UnraidNotification({
    required this.title,
    required this.description,
    required this.severity,
    this.subject = '',
    this.timestamp = '',
  });

  final String title;
  final String subject;
  final String description;
  final InfoSeverity severity;
  final String timestamp;
}

class UnraidFileEntry {
  const UnraidFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.sizeBytes,
    required this.size,
    required this.modified,
    required this.modifiedDate,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int sizeBytes;
  final String size;
  final String modified;
  final DateTime? modifiedDate;

  bool get isMedia {
    final lower = name.toLowerCase();
    return _imageExtensions.any(lower.endsWith) ||
        _videoExtensions.any(lower.endsWith) ||
        _audioExtensions.any(lower.endsWith);
  }

  bool get isImage => _imageExtensions.any(name.toLowerCase().endsWith);

  bool get isVideo => _videoExtensions.any(name.toLowerCase().endsWith);

  bool get isAudio => _audioExtensions.any(name.toLowerCase().endsWith);
}

const _imageExtensions = <String>[
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
];

const _videoExtensions = <String>[
  '.mp4',
  '.mov',
  '.m4v',
  '.mkv',
  '.avi',
  '.webm',
];

const _audioExtensions = <String>[
  '.mp3',
  '.flac',
  '.wav',
  '.aac',
  '.m4a',
  '.ogg',
  '.opus',
  '.wma',
  '.aiff',
  '.ape',
  '.alac',
];

List<UnraidManagementItem> _parseDockerItems(String body) {
  final items = <UnraidManagementItem>[];
  final script =
      body.split('\u0000').length > 1 ? body.split('\u0000')[1] : body;
  final regex = RegExp(
    r'''docker\.push\(\{name:'((?:\\'|[^'])*)',id:'([^']*)',state:(\d+),pause:(\d+),update:(\d+)''',
  );

  for (final match in regex.allMatches(script)) {
    final name = _decodeJsString(match.group(1) ?? '');
    final id = match.group(2) ?? name;
    final isRunning = match.group(3) == '1';
    final isPaused = match.group(4) == '1';
    final hasUpdate = match.group(5) == '1';
    final status = isPaused
        ? '已暂停'
        : isRunning
            ? '运行中'
            : '已停止';
    items.add(
      UnraidManagementItem(
        id: id,
        title: name,
        status: status,
        description: 'Docker 容器',
        type: ManagementItemType.docker,
        detail: id,
        tags: <String>[
          if (hasUpdate) '有更新',
        ],
      ),
    );
  }
  return items;
}

List<UnraidManagementItem> _parseVmItems(String body) {
  final parts = body.split('\u0000');
  final html = parts.isNotEmpty ? parts.first : body;
  final script = parts.length > 1 ? parts.last : body;
  final states = <String, String>{};
  final stateRegex =
      RegExp(r'''kvm\.push\(\{id:'([^']*)',state:'([^']*)'\}\);''');
  for (final match in stateRegex.allMatches(script)) {
    states[match.group(1) ?? ''] = match.group(2) ?? '';
  }

  final items = <UnraidManagementItem>[];
  final nameRegex = RegExp(r"addVMContext\('((?:\\'|[^'])*)','([^']*)'");
  for (final match in nameRegex.allMatches(html)) {
    final name = _decodeJsString(match.group(1) ?? '');
    final uuid = match.group(2) ?? name;
    final state = states[uuid] ?? '';
    items.add(
      UnraidManagementItem(
        id: uuid,
        title: name,
        status: _vmStatus(state),
        description: '虚拟机',
        type: ManagementItemType.vm,
        detail: uuid,
      ),
    );
  }

  for (final entry in states.entries) {
    if (items.any((item) => item.id == entry.key)) {
      continue;
    }
    items.add(
      UnraidManagementItem(
        id: entry.key,
        title: entry.key,
        status: _vmStatus(entry.value),
        description: '虚拟机',
        type: ManagementItemType.vm,
        detail: entry.key,
      ),
    );
  }
  return items;
}

@visibleForTesting
String buildSshDirectoryListCommand(String path) {
  return _buildSshDirectoryListCommand(_normalizeUnraidPath(path));
}

@visibleForTesting
String buildSetModifiedTimeCommand(String path, DateTime modifiedDate) {
  final seconds = modifiedDate.toUtc().millisecondsSinceEpoch ~/ 1000;
  return 'touch -m -d @$seconds -- ${shellQuote(_normalizeUnraidPath(path))}';
}

String _buildSshDirectoryListCommand(String normalizedPath) {
  return "LC_ALL=C find ${shellQuote(normalizedPath)} -mindepth 1 "
      "-maxdepth 1 -printf '%p\\0%y\\0%s\\0%T@\\0%f\\0'";
}

@visibleForTesting
List<UnraidFileEntry> parseSshDirectoryListing(
  String output,
  String parentPath,
) {
  final entries = <UnraidFileEntry>[];
  final fields = output.split('\u0000');
  for (var i = 0; i + 4 < fields.length; i += 5) {
    final rawPath = fields[i];
    final type = fields[i + 1].trim();
    final rawSize = fields[i + 2].trim();
    final rawModified = fields[i + 3].trim();
    final rawName = fields[i + 4];
    if (rawPath.isEmpty || rawName.isEmpty) {
      continue;
    }

    final isDirectory = type == 'd';
    final size = int.tryParse(rawSize) ?? 0;
    final modifiedSeconds = double.tryParse(rawModified)?.floor() ?? 0;
    final modifiedDate = modifiedSeconds > 0
        ? DateTime.fromMillisecondsSinceEpoch(modifiedSeconds * 1000)
        : DateTime.fromMillisecondsSinceEpoch(0);
    final path =
        rawPath.startsWith('/') ? rawPath : _joinPath(parentPath, rawPath);
    entries.add(
      UnraidFileEntry(
        name: rawName,
        path: path,
        isDirectory: isDirectory,
        sizeBytes: isDirectory ? 0 : size,
        size: isDirectory ? '' : _formatSize(size),
        modified: _formatDate(modifiedDate),
        modifiedDate: modifiedDate,
      ),
    );
  }

  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) {
      return a.isDirectory ? -1 : 1;
    }
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return entries;
}

_DashboardSnapshot _parseDashboardSnapshot(String html) {
  final cpuSummary = _normalizeText(_extractSectionTextAfterHeader(
        html: html,
        marker: 'icon-cpu',
        headerClass: 'tile-header-main',
      )) ??
      '';
  final memoryInstalled = _normalizeText(_firstMatch(
    html,
    RegExp(
      r'''fa-line-chart[^>]*></i>\s*[^:：<]*[:：]\s*([^<]+)''',
      caseSensitive: false,
      dotAll: true,
    ),
  ));
  final memoryUsable = _normalizeText(_firstMatch(
    html,
    RegExp(
      r'''fa-compress[^>]*></i>\s*[^:：<]*[:：]\s*([^<]+)''',
      caseSensitive: false,
      dotAll: true,
    ),
  ));
  final arrayBlock = _firstMatch(
        html,
        RegExp(
          r'''<tbody\b[^>]*\bid=["']array_list["'][^>]*>(.*?)</tbody>''',
          caseSensitive: false,
          dotAll: true,
        ),
      ) ??
      '';
  final arrayHeader = _normalizeText(_firstMatch(
        arrayBlock,
        RegExp(
          r'''<h3\b[^>]*class=["']tile-header-main["'][^>]*>(.*?)</h3>''',
          caseSensitive: false,
          dotAll: true,
        ),
      )) ??
      '';
  final arrayUsage = _normalizeText(_firstMatch(
        arrayBlock,
        RegExp(
          r'''<h3\b[^>]*class=["']tile-header-main["'][^>]*>.*?</h3>\s*<span>\s*(.*?)\s*</span>''',
          caseSensitive: false,
          dotAll: true,
        ),
      )) ??
      '';
  final arrayPercent = _parsePercent(arrayUsage);

  return _DashboardSnapshot(
    cpuSummary: cpuSummary,
    memoryUsage: memoryUsable ??
        memoryInstalled ??
        (html.contains('tile-system-memory') ? '等待实时数据' : ''),
    arrayState: arrayHeader.toLowerCase().contains('stopped') ||
            arrayHeader.contains('停止')
        ? '已停止'
        : arrayBlock.isNotEmpty
            ? '已启动'
            : '未知',
    arrayUsage: arrayUsage.isEmpty ? '等待实时数据' : arrayUsage,
    arrayPercent: arrayPercent,
  );
}

String _normalizeBaseUrl(String baseUrl) {
  final trimmed = baseUrl.trim();
  final withScheme =
      trimmed.startsWith('http://') || trimmed.startsWith('https://')
          ? trimmed
          : 'http://$trimmed';
  return withScheme.endsWith('/')
      ? withScheme.substring(0, withScheme.length - 1)
      : withScheme;
}

String _dockerAction(ManagementAction action) {
  return switch (action) {
    ManagementAction.start => 'start',
    ManagementAction.stop => 'stop',
    ManagementAction.restart => 'restart',
  };
}

String _vmAction(ManagementAction action) {
  return switch (action) {
    ManagementAction.start => 'domain-start',
    ManagementAction.stop => 'domain-stop',
    ManagementAction.restart => 'domain-restart',
  };
}

String _vmStatus(String state) {
  return switch (state.toLowerCase()) {
    'running' => '运行中',
    'paused' => '已暂停',
    'shutoff' || 'shutdown' || 'stopped' => '已停止',
    '' => '未知',
    _ => state,
  };
}

bool _isRedirect(int statusCode) =>
    statusCode == 301 ||
    statusCode == 302 ||
    statusCode == 303 ||
    statusCode == 307 ||
    statusCode == 308;

bool _isLoginPath(String path) {
  final lower = path.toLowerCase();
  return lower == '/login' ||
      lower.endsWith('/login') ||
      lower.endsWith('/login.php');
}

bool _isWritableFilePath(String path) {
  return _isWritableDirectoryPath(_parentPath(path));
}

bool _isWritableDirectoryPath(String path) {
  final normalized = _normalizeUnraidPath(path);
  if (_hasUnsafePathSegment(normalized)) {
    return false;
  }
  return normalized.startsWith('/mnt/') ||
      normalized == '/boot' ||
      normalized.startsWith('/boot/');
}

@visibleForTesting
bool isUnsafeDestructivePath(String path) {
  final normalized = _normalizeUnraidPath(path);
  if (normalized == '/' ||
      normalized == '/mnt' ||
      normalized == '/mnt/user' ||
      normalized == '/boot') {
    return true;
  }
  return RegExp(r'^/mnt/(?:disk[^/]*|cache[^/]*)$').hasMatch(normalized);
}

void _throwIfUnsafeDestructivePath(String path, String label) {
  if (isUnsafeDestructivePath(path) || _hasUnsafePathSegment(path)) {
    throw UnraidClientException('$label 不允许执行该操作');
  }
}

bool _hasUnsafePathSegment(String path) {
  return _normalizeUnraidPath(path)
      .split('/')
      .any((segment) => segment == '..' || segment == '.');
}

bool _isValidRemoteName(String name) {
  return name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains(r'\') &&
      !name.contains('\u0000');
}

String _normalizeUnraidPath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  if (normalized.isEmpty) {
    return '/';
  }
  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }
  normalized = normalized.replaceAll(RegExp(r'/+'), '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String _parentPath(String path) {
  final normalized = _normalizeUnraidPath(path);
  final slash = normalized.lastIndexOf('/');
  if (slash <= 0) {
    return '/';
  }
  return normalized.substring(0, slash);
}

@visibleForTesting
class SmbSharePath {
  const SmbSharePath({
    required this.share,
    required this.relativePath,
  });

  final String share;
  final String relativePath;
}

@visibleForTesting
SmbSharePath? smbSharePathFromUnraidPath(String path) {
  final normalized = _normalizeUnraidPath(path);
  const prefix = '/mnt/user/';
  if (!normalized.startsWith(prefix)) {
    return null;
  }

  final remainder = normalized.substring(prefix.length);
  final slash = remainder.indexOf('/');
  if (slash <= 0 || slash == remainder.length - 1) {
    return null;
  }

  return SmbSharePath(
    share: remainder.substring(0, slash),
    relativePath: remainder.substring(slash + 1),
  );
}

class _LocalMediaUploadRequest {
  const _LocalMediaUploadRequest({
    required this.rootToken,
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    required this.targetPath,
    required this.sourceUri,
    required this.sizeBytes,
    required this.chunkSize,
    this.modifiedMs,
  });

  final RootIsolateToken rootToken;
  final String host;
  final int port;
  final String username;
  final String password;
  final String targetPath;
  final String sourceUri;
  final int sizeBytes;
  final int chunkSize;
  final int? modifiedMs;
}

Future<void> _uploadLocalMediaFileInBackground(
  _LocalMediaUploadRequest request,
) async {
  BackgroundIsolateBinaryMessenger.ensureInitialized(request.rootToken);
  const localMediaChannel = MethodChannel('unraider/local_media');
  SSHClient? client;
  SftpFile? file;
  try {
    final socket = await SSHSocket.connect(
      request.host,
      request.port,
      timeout: const Duration(seconds: 10),
    );
    client = SSHClient(
      socket,
      username: request.username,
      onPasswordRequest: () => request.password,
      ident: 'unraider-sync',
    );
    await client.authenticated.timeout(const Duration(seconds: 15));
    final sftp = await client.sftp().timeout(const Duration(seconds: 15));
    await sftp.handshake.timeout(const Duration(seconds: 15));
    file = await sftp.open(
      request.targetPath,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );

    var offset = 0;
    while (
        offset < request.sizeBytes || (request.sizeBytes == 0 && offset == 0)) {
      final remaining = request.sizeBytes - offset;
      final length = request.sizeBytes == 0
          ? 0
          : remaining < request.chunkSize
              ? remaining
              : request.chunkSize;
      final chunk = request.sizeBytes == 0
          ? Uint8List(0)
          : await localMediaChannel.invokeMethod<Uint8List>('readChunk', {
              'uri': request.sourceUri,
              'offset': offset,
              'length': length,
            });
      final bytes = chunk ?? Uint8List(0);
      if (bytes.length < length) {
        throw const UnraidClientException('读取本机媒体文件失败');
      }
      if (bytes.isNotEmpty) {
        await file.writeBytes(bytes, offset: offset);
      }
      offset += bytes.length;
      if (request.sizeBytes == 0) {
        break;
      }
    }
    await file.close();
    file = null;

    final modifiedMs = request.modifiedMs;
    if (modifiedMs != null && modifiedMs > 0) {
      final result = await client
          .runWithResult(
            buildSetModifiedTimeCommand(
              request.targetPath,
              DateTime.fromMillisecondsSinceEpoch(modifiedMs, isUtc: true),
            ),
            stdout: true,
            stderr: true,
          )
          .timeout(const Duration(seconds: 20));
      if (result.exitCode != 0) {
        final error = utf8
            .decode(
              result.stderr.isNotEmpty ? result.stderr : result.stdout,
              allowMalformed: true,
            )
            .trim();
        throw UnraidClientException(
          error.isEmpty ? '保留文件时间失败' : '保留文件时间失败：$error',
        );
      }
    }
  } finally {
    await file?.close();
    client?.close();
  }
}

@visibleForTesting
String shellQuote(String value) {
  if (value.isEmpty) {
    return "''";
  }
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}

Future<Uint8List> _readRemoteFileViaSsh({
  required String host,
  required int port,
  required String username,
  required String password,
  required String path,
}) async {
  SSHClient? client;
  try {
    final socket = await SSHSocket.connect(
      host,
      port,
      timeout: const Duration(seconds: 10),
    );
    client = SSHClient(
      socket,
      username: username,
      onPasswordRequest: () => password,
      ident: 'unraider-preview',
    );
    await client.authenticated.timeout(const Duration(seconds: 15));
    final result = await client
        .runWithResult(
          'cat -- ${shellQuote(path)}',
          stdout: true,
          stderr: true,
        )
        .timeout(const Duration(seconds: 30));
    if (result.exitCode != 0) {
      final error = utf8
          .decode(
            result.stderr.isNotEmpty ? result.stderr : result.stdout,
            allowMalformed: true,
          )
          .trim();
      throw Exception(
        error.isEmpty ? '读取文件失败：退出码 ${result.exitCode}' : '读取文件失败：$error',
      );
    }
    return result.stdout;
  } finally {
    client?.close();
  }
}

bool _looksLikeLoginPage(String body) {
  final lower = body.toLowerCase();
  return lower.contains('name="username"') &&
      lower.contains('name="password"') &&
      (lower.contains('/login') || lower.contains('unraid_login'));
}

Map<String, dynamic>? _findNestedMap(Object? value, List<String> path) {
  Object? current = value;
  for (final segment in path) {
    if (current is! Map) {
      return null;
    }
    current = current[segment];
  }
  if (current is Map<String, dynamic>) {
    return current;
  }
  if (current is Map) {
    return current.map(
      (key, value) => MapEntry(key.toString(), value),
    );
  }
  return null;
}

bool? _parseBoolish(Object? value) {
  if (value is bool) {
    return value;
  }
  final text = value?.toString().trim().toLowerCase();
  if (text == null || text.isEmpty) {
    return null;
  }
  if (text == 'yes' || text == 'true' || text == '1' || text == 'enabled') {
    return true;
  }
  if (text == 'no' || text == 'false' || text == '0' || text == 'disabled') {
    return false;
  }
  return null;
}

int? _parsePort(Object? value) {
  final port = int.tryParse(value?.toString().trim() ?? '');
  if (port == null || port <= 0 || port > 65535) {
    return null;
  }
  return port;
}

String? _htmlInputValue(String html, String name) {
  final namePattern = RegExp.escape(name);
  final nameThenValue = RegExp(
    '''<input\\b[^>]*\\bname=["']$namePattern["'][^>]*\\bvalue=["']([^"']*)["']''',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  final valueThenName = RegExp(
    '''<input\\b[^>]*\\bvalue=["']([^"']*)["'][^>]*\\bname=["']$namePattern["']''',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html);
  final value = nameThenValue?.group(1) ?? valueThenName?.group(1);
  return value == null ? null : _decodeHtml(value).trim();
}

bool? _parseSettingsBool(String html, String name) {
  final namePattern = RegExp.escape(name);
  final input = RegExp(
    '''<input\\b(?=[^>]*\\bname=["']$namePattern["'])([^>]*)>''',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(html)?.group(1);
  if (input == null) {
    return _parseBoolish(_htmlInputValue(html, name));
  }
  if (RegExp(r'\bchecked\b', caseSensitive: false).hasMatch(input)) {
    return true;
  }
  final value = RegExp(
    r'''value=["']([^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(input)?.group(1);
  return _parseBoolish(value);
}

List<String> _splitSetCookie(String header) {
  final cookies = <String>[];
  final buffer = StringBuffer();
  for (var i = 0; i < header.length; i += 1) {
    final char = header[i];
    if (char == ',' && !_looksLikeExpiresComma(header, i)) {
      cookies.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(char);
    }
  }
  if (buffer.isNotEmpty) {
    cookies.add(buffer.toString());
  }
  return cookies;
}

bool _looksLikeExpiresComma(String header, int commaIndex) {
  final prefix = header.substring(0, commaIndex).toLowerCase();
  final suffix = header.substring(commaIndex + 1);
  return prefix.lastIndexOf('expires=') > prefix.lastIndexOf(';') &&
      RegExp(r'^\s*\d{2}\s').hasMatch(suffix);
}

String? _firstMatch(String input, RegExp regex) {
  final match = regex.firstMatch(input);
  return match == null ? null : match.group(1);
}

String? _extractSectionTextAfterHeader({
  required String html,
  required String marker,
  required String headerClass,
}) {
  final markerIndex = html.indexOf(marker);
  if (markerIndex < 0) {
    return null;
  }
  final section = html.substring(markerIndex).split('</tbody>').first;
  final header = RegExp(
    '<h3\\b[^>]*class=["\\\']$headerClass["\\\'][^>]*>.*?</h3>',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(section);
  if (header == null) {
    return null;
  }
  final afterHeader = section.substring(header.end);
  final nextTag = afterHeader.indexOf('<span class');
  final text = nextTag >= 0 ? afterHeader.substring(0, nextTag) : afterHeader;
  return _stripHtml(text);
}

String? _normalizeText(String? value) {
  final text = _decodeHtml(_stripHtml(value ?? ''))
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (text.isEmpty || text == 'N/A') {
    return null;
  }
  return text;
}

double _parsePercent(String value) {
  final match = RegExp(r'(\d+(?:[.,]\d+)?)\s*%').firstMatch(value);
  if (match == null) {
    return 0;
  }
  final number = double.tryParse((match.group(1) ?? '').replaceAll(',', '.'));
  if (number == null) {
    return 0;
  }
  return (number / 100).clamp(0, 1).toDouble();
}

String _serverNameFromHtml(String html) {
  final title = _decodeHtml(
    _stripHtml(
      _firstMatch(
            html,
            RegExp(r'<title[^>]*>(.*?)</title>',
                caseSensitive: false, dotAll: true),
          ) ??
          '',
    ),
  ).trim();
  if (title.isEmpty) {
    return 'Unraid';
  }
  return title
      .replaceAll(RegExp(r'\s+-\s+Unraid.*$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+\|\s+Unraid.*$', caseSensitive: false), '')
      .trim();
}

String _decodeJsString(String value) {
  return value
      .replaceAll(r"\'", "'")
      .replaceAll(r'\"', '"')
      .replaceAll(r'\\', '\\');
}

String _decodeHtml(String value) {
  return value
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&nbsp;', ' ');
}

String _stripHtml(String html) {
  return html.replaceAll(RegExp(r'<[^>]+>'), ' ');
}

String _joinPath(String parent, String child) {
  final left =
      parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent;
  final right = child.startsWith('/') ? child.substring(1) : child;
  return '$left/$right';
}

String _formatSize(int bytes) {
  if (bytes <= 0) {
    return '';
  }
  const units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  final precision = value >= 10 || unitIndex == 0 ? 0 : 1;
  return '${value.toStringAsFixed(precision)} ${units[unitIndex]}';
}

String _formatDate(DateTime value) {
  if (value.millisecondsSinceEpoch == 0) {
    return '';
  }
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

class _DashboardSnapshot {
  const _DashboardSnapshot({
    required this.cpuSummary,
    required this.memoryUsage,
    required this.arrayState,
    required this.arrayUsage,
    required this.arrayPercent,
  });

  final String cpuSummary;
  final String memoryUsage;
  final String arrayState;
  final String arrayUsage;
  final double arrayPercent;
}

class _SshServiceConfig {
  const _SshServiceConfig({
    required this.useSsh,
    required this.port,
  });

  final bool? useSsh;
  final int? port;
}
