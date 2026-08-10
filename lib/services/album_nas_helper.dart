import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'album_backup_models.dart';

enum AlbumNasHelperAvailability {
  disabled,
  ready,
  notInstalled,
  offline,
  unauthorized,
  incompatible,
}

class AlbumNasHelperStatus {
  const AlbumNasHelperStatus({
    required this.availability,
    required this.message,
    this.helperVersion,
    this.capabilities = const <String>{},
    this.roots = const <AlbumNasHelperRoot>[],
  });

  const AlbumNasHelperStatus.disabled()
      : availability = AlbumNasHelperAvailability.disabled,
        message = 'NAS 助手未启用，当前使用纯客户端模式',
        helperVersion = null,
        capabilities = const <String>{},
        roots = const <AlbumNasHelperRoot>[];

  final AlbumNasHelperAvailability availability;
  final String message;
  final String? helperVersion;
  final Set<String> capabilities;
  final List<AlbumNasHelperRoot> roots;

  bool get isReady => availability == AlbumNasHelperAvailability.ready;
}

class AlbumNasHelperRoot {
  const AlbumNasHelperRoot({required this.id, required this.remotePrefix});

  factory AlbumNasHelperRoot.fromJson(Map<String, dynamic> value) =>
      AlbumNasHelperRoot(
        id: value['id']?.toString() ?? '',
        remotePrefix: value['remotePrefix']?.toString() ?? '',
      );

  final String id;
  final String remotePrefix;
}

class AlbumNasHelperAsset {
  const AlbumNasHelperAsset({
    required this.remotePath,
    required this.displayName,
    required this.mediaKind,
    required this.mimeType,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.versionKey,
    this.thumbnailPath,
    this.contentHash,
  });

  factory AlbumNasHelperAsset.fromJson(Map<String, dynamic> value) =>
      AlbumNasHelperAsset(
        remotePath: value['remotePath']?.toString() ?? '',
        displayName: value['displayName']?.toString() ?? '',
        mediaKind: AlbumMediaKind.parse(value['mediaKind']),
        mimeType: value['mimeType']?.toString() ?? '',
        sizeBytes: (value['sizeBytes'] as num?)?.toInt() ?? 0,
        modifiedMs: (value['modifiedMs'] as num?)?.toInt() ?? 0,
        versionKey: value['versionKey']?.toString() ?? '',
        thumbnailPath: value['thumbnailPath']?.toString(),
        contentHash: value['contentHash']?.toString(),
      );

  final String remotePath;
  final String displayName;
  final AlbumMediaKind mediaKind;
  final String mimeType;
  final int sizeBytes;
  final int modifiedMs;
  final String versionKey;
  final String? thumbnailPath;
  final String? contentHash;

  AlbumRemoteAsset toRemoteAsset(String destinationId) => AlbumRemoteAsset(
        destinationId: destinationId,
        path: remotePath,
        displayName: displayName,
        mediaKind: mediaKind,
        sizeBytes: sizeBytes,
        modifiedMs: modifiedMs,
        versionKey: versionKey,
        thumbnailPath: thumbnailPath,
        origin: 'helper-indexed',
      );
}

class AlbumNasHelperJob {
  const AlbumNasHelperJob({
    required this.id,
    required this.type,
    required this.state,
    required this.progress,
    required this.processed,
    required this.total,
    this.message,
    this.lastError,
  });

  factory AlbumNasHelperJob.fromJson(Map<String, dynamic> value) =>
      AlbumNasHelperJob(
        id: value['id']?.toString() ?? '',
        type: value['type']?.toString() ?? '',
        state: value['state']?.toString() ?? 'unknown',
        progress: (value['progress'] as num?)?.toDouble() ?? 0,
        processed: (value['processed'] as num?)?.toInt() ?? 0,
        total: (value['total'] as num?)?.toInt() ?? 0,
        message: value['message']?.toString(),
        lastError: value['lastError']?.toString(),
      );

  final String id;
  final String type;
  final String state;
  final double progress;
  final int processed;
  final int total;
  final String? message;
  final String? lastError;

  bool get isFinished =>
      state == 'completed' || state == 'failed' || state == 'cancelled';
}

class AlbumNasHelperClient {
  AlbumNasHelperClient({
    required String baseUrl,
    required String token,
    http.Client? httpClient,
  })  : baseUrl = _normalizeBaseUrl(baseUrl),
        token = token.trim(),
        _httpClient = httpClient ?? http.Client(),
        _ownsHttpClient = httpClient == null;

  static const supportedApiVersion = 1;
  static const probeTimeout = Duration(seconds: 4);
  static const requestTimeout = Duration(seconds: 20);

  final String baseUrl;
  final String token;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  Future<AlbumNasHelperStatus> probe() async {
    if (baseUrl.isEmpty) {
      return const AlbumNasHelperStatus(
        availability: AlbumNasHelperAvailability.notInstalled,
        message: '未配置 NAS 助手地址',
      );
    }
    try {
      final health =
          await _httpClient.get(_uri('/healthz')).timeout(probeTimeout);
      if (health.statusCode == 404 ||
          health.statusCode != 200 ||
          !_isHelperHealth(health.body)) {
        return const AlbumNasHelperStatus(
          availability: AlbumNasHelperAvailability.notInstalled,
          message: '目标地址未发现 Unraider NAS 助手',
        );
      }
      final response = await _httpClient
          .get(_uri('/api/v1/capabilities'), headers: _headers)
          .timeout(probeTimeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const AlbumNasHelperStatus(
          availability: AlbumNasHelperAvailability.unauthorized,
          message: 'NAS 助手令牌无效，请检查访问令牌',
        );
      }
      if (response.statusCode != 200) {
        return AlbumNasHelperStatus(
          availability: AlbumNasHelperAvailability.offline,
          message: 'NAS 助手响应异常（HTTP ${response.statusCode}）',
        );
      }
      final value = _jsonObject(response.body);
      final apiVersion = (value['apiVersion'] as num?)?.toInt();
      if (apiVersion != supportedApiVersion) {
        return AlbumNasHelperStatus(
          availability: AlbumNasHelperAvailability.incompatible,
          message:
              'NAS 助手 API 版本不兼容（服务端 ${apiVersion ?? '未知'}，客户端 $supportedApiVersion）',
          helperVersion: value['helperVersion']?.toString(),
        );
      }
      final capabilities =
          (value['capabilities'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => item.toString())
              .toSet();
      if (!capabilities.contains('asset-index-v1')) {
        return AlbumNasHelperStatus(
          availability: AlbumNasHelperAvailability.incompatible,
          message: 'NAS 助手缺少客户端所需的资产索引能力',
          helperVersion: value['helperVersion']?.toString(),
          capabilities: capabilities,
        );
      }
      return AlbumNasHelperStatus(
        availability: AlbumNasHelperAvailability.ready,
        message: 'NAS 助手在线，可以使用历史索引和批量派生作业',
        helperVersion: value['helperVersion']?.toString(),
        capabilities: capabilities,
        roots: (value['roots'] as List<dynamic>? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(AlbumNasHelperRoot.fromJson)
            .toList(growable: false),
      );
    } on TimeoutException {
      return const AlbumNasHelperStatus(
        availability: AlbumNasHelperAvailability.offline,
        message: 'NAS 助手连接超时，已降级为纯客户端模式',
      );
    } on Object {
      return const AlbumNasHelperStatus(
        availability: AlbumNasHelperAvailability.offline,
        message: 'NAS 助手当前不可达，已降级为纯客户端模式',
      );
    }
  }

  Future<List<AlbumNasHelperAsset>> listAllAssets({
    required String prefix,
    int maximum = 100000,
  }) async {
    final assets = <AlbumNasHelperAsset>[];
    String? cursor;
    do {
      final query = <String, String>{
        'limit': '500',
        'prefix': prefix,
        if (cursor != null) 'cursor': cursor,
      };
      final response = await _httpClient
          .get(_uri('/api/v1/assets', query), headers: _headers)
          .timeout(requestTimeout);
      _requireSuccess(response);
      final value = _jsonObject(response.body);
      final page = (value['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(AlbumNasHelperAsset.fromJson)
          .where((asset) => asset.remotePath.isNotEmpty)
          .toList(growable: false);
      assets.addAll(page.take(maximum - assets.length));
      cursor = value['nextCursor']?.toString();
    } while (cursor != null && cursor.isNotEmpty && assets.length < maximum);
    return assets;
  }

  Future<AlbumNasHelperJob> submitJob({
    required String type,
    String? rootId,
    bool force = false,
    String? idempotencyKey,
  }) async {
    final response = await _httpClient
        .post(
          _uri('/api/v1/jobs'),
          headers: <String, String>{
            ..._headers,
            'Content-Type': 'application/json',
            if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
          },
          body: jsonEncode(<String, Object?>{
            'type': type,
            'payload': <String, Object?>{
              if (rootId != null && rootId.isNotEmpty) 'rootId': rootId,
              if (force) 'force': true,
            },
          }),
        )
        .timeout(requestTimeout);
    _requireSuccess(response);
    return AlbumNasHelperJob.fromJson(_jsonObject(response.body));
  }

  Future<AlbumNasHelperJob> job(String id) async {
    final response = await _httpClient
        .get(_uri('/api/v1/jobs/${Uri.encodeComponent(id)}'), headers: _headers)
        .timeout(requestTimeout);
    _requireSuccess(response);
    return AlbumNasHelperJob.fromJson(_jsonObject(response.body));
  }

  Future<AlbumNasHelperJob> retryJob(String id) => _jobAction(id, 'retry');

  Future<AlbumNasHelperJob> cancelJob(String id) => _jobAction(id, 'cancel');

  Future<AlbumNasHelperJob> _jobAction(String id, String action) async {
    final response = await _httpClient
        .post(
          _uri('/api/v1/jobs/${Uri.encodeComponent(id)}/$action'),
          headers: _headers,
        )
        .timeout(requestTimeout);
    _requireSuccess(response);
    return AlbumNasHelperJob.fromJson(_jsonObject(response.body));
  }

  Map<String, String> get _headers => <String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
    return withScheme.replaceAll(RegExp(r'/+$'), '');
  }

  static bool _isHelperHealth(String body) {
    try {
      return _jsonObject(body)['service'] == 'unraider-album-helper';
    } on FormatException {
      return false;
    }
  }

  static Map<String, dynamic> _jsonObject(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('NAS 助手返回了无效 JSON 对象');
    }
    return decoded;
  }

  static void _requireSuccess(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var message = 'NAS 助手请求失败（HTTP ${response.statusCode}）';
    try {
      final error = _jsonObject(response.body)['error'];
      if (error is Map<String, dynamic> && error['message'] != null) {
        message = error['message'].toString();
      }
    } on Object {
      // Keep the status-based message when the response is not JSON.
    }
    throw AlbumNasHelperException(message, statusCode: response.statusCode);
  }
}

class AlbumNasHelperException implements Exception {
  const AlbumNasHelperException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}
