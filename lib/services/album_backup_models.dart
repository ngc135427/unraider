enum AlbumInitialBackupMode {
  all,
  newOnly;

  static AlbumInitialBackupMode parse(Object? value) {
    return value?.toString() == newOnly.name ? newOnly : all;
  }
}

enum AlbumMediaKind {
  image,
  video;

  static AlbumMediaKind parse(Object? value) {
    return value?.toString() == video.name ? video : image;
  }
}

enum AlbumBackupState {
  discovered,
  queued,
  uploading,
  verifying,
  completed,
  failed,
  paused,
  missingLocal,
  remoteConflict,
  skippedExisting;

  static AlbumBackupState parse(Object? value) {
    final text = value?.toString();
    return AlbumBackupState.values.firstWhere(
      (state) => state.name == text,
      orElse: () => discovered,
    );
  }
}

enum AlbumDerivedMediaState {
  missing,
  queued,
  generating,
  available,
  failed;

  static AlbumDerivedMediaState parse(Object? value) {
    final text = value?.toString();
    return AlbumDerivedMediaState.values.firstWhere(
      (state) => state.name == text,
      orElse: () => missing,
    );
  }
}

class AlbumSourceFolder {
  const AlbumSourceFolder({
    required this.id,
    required this.volumeName,
    required this.relativePath,
    required this.displayName,
    required this.destinationId,
    required this.remoteBasePath,
    required this.deviceId,
    required this.deviceName,
    required this.initialMode,
    required this.baselineMs,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.enabled = true,
    this.includeImages = true,
    this.includeVideos = true,
  });

  factory AlbumSourceFolder.fromMap(Map<String, Object?> map) {
    return AlbumSourceFolder(
      id: map['id']! as String,
      volumeName: map['volume_name']! as String,
      relativePath: map['relative_path']! as String,
      displayName: map['display_name']! as String,
      destinationId: map['destination_id']! as String,
      remoteBasePath: map['remote_base_path']! as String,
      deviceId: map['device_id']! as String,
      deviceName: map['device_name']! as String,
      initialMode: AlbumInitialBackupMode.parse(map['initial_mode']),
      baselineMs: map['baseline_ms']! as int,
      createdAtMs: map['created_at_ms']! as int,
      updatedAtMs: map['updated_at_ms']! as int,
      enabled: map['enabled'] == 1,
      includeImages: map['include_images'] == 1,
      includeVideos: map['include_videos'] == 1,
    );
  }

  final String id;
  final String volumeName;
  final String relativePath;
  final String displayName;
  final String destinationId;
  final String remoteBasePath;
  final String deviceId;
  final String deviceName;
  final AlbumInitialBackupMode initialMode;
  final int baselineMs;
  final int createdAtMs;
  final int updatedAtMs;
  final bool enabled;
  final bool includeImages;
  final bool includeVideos;

  Map<String, Object?> toMap() => <String, Object?>{
        'id': id,
        'volume_name': volumeName,
        'relative_path': relativePath,
        'display_name': displayName,
        'destination_id': destinationId,
        'remote_base_path': remoteBasePath,
        'device_id': deviceId,
        'device_name': deviceName,
        'initial_mode': initialMode.name,
        'baseline_ms': baselineMs,
        'created_at_ms': createdAtMs,
        'updated_at_ms': updatedAtMs,
        'enabled': enabled ? 1 : 0,
        'include_images': includeImages ? 1 : 0,
        'include_videos': includeVideos ? 1 : 0,
      };

  AlbumSourceFolder copyWith({
    int? baselineMs,
    int? createdAtMs,
    int? updatedAtMs,
    bool? enabled,
  }) {
    return AlbumSourceFolder(
      id: id,
      volumeName: volumeName,
      relativePath: relativePath,
      displayName: displayName,
      destinationId: destinationId,
      remoteBasePath: remoteBasePath,
      deviceId: deviceId,
      deviceName: deviceName,
      initialMode: initialMode,
      baselineMs: baselineMs ?? this.baselineMs,
      createdAtMs: createdAtMs ?? this.createdAtMs,
      updatedAtMs: updatedAtMs ?? this.updatedAtMs,
      enabled: enabled ?? this.enabled,
      includeImages: includeImages,
      includeVideos: includeVideos,
    );
  }
}

class AlbumMediaAsset {
  const AlbumMediaAsset({
    required this.id,
    required this.volumeName,
    required this.mediaStoreId,
    required this.uri,
    required this.relativePath,
    required this.displayName,
    required this.mimeType,
    required this.kind,
    required this.sizeBytes,
    required this.dateAddedMs,
    required this.dateModifiedMs,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.orientation,
    required this.bucketId,
    required this.bucketName,
    this.captureTimeMs,
    this.missingLocal = false,
  });

  factory AlbumMediaAsset.fromMap(Map<String, Object?> map) {
    return AlbumMediaAsset(
      id: map['id']! as String,
      volumeName: map['volume_name']! as String,
      mediaStoreId: map['media_store_id']! as String,
      uri: map['uri']! as String,
      relativePath: map['relative_path']! as String,
      displayName: map['display_name']! as String,
      mimeType: map['mime_type']! as String,
      kind: AlbumMediaKind.parse(map['media_kind']),
      sizeBytes: map['size_bytes']! as int,
      dateAddedMs: map['date_added_ms']! as int,
      dateModifiedMs: map['date_modified_ms']! as int,
      captureTimeMs: map['capture_time_ms'] as int?,
      width: map['width']! as int,
      height: map['height']! as int,
      durationMs: map['duration_ms']! as int,
      orientation: map['orientation']! as int,
      bucketId: map['bucket_id']! as String,
      bucketName: map['bucket_name']! as String,
      missingLocal: map['missing_local'] == 1,
    );
  }

  final String id;
  final String volumeName;
  final String mediaStoreId;
  final String uri;
  final String relativePath;
  final String displayName;
  final String mimeType;
  final AlbumMediaKind kind;
  final int sizeBytes;
  final int dateAddedMs;
  final int dateModifiedMs;
  final int? captureTimeMs;
  final int width;
  final int height;
  final int durationMs;
  final int orientation;
  final String bucketId;
  final String bucketName;
  final bool missingLocal;

  String get versionKey => '$sizeBytes:$dateModifiedMs';

  Map<String, Object?> toMap({
    required String scanId,
    required int updatedAtMs,
  }) =>
      <String, Object?>{
        'id': id,
        'volume_name': volumeName,
        'media_store_id': mediaStoreId,
        'uri': uri,
        'relative_path': relativePath,
        'display_name': displayName,
        'mime_type': mimeType,
        'media_kind': kind.name,
        'size_bytes': sizeBytes,
        'date_added_ms': dateAddedMs,
        'date_modified_ms': dateModifiedMs,
        'capture_time_ms': captureTimeMs,
        'width': width,
        'height': height,
        'duration_ms': durationMs,
        'orientation': orientation,
        'bucket_id': bucketId,
        'bucket_name': bucketName,
        'last_seen_scan_id': scanId,
        'missing_local': 0,
        'updated_at_ms': updatedAtMs,
      };
}

class AlbumBackupRecord {
  const AlbumBackupRecord({
    required this.assetId,
    required this.destinationId,
    required this.sourceFolderId,
    required this.remotePath,
    required this.state,
    required this.uploadedBytes,
    required this.totalBytes,
    required this.retryCount,
    required this.thumbnailState,
    required this.updatedAtMs,
    this.nextRetryMs,
    this.lastError,
    this.remoteSize,
    this.remoteModifiedMs,
    this.remoteEtag,
    this.remoteHash,
    this.leaseOwner,
    this.leaseExpiresMs,
  });

  factory AlbumBackupRecord.fromMap(Map<String, Object?> map) {
    return AlbumBackupRecord(
      assetId: map['asset_id']! as String,
      destinationId: map['destination_id']! as String,
      sourceFolderId: map['source_folder_id']! as String,
      remotePath: map['remote_path']! as String,
      state: AlbumBackupState.parse(map['state']),
      uploadedBytes: map['uploaded_bytes']! as int,
      totalBytes: map['total_bytes']! as int,
      retryCount: map['retry_count']! as int,
      nextRetryMs: map['next_retry_ms'] as int?,
      lastError: map['last_error'] as String?,
      remoteSize: map['remote_size'] as int?,
      remoteModifiedMs: map['remote_modified_ms'] as int?,
      remoteEtag: map['remote_etag'] as String?,
      remoteHash: map['remote_hash'] as String?,
      thumbnailState: AlbumDerivedMediaState.parse(map['thumbnail_state']),
      leaseOwner: map['lease_owner'] as String?,
      leaseExpiresMs: map['lease_expires_ms'] as int?,
      updatedAtMs: map['updated_at_ms']! as int,
    );
  }

  final String assetId;
  final String destinationId;
  final String sourceFolderId;
  final String remotePath;
  final AlbumBackupState state;
  final int uploadedBytes;
  final int totalBytes;
  final int retryCount;
  final int? nextRetryMs;
  final String? lastError;
  final int? remoteSize;
  final int? remoteModifiedMs;
  final String? remoteEtag;
  final String? remoteHash;
  final AlbumDerivedMediaState thumbnailState;
  final String? leaseOwner;
  final int? leaseExpiresMs;
  final int updatedAtMs;
}

class AlbumRemoteAsset {
  const AlbumRemoteAsset({
    required this.destinationId,
    required this.path,
    required this.displayName,
    required this.mediaKind,
    required this.sizeBytes,
    required this.modifiedMs,
    required this.versionKey,
    required this.origin,
    this.captureTimeMs,
    this.durationMs = 0,
    this.thumbnailPath,
    this.previewPath,
  });

  final String destinationId;
  final String path;
  final String displayName;
  final AlbumMediaKind mediaKind;
  final int sizeBytes;
  final int modifiedMs;
  final int? captureTimeMs;
  final int durationMs;
  final String versionKey;
  final String? thumbnailPath;
  final String? previewPath;
  final String origin;

  Map<String, Object?> toMap() => <String, Object?>{
        'destination_id': destinationId,
        'path': path,
        'display_name': displayName,
        'media_kind': mediaKind.name,
        'size_bytes': sizeBytes,
        'modified_ms': modifiedMs,
        'capture_time_ms': captureTimeMs,
        'version_key': versionKey,
        'thumbnail_path': thumbnailPath,
        'preview_path': previewPath,
        'origin': origin,
      };
}

class AlbumDiscoveryResult {
  const AlbumDiscoveryResult({
    required this.scanId,
    required this.discoveredCount,
    required this.queuedCount,
    required this.skippedExistingCount,
    required this.missingCount,
  });

  final String scanId;
  final int discoveredCount;
  final int queuedCount;
  final int skippedExistingCount;
  final int missingCount;
}

class AlbumDiscoveryCheckpoint {
  const AlbumDiscoveryCheckpoint({
    required this.sourceFolderId,
    required this.lastScanId,
    required this.lastScanStartedMs,
    required this.lastScanCompletedMs,
    required this.lastModifiedMs,
    required this.lastMediaStoreId,
  });

  factory AlbumDiscoveryCheckpoint.fromMap(Map<String, Object?> map) {
    return AlbumDiscoveryCheckpoint(
      sourceFolderId: map['source_folder_id']! as String,
      lastScanId: map['last_scan_id']! as String,
      lastScanStartedMs: map['last_scan_started_ms']! as int,
      lastScanCompletedMs: map['last_scan_completed_ms']! as int,
      lastModifiedMs: map['last_modified_ms']! as int,
      lastMediaStoreId: map['last_media_store_id']! as String,
    );
  }

  final String sourceFolderId;
  final String lastScanId;
  final int lastScanStartedMs;
  final int lastScanCompletedMs;
  final int lastModifiedMs;
  final String lastMediaStoreId;
}

class AlbumLogicalAlbum {
  const AlbumLogicalAlbum({
    required this.id,
    required this.name,
    required this.itemCount,
    required this.createdAtMs,
    required this.updatedAtMs,
  });

  final String id;
  final String name;
  final int itemCount;
  final int createdAtMs;
  final int updatedAtMs;
}

class AlbumAssetMetadata {
  const AlbumAssetMetadata({
    required this.assetId,
    required this.favorite,
    required this.archived,
    required this.tags,
    required this.description,
    required this.rating,
  });

  factory AlbumAssetMetadata.empty(String assetId) => AlbumAssetMetadata(
        assetId: assetId,
        favorite: false,
        archived: false,
        tags: const <String>[],
        description: '',
        rating: 0,
      );

  factory AlbumAssetMetadata.fromMap(Map<String, Object?> map) {
    return AlbumAssetMetadata(
      assetId: map['asset_id']! as String,
      favorite: map['favorite'] == 1,
      archived: map['archived'] == 1,
      tags: map['tags']
          .toString()
          .split(',')
          .map((tag) => tag.trim())
          .where((tag) => tag.isNotEmpty)
          .toList(growable: false),
      description: map['description']?.toString() ?? '',
      rating: (map['rating'] as int?) ?? 0,
    );
  }

  final String assetId;
  final bool favorite;
  final bool archived;
  final List<String> tags;
  final String description;
  final int rating;
}

class AlbumDuplicateGroup {
  const AlbumDuplicateGroup({
    required this.sha256,
    required this.sizeBytes,
    required this.assets,
  });

  final String sha256;
  final int sizeBytes;
  final List<AlbumMediaAsset> assets;
}

class AlbumBackupException implements Exception {
  const AlbumBackupException(this.message);

  final String message;

  @override
  String toString() => message;
}
