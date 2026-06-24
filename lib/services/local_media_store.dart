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

  static Future<List<LocalMediaAsset>> listMedia({
    int limit = 0,
    String? bucketId,
  }) async {
    final result = await _channel.invokeMethod<List<dynamic>>('listMedia', {
      'limit': limit,
      if (bucketId != null && bucketId.isNotEmpty) 'bucketId': bucketId,
    });
    return (result ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(LocalMediaAsset.fromMap)
        .toList(growable: false);
  }

  static Future<List<LocalMediaAsset>> listImages({
    int limit = 0,
    String? bucketId,
  }) {
    return listMedia(limit: limit, bucketId: bucketId);
  }

  static Future<List<LocalMediaBucket>> listBuckets() async {
    final result = await _channel.invokeMethod<List<dynamic>>('listBuckets');
    return (result ?? const <dynamic>[])
        .whereType<Map<dynamic, dynamic>>()
        .map(LocalMediaBucket.fromMap)
        .toList(growable: false);
  }

  static Future<Uint8List?> loadThumbnail(String uri) async {
    return _channel.invokeMethod<Uint8List>('loadThumbnail', {
      'uri': uri,
      'size': 320,
    });
  }

  static Future<Uint8List> readChunk({
    required String uri,
    required int offset,
    required int length,
  }) async {
    final bytes = await _channel.invokeMethod<Uint8List>('readChunk', {
      'uri': uri,
      'offset': offset,
      'length': length,
    });
    return bytes ?? Uint8List(0);
  }
}
