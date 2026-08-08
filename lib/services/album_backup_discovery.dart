import 'album_backup_models.dart';
import 'album_backup_path.dart';
import 'album_backup_repository.dart';
import 'album_preferences.dart';
import 'local_media_store.dart';

class AlbumBackupDiscovery {
  const AlbumBackupDiscovery(this.repository);

  final AlbumBackupRepository repository;

  Future<AlbumDiscoveryResult> reconcile({
    required List<LocalMediaAsset> media,
    required List<LocalMediaBucket> buckets,
    required AlbumBackupPreferences preferences,
    bool fullScan = true,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final sources = await repository.replaceSourceFolders(
      sourceFoldersFromPreferences(
        preferences: preferences,
        buckets: buckets,
        now: timestamp,
      ),
    );
    return repository.reconcileAssets(
      assets: media.map(albumMediaAssetFromLocal).toList(growable: false),
      sources: sources,
      fullScan: fullScan,
      now: timestamp,
    );
  }

  Future<AlbumDiscoveryResult> discoverIncremental({
    required List<LocalMediaBucket> buckets,
    required AlbumBackupPreferences preferences,
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    final sources = await repository.replaceSourceFolders(
      sourceFoldersFromPreferences(
        preferences: preferences,
        buckets: buckets,
        now: timestamp,
      ),
    );
    final sourceIds = sources.map((source) => source.id).toSet();
    final checkpoints = (await repository.listDiscoveryCheckpoints())
        .where((checkpoint) => sourceIds.contains(checkpoint.sourceFolderId))
        .toList(growable: false);
    final modifiedAfterMs = checkpoints.isEmpty
        ? null
        : checkpoints
                .map((checkpoint) => checkpoint.lastModifiedMs)
                .reduce((a, b) => a < b ? a : b) -
            1000;
    final changed = await LocalMediaStore.listMedia(
      modifiedAfterMs: modifiedAfterMs == null
          ? null
          : modifiedAfterMs < 0
              ? 0
              : modifiedAfterMs,
    );
    return repository.reconcileAssets(
      assets: changed.map(albumMediaAssetFromLocal).toList(growable: false),
      sources: sources,
      fullScan: false,
      now: timestamp,
    );
  }
}

List<AlbumSourceFolder> sourceFoldersFromPreferences({
  required AlbumBackupPreferences preferences,
  required List<LocalMediaBucket> buckets,
  DateTime? now,
}) {
  final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
  final destinationId = albumDestinationId(preferences.targetDir);
  final selectedIds = preferences.selectedSourceIds.toSet();
  if (selectedIds.isEmpty) {
    return <AlbumSourceFolder>[
      AlbumSourceFolder(
        id: albumSourceFolderId(
          volumeName: '*',
          relativePath: '',
          destinationId: destinationId,
        ),
        volumeName: '*',
        relativePath: '',
        displayName: '全部媒体',
        destinationId: destinationId,
        remoteBasePath: preferences.targetDir,
        deviceId: preferences.deviceId,
        deviceName: preferences.deviceName,
        initialMode: preferences.initialBackupMode,
        baselineMs: timestamp,
        createdAtMs: timestamp,
        updatedAtMs: timestamp,
      ),
    ];
  }

  return buckets
      .where((bucket) => selectedIds.contains(bucket.id))
      .map(
        (bucket) => AlbumSourceFolder(
          id: albumSourceFolderId(
            volumeName: bucket.volumeName,
            relativePath: bucket.relativePath,
            destinationId: destinationId,
          ),
          volumeName: bucket.volumeName,
          relativePath: bucket.relativePath,
          displayName: bucket.name,
          destinationId: destinationId,
          remoteBasePath: preferences.targetDir,
          deviceId: preferences.deviceId,
          deviceName: preferences.deviceName,
          initialMode: preferences.initialBackupMode,
          baselineMs: timestamp,
          createdAtMs: timestamp,
          updatedAtMs: timestamp,
        ),
      )
      .toList(growable: false);
}

AlbumMediaAsset albumMediaAssetFromLocal(LocalMediaAsset asset) {
  return AlbumMediaAsset(
    id: asset.id,
    volumeName: asset.volumeName,
    mediaStoreId: asset.mediaStoreId,
    uri: asset.uri,
    relativePath: normalizeAlbumRelativePath(asset.relativePath),
    displayName: asset.name,
    mimeType: asset.mimeType,
    kind: asset.isVideo ? AlbumMediaKind.video : AlbumMediaKind.image,
    sizeBytes: asset.sizeBytes,
    dateAddedMs: asset.dateAdded.millisecondsSinceEpoch,
    dateModifiedMs: asset.dateModified.millisecondsSinceEpoch,
    captureTimeMs: asset.captureDate?.millisecondsSinceEpoch,
    width: asset.width,
    height: asset.height,
    durationMs: asset.duration.inMilliseconds,
    orientation: asset.orientation,
    bucketId: asset.bucketId,
    bucketName: asset.bucketName,
  );
}
