import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'album_backup_path.dart';
import 'app_logger.dart';
import 'unraid_client.dart';

String albumThumbnailSidecarPath({
  required String remoteRoot,
  required String remotePath,
  required String versionKey,
}) {
  final key = albumStableKey('$remotePath\u0000$versionKey');
  final root = remoteRoot.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
  return '$root/.unraider/thumbnails/${key.substring(0, 2)}/$key.jpg';
}

class AlbumPreviewCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void _listen(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

class _AlbumPreviewOperation {
  int listeners = 0;
  bool cancelled = false;
  late Future<Uint8List?> future;
}

class AlbumPreviewCache {
  AlbumPreviewCache({
    this.byteBudget = 256 * 1024 * 1024,
    Future<Directory> Function()? directoryProvider,
  }) : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final int byteBudget;
  final Future<Directory> Function() _directoryProvider;
  final Map<String, _AlbumPreviewOperation> _inflight =
      <String, _AlbumPreviewOperation>{};
  int _activeGeneration = 0;
  final List<Completer<void>> _generationWaiters = <Completer<void>>[];

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    return Directory(path.join(base.path, 'album_previews'));
  }

  Future<Uint8List?> load({
    required UnraidClient client,
    required String destinationId,
    required String remoteRoot,
    required String remotePath,
    required String versionKey,
    required bool isVideo,
    AlbumPreviewCancellation? cancellation,
  }) {
    final key =
        albumStableKey('$destinationId\u0000$remotePath\u0000$versionKey');
    var operation = _inflight[key];
    if (operation == null || operation.cancelled) {
      operation = _AlbumPreviewOperation();
      final created = operation;
      created.future = _load(
        client: client,
        key: key,
        remoteRoot: remoteRoot,
        remotePath: remotePath,
        versionKey: versionKey,
        isVideo: isVideo,
        isCancelled: () => created.cancelled,
      );
      _inflight[key] = created;
      void cleanUp() {
        if (identical(_inflight[key], created)) _inflight.remove(key);
      }

      unawaited(created.future.then<void>(
        (_) => cleanUp(),
        onError: (Object _, StackTrace __) => cleanUp(),
      ));
      operation = created;
    }
    final selected = operation;
    selected.listeners += 1;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      selected.listeners -= 1;
      if (selected.listeners <= 0) selected.cancelled = true;
    }

    cancellation?._listen(release);
    return selected.future.then((bytes) {
      return cancellation?.isCancelled == true ? null : bytes;
    }).whenComplete(release);
  }

  Future<Uint8List?> _load({
    required UnraidClient client,
    required String key,
    required String remoteRoot,
    required String remotePath,
    required String versionKey,
    required bool isVideo,
    required bool Function() isCancelled,
  }) async {
    if (isCancelled()) return null;
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final file = File(path.join(directory.path, '$key.jpg'));
    if (await file.exists()) {
      if (isCancelled()) return null;
      await file.setLastModified(DateTime.now());
      return file.readAsBytes();
    }
    final sidecar = albumThumbnailSidecarPath(
      remoteRoot: remoteRoot,
      remotePath: remotePath,
      versionKey: versionKey,
    );
    try {
      final bytes = await client.fetchFileBytes(sidecar);
      if (bytes.isEmpty || isCancelled()) return null;
      await file.writeAsBytes(bytes, flush: true);
      unawaited(_prune(directory));
      return bytes;
    } on Object catch (error) {
      await AppLogger.log(
        'album_thumbnail_sidecar_miss path=$remotePath sidecar=$sidecar error=$error',
      );
      return _generateOnDemand(
        client: client,
        file: file,
        sidecarPath: sidecar,
        remotePath: remotePath,
        isVideo: isVideo,
        directory: directory,
        isCancelled: isCancelled,
      );
    }
  }

  Future<Uint8List?> _generateOnDemand({
    required UnraidClient client,
    required File file,
    required String sidecarPath,
    required String remotePath,
    required bool isVideo,
    required Directory directory,
    required bool Function() isCancelled,
  }) async {
    while (_activeGeneration >= 2) {
      if (isCancelled()) return null;
      final waiter = Completer<void>();
      _generationWaiters.add(waiter);
      await waiter.future;
    }
    if (isCancelled()) return null;
    _activeGeneration += 1;
    try {
      final bytes = await client.generateAlbumThumbnail(
        remotePath: remotePath,
        isVideo: isVideo,
      );
      if (bytes == null || bytes.isEmpty || isCancelled()) return null;
      await file.writeAsBytes(bytes, flush: true);
      unawaited(
        client
            .uploadBytesSafely(targetPath: sidecarPath, bytes: bytes)
            .catchError((Object error) {
          AppLogger.log(
            'album_thumbnail_sidecar_publish_failed path=$sidecarPath error=$error',
          );
        }),
      );
      unawaited(_prune(directory));
      return bytes;
    } finally {
      _activeGeneration -= 1;
      if (_generationWaiters.isNotEmpty) {
        _generationWaiters.removeAt(0).complete();
      }
    }
  }

  Future<void> store({
    required String destinationId,
    required String remotePath,
    required String versionKey,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return;
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    final key =
        albumStableKey('$destinationId\u0000$remotePath\u0000$versionKey');
    await File(path.join(directory.path, '$key.jpg'))
        .writeAsBytes(bytes, flush: true);
    await _prune(directory);
  }

  Future<void> clear() async {
    final directory = await _directoryProvider();
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Future<void> _prune(Directory directory) async {
    if (byteBudget <= 0 || !await directory.exists()) return;
    final files = await directory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    final entries = <({File file, int size, DateTime modified})>[];
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      total += stat.size;
      entries.add((file: file, size: stat.size, modified: stat.modified));
    }
    if (total <= byteBudget) return;
    entries.sort((a, b) => a.modified.compareTo(b.modified));
    for (final entry in entries) {
      if (total <= byteBudget) break;
      try {
        await entry.file.delete();
        total -= entry.size;
      } on FileSystemException {
        // Best-effort LRU pruning; a later pass can retry locked files.
      }
    }
  }
}
