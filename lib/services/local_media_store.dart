import 'package:flutter/services.dart';

class LocalMediaAsset {
  const LocalMediaAsset({
    required this.id,
    required this.uri,
    required this.name,
    required this.bucketId,
    required this.bucketName,
    required this.dateModified,
    required this.sizeBytes,
    required this.isVideo,
    this.mediaStoreId = '',
    this.volumeName = 'external',
    this.relativePath = '',
    this.mimeType = '',
    DateTime? dateAdded,
    this.captureDate,
    this.width = 0,
    this.height = 0,
    this.duration = Duration.zero,
    this.orientation = 0,
  }) : dateAdded = dateAdded ?? dateModified;

  factory LocalMediaAsset.fromMap(Map<dynamic, dynamic> map) {
    final modifiedMs = (map['dateModifiedMs'] as num?)?.toInt() ?? 0;
    return LocalMediaAsset(
      id: map['id']?.toString() ?? '',
      mediaStoreId: map['mediaStoreId']?.toString() ??
          _mediaStoreIdFromStableId(map['id']?.toString() ?? ''),
      uri: map['uri']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      bucketId: map['bucketId']?.toString() ?? '',
      bucketName: map['bucketName']?.toString() ?? '本机相册',
      volumeName: map['volumeName']?.toString() ?? 'external',
      relativePath: map['relativePath']?.toString() ?? '',
      mimeType: map['mimeType']?.toString() ?? '',
      dateAdded: _dateTimeFromMilliseconds(map['dateAddedMs'], modifiedMs),
      dateModified: DateTime.fromMillisecondsSinceEpoch(modifiedMs),
      captureDate: _nullableDateTimeFromMilliseconds(map['captureTimeMs']),
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      isVideo: map['isVideo'] == true,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      duration: Duration(
        milliseconds: (map['durationMs'] as num?)?.toInt() ?? 0,
      ),
      orientation: (map['orientation'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String mediaStoreId;
  final String uri;
  final String name;
  final String bucketId;
  final String bucketName;
  final String volumeName;
  final String relativePath;
  final String mimeType;
  final DateTime dateAdded;
  final DateTime dateModified;
  final DateTime? captureDate;
  final int sizeBytes;
  final bool isVideo;
  final int width;
  final int height;
  final Duration duration;
  final int orientation;
}

class LocalMediaBucket {
  const LocalMediaBucket({
    required this.id,
    required this.name,
    required this.count,
    this.volumeName = 'external',
    this.relativePath = '',
  });

  factory LocalMediaBucket.fromMap(Map<dynamic, dynamic> map) {
    return LocalMediaBucket(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '本机相册',
      count: (map['count'] as num?)?.toInt() ?? 0,
      volumeName: map['volumeName']?.toString() ?? 'external',
      relativePath: map['relativePath']?.toString() ?? '',
    );
  }

  final String id;
  final String name;
  final int count;
  final String volumeName;
  final String relativePath;
}

class LocalMediaStore {
  static const channelName = 'unraider/local_media';
  static const _channel = MethodChannel(channelName);
  static const _listCacheTtl = Duration(seconds: 30);
  static const _maxThumbnailCacheEntries = 96;

  static final Map<String, _LocalListCacheEntry<List<LocalMediaAsset>>>
      _mediaListCache = <String, _LocalListCacheEntry<List<LocalMediaAsset>>>{};
  static final Map<String, Future<List<LocalMediaAsset>>> _mediaListInflight =
      <String, Future<List<LocalMediaAsset>>>{};
  static _LocalListCacheEntry<List<LocalMediaBucket>>? _bucketCache;
  static Future<List<LocalMediaBucket>>? _bucketInflight;
  static final Map<String, Future<Uint8List?>> _thumbnailCache =
      <String, Future<Uint8List?>>{};

  static const _maxMediaListCacheEntries = 8;

  static Future<List<LocalMediaAsset>> listMedia({
    int limit = 0,
    String? bucketId,
    int? modifiedAfterMs,
  }) async {
    final key = '${bucketId ?? ''}|$limit|${modifiedAfterMs ?? ''}';
    final cached = _readMediaListCache(key);
    if (cached != null) {
      return cached;
    }
    // Coalesce concurrent album/open taps so native MediaStore is hit once.
    final inflight = _mediaListInflight[key];
    if (inflight != null) {
      return inflight;
    }

    final future = _listMediaUncached(
      limit: limit,
      bucketId: bucketId,
      modifiedAfterMs: modifiedAfterMs,
    );
    _mediaListInflight[key] = future;
    try {
      final media = await future;
      _storeMediaListCache(key, media);
      return media;
    } finally {
      if (identical(_mediaListInflight[key], future)) {
        _mediaListInflight.remove(key);
      }
    }
  }

  static List<LocalMediaAsset>? _readMediaListCache(String key) {
    final cached = _mediaListCache[key];
    if (cached == null) {
      return null;
    }
    if (DateTime.now().difference(cached.fetchedAt) >= _listCacheTtl) {
      _mediaListCache.remove(key);
      return null;
    }
    // LRU touch for frequently reopened album lists.
    _mediaListCache.remove(key);
    _mediaListCache[key] = cached;
    return cached.value;
  }

  static void _storeMediaListCache(String key, List<LocalMediaAsset> media) {
    _mediaListCache.remove(key);
    if (_mediaListCache.length >= _maxMediaListCacheEntries) {
      _mediaListCache.remove(_mediaListCache.keys.first);
    }
    _mediaListCache[key] = _LocalListCacheEntry(
      value: media,
      fetchedAt: DateTime.now(),
    );
  }

  static Future<List<LocalMediaAsset>> _listMediaUncached({
    required int limit,
    String? bucketId,
    int? modifiedAfterMs,
  }) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listMedia', {
        'limit': limit,
        if (bucketId != null && bucketId.isNotEmpty) 'bucketId': bucketId,
        if (modifiedAfterMs != null && modifiedAfterMs > 0)
          'modifiedAfterMs': modifiedAfterMs,
      });
      return (result ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(LocalMediaAsset.fromMap)
          .toList(growable: false);
    } on MissingPluginException {
      return const <LocalMediaAsset>[];
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '读取本机媒体失败');
    }
  }

  static Future<List<LocalMediaAsset>> listImages({
    int limit = 0,
    String? bucketId,
    int? modifiedAfterMs,
  }) {
    return listMedia(
      limit: limit,
      bucketId: bucketId,
      modifiedAfterMs: modifiedAfterMs,
    );
  }

  static Future<List<LocalMediaBucket>> listBuckets() async {
    final cached = _bucketCache;
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _listCacheTtl) {
      return cached.value;
    }
    final inflight = _bucketInflight;
    if (inflight != null) {
      return inflight;
    }

    final future = _listBucketsUncached();
    _bucketInflight = future;
    try {
      final buckets = await future;
      _bucketCache = _LocalListCacheEntry(
        value: buckets,
        fetchedAt: DateTime.now(),
      );
      return buckets;
    } finally {
      if (identical(_bucketInflight, future)) {
        _bucketInflight = null;
      }
    }
  }

  static Future<List<LocalMediaBucket>> _listBucketsUncached() async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listBuckets');
      return (result ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(LocalMediaBucket.fromMap)
          .toList(growable: false);
    } on MissingPluginException {
      return const <LocalMediaBucket>[];
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '读取相册分组失败');
    }
  }

  static Future<Uint8List?> loadThumbnail(String uri, {int size = 320}) {
    if (uri.isEmpty) {
      return Future<Uint8List?>.value();
    }
    final cacheKey = '$uri|$size';
    final cached = _thumbnailCache.remove(cacheKey);
    if (cached != null) {
      // LRU touch so hot local tiles outlive cold ones under the cap.
      _thumbnailCache[cacheKey] = cached;
      return cached;
    }

    final future = _loadThumbnailUncached(uri, size);
    if (_thumbnailCache.length >= _maxThumbnailCacheEntries) {
      _thumbnailCache.remove(_thumbnailCache.keys.first);
    }
    _thumbnailCache[cacheKey] = future;
    return future;
  }

  static Future<Uint8List?> _loadThumbnailUncached(String uri, int size) async {
    try {
      return await _channel.invokeMethod<Uint8List>('loadThumbnail', {
        'uri': uri,
        'size': size.clamp(64, 2048),
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  static Future<String> sha256(String uri) async {
    if (uri.isEmpty) throw const LocalMediaException('媒体 URI 为空');
    try {
      final value = await _channel.invokeMethod<String>('sha256', {'uri': uri});
      if (value == null || value.isEmpty) {
        throw const LocalMediaException('媒体哈希为空');
      }
      return value;
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '计算媒体哈希失败');
    }
  }

  static Future<LocalMediaDeleteResult> deleteMedia(List<String> uris) async {
    final unique = uris.where((uri) => uri.isNotEmpty).toSet().toList();
    if (unique.isEmpty) {
      return const LocalMediaDeleteResult(requested: 0, deleted: 0);
    }
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'deleteMedia',
        {'uris': unique},
      );
      invalidateCaches();
      return LocalMediaDeleteResult(
        requested: (result?['requested'] as num?)?.toInt() ?? unique.length,
        deleted: (result?['deleted'] as num?)?.toInt() ?? 0,
        cancelled: result?['cancelled'] == true,
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '删除媒体失败');
    }
  }

  /// Drop process-local caches after uploads/sync so the next open is fresh.
  static void invalidateCaches() {
    _mediaListCache.clear();
    _mediaListInflight.clear();
    _bucketCache = null;
    _bucketInflight = null;
    // Keep thumbnail cache — bytes are still valid for the same URI.
  }

  static Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    if (uri.isEmpty || length <= 0) {
      return Uint8List(0);
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readChunk', {
        'uri': uri,
        'offset': offset,
        'length': length,
      });
      return bytes ?? Uint8List(0);
    } on MissingPluginException {
      // Do not silently return empty bytes — callers (album sync) would then
      // treat a truncated read as a hard failure with a clearer message.
      throw const LocalMediaException(
        '本机媒体通道不可用，请确认在 Android 真机/模拟器上运行',
      );
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '读取媒体文件失败');
    }
  }

  /// Full-file read for local photo fullscreen preview.
  static Future<Uint8List> readBytes(String uri) async {
    if (uri.isEmpty) {
      return Uint8List(0);
    }
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readBytes', {
        'uri': uri,
      });
      return bytes ?? Uint8List(0);
    } on MissingPluginException {
      return Uint8List(0);
    } on PlatformException catch (error) {
      throw LocalMediaException(error.message ?? '读取媒体文件失败');
    }
  }
}

class LocalMediaDeleteResult {
  const LocalMediaDeleteResult({
    required this.requested,
    required this.deleted,
    this.cancelled = false,
  });

  final int requested;
  final int deleted;
  final bool cancelled;
}

String _mediaStoreIdFromStableId(String id) {
  final separator = id.lastIndexOf(':');
  return separator < 0 ? id : id.substring(separator + 1);
}

DateTime _dateTimeFromMilliseconds(Object? value, int fallbackMs) {
  final milliseconds = (value as num?)?.toInt() ?? fallbackMs;
  return DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

DateTime? _nullableDateTimeFromMilliseconds(Object? value) {
  final milliseconds = (value as num?)?.toInt() ?? 0;
  return milliseconds <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(milliseconds);
}

class LocalMediaException implements Exception {
  const LocalMediaException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _LocalListCacheEntry<T> {
  const _LocalListCacheEntry({
    required this.value,
    required this.fetchedAt,
  });

  final T value;
  final DateTime fetchedAt;
}
