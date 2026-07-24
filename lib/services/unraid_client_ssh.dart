part of 'unraid_client.dart';

@visibleForTesting
String buildSshDirectoryListCommand(String path) {
  return _buildSshDirectoryListCommand(_normalizeUnraidPath(path));
}

@visibleForTesting
String buildSshMediaScanCommand(String path, {int maxDepth = 6}) {
  return _buildSshMediaScanCommand(
    _normalizeUnraidPath(path),
    maxDepth: maxDepth < 0 ? 0 : maxDepth,
  );
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

String _buildSshMediaScanCommand(String normalizedPath, {required int maxDepth}) {
  // maxDepth is relative to the root (root itself is depth 0), matching the
  // previous recursive walker semantics.
  return "LC_ALL=C find ${shellQuote(normalizedPath)} -mindepth 1 "
      "-maxdepth $maxDepth -type f "
      "-printf '%p\\0%y\\0%s\\0%T@\\0%f\\0'";
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
