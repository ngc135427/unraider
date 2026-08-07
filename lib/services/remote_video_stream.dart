import 'package:video_player/video_player.dart';

import 'app_logger.dart';
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
}
