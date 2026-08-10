import 'dart:async';

import 'album_backup_models.dart';
import 'album_backup_repository.dart';
import 'local_media_store.dart';

class AlbumHashProgress {
  const AlbumHashProgress({required this.completed, required this.total});

  final int completed;
  final int total;
}

class AlbumFreeSpacePreview {
  const AlbumFreeSpacePreview({required this.assets});

  final List<AlbumMediaAsset> assets;
  int get totalBytes => assets.fold(0, (sum, asset) => sum + asset.sizeBytes);
}

class AlbumManagementService {
  AlbumManagementService(
    this.repository, {
    Future<LocalMediaDeleteResult> Function(List<String>)? deleteMedia,
  }) : _deleteMedia = deleteMedia ?? LocalMediaStore.deleteMedia;

  final AlbumBackupRepository repository;
  final Future<LocalMediaDeleteResult> Function(List<String>) _deleteMedia;

  Future<List<AlbumDuplicateGroup>> scanExactDuplicates({
    void Function(AlbumHashProgress progress)? onProgress,
  }) async {
    final candidates = await repository.listPotentialDuplicateAssets();
    var cursor = 0;
    var completed = 0;
    Future<void> worker() async {
      while (cursor < candidates.length) {
        final asset = candidates[cursor++];
        final hash = await LocalMediaStore.sha256(asset.uri);
        await repository.upsertAssetHash(
          assetId: asset.id,
          versionKey: asset.versionKey,
          sha256: hash,
        );
        completed += 1;
        onProgress?.call(
          AlbumHashProgress(completed: completed, total: candidates.length),
        );
      }
    }

    await Future.wait(
        List.generate(candidates.length < 2 ? 1 : 2, (_) => worker()));
    return repository.listDuplicateGroups();
  }

  Future<AlbumFreeSpacePreview> freeSpacePreview() async {
    return AlbumFreeSpacePreview(
      assets: await repository.listVerifiedLocalAssets(limit: 5000),
    );
  }

  Future<LocalMediaDeleteResult> releaseVerifiedAssets(
    Iterable<AlbumMediaAsset> requested,
  ) async {
    final verified = await repository.listVerifiedLocalAssets(limit: 5000);
    final verifiedById = <String, AlbumMediaAsset>{
      for (final asset in verified) asset.id: asset,
    };
    final allowed = requested
        .map((asset) => verifiedById[asset.id])
        .whereType<AlbumMediaAsset>()
        .toList(growable: false);
    final result = await _deleteMedia(
      allowed.map((asset) => asset.uri).toList(growable: false),
    );
    if (!result.cancelled && result.deleted > 0) {
      final deletedIds =
          result.deletedUris.isEmpty && result.deleted == allowed.length
              ? allowed.map((asset) => asset.id)
              : allowed
                  .where((asset) => result.deletedUris.contains(asset.uri))
                  .map((asset) => asset.id);
      await repository.markAssetsMissing(deletedIds);
    }
    return result;
  }
}
