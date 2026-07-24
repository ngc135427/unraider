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
  static _LocalListCacheEntry<List<LocalMediaBucket>>? _bucketCache;
  static final Map<String, Future<Uint8List?>> _thumbnailCache =
      <String, Future<Uint8List?>>{};

  static Future<List<LocalMediaAsset>> listMedia({
    int limit = 0,
    String? bucketId,
  }) async {
    final key = '${bucketId ?? ''}|$limit';
    final cached = _mediaListCache[key];
    if (cached != null &&
        DateTime.now().difference(cached.fetchedAt) < _listCacheTtl) {
      return cached.value;
    }

    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listMedia', {
        'limit': limit,
        if (bucketId != null && bucketId.isNotEmpty) 'bucketId': bucketId,
      });
      final media = (result ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(LocalMediaAsset.fromMap)
          .toList(growable: false);
      _mediaListCache[key] = _LocalListCacheEntry(
        value: media,
        fetchedAt: DateTime.now(),
      );
      return media;
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

    try {
      final result = await _channel.invokeMethod<List<dynamic>>('listBuckets');
      final buckets = (result ?? const <dynamic>[])
          .whereType<Map<dynamic, dynamic>>()
          .map(LocalMediaBucket.fromMap)
          .toList(growable: false);
      _bucketCache = _LocalListCacheEntry(
        value: buckets,
        fetchedAt: DateTime.now(),
      );
      return buckets;
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
    final cached = _thumbnailCache[uri];
    if (cached != null) {
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
    _bucketCache = null;
    // Keep thumbnail cache — bytes are still valid for the same URI.
  }

  static Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    try {
      final bytes = await _channel.invokeMethod<Uint8List>('readChunk', {
        'uri': uri,
        'offset': offset,
        'length': length,
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
