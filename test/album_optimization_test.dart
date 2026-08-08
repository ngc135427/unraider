import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unraider/services/album_backup_models.dart';
import 'package:unraider/services/album_backup_repository.dart';
import 'package:unraider/services/album_preview_cache.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Album preview cache', () {
    test('uses a deterministic versioned sidecar path', () {
      final first = albumThumbnailSidecarPath(
        remoteRoot: '/mnt/user/photos',
        remotePath: '/mnt/user/photos/DCIM/IMG_1.jpg',
        versionKey: '100:200',
      );
      final same = albumThumbnailSidecarPath(
        remoteRoot: '/mnt/user/photos/',
        remotePath: '/mnt/user/photos/DCIM/IMG_1.jpg',
        versionKey: '100:200',
      );
      final changed = albumThumbnailSidecarPath(
        remoteRoot: '/mnt/user/photos',
        remotePath: '/mnt/user/photos/DCIM/IMG_1.jpg',
        versionKey: '100:201',
      );

      expect(first, same);
      expect(first, startsWith('/mnt/user/photos/.unraider/thumbnails/'));
      expect(first, endsWith('.jpg'));
      expect(changed, isNot(first));
    });

    test('prunes the least recently used preview to its byte budget', () async {
      final directory = await Directory.systemTemp.createTemp('album_cache_');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final cache = AlbumPreviewCache(
        byteBudget: 8,
        directoryProvider: () async => directory,
      );

      await cache.store(
        destinationId: 'destination',
        remotePath: '/older.jpg',
        versionKey: 'v1',
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
      );
      final older = await directory
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .single;
      await older.setLastModified(DateTime.fromMillisecondsSinceEpoch(1000));
      await cache.store(
        destinationId: 'destination',
        remotePath: '/newer.jpg',
        versionKey: 'v1',
        bytes: Uint8List.fromList(<int>[7, 8, 9, 10, 11, 12]),
      );

      final files =
          await directory.list().where((entry) => entry is File).toList();
      expect(files, hasLength(1));
      expect(await File(files.single.path).readAsBytes(),
          <int>[7, 8, 9, 10, 11, 12]);
    });
  });

  group('Album management index', () {
    test('supports search, logical albums and exact duplicate review',
        () async {
      final repository = await _openRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final camera = _asset(id: 'camera', displayName: 'Summer Camera.jpg');
      final copy = _asset(id: 'copy', displayName: 'Summer Copy.jpg');
      final other = _asset(
        id: 'other',
        displayName: 'Winter.png',
        sizeBytes: 2048,
      );
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[camera, copy, other],
        sources: sources,
      );

      final search = await repository.searchMedia(query: 'Summer');
      expect(search.map((asset) => asset.id),
          containsAll(<String>['camera', 'copy']));

      final album = await repository.createLogicalAlbum(
        '收藏',
        now: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await repository.addAssetsToLogicalAlbum(
        albumId: album.id,
        assetIds: <String>[camera.id, other.id, camera.id],
      );
      expect(await repository.listLogicalAlbumAssets(albumId: album.id),
          hasLength(2));
      expect((await repository.listLogicalAlbums()).single.itemCount, 2);

      for (final asset in <AlbumMediaAsset>[camera, copy]) {
        await repository.upsertAssetHash(
          assetId: asset.id,
          versionKey: asset.versionKey,
          sha256: 'same-sha256',
        );
      }
      await repository.upsertAssetHash(
        assetId: other.id,
        versionKey: other.versionKey,
        sha256: 'different-sha256',
      );

      final groups = await repository.listDuplicateGroups();
      expect(groups, hasLength(1));
      expect(groups.single.sha256, 'same-sha256');
      expect(groups.single.assets.map((asset) => asset.id),
          containsAll(<String>['camera', 'copy']));
    });

    test('only exposes size-verified completed originals for space release',
        () async {
      final repository = await _openRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final verified = _asset(id: 'verified', displayName: 'verified.jpg');
      final failed = _asset(id: 'failed', displayName: 'failed.jpg');
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[verified, failed],
        sources: sources,
      );
      final claimed =
          await repository.claimQueued(leaseOwner: 'test', limit: 2);
      expect(claimed, hasLength(2));

      await repository.transitionBackupState(
        assetId: verified.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.verifying,
        uploadedBytes: verified.sizeBytes,
      );
      await repository.transitionBackupState(
        assetId: verified.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.completed,
        uploadedBytes: verified.sizeBytes,
        remoteSize: verified.sizeBytes,
      );
      await repository.transitionBackupState(
        assetId: failed.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.failed,
        error: 'network',
      );

      final releasable = await repository.listVerifiedLocalAssets();
      expect(releasable.map((asset) => asset.id), <String>['verified']);

      expect(
        await repository.requeueRetryable(
          destinationId: source.destinationId,
          assetId: failed.id,
        ),
        1,
      );
      final retried = (await repository.listBackupRecords())
          .singleWhere((record) => record.assetId == failed.id);
      expect(retried.state, AlbumBackupState.queued);
      expect(retried.nextRetryMs, isNull);
    });
  });
}

Future<AlbumBackupRepository> _openRepository() {
  return AlbumBackupRepository.open(
    databasePath: inMemoryDatabasePath,
    factory: databaseFactoryFfi,
  );
}

AlbumSourceFolder _source() {
  return const AlbumSourceFolder(
    id: 'camera-source',
    volumeName: 'external',
    relativePath: 'DCIM/Camera/',
    displayName: 'Camera',
    destinationId: 'destination',
    remoteBasePath: '/mnt/user/photos',
    deviceId: 'device',
    deviceName: 'Phone',
    initialMode: AlbumInitialBackupMode.all,
    baselineMs: 0,
    createdAtMs: 1,
    updatedAtMs: 1,
  );
}

AlbumMediaAsset _asset({
  required String id,
  required String displayName,
  int sizeBytes = 1024,
}) {
  return AlbumMediaAsset(
    id: id,
    volumeName: 'external',
    mediaStoreId: id,
    uri: 'content://media/$id',
    relativePath: 'DCIM/Camera/',
    displayName: displayName,
    mimeType: 'image/jpeg',
    kind: AlbumMediaKind.image,
    sizeBytes: sizeBytes,
    dateAddedMs: 1000,
    dateModifiedMs: 2000,
    captureTimeMs: 2000,
    width: 1920,
    height: 1080,
    durationMs: 0,
    orientation: 0,
    bucketId: 'camera',
    bucketName: 'Camera',
  );
}
