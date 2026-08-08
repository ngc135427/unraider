import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unraider/services/album_backup_discovery.dart';
import 'package:unraider/services/album_backup_models.dart';
import 'package:unraider/services/album_backup_path.dart';
import 'package:unraider/services/album_backup_repository.dart';
import 'package:unraider/services/album_preferences.dart';
import 'package:unraider/services/local_media_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();

  group('MediaStore boundary', () {
    test('decodes full media metadata with backwards-compatible dates', () {
      final asset = LocalMediaAsset.fromMap(<String, Object?>{
        'id': 'external:image:42',
        'mediaStoreId': '42',
        'uri': 'content://media/external/images/media/42',
        'name': 'IMG_0042.jpg',
        'bucketId': 'camera',
        'bucketName': 'Camera',
        'volumeName': 'external',
        'relativePath': 'DCIM/Camera/',
        'mimeType': 'image/jpeg',
        'dateAddedMs': 1700000000000,
        'dateModifiedMs': 1700000005000,
        'captureTimeMs': 1699999999000,
        'sizeBytes': 123456,
        'isVideo': false,
        'width': 4032,
        'height': 3024,
        'durationMs': 0,
        'orientation': 90,
      });

      expect(asset.id, 'external:image:42');
      expect(asset.mediaStoreId, '42');
      expect(asset.relativePath, 'DCIM/Camera/');
      expect(asset.mimeType, 'image/jpeg');
      expect(asset.width, 4032);
      expect(asset.orientation, 90);
      expect(asset.dateAdded.millisecondsSinceEpoch, 1700000000000);
      expect(asset.captureDate?.millisecondsSinceEpoch, 1699999999000);
    });

    test('falls back to modified date when old payload lacks dateAddedMs', () {
      final asset = LocalMediaAsset.fromMap(<String, Object?>{
        'id': 'image:7',
        'uri': 'content://media/7',
        'name': 'old.jpg',
        'bucketId': 'old',
        'bucketName': 'Old',
        'dateModifiedMs': 123000,
        'sizeBytes': 10,
        'isVideo': false,
      });

      expect(asset.mediaStoreId, '7');
      expect(asset.dateAdded, asset.dateModified);
    });
  });

  group('Folder-preserving mapping', () {
    test('keeps the source-relative folder hierarchy', () {
      final source = _source(relativePath: 'DCIM/Camera/');
      final asset = _asset(
        id: 'external:image:1',
        relativePath: 'DCIM/Camera/Trips/Shanghai/',
        displayName: 'IMG:0001.jpg',
      );

      final remote = buildAlbumRemotePath(source: source, asset: asset);

      expect(remote, startsWith('/mnt/user/photos/mobile/Pixel_8-device12/'));
      expect(remote, contains('/Camera-'));
      expect(remote, endsWith('/Trips/Shanghai/IMG_0001.jpg'));
      expect(remote, isNot(contains('/2023/')));
    });

    test('rejects parent traversal and selects the most specific source',
        () async {
      expect(
        () => normalizeAlbumRelativePath('DCIM/../Secrets/'),
        throwsA(isA<AlbumBackupException>()),
      );
      expect(
        () => normalizeAlbumRemoteRoot('/mnt/user/../boot'),
        throwsA(isA<AlbumBackupException>()),
      );
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final all = _source(
        id: 'all',
        volumeName: '*',
        relativePath: '',
        displayName: 'All',
      );
      final camera = _source(id: 'camera', relativePath: 'DCIM/Camera/');
      final sources = await repository.replaceSourceFolders(<AlbumSourceFolder>[
        all,
        camera,
      ]);

      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(id: 'external:image:2', relativePath: 'DCIM/Camera/'),
        ],
        sources: sources,
      );

      final records = await repository.listBackupRecords();
      expect(records, hasLength(1));
      expect(records.single.sourceFolderId, camera.id);
    });
  });

  group('Persistent backup repository', () {
    test('persists completion across reopen and flags a later move', () async {
      final directory =
          await Directory.systemTemp.createTemp('unraider_album_');
      addTearDown(() => directory.delete(recursive: true));
      final databasePath = '${directory.path}/album.db';
      final source = _source();
      final asset = _asset(id: 'external:image:10');

      var repository = await AlbumBackupRepository.open(
        databasePath: databasePath,
        factory: databaseFactoryFfi,
      );
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      await repository
          .reconcileAssets(assets: <AlbumMediaAsset>[asset], sources: sources);
      final claimed = await repository.claimQueued(leaseOwner: 'test-worker');
      expect(claimed.single.state, AlbumBackupState.uploading);
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
      await repository.close();

      repository = await AlbumBackupRepository.open(
        databasePath: databasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(repository.close);
      var records = await repository.listBackupRecords();
      expect(records.single.state, AlbumBackupState.completed);

      final moved = _asset(
        id: asset.id,
        relativePath: 'Pictures/Moved/',
        dateModifiedMs: asset.dateModifiedMs + 1000,
      );
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[moved],
        sources: await repository.listSourceFolders(enabledOnly: true),
      );
      records = await repository.listBackupRecords();
      expect(records.single.state, AlbumBackupState.remoteConflict);
      expect(records.single.lastError, contains('远端旧文件保留'));
    });

    test('persists failed state and retry metadata across reopen', () async {
      final directory =
          await Directory.systemTemp.createTemp('unraider_album_failed_');
      addTearDown(() => directory.delete(recursive: true));
      final databasePath = '${directory.path}/album.db';
      final source = _source();
      final asset = _asset(id: 'failed-persistent');

      var repository = await AlbumBackupRepository.open(
        databasePath: databasePath,
        factory: databaseFactoryFfi,
      );
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[asset],
        sources: sources,
      );
      await repository.claimQueued(leaseOwner: 'worker');
      await repository.transitionBackupState(
        assetId: asset.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.failed,
        error: 'network unavailable',
        nextRetry: DateTime.fromMillisecondsSinceEpoch(5000),
      );
      await repository.close();

      repository = await AlbumBackupRepository.open(
        databasePath: databasePath,
        factory: databaseFactoryFfi,
      );
      addTearDown(repository.close);
      final record = (await repository.listBackupRecords()).single;
      expect(record.state, AlbumBackupState.failed);
      expect(record.retryCount, 1);
      expect(record.nextRetryMs, 5000);
      expect(record.lastError, 'network unavailable');
    });

    test('new-only baseline skips old assets and queues later assets',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source(
        initialMode: AlbumInitialBackupMode.newOnly,
        baselineMs: 2000,
      );
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);

      final result = await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(id: 'old', dateAddedMs: 1000),
          _asset(id: 'new', dateAddedMs: 3000),
        ],
        sources: sources,
        now: DateTime.fromMillisecondsSinceEpoch(4000),
      );

      expect(result.queuedCount, 1);
      expect(result.skippedExistingCount, 1);
      final counts = await repository.countBackupStates();
      expect(counts[AlbumBackupState.queued], 1);
      expect(counts[AlbumBackupState.skippedExisting], 1);
    });

    test('full reconciliation marks media that disappeared locally', () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final first = _asset(id: 'first');
      final second = _asset(id: 'second');
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[first, second],
        sources: sources,
        now: DateTime.fromMillisecondsSinceEpoch(10000),
      );

      final result = await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[second],
        sources: sources,
        now: DateTime.fromMillisecondsSinceEpoch(11000),
      );

      expect(result.missingCount, 1);
      final records = await repository.listBackupRecords();
      expect(
        records.singleWhere((record) => record.assetId == first.id).state,
        AlbumBackupState.missingLocal,
      );
    });

    test('legacy date-layout matches are skipped without claiming verification',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final asset = _asset(id: 'legacy');
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[asset],
        sources: sources,
      );

      final updated = await repository.markLegacyExistingAssets(
        destinationId: source.destinationId,
        assetIds: <String>{asset.id},
      );

      expect(updated, 1);
      final record = (await repository.listBackupRecords()).single;
      expect(record.state, AlbumBackupState.skippedExisting);
      expect(record.remoteSize, isNull);
      expect(record.lastError, contains('等待显式迁移'));
    });

    test('reconciliation preserves an active worker lease', () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      final asset = _asset(id: 'leased');
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[asset],
        sources: sources,
      );
      await repository.claimQueued(
        leaseOwner: 'worker-a',
        leaseDuration: const Duration(minutes: 5),
      );

      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[asset],
        sources: sources,
      );

      final record = (await repository.listBackupRecords()).single;
      expect(record.state, AlbumBackupState.uploading);
      expect(record.leaseOwner, 'worker-a');
      expect(record.leaseExpiresMs, isNotNull);
      expect(await repository.claimQueued(leaseOwner: 'worker-b'), isEmpty);
    });

    test('verification keeps its lease and an expired worker can be reclaimed',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final asset = _asset(id: 'reclaimable');
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[asset],
        sources: sources,
      );
      await repository.claimQueued(
        leaseOwner: 'worker-a',
        leaseDuration: const Duration(seconds: 1),
        now: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      await repository.transitionBackupState(
        assetId: asset.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.verifying,
        now: DateTime.fromMillisecondsSinceEpoch(1500),
      );

      var record = (await repository.listBackupRecords()).single;
      expect(record.leaseOwner, 'worker-a');
      expect(record.leaseExpiresMs, 2000);
      final reclaimed = await repository.claimQueued(
        leaseOwner: 'worker-b',
        now: DateTime.fromMillisecondsSinceEpoch(2001),
      );

      expect(reclaimed, hasLength(1));
      record = reclaimed.single;
      expect(record.state, AlbumBackupState.uploading);
      expect(record.leaseOwner, 'worker-b');
    });

    test('changed completed media is requeued and loses stale verification',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final original = _asset(id: 'changed');
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[original],
        sources: sources,
      );
      await repository.claimQueued(leaseOwner: 'worker');
      await repository.transitionBackupState(
        assetId: original.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.verifying,
        uploadedBytes: original.sizeBytes,
      );
      await repository.transitionBackupState(
        assetId: original.id,
        destinationId: source.destinationId,
        state: AlbumBackupState.completed,
        uploadedBytes: original.sizeBytes,
        remoteSize: original.sizeBytes,
        remoteEtag: 'stale-etag',
      );

      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(
            id: original.id,
            dateModifiedMs: original.dateModifiedMs + 1000,
          ),
        ],
        sources: sources,
        fullScan: false,
      );

      final record = (await repository.listBackupRecords()).single;
      expect(record.state, AlbumBackupState.queued);
      expect(record.uploadedBytes, 0);
      expect(record.remoteSize, isNull);
      expect(record.remoteEtag, isNull);
    });

    test('incremental reconciliation never moves its checkpoint backwards',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(
            id: 'newest',
            mediaStoreId: '100',
            dateModifiedMs: 10000,
          ),
        ],
        sources: sources,
        now: DateTime.fromMillisecondsSinceEpoch(11000),
      );

      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(
            id: 'overlap',
            mediaStoreId: '90',
            dateModifiedMs: 9000,
          ),
        ],
        sources: sources,
        fullScan: false,
        now: DateTime.fromMillisecondsSinceEpoch(12000),
      );
      await repository.reconcileAssets(
        assets: const <AlbumMediaAsset>[],
        sources: sources,
        fullScan: false,
        now: DateTime.fromMillisecondsSinceEpoch(13000),
      );

      final checkpoint = (await repository.listDiscoveryCheckpoints()).single;
      expect(checkpoint.lastModifiedMs, 10000);
      expect(checkpoint.lastMediaStoreId, '100');
      expect(checkpoint.lastScanCompletedMs, 13000);
    });

    test('stores remote metadata and pages it by media time', () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      await repository.upsertRemoteAssets(<AlbumRemoteAsset>[
        const AlbumRemoteAsset(
          destinationId: 'destination-a',
          path: '/photos/older.jpg',
          displayName: 'older.jpg',
          mediaKind: AlbumMediaKind.image,
          sizeBytes: 10,
          modifiedMs: 1000,
          captureTimeMs: 500,
          versionKey: 'older-v1',
          origin: 'remote-scan',
        ),
        const AlbumRemoteAsset(
          destinationId: 'destination-a',
          path: '/photos/newer.mp4',
          displayName: 'newer.mp4',
          mediaKind: AlbumMediaKind.video,
          sizeBytes: 20,
          modifiedMs: 2000,
          captureTimeMs: 3000,
          versionKey: 'newer-v1',
          thumbnailPath: '/cache/newer.jpg',
          origin: 'uploaded',
        ),
        const AlbumRemoteAsset(
          destinationId: 'destination-b',
          path: '/other/ignored.jpg',
          displayName: 'ignored.jpg',
          mediaKind: AlbumMediaKind.image,
          sizeBytes: 30,
          modifiedMs: 4000,
          versionKey: 'ignored-v1',
          origin: 'remote-scan',
        ),
      ]);

      final firstPage = await repository.listRemotePage(
        destinationId: 'destination-a',
        limit: 1,
      );
      final secondPage = await repository.listRemotePage(
        destinationId: 'destination-a',
        limit: 1,
        offset: 1,
      );

      expect(firstPage.single.path, '/photos/newer.mp4');
      expect(firstPage.single.thumbnailPath, '/cache/newer.jpg');
      expect(secondPage.single.path, '/photos/older.jpg');
    });

    test('disambiguates filenames that sanitize to the same remote path',
        () async {
      final repository = await _openMemoryRepository();
      addTearDown(repository.close);
      final source = _source();
      final sources =
          await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);

      await repository.reconcileAssets(
        assets: <AlbumMediaAsset>[
          _asset(id: 'colon', displayName: 'IMG:1.jpg'),
          _asset(id: 'question', displayName: 'IMG?1.jpg'),
        ],
        sources: sources,
      );

      final paths = (await repository.listBackupRecords())
          .map((record) => record.remotePath)
          .toSet();
      expect(paths, hasLength(2));
      expect(paths.every((path) => path.endsWith('.jpg')), isTrue);
    });

    test(
      'stores ten thousand assets and returns bounded timeline pages',
      () async {
        final repository = await _openMemoryRepository();
        addTearDown(repository.close);
        final source = _source();
        final sources =
            await repository.replaceSourceFolders(<AlbumSourceFolder>[source]);
        final assets = List<AlbumMediaAsset>.generate(
          10000,
          (index) => _asset(
            id: 'external:image:$index',
            mediaStoreId: '$index',
            dateAddedMs: 1000 + index,
            dateModifiedMs: 2000 + index,
            displayName: 'IMG_$index.jpg',
          ),
        );

        await repository.reconcileAssets(assets: assets, sources: sources);
        final firstPage = await repository.listMediaPage(limit: 100);
        final secondPage =
            await repository.listMediaPage(limit: 100, offset: 100);

        expect(firstPage, hasLength(100));
        expect(secondPage, hasLength(100));
        expect(firstPage.map((asset) => asset.id).toSet(),
            isNot(contains(secondPage.first.id)));
        expect((await repository.countBackupStates())[AlbumBackupState.queued],
            10000);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('Legacy preference migration', () {
    test('creates one stable source per selected media folder', () {
      final preferences = AlbumBackupPreferences(
        targetDir: '/mnt/user/photos/mobile',
        sourceIds: const <String>['camera', 'screenshots'],
        sourceName: '2 个文件夹',
        deviceId: 'device-12345678',
        deviceName: 'Pixel 8',
      );
      const buckets = <LocalMediaBucket>[
        LocalMediaBucket(
          id: 'camera',
          name: 'Camera',
          count: 20,
          volumeName: 'external',
          relativePath: 'DCIM/Camera/',
        ),
        LocalMediaBucket(
          id: 'screenshots',
          name: 'Screenshots',
          count: 10,
          volumeName: 'external',
          relativePath: 'Pictures/Screenshots/',
        ),
      ];

      final sources = sourceFoldersFromPreferences(
        preferences: preferences,
        buckets: buckets,
        now: DateTime.fromMillisecondsSinceEpoch(1234),
      );

      expect(sources, hasLength(2));
      expect(sources.map((source) => source.relativePath),
          containsAll(<String>['DCIM/Camera/', 'Pictures/Screenshots/']));
      expect(sources.map((source) => source.id).toSet(), hasLength(2));
    });
  });
}

Future<AlbumBackupRepository> _openMemoryRepository() {
  return AlbumBackupRepository.open(
    databasePath: inMemoryDatabasePath,
    factory: databaseFactoryFfi,
  );
}

AlbumSourceFolder _source({
  String id = 'camera-source',
  String volumeName = 'external',
  String relativePath = 'DCIM/Camera/',
  String displayName = 'Camera',
  AlbumInitialBackupMode initialMode = AlbumInitialBackupMode.all,
  int baselineMs = 0,
}) {
  return AlbumSourceFolder(
    id: id,
    volumeName: volumeName,
    relativePath: relativePath,
    displayName: displayName,
    destinationId: 'unraid-destination',
    remoteBasePath: '/mnt/user/photos/mobile',
    deviceId: 'device-12345678',
    deviceName: 'Pixel:8',
    initialMode: initialMode,
    baselineMs: baselineMs,
    createdAtMs: 1,
    updatedAtMs: 1,
  );
}

AlbumMediaAsset _asset({
  required String id,
  String? mediaStoreId,
  String relativePath = 'DCIM/Camera/',
  String displayName = 'IMG_0001.jpg',
  int dateAddedMs = 1000,
  int dateModifiedMs = 2000,
}) {
  final resolvedMediaStoreId = mediaStoreId ?? id;
  return AlbumMediaAsset(
    id: id,
    volumeName: 'external',
    mediaStoreId: resolvedMediaStoreId,
    uri: 'content://media/$resolvedMediaStoreId',
    relativePath: relativePath,
    displayName: displayName,
    mimeType: 'image/jpeg',
    kind: AlbumMediaKind.image,
    sizeBytes: 1024,
    dateAddedMs: dateAddedMs,
    dateModifiedMs: dateModifiedMs,
    captureTimeMs: dateModifiedMs,
    width: 1920,
    height: 1080,
    durationMs: 0,
    orientation: 0,
    bucketId: 'camera',
    bucketName: 'Camera',
  );
}
