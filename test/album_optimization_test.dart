import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unraider/services/album_backup_models.dart';
import 'package:unraider/services/album_backup_repository.dart';
import 'package:unraider/services/album_management_service.dart';
import 'package:unraider/services/album_preview_cache.dart';
import 'package:unraider/services/local_media_store.dart';
import 'package:unraider/services/remote_video_stream.dart';
import 'package:unraider/services/unraid_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('Album preview cache', () {
    test('detects a transport stream shifted by one damaged packet', () {
      const packetSize = 188;
      final shifted = Uint8List(packetSize * 6);
      for (var packet = 1; packet <= 5; packet++) {
        shifted[packet * packetSize] = 0x47;
      }
      final normal = Uint8List.fromList(shifted)..[0] = 0x47;

      expect(RemoteVideoStream.hasShiftedTransportStream(shifted), isTrue);
      expect(RemoteVideoStream.hasShiftedTransportStream(normal), isFalse);
      expect(
        RemoteVideoStream.hasShiftedTransportStream(
          Uint8List(packetSize * 5),
        ),
        isFalse,
      );
    });

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

    test('a disposed tile can cancel before on-demand generation', () async {
      final directory = await Directory.systemTemp.createTemp('album_cancel_');
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final cache = AlbumPreviewCache(directoryProvider: () async => directory);
      await cache.store(
        destinationId: 'destination',
        remotePath: '/cached.jpg',
        versionKey: 'v1',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
      );
      final client = UnraidClient(
        baseUrl: 'http://127.0.0.1',
        username: 'root',
        password: 'test',
      );
      addTearDown(client.close);
      final cancellation = AlbumPreviewCancellation()..cancel();

      final bytes = await cache.load(
        client: client,
        destinationId: 'destination',
        remoteRoot: '/mnt/user/photos',
        remotePath: '/cached.jpg',
        versionKey: 'v1',
        isVideo: false,
        cancellation: cancellation,
      );

      expect(bytes, isNull);
    });
  });

  group('Album management index', () {
    test('remote refresh preserves only same-version derived preview paths',
        () async {
      final repository = await _openRepository();
      addTearDown(repository.close);
      const destination = 'destination';
      const remotePath = '/mnt/user/photos/photo.jpg';
      AlbumRemoteAsset asset(String version, {String? thumbnailPath}) =>
          AlbumRemoteAsset(
            destinationId: destination,
            path: remotePath,
            displayName: 'photo.jpg',
            mediaKind: AlbumMediaKind.image,
            sizeBytes: 10,
            modifiedMs: version == '10:1000' ? 1000 : 2000,
            versionKey: version,
            thumbnailPath: thumbnailPath,
            origin: 'test',
          );

      await repository.upsertRemoteAssets(<AlbumRemoteAsset>[
        asset('10:1000', thumbnailPath: '/derived/old.jpg'),
      ]);
      await repository.upsertRemoteAssets(<AlbumRemoteAsset>[
        asset('10:1000'),
      ]);
      expect(
        (await repository.listRemotePage(destinationId: destination))
            .single
            .thumbnailPath,
        '/derived/old.jpg',
      );

      await repository.upsertRemoteAssets(<AlbumRemoteAsset>[
        asset('10:2000'),
      ]);
      expect(
        (await repository.listRemotePage(destinationId: destination))
            .single
            .thumbnailPath,
        isNull,
      );
    });

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
      await repository.updateAssetMetadata(
        assetId: camera.id,
        favorite: true,
        tags: const <String>['beach'],
        description: 'sunset walk',
        rating: 5,
      );
      expect(
          (await repository.searchMedia(query: 'beach')).single.id, camera.id);
      expect((await repository.assetMetadata(camera.id)).rating, 5);
      expect(
        await repository.searchMedia(fromMs: 2500, toMs: 4000),
        isEmpty,
      );

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
      await repository.deleteLogicalAlbum(album.id);
      expect(await repository.listLogicalAlbums(), isEmpty);

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

    test('partial system deletion marks only the deleted local asset',
        () async {
      final repository = await _openRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final first = _asset(id: 'first', displayName: 'first.jpg');
      final second = _asset(id: 'second', displayName: 'second.jpg');
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[first, second],
        sources: sources,
      );
      await repository.claimQueued(leaseOwner: 'test', limit: 2);
      for (final asset in <AlbumMediaAsset>[first, second]) {
        await repository.transitionBackupState(
          assetId: asset.id,
          destinationId: source.destinationId,
          state: AlbumBackupState.verifying,
          uploadedBytes: asset.sizeBytes,
        );
        await repository.transitionBackupState(
          assetId: asset.id,
          destinationId: source.destinationId,
          state: AlbumBackupState.completed,
          uploadedBytes: asset.sizeBytes,
          remoteSize: asset.sizeBytes,
        );
      }
      final service = AlbumManagementService(
        repository,
        deleteMedia: (uris) async => LocalMediaDeleteResult(
          requested: uris.length,
          deleted: 1,
          deletedUris: <String>{first.uri},
        ),
      );

      final result = await service.releaseVerifiedAssets(<AlbumMediaAsset>[
        first,
        second,
      ]);

      expect(result.deleted, 1);
      expect((await repository.listVerifiedLocalAssets()).single.id, second.id);
    });

    test('remote video page includes duration from its indexed local source',
        () async {
      final repository = await _openRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final video = _asset(
        id: 'video',
        displayName: 'clip.mp4',
        kind: AlbumMediaKind.video,
        durationMs: 125000,
      );
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[video],
        sources: sources,
      );
      final record = (await repository.listBackupRecords()).single;
      await repository.upsertRemoteAssets(<AlbumRemoteAsset>[
        AlbumRemoteAsset(
          destinationId: source.destinationId,
          path: record.remotePath,
          displayName: video.displayName,
          mediaKind: AlbumMediaKind.video,
          sizeBytes: video.sizeBytes,
          modifiedMs: video.dateModifiedMs,
          versionKey: video.versionKey,
          origin: 'uploaded',
        ),
      ]);

      expect(
          (await repository.listRemotePage(
            destinationId: source.destinationId,
          ))
              .single
              .durationMs,
          125000);
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
  AlbumMediaKind kind = AlbumMediaKind.image,
  int durationMs = 0,
}) {
  return AlbumMediaAsset(
    id: id,
    volumeName: 'external',
    mediaStoreId: id,
    uri: 'content://media/$id',
    relativePath: 'DCIM/Camera/',
    displayName: displayName,
    mimeType: kind == AlbumMediaKind.video ? 'video/mp4' : 'image/jpeg',
    kind: kind,
    sizeBytes: sizeBytes,
    dateAddedMs: 1000,
    dateModifiedMs: 2000,
    captureTimeMs: 2000,
    width: 1920,
    height: 1080,
    durationMs: durationMs,
    orientation: 0,
    bucketId: 'camera',
    bucketName: 'Camera',
  );
}
