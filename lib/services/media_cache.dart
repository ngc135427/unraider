import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'local_media_store.dart';
import 'streaming_audio_source.dart';
import 'unraid_client.dart';

/// Disk-backed media cache with range streaming (no hard file-size ceiling).
///
/// Full-resolution stills and videos are written chunk-by-chunk to temp files
/// so previews never need the entire payload resident in Dart heap memory.
class MediaCache {
  MediaCache._();

  static const defaultChunkBytes = 512 * 1024;
  /// How many completed cache files to keep indexed in-process.
  static const _maxIndexEntries = 32;

  static final Map<String, Future<File>> _inflight = <String, Future<File>>{};
  static final Map<String, File> _ready = <String, File>{};
  static final Map<String, ProgressiveMediaFile> _progressive =
      <String, ProgressiveMediaFile>{};

  static Future<Directory> cacheDir() async {
    final root = await getTemporaryDirectory();
    final dir = Directory('${root.path}/unraider_media_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Fully materialize a remote path to a local file via range reads.
  ///
  /// Suitable for images ([Image.file]) where the decoder needs a complete
  /// file. There is no byte-size reject — only disk and network limits apply.
  static Future<File> ensureLocalFile({
    required UnraidClient client,
    required String remotePath,
    int? expectedSizeBytes,
    String? fileName,
    void Function(double progress)? onProgress,
  }) async {
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持媒体缓存');
    }

    final key = remotePath;
    final ready = _ready[key];
    if (ready != null && await ready.exists()) {
      if (expectedSizeBytes == null ||
          expectedSizeBytes <= 0 ||
          await ready.length() == expectedSizeBytes) {
        onProgress?.call(1);
        return ready;
      }
    }

    final inflight = _inflight[key];
    if (inflight != null) {
      final file = await inflight;
      onProgress?.call(1);
      return file;
    }

    final future = _downloadComplete(
      client: client,
      remotePath: remotePath,
      expectedSizeBytes: expectedSizeBytes,
      fileName: fileName,
      onProgress: onProgress,
    );
    _inflight[key] = future;
    try {
      final file = await future;
      _storeReady(key, file);
      return file;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  /// Start (or resume) a progressive download that becomes ready after the
  /// first [readyBytes]. Used for video so playback can begin early.
  /// Choose a start-play threshold from file size so small clips start faster
  /// and large videos still get a usable container probe buffer.
  static int adaptiveReadyBytes(int? expectedSizeBytes) {
    final size = expectedSizeBytes ?? 0;
    if (size <= 0) {
      return 1024 * 1024;
    }
    if (size < 2 * 1024 * 1024) {
      // Tiny clips: wait for most of the file (min 256 KB).
      return size < 256 * 1024 ? size : (size * 3) ~/ 4;
    }
    if (size < 32 * 1024 * 1024) {
      return 1024 * 1024;
    }
    if (size < 200 * 1024 * 1024) {
      return 2 * 1024 * 1024;
    }
    return 4 * 1024 * 1024;
  }

  static Future<ProgressiveMediaHandle> ensureProgressive({
    required UnraidClient client,
    required String remotePath,
    int? expectedSizeBytes,
    String? fileName,
    int? readyBytes,
  }) async {
    final resolvedReady =
        readyBytes ?? adaptiveReadyBytes(expectedSizeBytes);
    if (kIsWeb) {
      throw const UnraidClientException('Web 端暂不支持媒体缓存');
    }

    final key = 'prog:$remotePath';
    final existing = _progressive[key];
    if (existing != null) {
      unawaited(existing.start());
      return ProgressiveMediaHandle(existing);
    }

    // Prefer a completed full cache hit when available.
    final ready = _ready[remotePath];
    if (ready != null && await ready.exists()) {
      if (expectedSizeBytes == null ||
          expectedSizeBytes <= 0 ||
          await ready.length() == expectedSizeBytes) {
        return ProgressiveMediaHandle.completed(ready);
      }
    }

    final dir = await cacheDir();
    final ext = _extensionOf(fileName ?? remotePath);
    final digest = _stableKey(remotePath);
    final target = File('${dir.path}/stream_$digest$ext');
    final progressive = ProgressiveMediaFile(
      client: client,
      remotePath: remotePath,
      targetFile: target,
      expectedSizeBytes: expectedSizeBytes ?? 0,
      readyBytes: resolvedReady,
    );
    _progressive[key] = progressive;
    unawaited(
      progressive.start().then((_) async {
        if (await target.exists()) {
          _storeReady(remotePath, target);
        }
      }, onError: (Object _) {
        _progressive.remove(key);
      }),
    );
    return ProgressiveMediaHandle(progressive);
  }

  /// Stream a local MediaStore URI to a temp file via chunked reads.
  static Future<File> ensureLocalUriFile({
    required String uri,
    required String preferredName,
    int? expectedSizeBytes,
    void Function(double progress)? onProgress,
  }) async {
    if (kIsWeb) {
      throw const LocalMediaException('Web 端暂不支持本地媒体缓存');
    }
    final key = 'local:$uri';
    final ready = _ready[key];
    if (ready != null && await ready.exists()) {
      onProgress?.call(1);
      return ready;
    }
    final inflight = _inflight[key];
    if (inflight != null) {
      final file = await inflight;
      onProgress?.call(1);
      return file;
    }

    final future = _downloadLocalUri(
      uri: uri,
      preferredName: preferredName,
      expectedSizeBytes: expectedSizeBytes,
      onProgress: onProgress,
    );
    _inflight[key] = future;
    try {
      final file = await future;
      _storeReady(key, file);
      return file;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  static Future<File> _downloadComplete({
    required UnraidClient client,
    required String remotePath,
    int? expectedSizeBytes,
    String? fileName,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await cacheDir();
    final ext = _extensionOf(fileName ?? remotePath);
    final digest = _stableKey(remotePath);
    final target = File('${dir.path}/$digest$ext');
    if (await target.exists()) {
      final length = await target.length();
      if (expectedSizeBytes == null ||
          expectedSizeBytes <= 0 ||
          length == expectedSizeBytes) {
        onProgress?.call(1);
        return target;
      }
      await target.delete();
    }

    final temp = File('${target.path}.part');
    if (await temp.exists()) {
      await temp.delete();
    }

    final progressive = ProgressiveMediaFile(
      client: client,
      remotePath: remotePath,
      targetFile: temp,
      expectedSizeBytes: expectedSizeBytes ?? 0,
      // Images need the full file before decode — ready == complete.
      readyBytes: expectedSizeBytes != null && expectedSizeBytes > 0
          ? expectedSizeBytes
          : 1 << 30,
      chunkBytes: defaultChunkBytes,
    );
    if (onProgress != null) {
      progressive.progress.listen(onProgress);
    }
    await progressive.start();
    await progressive.ready;
    // Wait until the download loop finishes writing the last chunk.
    await progressive.done;
    if (!await temp.exists() || await temp.length() == 0) {
      throw const UnraidClientException('远程文件为空');
    }
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
    onProgress?.call(1);
    return target;
  }

  static Future<File> _downloadLocalUri({
    required String uri,
    required String preferredName,
    int? expectedSizeBytes,
    void Function(double progress)? onProgress,
  }) async {
    final dir = await cacheDir();
    final digest = _stableKey(uri);
    final ext = _extensionOf(preferredName);
    final target = File('${dir.path}/local_$digest$ext');
    if (await target.exists()) {
      if (expectedSizeBytes == null ||
          expectedSizeBytes <= 0 ||
          await target.length() == expectedSizeBytes) {
        onProgress?.call(1);
        return target;
      }
      await target.delete();
    }

    final temp = File('${target.path}.part');
    final sink = await temp.open(mode: FileMode.write);
    try {
      var offset = 0;
      final total = expectedSizeBytes != null && expectedSizeBytes > 0
          ? expectedSizeBytes
          : null;
      while (true) {
        final remaining = total == null ? defaultChunkBytes : total - offset;
        if (total != null && remaining <= 0) {
          break;
        }
        final length = total == null
            ? defaultChunkBytes
            : (remaining < defaultChunkBytes ? remaining : defaultChunkBytes);
        final chunk = await LocalMediaStore.readChunk(
          uri: uri,
          offset: offset,
          length: length,
        );
        if (chunk.isEmpty) {
          break;
        }
        await sink.writeFrom(chunk);
        offset += chunk.length;
        if (total != null && total > 0) {
          onProgress?.call((offset / total).clamp(0.0, 1.0));
        }
        if (total != null && offset >= total) {
          break;
        }
        if (chunk.length < length) {
          break;
        }
      }
      if (offset == 0) {
        throw const LocalMediaException('无法读取本机媒体文件');
      }
    } finally {
      await sink.close();
    }
    if (await target.exists()) {
      await target.delete();
    }
    await temp.rename(target.path);
    onProgress?.call(1);
    return target;
  }

  static void _storeReady(String key, File file) {
    _ready.remove(key);
    if (_ready.length >= _maxIndexEntries) {
      _ready.remove(_ready.keys.first);
    }
    _ready[key] = file;
  }

  static String _stableKey(String path) {
    var hash = 2166136261;
    for (final unit in path.codeUnits) {
      hash ^= unit;
      hash = (hash * 16777619) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  static String _extensionOf(String path) {
    final slash = path.replaceAll(r'\', '/').lastIndexOf('/');
    final name = slash >= 0 ? path.substring(slash + 1) : path;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) {
      return '';
    }
    final ext = name.substring(dot).toLowerCase();
    if (ext.length > 8) {
      return '';
    }
    return ext;
  }
}

/// Thin wrapper so callers can await [ready] and observe [progress].
class ProgressiveMediaHandle {
  ProgressiveMediaHandle(ProgressiveMediaFile progressive)
      : _progressive = progressive,
        file = progressive.targetFile,
        _completedFile = null;

  ProgressiveMediaHandle.completed(File completed)
      : _progressive = null,
        file = completed,
        _completedFile = completed;

  final ProgressiveMediaFile? _progressive;
  final File? _completedFile;
  final File file;

  Stream<double> get progress =>
      _progressive?.progress ?? Stream<double>.value(1);

  Future<void> get ready async {
    final progressive = _progressive;
    if (progressive == null) {
      return;
    }
    await progressive.start();
    await progressive.ready;
  }

  Future<void>? get done => _progressive?.done;

  int get writtenBytes =>
      _progressive?.writtenBytes ?? (_completedFile?.lengthSync() ?? 0);
}

String formatByteSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Writes [bytes] into a unique temp file under the media cache directory.
Future<File> writeTempMediaBytes({
  required Uint8List bytes,
  required String preferredName,
}) async {
  final dir = await MediaCache.cacheDir();
  final safe = preferredName
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
      .replaceAll(RegExp(r'\s+'), '_');
  final file = File(
    '${dir.path}/local_${DateTime.now().microsecondsSinceEpoch}_$safe',
  );
  await file.writeAsBytes(bytes, flush: true);
  return file;
}
