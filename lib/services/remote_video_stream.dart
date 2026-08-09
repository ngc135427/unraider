import 'package:video_player/video_player.dart';

import 'app_logger.dart';
import 'media_cache.dart';
import 'unraid_client.dart';

/// Opens a remote video over FileBrowser Quantum WebDAV/HTTP Range.
/// Returns null when direct streaming is unavailable so callers can fall back
/// to the SMB/SFTP progressive cache.
class RemoteVideoStream {
  RemoteVideoStream._();

  static const _openTimeout = Duration(seconds: 15);

  static Future<VideoPlayerController?> tryOpen({
    required UnraidClient client,
    required UnraidFileEntry entry,
  }) async {
    final uri = client.webDavFileUri(entry.path);
    if (uri == null) {
      return null;
    }
    try {
      final probe = await client
          .fetchFileRange(entry.path, offset: 0, length: 2048)
          .timeout(const Duration(seconds: 5));
      if (hasShiftedTransportStream(probe)) {
        await AppLogger.log(
          'video_http_stream_shifted_ts_fallback path=${entry.path}',
        );
        return null;
      }
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'video_http_stream_probe_fallback path=${entry.path}',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: client.webDavHeaders,
    );
    try {
      await controller.initialize().timeout(_openTimeout);
      await AppLogger.log(
        'video_http_stream_ready path=${entry.path} uri=$uri',
      );
      return controller;
    } on Object catch (error, stackTrace) {
      await AppLogger.log(
        'video_http_stream_fallback path=${entry.path} uri=$uri',
        error: error,
        stackTrace: stackTrace,
      );
      await controller.dispose();
      return null;
    }
  }

  static bool hasShiftedTransportStream(List<int> bytes) {
    const packetSize = 188;
    if (bytes.length < packetSize * 6 || bytes.first == 0x47) {
      return false;
    }
    for (var packet = 1; packet <= 5; packet++) {
      if (bytes[packet * packetSize] != 0x47) {
        return false;
      }
    }
    return true;
  }

  static Future<VideoPlayerController> openCached({
    required ProgressiveMediaHandle handle,
    required UnraidFileEntry entry,
  }) async {
    await handle.ready;
    await MediaCache.repairVideoHeader(handle.file);
    var controller = VideoPlayerController.file(handle.file);
    try {
      await controller.initialize();
      return controller;
    } on Object catch (firstError, firstStackTrace) {
      await controller.dispose();
      final done = handle.done;
      if (done == null) {
        rethrow;
      }
      await AppLogger.log(
        'video_progressive_wait_for_complete path=${entry.path}',
        error: firstError,
        stackTrace: firstStackTrace,
      );
      await done;
      await MediaCache.repairVideoHeader(handle.file);
      controller = VideoPlayerController.file(handle.file);
      try {
        await controller.initialize();
        return controller;
      } on Object catch (error, stackTrace) {
        await controller.dispose();
        await AppLogger.log(
          'video_cached_file_invalid path=${entry.path}',
          error: error,
          stackTrace: stackTrace,
        );
        throw const UnraidClientException(
          '视频格式无法识别，文件可能损坏或扩展名与实际格式不一致',
        );
      }
    }
  }
}
