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
  });

  factory LocalMediaAsset.fromMap(Map<dynamic, dynamic> map) {
    return LocalMediaAsset(
      id: map['id']?.toString() ?? '',
      uri: map['uri']?.toString() ?? '',
      name: map['name']?.toString() ?? '',
      bucketId: map['bucketId']?.toString() ?? '',
      bucketName: map['bucketName']?.toString() ?? '本机相册',
      dateModified: DateTime.fromMillisecondsSinceEpoch(
        (map['dateModifiedMs'] as num?)?.toInt() ?? 0,
      ),
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      isVideo: map['isVideo'] == true,
    );
  }

  final String id;
  final String uri;
  final String name;
  final String bucketId;
  final String bucketName;
  final DateTime dateModified;
  final int sizeBytes;
  final bool isVideo;
}

class LocalMediaBucket {
  const LocalMediaBucket({
    required this.id,
    required this.name,
    required this.count,
  });

  factory LocalMediaBucket.fromMap(Map<dynamic, dynamic> map) {
    return LocalMediaBucket(
      id: map['id']?.toString() ?? '',
      name: map['name']?.toString() ?? '本机相册',
      count: (map['count'] as num?)?.toInt() ?? 0,
    );
  }

  final String id;
  final String name;
  final int count;
}

class LocalMediaStore {
  static const channelName = 'unraider/local_media';
  static const _channel = MethodChannel(channelName);
  static const _listCacheTtl = Duration(seconds: 30);
  static const _maxThumbnailCacheEntries = 96;

  static final Map<String, _LocalListCacheEntry<List<LocalMediaAsset>>>
      _mediaListCache =
      <String, _LocalListCacheEntry<List<LocalMediaAsset>>>{};
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
  }) async {
    final key = '${bucketId ?? ''}|$limit';
    final cached = _readMediaListCache(key);
    if (cached != null) {
      return cached;
    }
    // Coalesce concurrent album/open taps so native MediaStore is hit once.
    final inflight = _mediaListInflight[key];
    if (inflight != null) {
      return inflight;
    }

    final future = _listMediaUncached(limit: limit, bucketId: bucketId);
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
  }) async {
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listMedia', {
        'limit': limit,
        if (bucketId != null && bucketId.isNotEmpty) 'bucketId': bucketId,
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
  }) {
    return listMedia(limit: limit, bucketId: bucketId);
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

  static Future<Uint8List?> loadThumbnail(String uri) {
    if (uri.isEmpty) {
      return Future<Uint8List?>.value();
    }
    final cached = _thumbnailCache.remove(uri);
    if (cached != null) {
      // LRU touch so hot local tiles outlive cold ones under the cap.
      _thumbnailCache[uri] = cached;
      return cached;
    }

    final future = _loadThumbnailUncached(uri);
    if (_thumbnailCache.length >= _maxThumbnailCacheEntries) {
      _thumbnailCache.remove(_thumbnailCache.keys.first);
    }
    _thumbnailCache[uri] = future;
    return future;
  }

  static Future<Uint8List?> _loadThumbnailUncached(String uri) async {
    try {
      return await _channel.invokeMethod<Uint8List>('loadThumbnail', {
        'uri': uri,
        'size': 320,
      });
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
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
