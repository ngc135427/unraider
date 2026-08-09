import 'dart:async';

import 'package:flutter/foundation.dart';

import 'album_backup_models.dart';
import 'album_backup_repository.dart';
import 'app_logger.dart';
import 'local_media_store.dart';
import 'unraid_client.dart';

enum AlbumTransportKind { webDav, smb, sftp }

class AlbumTransportCapabilities {
  const AlbumTransportCapabilities({
    required this.kind,
    required this.atomicMove,
    required this.sizeVerification,
    required this.connectionReuse,
    required this.concurrentUploads,
    required this.resumableUpload,
  });

  final AlbumTransportKind kind;
  final bool atomicMove;
  final bool sizeVerification;
  final bool connectionReuse;
  final bool concurrentUploads;
  final bool resumableUpload;
}

class AlbumTransferMetrics {
  const AlbumTransferMetrics({
    required this.transport,
    required this.totalBytes,
    required this.elapsed,
    this.connect = Duration.zero,
    this.prepare = Duration.zero,
    this.upload = Duration.zero,
    this.verify = Duration.zero,
    this.commit = Duration.zero,
  });

  final AlbumTransportKind transport;
  final int totalBytes;
  final Duration elapsed;
  final Duration connect;
  final Duration prepare;
  final Duration upload;
  final Duration verify;
  final Duration commit;

  double get bytesPerSecond => elapsed.inMilliseconds <= 0
      ? 0
      : totalBytes * 1000 / elapsed.inMilliseconds;
}

class AlbumTransferResult {
  const AlbumTransferResult({
    required this.remoteSize,
    required this.metrics,
    this.remoteModifiedMs,
    this.etag,
  });

  final int remoteSize;
  final int? remoteModifiedMs;
  final String? etag;
  final AlbumTransferMetrics metrics;
}

class AlbumTransferProgress {
  const AlbumTransferProgress({
    required this.completed,
    required this.failed,
    required this.total,
    required this.active,
    required this.bytesTransferred,
    required this.elapsed,
    this.currentName,
    this.lastError,
    this.fallbackNotice,
  });

  final int completed;
  final int failed;
  final int total;
  final int active;
  final int bytesTransferred;
  final Duration elapsed;
  final String? currentName;
  final String? lastError;
  final String? fallbackNotice;

  double get bytesPerSecond => elapsed.inMilliseconds <= 0
      ? 0
      : bytesTransferred * 1000 / elapsed.inMilliseconds;
}

class AlbumTransferJob {
  const AlbumTransferJob({
    required this.record,
    required this.asset,
  });

  final AlbumBackupRecord record;
  final LocalMediaAsset asset;
}

class AlbumTransferRunResult {
  const AlbumTransferRunResult({
    required this.completed,
    required this.failed,
    required this.cancelled,
    this.fallbackNotice,
  });

  final int completed;
  final int failed;
  final bool cancelled;
  final String? fallbackNotice;
}

class AlbumTransferEngine {
  AlbumTransferEngine({
    required this.repository,
    required this.client,
    this.maxConcurrency = 2,
    this.onProgress,
  }) : assert(maxConcurrency > 0);

  final AlbumBackupRepository repository;
  final UnraidClient client;
  final int maxConcurrency;
  final ValueChanged<AlbumTransferProgress>? onProgress;

  bool _paused = false;
  bool _cancelled = false;
  Completer<void>? _resumeCompleter;

  void pause() {
    if (_paused) return;
    _paused = true;
    _resumeCompleter = Completer<void>();
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    final completer = _resumeCompleter;
    _resumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void cancel() {
    _cancelled = true;
    resume();
  }

  Future<AlbumTransferRunResult> run(List<AlbumTransferJob> jobs) async {
    if (jobs.isEmpty) {
      return const AlbumTransferRunResult(
        completed: 0,
        failed: 0,
        cancelled: false,
      );
    }
    _cancelled = false;
    final stopwatch = Stopwatch()..start();
    var cursor = 0;
    var completed = 0;
    var failed = 0;
    var active = 0;
    var bytesTransferred = 0;
    String? currentName;
    String? lastError;
    String? fallbackNotice;

    void publish() {
      onProgress?.call(
        AlbumTransferProgress(
          completed: completed,
          failed: failed,
          total: jobs.length,
          active: active,
          bytesTransferred: bytesTransferred,
          elapsed: stopwatch.elapsed,
          currentName: currentName,
          lastError: lastError,
          fallbackNotice: fallbackNotice,
        ),
      );
    }

    Future<void> worker() async {
      while (!_cancelled) {
        if (_paused) {
          await _resumeCompleter?.future;
          continue;
        }
        if (cursor >= jobs.length) return;
        final job = jobs[cursor++];
        active += 1;
        currentName = job.asset.name;
        publish();
        try {
          final expectedWebDav =
              client.webDavFileUri(job.record.remotePath) != null;
          final uploadResult = await client.uploadLocalMediaSafely(
            targetPath: job.record.remotePath,
            sourceUri: job.asset.uri,
            sizeBytes: job.asset.sizeBytes,
            modifiedDate: job.asset.dateModified,
          );
          await repository.transitionBackupState(
            assetId: job.record.assetId,
            destinationId: job.record.destinationId,
            state: AlbumBackupState.verifying,
            uploadedBytes: job.asset.sizeBytes,
          );
          await repository.transitionBackupState(
            assetId: job.record.assetId,
            destinationId: job.record.destinationId,
            state: AlbumBackupState.completed,
            uploadedBytes: uploadResult.remoteSize,
            remoteSize: uploadResult.remoteSize,
            remoteModifiedMs: uploadResult.remoteModifiedMs ??
                job.asset.dateModified.millisecondsSinceEpoch,
            remoteEtag: uploadResult.etag,
          );
          final transport = switch (uploadResult.transport.toLowerCase()) {
            'webdav' => AlbumTransportKind.webDav,
            'smb' => AlbumTransportKind.smb,
            _ => AlbumTransportKind.sftp,
          };
          if (expectedWebDav && transport != AlbumTransportKind.webDav) {
            fallbackNotice = switch (transport) {
              AlbumTransportKind.smb => 'WebDAV 连接失败，已自动降级为 SMB 上传',
              AlbumTransportKind.sftp => 'WebDAV/SMB 连接失败，已自动降级为 SFTP 上传',
              AlbumTransportKind.webDav => null,
            };
          }
          final metrics = AlbumTransferMetrics(
            transport: transport,
            totalBytes: uploadResult.remoteSize,
            elapsed: uploadResult.elapsed,
            connect: uploadResult.connect,
            prepare: uploadResult.prepare,
            upload: uploadResult.upload,
            verify: uploadResult.verify,
            commit: uploadResult.commit,
          );
          bytesTransferred += uploadResult.remoteSize;
          completed += 1;
          await AppLogger.log(
            'album_transfer_complete transport=${metrics.transport.name} '
            'path=${job.record.remotePath} bytes=${uploadResult.remoteSize} '
            'elapsedMs=${metrics.elapsed.inMilliseconds} '
            'connectMs=${metrics.connect.inMilliseconds} '
            'prepareMs=${metrics.prepare.inMilliseconds} '
            'uploadMs=${metrics.upload.inMilliseconds} '
            'verifyMs=${metrics.verify.inMilliseconds} '
            'commitMs=${metrics.commit.inMilliseconds}',
          );
        } on Object catch (error, stackTrace) {
          failed += 1;
          lastError = error.toString();
          final retryExponent = job.record.retryCount.clamp(0, 6);
          final retry = Duration(
            seconds: (30 * (1 << retryExponent)).clamp(30, 30 * 60),
          );
          await repository.transitionBackupState(
            assetId: job.record.assetId,
            destinationId: job.record.destinationId,
            state: AlbumBackupState.failed,
            error: error.toString(),
            nextRetry: DateTime.now().add(retry),
          );
          await AppLogger.log(
            'album_transfer_failed path=${job.record.remotePath} '
            'retrySeconds=${retry.inSeconds}',
            error: error,
            stackTrace: stackTrace,
          );
        } finally {
          active -= 1;
          publish();
        }
      }
    }

    publish();
    final workerCount =
        jobs.length < maxConcurrency ? jobs.length : maxConcurrency;
    await Future.wait(List.generate(workerCount, (_) => worker()));
    if (_cancelled && cursor < jobs.length) {
      await Future.wait(
        jobs.skip(cursor).map(
              (job) => repository.transitionBackupState(
                assetId: job.record.assetId,
                destinationId: job.record.destinationId,
                state: AlbumBackupState.paused,
                error: '用户取消，等待手动继续',
              ),
            ),
      );
    }
    stopwatch.stop();
    return AlbumTransferRunResult(
      completed: completed,
      failed: failed,
      cancelled: _cancelled,
      fallbackNotice: fallbackNotice,
    );
  }
}
