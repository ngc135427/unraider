import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'album_backup_models.dart';
import 'album_backup_path.dart';

const albumBackupDatabaseName = 'album_backup_v1.db';
const albumBackupDatabaseVersion = 2;

class AlbumBackupRepository {
  AlbumBackupRepository._(this._database);

  final Database _database;
  int _scanSequence = 0;

  static Future<AlbumBackupRepository> open({
    String? databasePath,
    DatabaseFactory? factory,
  }) async {
    final resolvedFactory = factory ?? databaseFactory;
    final resolvedPath = databasePath ??
        path.join(
            await resolvedFactory.getDatabasesPath(), albumBackupDatabaseName);
    final database = await resolvedFactory.openDatabase(
      resolvedPath,
      options: OpenDatabaseOptions(
        version: albumBackupDatabaseVersion,
        onConfigure: (database) => database.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return AlbumBackupRepository._(database);
  }

  static Future<void> _createSchema(Database database, int version) async {
    await database.execute('''
      CREATE TABLE source_folders (
        id TEXT PRIMARY KEY,
        volume_name TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        display_name TEXT NOT NULL,
        destination_id TEXT NOT NULL,
        remote_base_path TEXT NOT NULL,
        device_id TEXT NOT NULL,
        device_name TEXT NOT NULL,
        initial_mode TEXT NOT NULL,
        baseline_ms INTEGER NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        include_images INTEGER NOT NULL DEFAULT 1,
        include_videos INTEGER NOT NULL DEFAULT 1
      )
    ''');
    await database.execute('''
      CREATE TABLE media_assets (
        id TEXT PRIMARY KEY,
        volume_name TEXT NOT NULL,
        media_store_id TEXT NOT NULL,
        uri TEXT NOT NULL,
        relative_path TEXT NOT NULL,
        display_name TEXT NOT NULL,
        mime_type TEXT NOT NULL,
        media_kind TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        date_added_ms INTEGER NOT NULL,
        date_modified_ms INTEGER NOT NULL,
        capture_time_ms INTEGER,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER NOT NULL DEFAULT 0,
        orientation INTEGER NOT NULL DEFAULT 0,
        bucket_id TEXT NOT NULL,
        bucket_name TEXT NOT NULL,
        last_seen_scan_id TEXT NOT NULL,
        missing_local INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX media_assets_store_identity
      ON media_assets(volume_name, media_kind, media_store_id)
    ''');
    await database.execute('''
      CREATE INDEX media_assets_timeline
      ON media_assets(missing_local, capture_time_ms DESC, date_modified_ms DESC, id DESC)
    ''');
    await database.execute('''
      CREATE INDEX media_assets_folder
      ON media_assets(relative_path, display_name)
    ''');
    await database.execute('''
      CREATE TABLE backup_records (
        asset_id TEXT NOT NULL,
        destination_id TEXT NOT NULL,
        source_folder_id TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        state TEXT NOT NULL,
        uploaded_bytes INTEGER NOT NULL DEFAULT 0,
        total_bytes INTEGER NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0,
        next_retry_ms INTEGER,
        last_error TEXT,
        remote_size INTEGER,
        remote_modified_ms INTEGER,
        remote_etag TEXT,
        remote_hash TEXT,
        thumbnail_state TEXT NOT NULL DEFAULT 'missing',
        lease_owner TEXT,
        lease_expires_ms INTEGER,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY(asset_id, destination_id),
        FOREIGN KEY(asset_id) REFERENCES media_assets(id),
        FOREIGN KEY(source_folder_id) REFERENCES source_folders(id)
      )
    ''');
    await database.execute('''
      CREATE INDEX backup_records_queue
      ON backup_records(destination_id, state, next_retry_ms, lease_expires_ms, updated_at_ms)
    ''');
    await database.execute('''
      CREATE UNIQUE INDEX backup_records_remote_path
      ON backup_records(destination_id, remote_path)
    ''');
    await database.execute('''
      CREATE TABLE remote_assets (
        destination_id TEXT NOT NULL,
        path TEXT NOT NULL,
        display_name TEXT NOT NULL,
        media_kind TEXT NOT NULL,
        size_bytes INTEGER NOT NULL,
        modified_ms INTEGER NOT NULL,
        capture_time_ms INTEGER,
        version_key TEXT NOT NULL,
        thumbnail_path TEXT,
        preview_path TEXT,
        origin TEXT NOT NULL,
        PRIMARY KEY(destination_id, path)
      )
    ''');
    await database.execute('''
      CREATE INDEX remote_assets_timeline
      ON remote_assets(destination_id, capture_time_ms DESC, modified_ms DESC, path)
    ''');
    await database.execute('''
      CREATE TABLE derived_media (
        destination_id TEXT NOT NULL,
        remote_path TEXT NOT NULL,
        kind TEXT NOT NULL,
        version_key TEXT NOT NULL,
        state TEXT NOT NULL,
        derived_path TEXT,
        last_error TEXT,
        updated_at_ms INTEGER NOT NULL,
        PRIMARY KEY(destination_id, remote_path, kind)
      )
    ''');
    await database.execute('''
      CREATE TABLE discovery_checkpoints (
        source_folder_id TEXT PRIMARY KEY,
        last_scan_id TEXT NOT NULL,
        last_scan_started_ms INTEGER NOT NULL,
        last_scan_completed_ms INTEGER NOT NULL,
        last_modified_ms INTEGER NOT NULL DEFAULT 0,
        last_media_store_id TEXT NOT NULL DEFAULT '',
        FOREIGN KEY(source_folder_id) REFERENCES source_folders(id)
      )
    ''');
    await _createManagementSchema(database);
  }

  static Future<void> _upgradeSchema(
    Database database,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) await _createManagementSchema(database);
  }

  static Future<void> _createManagementSchema(Database database) async {
    await database.execute('''
      CREATE TABLE IF NOT EXISTS logical_albums (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at_ms INTEGER NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS logical_album_items (
        album_id TEXT NOT NULL,
        asset_id TEXT NOT NULL,
        added_at_ms INTEGER NOT NULL,
        PRIMARY KEY(album_id, asset_id),
        FOREIGN KEY(album_id) REFERENCES logical_albums(id) ON DELETE CASCADE,
        FOREIGN KEY(asset_id) REFERENCES media_assets(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS asset_metadata (
        asset_id TEXT PRIMARY KEY,
        favorite INTEGER NOT NULL DEFAULT 0,
        archived INTEGER NOT NULL DEFAULT 0,
        tags TEXT NOT NULL DEFAULT '',
        description TEXT NOT NULL DEFAULT '',
        rating INTEGER NOT NULL DEFAULT 0,
        updated_at_ms INTEGER NOT NULL,
        FOREIGN KEY(asset_id) REFERENCES media_assets(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE TABLE IF NOT EXISTS asset_hashes (
        asset_id TEXT PRIMARY KEY,
        version_key TEXT NOT NULL,
        sha256 TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL,
        FOREIGN KEY(asset_id) REFERENCES media_assets(id) ON DELETE CASCADE
      )
    ''');
    await database.execute('''
      CREATE INDEX IF NOT EXISTS asset_hashes_duplicates
      ON asset_hashes(sha256)
    ''');
  }

  Future<void> close() => _database.close();

  Future<List<AlbumSourceFolder>> listSourceFolders({
    bool enabledOnly = false,
  }) async {
    final rows = await _database.query(
      'source_folders',
      where: enabledOnly ? 'enabled = 1' : null,
      orderBy: 'display_name COLLATE NOCASE, id',
    );
    return rows.map(AlbumSourceFolder.fromMap).toList(growable: false);
  }

  Future<List<AlbumSourceFolder>> replaceSourceFolders(
    List<AlbumSourceFolder> sources,
  ) {
    return _database.transaction((transaction) async {
      final existingRows = await transaction.query('source_folders');
      final existing = <String, AlbumSourceFolder>{
        for (final row in existingRows)
          row['id']! as String: AlbumSourceFolder.fromMap(row),
      };
      await transaction.update(
        'source_folders',
        <String, Object?>{'enabled': 0},
      );
      final persisted = <AlbumSourceFolder>[];
      for (final source in sources) {
        final previous = existing[source.id];
        final value = previous == null
            ? source
            : source.copyWith(
                baselineMs: previous.baselineMs,
                createdAtMs: previous.createdAtMs,
              );
        await transaction.insert(
          'source_folders',
          value.toMap(),
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        await transaction.update(
          'source_folders',
          value.toMap()..remove('id'),
          where: 'id = ?',
          whereArgs: <Object?>[value.id],
        );
        persisted.add(value);
      }
      return persisted;
    });
  }

  Future<AlbumDiscoveryResult> reconcileAssets({
    required List<AlbumMediaAsset> assets,
    required List<AlbumSourceFolder> sources,
    bool fullScan = true,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final scanId =
        '$timestamp-${DateTime.now().microsecondsSinceEpoch}-${++_scanSequence}-${assets.length}';
    return _database.transaction((transaction) async {
      final existingAssetRows = await transaction.query('media_assets');
      final existingAssets = <String, Map<String, Object?>>{
        for (final row in existingAssetRows) row['id']! as String: row,
      };
      final existingRecordRows = await transaction.query('backup_records');
      final checkpointRows = await transaction.query('discovery_checkpoints');
      final checkpoints = <String, AlbumDiscoveryCheckpoint>{
        for (final row in checkpointRows)
          row['source_folder_id']! as String:
              AlbumDiscoveryCheckpoint.fromMap(row),
      };
      final existingRecords = <String, Map<String, Object?>>{
        for (final row in existingRecordRows)
          _recordKey(
                  row['asset_id']! as String, row['destination_id']! as String):
              row,
      };
      final remotePathOwners = <String, String>{
        for (final row in existingRecordRows)
          _recordKey(
            row['remote_path']! as String,
            row['destination_id']! as String,
          ): row['asset_id']! as String,
      };
      var upsertBatch = transaction.batch();
      var pendingBatchOperations = 0;

      Future<void> flushUpserts() async {
        if (pendingBatchOperations == 0) {
          return;
        }
        await upsertBatch.commit(noResult: true);
        upsertBatch = transaction.batch();
        pendingBatchOperations = 0;
      }

      var queuedCount = 0;
      var skippedExistingCount = 0;
      final activeSourceIds = sources.map((source) => source.id).toSet();
      for (final asset in assets) {
        final previousAsset = existingAssets[asset.id];
        final changed =
            previousAsset == null || _assetChanged(previousAsset, asset);
        final assetMap = asset.toMap(
          scanId: scanId,
          updatedAtMs: timestamp,
        );
        upsertBatch.insert(
          'media_assets',
          assetMap,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        upsertBatch.update(
          'media_assets',
          <String, Object?>{...assetMap}..remove('id'),
          where: 'id = ?',
          whereArgs: <Object?>[asset.id],
        );
        pendingBatchOperations += 2;

        final matchingSources = _bestMatchingSources(asset, sources);
        final matchedRecordKeys = <String>{};
        for (final source in matchingSources) {
          final key = _recordKey(asset.id, source.destinationId);
          matchedRecordKeys.add(key);
          final previous = existingRecords[key];
          final requestedRemotePath =
              buildAlbumRemotePath(source: source, asset: asset);
          final remoteOwner = remotePathOwners[
              _recordKey(requestedRemotePath, source.destinationId)];
          final remotePath = remoteOwner == null || remoteOwner == asset.id
              ? requestedRemotePath
              : _disambiguateRemotePath(requestedRemotePath, asset.id);
          final eligible = source.initialMode == AlbumInitialBackupMode.all ||
              asset.dateAddedMs > source.baselineMs;
          var state = previous == null
              ? (eligible
                  ? AlbumBackupState.queued
                  : AlbumBackupState.skippedExisting)
              : AlbumBackupState.parse(previous['state']);
          var lastError = previous?['last_error'] as String?;

          if (previous != null) {
            final previousRemotePath = previous['remote_path']! as String;
            if (previousRemotePath != remotePath &&
                state == AlbumBackupState.completed) {
              state = AlbumBackupState.remoteConflict;
              lastError = '本地路径已变化，远端旧文件保留待确认';
            } else if (changed &&
                eligible &&
                state != AlbumBackupState.uploading &&
                state != AlbumBackupState.verifying) {
              state = AlbumBackupState.queued;
              lastError = null;
            } else if (state == AlbumBackupState.missingLocal) {
              state = eligible
                  ? AlbumBackupState.queued
                  : AlbumBackupState.skippedExisting;
              lastError = null;
            } else if (state == AlbumBackupState.skippedExisting && eligible) {
              state = AlbumBackupState.queued;
              lastError = null;
            }
          }

          if (state == AlbumBackupState.queued) {
            queuedCount += 1;
          } else if (state == AlbumBackupState.skippedExisting) {
            skippedExistingCount += 1;
          }
          final resetTransfer =
              previous == null || (changed && state == AlbumBackupState.queued);
          final preserveLease = state == AlbumBackupState.uploading ||
              state == AlbumBackupState.verifying;
          final row = <String, Object?>{
            'asset_id': asset.id,
            'destination_id': source.destinationId,
            'source_folder_id': source.id,
            'remote_path':
                state == AlbumBackupState.remoteConflict && previous != null
                    ? previous['remote_path']
                    : remotePath,
            'state': state.name,
            'uploaded_bytes':
                resetTransfer ? 0 : (previous['uploaded_bytes'] ?? 0),
            'total_bytes': asset.sizeBytes,
            'retry_count': previous?['retry_count'] ?? 0,
            'next_retry_ms': state == AlbumBackupState.queued
                ? null
                : previous?['next_retry_ms'],
            'last_error': lastError,
            'remote_size': resetTransfer ? null : previous['remote_size'],
            'remote_modified_ms':
                resetTransfer ? null : previous['remote_modified_ms'],
            'remote_etag': resetTransfer ? null : previous['remote_etag'],
            'remote_hash': resetTransfer ? null : previous['remote_hash'],
            'thumbnail_state': previous?['thumbnail_state'] ??
                AlbumDerivedMediaState.missing.name,
            'lease_owner': preserveLease ? (previous?['lease_owner']) : null,
            'lease_expires_ms':
                preserveLease ? (previous?['lease_expires_ms']) : null,
            'updated_at_ms': timestamp,
          };
          upsertBatch.insert(
            'backup_records',
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          pendingBatchOperations += 1;
          existingRecords[key] = row;
          remotePathOwners[_recordKey(remotePath, source.destinationId)] =
              asset.id;
        }
        for (final entry in existingRecords.entries) {
          final row = entry.value;
          if (row['asset_id'] != asset.id ||
              !activeSourceIds.contains(row['source_folder_id']) ||
              matchedRecordKeys.contains(entry.key)) {
            continue;
          }
          upsertBatch.update(
            'backup_records',
            <String, Object?>{
              'state': AlbumBackupState.remoteConflict.name,
              'last_error': '媒体已移出原备份源，远端旧文件保留待确认',
              'lease_owner': null,
              'lease_expires_ms': null,
              'updated_at_ms': timestamp,
            },
            where: 'asset_id = ? AND destination_id = ?',
            whereArgs: <Object?>[asset.id, row['destination_id']],
          );
          pendingBatchOperations += 1;
        }
        if (pendingBatchOperations >= 500) {
          await flushUpserts();
        }
      }
      await flushUpserts();

      var missingCount = 0;
      if (fullScan) {
        final missingRows = await transaction.query(
          'media_assets',
          columns: <String>['id'],
          where: 'last_seen_scan_id != ? AND missing_local = 0',
          whereArgs: <Object?>[scanId],
        );
        missingCount = missingRows.length;
        if (missingRows.isNotEmpty) {
          final ids = missingRows.map((row) => row['id']! as String).toList();
          final placeholders = List.filled(ids.length, '?').join(',');
          await transaction.rawUpdate(
            'UPDATE media_assets SET missing_local = 1, updated_at_ms = ? '
            'WHERE id IN ($placeholders)',
            <Object?>[timestamp, ...ids],
          );
          await transaction.rawUpdate(
            'UPDATE backup_records SET state = ?, last_error = ?, '
            'lease_owner = NULL, lease_expires_ms = NULL, updated_at_ms = ? '
            'WHERE asset_id IN ($placeholders)',
            <Object?>[
              AlbumBackupState.missingLocal.name,
              '本地媒体已不存在或当前不可访问',
              timestamp,
              ...ids,
            ],
          );
        }
      }

      final scannedMaxModified = assets.fold<int>(
        0,
        (value, asset) =>
            asset.dateModifiedMs > value ? asset.dateModifiedMs : value,
      );
      final newestAsset = assets.fold<AlbumMediaAsset?>(
        null,
        (current, asset) => current == null ||
                asset.dateModifiedMs > current.dateModifiedMs ||
                (asset.dateModifiedMs == current.dateModifiedMs &&
                    asset.mediaStoreId.compareTo(current.mediaStoreId) > 0)
            ? asset
            : current,
      );
      for (final source in sources) {
        final previousCheckpoint = checkpoints[source.id];
        final maxModified =
            scannedMaxModified > (previousCheckpoint?.lastModifiedMs ?? 0)
                ? scannedMaxModified
                : (previousCheckpoint?.lastModifiedMs ?? 0);
        final previousModified = previousCheckpoint?.lastModifiedMs ?? 0;
        final previousMediaStoreId = previousCheckpoint?.lastMediaStoreId ?? '';
        final advancesMediaStoreId = newestAsset != null &&
            (newestAsset.dateModifiedMs > previousModified ||
                (newestAsset.dateModifiedMs == previousModified &&
                    newestAsset.mediaStoreId.compareTo(previousMediaStoreId) >
                        0));
        await transaction.insert(
          'discovery_checkpoints',
          <String, Object?>{
            'source_folder_id': source.id,
            'last_scan_id': scanId,
            'last_scan_started_ms': timestamp,
            'last_scan_completed_ms': timestamp,
            'last_modified_ms': maxModified,
            'last_media_store_id': advancesMediaStoreId
                ? newestAsset.mediaStoreId
                : previousMediaStoreId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      return AlbumDiscoveryResult(
        scanId: scanId,
        discoveredCount: assets.length,
        queuedCount: queuedCount,
        skippedExistingCount: skippedExistingCount,
        missingCount: missingCount,
      );
    });
  }

  Future<List<AlbumMediaAsset>> listMediaPage({
    int limit = 100,
    int offset = 0,
    String? folderPrefix,
    AlbumMediaKind? kind,
  }) async {
    final clauses = <String>['missing_local = 0'];
    final arguments = <Object?>[];
    if (folderPrefix != null && folderPrefix.isNotEmpty) {
      clauses.add('relative_path LIKE ?');
      arguments.add(
          '${folderPrefix.replaceAll('%', r'\%').replaceAll('_', r'\_')}%');
    }
    if (kind != null) {
      clauses.add('media_kind = ?');
      arguments.add(kind.name);
    }
    final rows = await _database.query(
      'media_assets',
      where: clauses.join(' AND '),
      whereArgs: arguments,
      orderBy: 'COALESCE(capture_time_ms, date_modified_ms) DESC, id DESC',
      limit: limit.clamp(1, 500),
      offset: offset < 0 ? 0 : offset,
    );
    return rows.map(AlbumMediaAsset.fromMap).toList(growable: false);
  }

  Future<List<AlbumBackupRecord>> listBackupRecords({
    Set<AlbumBackupState>? states,
    int limit = 500,
    int offset = 0,
  }) async {
    String? where;
    List<Object?>? whereArgs;
    if (states != null && states.isNotEmpty) {
      where = 'state IN (${List.filled(states.length, '?').join(',')})';
      whereArgs = states.map((state) => state.name).toList(growable: false);
    }
    final rows = await _database.query(
      'backup_records',
      where: where,
      whereArgs: whereArgs,
      orderBy: 'updated_at_ms, asset_id',
      limit: limit.clamp(1, 5000),
      offset: offset < 0 ? 0 : offset,
    );
    return rows.map(AlbumBackupRecord.fromMap).toList(growable: false);
  }

  Future<List<AlbumDiscoveryCheckpoint>> listDiscoveryCheckpoints() async {
    final rows = await _database.query(
      'discovery_checkpoints',
      orderBy: 'source_folder_id',
    );
    return rows.map(AlbumDiscoveryCheckpoint.fromMap).toList(growable: false);
  }

  Future<List<AlbumRemoteAsset>> listRemotePage({
    required String destinationId,
    int limit = 100,
    int offset = 0,
  }) async {
    final rows = await _database.rawQuery('''
      SELECT r.*, COALESCE(MAX(m.duration_ms), 0) AS duration_ms
      FROM remote_assets r
      LEFT JOIN backup_records b
        ON b.destination_id = r.destination_id AND b.remote_path = r.path
      LEFT JOIN media_assets m ON m.id = b.asset_id
      WHERE r.destination_id = ?
      GROUP BY r.destination_id, r.path
      ORDER BY COALESCE(r.capture_time_ms, r.modified_ms) DESC, r.path
      LIMIT ? OFFSET ?
    ''', <Object?>[
      destinationId,
      limit.clamp(1, 500),
      offset < 0 ? 0 : offset,
    ]);
    return rows
        .map(
          (row) => AlbumRemoteAsset(
            destinationId: row['destination_id']! as String,
            path: row['path']! as String,
            displayName: row['display_name']! as String,
            mediaKind: AlbumMediaKind.parse(row['media_kind']),
            sizeBytes: row['size_bytes']! as int,
            modifiedMs: row['modified_ms']! as int,
            captureTimeMs: row['capture_time_ms'] as int?,
            durationMs: row['duration_ms']! as int,
            versionKey: row['version_key']! as String,
            thumbnailPath: row['thumbnail_path'] as String?,
            previewPath: row['preview_path'] as String?,
            origin: row['origin']! as String,
          ),
        )
        .toList(growable: false);
  }

  Future<Map<AlbumBackupState, int>> countBackupStates() async {
    final rows = await _database.rawQuery(
      'SELECT state, COUNT(*) AS count FROM backup_records GROUP BY state',
    );
    return <AlbumBackupState, int>{
      for (final row in rows)
        AlbumBackupState.parse(row['state']): (row['count']! as int),
    };
  }

  Future<List<AlbumBackupRecord>> claimQueued({
    required String leaseOwner,
    String? destinationId,
    int limit = 10,
    Duration leaseDuration = const Duration(minutes: 10),
    DateTime? now,
  }) {
    if (leaseOwner.trim().isEmpty) {
      throw const AlbumBackupException('队列 lease owner 不能为空');
    }
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final expires = timestamp + leaseDuration.inMilliseconds;
    return _database.transaction((transaction) async {
      final destinationClause =
          destinationId == null ? '' : 'destination_id = ? AND ';
      final rows = await transaction.query(
        'backup_records',
        where: '$destinationClause(state = ? OR '
            '(state = ? AND (next_retry_ms IS NULL OR next_retry_ms <= ?)) OR '
            '(state IN (?, ?) AND lease_expires_ms IS NOT NULL AND lease_expires_ms <= ?)) '
            'AND (lease_expires_ms IS NULL OR lease_expires_ms <= ?)',
        whereArgs: <Object?>[
          if (destinationId != null) destinationId,
          AlbumBackupState.queued.name,
          AlbumBackupState.failed.name,
          timestamp,
          AlbumBackupState.uploading.name,
          AlbumBackupState.verifying.name,
          timestamp,
          timestamp,
        ],
        orderBy: 'updated_at_ms, asset_id',
        limit: limit.clamp(1, 100),
      );
      final claimed = <AlbumBackupRecord>[];
      for (final row in rows) {
        await transaction.update(
          'backup_records',
          <String, Object?>{
            'state': AlbumBackupState.uploading.name,
            'lease_owner': leaseOwner,
            'lease_expires_ms': expires,
            'last_error': null,
            'updated_at_ms': timestamp,
          },
          where: 'asset_id = ? AND destination_id = ?',
          whereArgs: <Object?>[row['asset_id'], row['destination_id']],
        );
        claimed.add(
          AlbumBackupRecord.fromMap(<String, Object?>{
            ...row,
            'state': AlbumBackupState.uploading.name,
            'lease_owner': leaseOwner,
            'lease_expires_ms': expires,
            'last_error': null,
            'updated_at_ms': timestamp,
          }),
        );
      }
      return claimed;
    });
  }

  Future<void> transitionBackupState({
    required String assetId,
    required String destinationId,
    required AlbumBackupState state,
    int? uploadedBytes,
    int? remoteSize,
    int? remoteModifiedMs,
    String? remoteEtag,
    String? remoteHash,
    String? error,
    DateTime? nextRetry,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return _database.transaction((transaction) async {
      final rows = await transaction.query(
        'backup_records',
        where: 'asset_id = ? AND destination_id = ?',
        whereArgs: <Object?>[assetId, destinationId],
        limit: 1,
      );
      if (rows.isEmpty) {
        throw const AlbumBackupException('找不到备份记录');
      }
      final current = AlbumBackupState.parse(rows.single['state']);
      if (!_allowedTransitions[current]!.contains(state) && current != state) {
        throw AlbumBackupException('不允许从 ${current.name} 转换到 ${state.name}');
      }
      final values = <String, Object?>{
        'state': state.name,
        'updated_at_ms': timestamp,
        if (uploadedBytes != null) 'uploaded_bytes': uploadedBytes,
        if (remoteSize != null) 'remote_size': remoteSize,
        if (remoteModifiedMs != null) 'remote_modified_ms': remoteModifiedMs,
        if (remoteEtag != null) 'remote_etag': remoteEtag,
        if (remoteHash != null) 'remote_hash': remoteHash,
        'last_error': error,
        'next_retry_ms': nextRetry?.millisecondsSinceEpoch,
      };
      if (state != AlbumBackupState.uploading &&
          state != AlbumBackupState.verifying) {
        values['lease_owner'] = null;
        values['lease_expires_ms'] = null;
      }
      if (state == AlbumBackupState.failed) {
        values['retry_count'] = (rows.single['retry_count']! as int) + 1;
      }
      await transaction.update(
        'backup_records',
        values,
        where: 'asset_id = ? AND destination_id = ?',
        whereArgs: <Object?>[assetId, destinationId],
      );
    });
  }

  Future<int> requeueRetryable({
    required String destinationId,
    String? assetId,
    DateTime? now,
  }) {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final assetClause = assetId == null ? '' : ' AND asset_id = ?';
    return _database.update(
      'backup_records',
      <String, Object?>{
        'state': AlbumBackupState.queued.name,
        'next_retry_ms': null,
        'last_error': null,
        'lease_owner': null,
        'lease_expires_ms': null,
        'updated_at_ms': timestamp,
      },
      where: 'destination_id = ? AND state IN (?, ?)$assetClause',
      whereArgs: <Object?>[
        destinationId,
        AlbumBackupState.failed.name,
        AlbumBackupState.paused.name,
        if (assetId != null) assetId,
      ],
    );
  }

  Future<int> requeueInterruptedForeground({
    required String destinationId,
    required String activeLeasePrefix,
    DateTime? now,
  }) {
    if (activeLeasePrefix.trim().isEmpty) {
      throw const AlbumBackupException('前台 lease 前缀不能为空');
    }
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return _database.update(
      'backup_records',
      <String, Object?>{
        'state': AlbumBackupState.queued.name,
        'next_retry_ms': null,
        'last_error': '检测到前台同步中断，已重新排队',
        'lease_owner': null,
        'lease_expires_ms': null,
        'updated_at_ms': timestamp,
      },
      where: 'destination_id = ? AND state IN (?, ?) '
          "AND lease_owner LIKE 'foreground-%' "
          'AND lease_owner NOT LIKE ?',
      whereArgs: <Object?>[
        destinationId,
        AlbumBackupState.uploading.name,
        AlbumBackupState.verifying.name,
        '$activeLeasePrefix%',
      ],
    );
  }

  Future<void> upsertRemoteAssets(List<AlbumRemoteAsset> assets) async {
    if (assets.isEmpty) {
      return;
    }
    await _database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final asset in assets) {
        batch.insert(
          'remote_assets',
          asset.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateThumbnailState({
    required String assetId,
    required String destinationId,
    required AlbumDerivedMediaState state,
    required String versionKey,
    String? thumbnailPath,
    String? error,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.transaction((transaction) async {
      await transaction.update(
        'backup_records',
        <String, Object?>{
          'thumbnail_state': state.name,
          'updated_at_ms': timestamp,
        },
        where: 'asset_id = ? AND destination_id = ?',
        whereArgs: <Object?>[assetId, destinationId],
      );
      final rows = await transaction.query(
        'backup_records',
        columns: const <String>['remote_path'],
        where: 'asset_id = ? AND destination_id = ?',
        whereArgs: <Object?>[assetId, destinationId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final remotePath = rows.single['remote_path']! as String;
      await transaction.insert(
        'derived_media',
        <String, Object?>{
          'destination_id': destinationId,
          'remote_path': remotePath,
          'kind': 'thumbnail',
          'version_key': versionKey,
          'state': state.name,
          'derived_path': thumbnailPath,
          'last_error': error,
          'updated_at_ms': timestamp,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      if (thumbnailPath != null) {
        await transaction.update(
          'remote_assets',
          <String, Object?>{'thumbnail_path': thumbnailPath},
          where: 'destination_id = ? AND path = ?',
          whereArgs: <Object?>[destinationId, remotePath],
        );
      } else if (state != AlbumDerivedMediaState.available) {
        await transaction.update(
          'remote_assets',
          <String, Object?>{'thumbnail_path': null},
          where: 'destination_id = ? AND path = ?',
          whereArgs: <Object?>[destinationId, remotePath],
        );
      }
    });
  }

  Future<List<AlbumMediaAsset>> searchMedia({
    String query = '',
    AlbumMediaKind? kind,
    int? fromMs,
    int? toMs,
    int limit = 200,
    int offset = 0,
  }) async {
    final clauses = <String>['m.missing_local = 0'];
    final arguments = <Object?>[];
    final normalized = query.trim();
    if (normalized.isNotEmpty) {
      clauses.add('(m.display_name LIKE ? ESCAPE \'\\\' OR '
          'm.relative_path LIKE ? ESCAPE \'\\\' OR m.mime_type LIKE ? OR '
          'md.tags LIKE ? ESCAPE \'\\\' OR md.description LIKE ? ESCAPE \'\\\')');
      final pattern =
          '%${normalized.replaceAll('\\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_')}%';
      arguments.addAll(<Object?>[
        pattern,
        pattern,
        '%$normalized%',
        pattern,
        pattern,
      ]);
    }
    if (kind != null) {
      clauses.add('m.media_kind = ?');
      arguments.add(kind.name);
    }
    if (fromMs != null) {
      clauses.add('COALESCE(m.capture_time_ms, m.date_modified_ms) >= ?');
      arguments.add(fromMs);
    }
    if (toMs != null) {
      clauses.add('COALESCE(m.capture_time_ms, m.date_modified_ms) <= ?');
      arguments.add(toMs);
    }
    final rows = await _database.rawQuery('''
      SELECT m.* FROM media_assets m
      LEFT JOIN asset_metadata md ON md.asset_id = m.id
      WHERE ${clauses.join(' AND ')}
      ORDER BY COALESCE(m.capture_time_ms, m.date_modified_ms) DESC, m.id DESC
      LIMIT ? OFFSET ?
    ''', <Object?>[
      ...arguments,
      limit.clamp(1, 500),
      offset < 0 ? 0 : offset,
    ]);
    return rows.map(AlbumMediaAsset.fromMap).toList(growable: false);
  }

  Future<List<AlbumLogicalAlbum>> listLogicalAlbums() async {
    final rows = await _database.rawQuery('''
      SELECT a.id, a.name, a.created_at_ms, a.updated_at_ms,
             COUNT(i.asset_id) AS item_count
      FROM logical_albums a
      LEFT JOIN logical_album_items i ON i.album_id = a.id
      GROUP BY a.id
      ORDER BY a.updated_at_ms DESC, a.name COLLATE NOCASE
    ''');
    return rows
        .map(
          (row) => AlbumLogicalAlbum(
            id: row['id']! as String,
            name: row['name']! as String,
            itemCount: row['item_count']! as int,
            createdAtMs: row['created_at_ms']! as int,
            updatedAtMs: row['updated_at_ms']! as int,
          ),
        )
        .toList(growable: false);
  }

  Future<AlbumLogicalAlbum> createLogicalAlbum(String name,
      {DateTime? now}) async {
    final normalized = name.trim();
    if (normalized.isEmpty) {
      throw const AlbumBackupException('相册名称不能为空');
    }
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final id = 'album-${albumStableKey('$normalized:$timestamp')}';
    await _database.insert('logical_albums', <String, Object?>{
      'id': id,
      'name': normalized,
      'created_at_ms': timestamp,
      'updated_at_ms': timestamp,
    });
    return AlbumLogicalAlbum(
      id: id,
      name: normalized,
      itemCount: 0,
      createdAtMs: timestamp,
      updatedAtMs: timestamp,
    );
  }

  Future<void> deleteLogicalAlbum(String albumId) async {
    await _database.delete(
      'logical_albums',
      where: 'id = ?',
      whereArgs: <Object?>[albumId],
    );
  }

  Future<void> addAssetsToLogicalAlbum({
    required String albumId,
    required Iterable<String> assetIds,
    DateTime? now,
  }) async {
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.transaction((transaction) async {
      final batch = transaction.batch();
      for (final assetId in assetIds.toSet()) {
        batch.insert(
          'logical_album_items',
          <String, Object?>{
            'album_id': albumId,
            'asset_id': assetId,
            'added_at_ms': timestamp,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
      }
      batch.update(
        'logical_albums',
        <String, Object?>{'updated_at_ms': timestamp},
        where: 'id = ?',
        whereArgs: <Object?>[albumId],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<List<AlbumMediaAsset>> listLogicalAlbumAssets({
    required String albumId,
    int limit = 200,
    int offset = 0,
  }) async {
    final rows = await _database.rawQuery('''
      SELECT m.* FROM media_assets m
      JOIN logical_album_items i ON i.asset_id = m.id
      WHERE i.album_id = ? AND m.missing_local = 0
      ORDER BY COALESCE(m.capture_time_ms, m.date_modified_ms) DESC, m.id DESC
      LIMIT ? OFFSET ?
    ''', <Object?>[albumId, limit.clamp(1, 500), offset < 0 ? 0 : offset]);
    return rows.map(AlbumMediaAsset.fromMap).toList(growable: false);
  }

  Future<List<AlbumMediaAsset>> listPotentialDuplicateAssets({
    int limit = 500,
  }) async {
    final rows = await _database.rawQuery('''
      SELECT m.* FROM media_assets m
      JOIN (
        SELECT size_bytes FROM media_assets
        WHERE missing_local = 0 AND size_bytes > 0
        GROUP BY size_bytes HAVING COUNT(*) > 1
      ) candidates ON candidates.size_bytes = m.size_bytes
      WHERE m.missing_local = 0
      ORDER BY m.size_bytes, m.id
      LIMIT ?
    ''', <Object?>[limit.clamp(2, 5000)]);
    return rows.map(AlbumMediaAsset.fromMap).toList(growable: false);
  }

  Future<void> upsertAssetHash({
    required String assetId,
    required String versionKey,
    required String sha256,
    DateTime? now,
  }) async {
    await _database.insert(
      'asset_hashes',
      <String, Object?>{
        'asset_id': assetId,
        'version_key': versionKey,
        'sha256': sha256,
        'updated_at_ms': (now ?? DateTime.now()).millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<AlbumDuplicateGroup>> listDuplicateGroups() async {
    final rows = await _database.rawQuery('''
      SELECT m.*, h.sha256 FROM media_assets m
      JOIN asset_hashes h ON h.asset_id = m.id
      JOIN (
        SELECT sha256 FROM asset_hashes GROUP BY sha256 HAVING COUNT(*) > 1
      ) duplicate_hashes ON duplicate_hashes.sha256 = h.sha256
      WHERE m.missing_local = 0 AND h.version_key =
            (CAST(m.size_bytes AS TEXT) || ':' || CAST(m.date_modified_ms AS TEXT))
      ORDER BY h.sha256, m.id
    ''');
    final grouped = <String, List<AlbumMediaAsset>>{};
    for (final row in rows) {
      grouped
          .putIfAbsent(row['sha256']! as String, () => <AlbumMediaAsset>[])
          .add(AlbumMediaAsset.fromMap(row));
    }
    return grouped.entries
        .where((entry) => entry.value.length > 1)
        .map(
          (entry) => AlbumDuplicateGroup(
            sha256: entry.key,
            sizeBytes: entry.value.first.sizeBytes,
            assets: List<AlbumMediaAsset>.unmodifiable(entry.value),
          ),
        )
        .toList(growable: false);
  }

  Future<List<AlbumMediaAsset>> listVerifiedLocalAssets(
      {int limit = 500}) async {
    final rows = await _database.rawQuery('''
      SELECT DISTINCT m.* FROM media_assets m
      JOIN backup_records b ON b.asset_id = m.id
      WHERE m.missing_local = 0 AND b.state = 'completed'
        AND b.remote_size = b.total_bytes AND b.remote_size = m.size_bytes
      ORDER BY m.size_bytes DESC, m.id
      LIMIT ?
    ''', <Object?>[limit.clamp(1, 5000)]);
    return rows.map(AlbumMediaAsset.fromMap).toList(growable: false);
  }

  Future<void> markAssetsMissing(Iterable<String> assetIds,
      {DateTime? now}) async {
    final ids = assetIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    await _database.transaction((transaction) async {
      for (var start = 0; start < ids.length; start += 400) {
        final chunk = ids.sublist(start, (start + 400).clamp(0, ids.length));
        final placeholders = List.filled(chunk.length, '?').join(',');
        await transaction.rawUpdate(
          'UPDATE media_assets SET missing_local=1, updated_at_ms=? '
          'WHERE id IN ($placeholders)',
          <Object?>[timestamp, ...chunk],
        );
        await transaction.rawUpdate(
          'UPDATE backup_records SET state=?, last_error=?, updated_at_ms=? '
          'WHERE asset_id IN ($placeholders)',
          <Object?>[
            AlbumBackupState.missingLocal.name,
            '本地原件已由用户确认释放；远端已验证副本保留',
            timestamp,
            ...chunk,
          ],
        );
      }
    });
  }

  Future<void> updateAssetMetadata({
    required String assetId,
    bool favorite = false,
    bool archived = false,
    Iterable<String> tags = const <String>[],
    String description = '',
    int rating = 0,
    DateTime? now,
  }) async {
    await _database.insert(
      'asset_metadata',
      <String, Object?>{
        'asset_id': assetId,
        'favorite': favorite ? 1 : 0,
        'archived': archived ? 1 : 0,
        'tags': tags
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty)
            .join(','),
        'description': description.trim(),
        'rating': rating.clamp(0, 5),
        'updated_at_ms': (now ?? DateTime.now()).millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<AlbumAssetMetadata> assetMetadata(String assetId) async {
    final rows = await _database.query(
      'asset_metadata',
      where: 'asset_id = ?',
      whereArgs: <Object?>[assetId],
      limit: 1,
    );
    return rows.isEmpty
        ? AlbumAssetMetadata.empty(assetId)
        : AlbumAssetMetadata.fromMap(rows.single);
  }

  Future<int> markLegacyExistingAssets({
    required String destinationId,
    required Set<String> assetIds,
    DateTime? now,
  }) async {
    if (assetIds.isEmpty) {
      return 0;
    }
    final timestamp = (now ?? DateTime.now()).millisecondsSinceEpoch;
    return _database.transaction((transaction) async {
      var updated = 0;
      final ids = assetIds.toList(growable: false);
      for (var start = 0; start < ids.length; start += 400) {
        final end = (start + 400).clamp(0, ids.length);
        final chunk = ids.sublist(start, end);
        final placeholders = List.filled(chunk.length, '?').join(',');
        updated += await transaction.rawUpdate(
          'UPDATE backup_records SET state = ?, last_error = ?, '
          'lease_owner = NULL, lease_expires_ms = NULL, updated_at_ms = ? '
          'WHERE destination_id = ? AND state = ? '
          'AND asset_id IN ($placeholders)',
          <Object?>[
            AlbumBackupState.skippedExisting.name,
            '已在旧日期目录中找到同尺寸文件；保留原件，等待显式迁移',
            timestamp,
            destinationId,
            AlbumBackupState.queued.name,
            ...chunk,
          ],
        );
      }
      return updated;
    });
  }

  static String _recordKey(String assetId, String destinationId) =>
      '$assetId\u0000$destinationId';

  static bool _assetChanged(
    Map<String, Object?> previous,
    AlbumMediaAsset asset,
  ) {
    return previous['size_bytes'] != asset.sizeBytes ||
        previous['date_modified_ms'] != asset.dateModifiedMs ||
        previous['relative_path'] != asset.relativePath ||
        previous['display_name'] != asset.displayName ||
        previous['mime_type'] != asset.mimeType;
  }

  static String _disambiguateRemotePath(String remotePath, String assetId) {
    final slash = remotePath.lastIndexOf('/');
    final dot = remotePath.lastIndexOf('.');
    final suffix = '_${albumStableKey(assetId).substring(0, 8)}';
    if (dot > slash + 1) {
      return '${remotePath.substring(0, dot)}$suffix${remotePath.substring(dot)}';
    }
    return '$remotePath$suffix';
  }

  static List<AlbumSourceFolder> _bestMatchingSources(
    AlbumMediaAsset asset,
    List<AlbumSourceFolder> sources,
  ) {
    final bestByDestination = <String, AlbumSourceFolder>{};
    for (final source in sources) {
      if (!albumAssetBelongsToSource(asset, source)) {
        continue;
      }
      final existing = bestByDestination[source.destinationId];
      if (existing == null ||
          source.relativePath.length > existing.relativePath.length) {
        bestByDestination[source.destinationId] = source;
      }
    }
    return bestByDestination.values.toList(growable: false);
  }

  static const Map<AlbumBackupState, Set<AlbumBackupState>>
      _allowedTransitions = <AlbumBackupState, Set<AlbumBackupState>>{
    AlbumBackupState.discovered: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.paused,
      AlbumBackupState.missingLocal,
      AlbumBackupState.skippedExisting,
    },
    AlbumBackupState.queued: <AlbumBackupState>{
      AlbumBackupState.uploading,
      AlbumBackupState.paused,
      AlbumBackupState.missingLocal,
      AlbumBackupState.remoteConflict,
    },
    AlbumBackupState.uploading: <AlbumBackupState>{
      AlbumBackupState.verifying,
      AlbumBackupState.failed,
      AlbumBackupState.paused,
      AlbumBackupState.missingLocal,
    },
    AlbumBackupState.verifying: <AlbumBackupState>{
      AlbumBackupState.completed,
      AlbumBackupState.failed,
      AlbumBackupState.missingLocal,
    },
    AlbumBackupState.completed: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.missingLocal,
      AlbumBackupState.remoteConflict,
    },
    AlbumBackupState.failed: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.uploading,
      AlbumBackupState.paused,
      AlbumBackupState.missingLocal,
    },
    AlbumBackupState.paused: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.missingLocal,
    },
    AlbumBackupState.missingLocal: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.skippedExisting,
    },
    AlbumBackupState.remoteConflict: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.paused,
      AlbumBackupState.missingLocal,
    },
    AlbumBackupState.skippedExisting: <AlbumBackupState>{
      AlbumBackupState.queued,
      AlbumBackupState.missingLocal,
    },
  };
}
