import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class UnraidClientException implements Exception {
  const UnraidClientException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef UnraidClient = UnraidWebGuiClient;

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

    await _ensureCsrfToken();
    final uri = _uri('/webGui/include/Browse.php').replace(
      queryParameters: <String, String>{
        'dir': path,
        'path': 'Browse',
      },
    );

    http.Response response;
    try {
      response =
          await _sendUri('GET', uri).timeout(const Duration(seconds: 20));
    } on TimeoutException {
      throw const UnraidClientException('读取目录超时');
    } on Object catch (error) {
      throw UnraidClientException('无法读取目录：$error');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('目录接口返回 HTTP ${response.statusCode}');
    }

    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    return _parseBrowseHtml(html, path);
  }

  Future<void> ensureDirectory(String path) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持创建 Unraid 目录');
    }

    final normalized = _normalizeUnraidPath(path);
    if (!_isWritableDirectoryPath(normalized)) {
      throw const UnraidClientException('目录必须位于 /mnt 或 /boot 下');
    }

    if (await _directoryExists(normalized)) {
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
    late int nextIndex;
    if (parts.first == 'boot') {
      current = '/boot';
      nextIndex = 1;
    } else if (parts.first == 'mnt' && parts.length >= 3) {
      current = '/mnt/${parts[1]}/${parts[2]}';
      nextIndex = 3;
    } else {
      throw const UnraidClientException('目标目录必须是 /mnt/<类型>/<共享> 或 /boot 下的路径');
    }

    if (!await _directoryExists(current)) {
      throw UnraidClientException('基础目录不存在：$current');
    }

    for (final segment in parts.skip(nextIndex)) {
      final next = _joinPath(current, segment);
      if (!await _directoryExists(next)) {
        await _createDirectory(current, segment);
      }
      current = next;
    }
  }

  Future<Uint8List> fetchFileBytes(String path) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持直接读取 Unraid 文件');
    }

    final uri = _fileUri(path);
    http.Response response;
    try {
      response =
          await _sendUri('GET', uri).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw const UnraidClientException('加载文件超时');
    } on Object catch (error) {
      throw UnraidClientException('无法加载文件：$error');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('文件接口返回 HTTP ${response.statusCode}');
    }

    return response.bodyBytes;
  }

  Future<void> uploadFile({
    required String targetPath,
    required int sizeBytes,
    required Future<Uint8List> Function(int offset, int length) readChunk,
    int chunkSize = 4 * 1024 * 1024,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持上传文件到 Unraid');
    }
    if (!_isWritableFilePath(targetPath)) {
      throw const UnraidClientException('目标路径必须位于 /mnt 或 /boot 下');
    }
    await _ensureCsrfToken();

    var offset = 0;
    try {
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
        await _postUploadChunk(
          targetPath: targetPath,
          offset: offset,
          bytes: chunk,
        );
        offset += chunk.length;
        if (sizeBytes == 0) {
          break;
        }
      }
      await _postUploadStop(targetPath);
    } on Object {
      await _postUploadCancel(targetPath);
      rethrow;
    }
  }

  Future<List<UnraidFileEntry>> fetchMediaFiles(
    String path, {
    int maxDepth = 6,
  }) async {
    final results = <UnraidFileEntry>[];
    final visited = <String>{};

    Future<void> walk(String currentPath, int depth) async {
      if (depth > maxDepth || !visited.add(currentPath)) {
        return;
      }

      final entries = await fetchDirectory(currentPath);
      for (final entry in entries) {
        if (entry.isDirectory) {
          await walk(entry.path, depth + 1);
        } else if (entry.isMedia) {
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

  void close() {
    _httpClient.close();
  }

  Future<bool> _directoryExists(String path) async {
    try {
      await fetchDirectory(path);
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _createDirectory(String parentPath, String name) async {
    final folderName = name.trim();
    if (folderName.isEmpty ||
        folderName.contains('/') ||
        folderName.contains(r'\')) {
      throw const UnraidClientException('目录名称无效');
    }

    await _ensureCsrfToken();
    await _send(
      'POST',
      '/webGui/include/Control.php',
      fields: <String, String>{
        'mode': 'file',
        'action': '0',
        'title': Uri.encodeComponent('Create folder'),
        'source': Uri.encodeComponent(parentPath),
        'target': Uri.encodeComponent(folderName),
        'hdlink': '',
        'sparse': '',
        'exist': '',
        'zfs': '',
      },
    );

    for (var i = 0; i < 20; i += 1) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final entries = await fetchDirectory(parentPath);
        final found = entries.any(
          (entry) => entry.isDirectory && entry.name == folderName,
        );
        if (found) {
          return;
        }
      } on Object {
        // Keep polling: Control.php starts the WebGUI file manager
        // asynchronously, so the folder may not be visible immediately.
      }
    }

    throw UnraidClientException('创建目录失败：${_joinPath(parentPath, folderName)}');
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

  Future<void> _postUploadChunk({
    required String targetPath,
    required int offset,
    required Uint8List bytes,
  }) async {
    final uri = _uri('/webGui/include/Control.php').replace(
      queryParameters: <String, String>{
        'mode': 'upload',
        'file': targetPath,
        'start': '$offset',
        'cancel': '0',
      },
    );
    http.Response response;
    try {
      response = await _sendRawPost(
        uri,
        bytes,
        timeout: const Duration(minutes: 10),
      );
    } on TimeoutException {
      throw const UnraidClientException('上传文件超时');
    } on Object catch (error) {
      throw UnraidClientException('无法上传文件：$error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UnraidClientException('上传接口返回 HTTP ${response.statusCode}');
    }
    final body = response.body.trim();
    if (body == 'stop') {
      throw const UnraidClientException('服务器拒绝上传，请检查目标目录');
    }
    if (body.startsWith('error')) {
      throw UnraidClientException('上传失败：$body');
    }
  }

  Future<void> _postUploadStop(String targetPath) async {
    await _send(
      'POST',
      '/webGui/include/Control.php',
      fields: <String, String>{
        'mode': 'stop',
        'file': Uri.encodeComponent(_basename(targetPath)),
      },
    );
  }

  Future<void> _postUploadCancel(String targetPath) async {
    try {
      final uri = _uri('/webGui/include/Control.php').replace(
        queryParameters: <String, String>{
          'mode': 'upload',
          'file': targetPath,
          'start': '0',
          'cancel': '1',
        },
      );
      await _sendRawPost(uri, Uint8List(0));
    } on Object {
      // Best effort cleanup only.
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

  Future<http.Response> _sendRawPost(
    Uri uri,
    Uint8List bytes, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final csrf = _csrfToken;
    if (csrf == null) {
      throw const UnraidClientException('缺少 csrf_token');
    }
    final request = http.Request('POST', uri);
    request.followRedirects = false;
    request.headers.addAll(<String, String>{
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Content-Type': 'application/octet-stream',
      'Referer': '$baseUrl/',
      'User-Agent': 'unraider-webgui',
      'X-CSRF-Token': csrf,
      'X-Requested-With': 'XMLHttpRequest',
      if (_cookies.isNotEmpty) 'Cookie': _cookieHeader,
    });
    request.bodyBytes = bytes;
    final streamed = await _httpClient.send(request).timeout(timeout);
    final response = await http.Response.fromStream(streamed);
    _storeCookies(response);
    if (_isRedirect(response.statusCode)) {
      final location = response.headers['location'];
      if (location != null && _isLoginPath(uri.resolve(location).path)) {
        throw const UnraidClientException('WebGUI 会话已失效，请重新登录');
      }
    }
    return response;
  }

  Uri _uri(String path) => Uri.parse(baseUrl).resolve(path);

  Uri _fileUri(String path) {
    final normalized = path.startsWith('/') ? path : '/$path';
    return Uri.parse(baseUrl)
        .replace(pathSegments: normalized.split('/').skip(1));
  }

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
    required this.size,
    required this.modified,
    required this.modifiedDate,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final String size;
  final String modified;
  final DateTime? modifiedDate;

  bool get isMedia {
    final lower = name.toLowerCase();
    return _imageExtensions.any(lower.endsWith) ||
        _videoExtensions.any(lower.endsWith);
  }

  bool get isImage => _imageExtensions.any(name.toLowerCase().endsWith);

  bool get isVideo => _videoExtensions.any(name.toLowerCase().endsWith);
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

List<UnraidFileEntry> _parseBrowseHtml(String html, String parentPath) {
  final entries = <UnraidFileEntry>[];
  final rows = RegExp(
    r'<tr\b[^>]*>(.*?)</tr>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(html);

  for (final row in rows) {
    final rowHtml = row.group(1) ?? '';
    if (rowHtml.contains('Parent Directory')) {
      continue;
    }

    final rowAction = RegExp(
      r'''<i\b[^>]*\bid=["']row_\d+["'][^>]*\bdata=["']([^"']*)["'][^>]*\btype=["']([df])["']''',
      caseSensitive: false,
      dotAll: true,
    ).firstMatch(rowHtml);
    final rawPath = rowAction?.group(1);
    final type = rowAction?.group(2);
    final isDirectory = type == 'd';

    final name = _decodeHtml(
      _stripHtml(
        _firstMatch(
              rowHtml,
              RegExp(
                r'''<td\b[^>]*id=["']name_[^"']*["'][^>]*>(.*?)</td>''',
                caseSensitive: false,
                dotAll: true,
              ),
            ) ??
            _firstMatch(
              rowHtml,
              RegExp(r'''<a\b[^>]*>(.*?)</a>''',
                  caseSensitive: false, dotAll: true),
            ) ??
            '',
      ),
    ).trim();

    if (name.isEmpty || rawPath == null) {
      continue;
    }

    final decodedPath = _decodeHtml(rawPath);
    final path = decodedPath.startsWith('/')
        ? decodedPath
        : _joinPath(parentPath, decodedPath);
    final cells = _parseTableCells(rowHtml);
    final size = isDirectory ? 0 : _parseSizeCell(cells, rowHtml);
    final modifiedDate = _parseModifiedCell(cells, rowHtml);
    entries.add(
      UnraidFileEntry(
        name: name,
        path: path,
        isDirectory: isDirectory,
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
  return normalized.startsWith('/mnt/') ||
      normalized == '/boot' ||
      normalized.startsWith('/boot/');
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

String _basename(String path) {
  final normalized = path.replaceAll('\\', '/');
  final slash = normalized.lastIndexOf('/');
  return slash >= 0 ? normalized.substring(slash + 1) : normalized;
}

bool _looksLikeLoginPage(String body) {
  final lower = body.toLowerCase();
  return lower.contains('name="username"') &&
      lower.contains('name="password"') &&
      (lower.contains('/login') || lower.contains('unraid_login'));
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

List<_HtmlCell> _parseTableCells(String rowHtml) {
  final matches = RegExp(
    r'<td\b([^>]*)>(.*?)</td>',
    caseSensitive: false,
    dotAll: true,
  ).allMatches(rowHtml);
  return matches
      .map(
        (match) => _HtmlCell(
          attributes: match.group(1) ?? '',
          text: _decodeHtml(_stripHtml(match.group(2) ?? '')).trim(),
        ),
      )
      .toList(growable: false);
}

int _parseSizeCell(List<_HtmlCell> cells, String rowHtml) {
  if (cells.length > 5) {
    final data = _attributeValue(cells[5].attributes, 'data');
    final bytes = int.tryParse(data ?? '');
    if (bytes != null) {
      return bytes;
    }
    return _parseSize(cells[5].text);
  }
  return _parseSize(_stripHtml(rowHtml));
}

DateTime _parseModifiedCell(List<_HtmlCell> cells, String rowHtml) {
  if (cells.length > 6) {
    final data = _attributeValue(cells[6].attributes, 'data');
    final seconds = int.tryParse(data ?? '');
    if (seconds != null && seconds > 0) {
      return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    }
    return _parseModified(cells[6].text);
  }
  return _parseModified(_stripHtml(rowHtml));
}

String? _attributeValue(String attributes, String name) {
  final match = RegExp(
    '''$name=["']([^"']*)["']''',
    caseSensitive: false,
  ).firstMatch(attributes);
  return match?.group(1);
}

String _joinPath(String parent, String child) {
  final left =
      parent.endsWith('/') ? parent.substring(0, parent.length - 1) : parent;
  final right = child.startsWith('/') ? child.substring(1) : child;
  return '$left/$right';
}

int _parseSize(String text) {
  final match =
      RegExp(r'(\d+(?:\.\d+)?)\s*(B|KB|MB|GB|TB)', caseSensitive: false)
          .firstMatch(text);
  if (match == null) {
    return 0;
  }
  final value = double.tryParse(match.group(1) ?? '') ?? 0;
  final unit = (match.group(2) ?? 'B').toUpperCase();
  final multiplier = switch (unit) {
    'KB' => 1024,
    'MB' => 1024 * 1024,
    'GB' => 1024 * 1024 * 1024,
    'TB' => 1024 * 1024 * 1024 * 1024,
    _ => 1,
  };
  return (value * multiplier).round();
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

DateTime _parseModified(String text) {
  final match = RegExp(r'(\d{4}-\d{2}-\d{2})(?:\s+(\d{2}:\d{2}(?::\d{2})?))?')
      .firstMatch(text);
  if (match == null) {
    return DateTime.fromMillisecondsSinceEpoch(0);
  }
  final date = match.group(1) ?? '';
  final time = match.group(2) ?? '00:00:00';
  return DateTime.tryParse('$date $time') ??
      DateTime.fromMillisecondsSinceEpoch(0);
}

String _formatDate(DateTime value) {
  if (value.millisecondsSinceEpoch == 0) {
    return '';
  }
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

class _HtmlCell {
  const _HtmlCell({
    required this.attributes,
    required this.text,
  });

  final String attributes;
  final String text;
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
