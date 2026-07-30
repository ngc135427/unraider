import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

import 'unraid_client.dart';

/// Progressive Unraid audio source that serves byte ranges over SFTP/SMB.
///
/// just_audio's local proxy issues range requests while decoding; each request
/// maps onto [UnraidClient.fetchFileRange] so playback can start without a
/// full-file download.
// ignore_for_file: experimental_member_use
class UnraidStreamingAudioSource extends StreamAudioSource {
  UnraidStreamingAudioSource({
    required this.client,
    required this.entry,
    this.contentType,
    super.tag,
  }) : sourceLength = entry.sizeBytes > 0 ? entry.sizeBytes : null;

  final UnraidClient client;
  final UnraidFileEntry entry;
  final String? contentType;
  final int? sourceLength;

  static const defaultChunkBytes = 256 * 1024;

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final total = sourceLength;
    final effectiveStart = start ?? 0;
    if (total != null && effectiveStart >= total) {
      return StreamAudioResponse(
        sourceLength: total,
        contentLength: 0,
        offset: effectiveStart,
        stream: const Stream<List<int>>.empty(),
        contentType: contentType ?? guessAudioContentType(entry.name),
      );
    }

    final effectiveEnd = end ?? total;
    if (effectiveEnd != null && effectiveEnd <= effectiveStart) {
      return StreamAudioResponse(
        sourceLength: total,
        contentLength: 0,
        offset: effectiveStart,
        stream: const Stream<List<int>>.empty(),
        contentType: contentType ?? guessAudioContentType(entry.name),
      );
    }

    final length = effectiveEnd == null
        ? (total == null ? defaultChunkBytes : total - effectiveStart)
        : effectiveEnd - effectiveStart;

    final bytes = await client.fetchFileRange(
      entry.path,
      offset: effectiveStart,
      length: length,
    );

    return StreamAudioResponse(
      sourceLength: total ?? (effectiveStart + bytes.length),
      contentLength: bytes.length,
      offset: effectiveStart,
      stream: Stream<List<int>>.value(bytes),
      contentType: contentType ?? guessAudioContentType(entry.name),
    );
  }
}

String guessAudioContentType(String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.mp3')) return 'audio/mpeg';
  if (lower.endsWith('.flac')) return 'audio/flac';
  if (lower.endsWith('.m4a') || lower.endsWith('.aac')) return 'audio/mp4';
  if (lower.endsWith('.wav')) return 'audio/wav';
  if (lower.endsWith('.ogg') || lower.endsWith('.oga')) return 'audio/ogg';
  if (lower.endsWith('.opus')) return 'audio/opus';
  if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'audio/aiff';
  if (lower.endsWith('.wma')) return 'audio/x-ms-wma';
  return 'audio/mpeg';
}

/// Progressive media materializer for [video_player] (needs a local file path).
///
/// Downloads the remote file in ordered chunks into [targetFile]. Completes
/// [ready] once enough leading bytes exist for container probing, then keeps
/// filling the remainder in the background.
class ProgressiveMediaFile {
  ProgressiveMediaFile({
    required this.client,
    required this.remotePath,
    required this.targetFile,
    required this.expectedSizeBytes,
    this.chunkBytes = 512 * 1024,
    this.readyBytes = 1024 * 1024,
  });

  final UnraidClient client;
  final String remotePath;
  final File targetFile;
  final int expectedSizeBytes;
  final int chunkBytes;
  final int readyBytes;

  final _progress = StreamController<double>.broadcast();
  Stream<double> get progress => _progress.stream;

  Future<void>? _downloadFuture;
  int _written = 0;
  bool _readyCompleted = false;
  final Completer<void> _ready = Completer<void>();

  Future<void> get ready => _ready.future;
  Future<void>? get done => _downloadFuture;
  int get writtenBytes => _written;

  Future<void> start() {
    return _downloadFuture ??= _run();
  }

  void _markReady() {
    if (_readyCompleted) {
      return;
    }
    _readyCompleted = true;
    if (!_ready.isCompleted) {
      _ready.complete();
    }
  }

  Future<void> _run() async {
    try {
      // Resume partial downloads when the temp file already has content.
      var offset = 0;
      if (await targetFile.exists()) {
        offset = await targetFile.length();
        _written = offset;
        final total = expectedSizeBytes > 0 ? expectedSizeBytes : null;
        if (offset >= readyBytes || (total != null && offset >= total)) {
          _markReady();
        }
        if (total != null && offset >= total && total > 0) {
          if (!_progress.isClosed) {
            _progress.add(1);
          }
          _markReady();
          return;
        }
      }

      final sink = await targetFile.open(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      try {
        final total = expectedSizeBytes > 0 ? expectedSizeBytes : null;
        while (true) {
          final remaining = total == null ? chunkBytes : total - offset;
          if (total != null && remaining <= 0) {
            break;
          }
          final length = total == null
              ? chunkBytes
              : (remaining < chunkBytes ? remaining : chunkBytes);
          final chunk = await client.fetchFileRange(
            remotePath,
            offset: offset,
            length: length,
          );
          if (chunk.isEmpty) {
            break;
          }
          await sink.writeFrom(chunk);
          offset += chunk.length;
          _written = offset;
          if (total != null && total > 0 && !_progress.isClosed) {
            _progress.add((offset / total).clamp(0.0, 1.0));
          }
          if (offset >= readyBytes ||
              (total != null && offset >= total) ||
              (total == null && chunk.length < chunkBytes)) {
            _markReady();
          }
          if (total != null && offset >= total) {
            break;
          }
          if (total != null && chunk.length < length) {
            break;
          }
          if (total == null && chunk.length < chunkBytes) {
            break;
          }
        }
        _markReady();
        if (!_progress.isClosed) {
          _progress.add(1);
        }
      } finally {
        await sink.close();
      }
    } catch (error, stackTrace) {
      if (!_ready.isCompleted) {
        _ready.completeError(error, stackTrace);
      }
      rethrow;
    } finally {
      await _progress.close();
    }
  }
}
