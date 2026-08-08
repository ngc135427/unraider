import 'album_backup_models.dart';

final _albumControlCharacters = RegExp(r'[\x00-\x1f\x7f]');
final _albumUnsafeSegmentCharacters = RegExp(r'[/\\:*?"<>|]');
final _albumRepeatedSlash = RegExp(r'/+');
final _albumDeviceIdCharacters = RegExp(r'[^a-zA-Z0-9]');

String normalizeAlbumRemoteRoot(String value) {
  var normalized = value.trim().replaceAll(r'\', '/');
  if (normalized.isEmpty) {
    return '';
  }
  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }
  normalized = normalized.replaceAll(_albumRepeatedSlash, '/');
  final segments = normalized.split('/');
  if (segments.any((segment) => segment == '.' || segment == '..')) {
    throw const AlbumBackupException('相册目标目录包含不安全的路径片段');
  }
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

String normalizeAlbumRelativePath(String value) {
  final normalized = value
      .trim()
      .replaceAll(r'\', '/')
      .replaceAll(_albumRepeatedSlash, '/')
      .split('/')
      .where((segment) => segment.isNotEmpty && segment != '.')
      .toList(growable: false);
  if (normalized.any((segment) => segment == '..')) {
    throw const AlbumBackupException('媒体目录包含不安全的上级路径');
  }
  return normalized.isEmpty ? '' : '${normalized.join('/')}/';
}

String safeAlbumPathSegment(String value, {String fallback = 'media'}) {
  final sanitized = value
      .replaceAll(_albumControlCharacters, '_')
      .replaceAll(_albumUnsafeSegmentCharacters, '_')
      .trim()
      .replaceAll(RegExp(r'[. ]+$'), '');
  if (sanitized.isEmpty || sanitized == '.' || sanitized == '..') {
    return fallback;
  }
  return sanitized;
}

String albumStableKey(String value) {
  var hash = 0x811c9dc5;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash.toRadixString(16).padLeft(8, '0');
}

String albumDestinationId(String remoteBasePath) {
  final root = normalizeAlbumRemoteRoot(remoteBasePath).toLowerCase();
  return 'unraid-${albumStableKey(root)}';
}

String albumSourceFolderId({
  required String volumeName,
  required String relativePath,
  required String destinationId,
}) {
  final normalized = normalizeAlbumRelativePath(relativePath).toLowerCase();
  return 'source-${albumStableKey('$volumeName|$normalized|$destinationId')}';
}

bool albumAssetBelongsToSource(
  AlbumMediaAsset asset,
  AlbumSourceFolder source,
) {
  if (!source.enabled ||
      (asset.kind == AlbumMediaKind.image && !source.includeImages) ||
      (asset.kind == AlbumMediaKind.video && !source.includeVideos)) {
    return false;
  }
  if (source.volumeName != '*' && source.volumeName != asset.volumeName) {
    return false;
  }
  final sourcePath =
      normalizeAlbumRelativePath(source.relativePath).toLowerCase();
  final assetPath =
      normalizeAlbumRelativePath(asset.relativePath).toLowerCase();
  return sourcePath.isEmpty || assetPath.startsWith(sourcePath);
}

String buildAlbumRemotePath({
  required AlbumSourceFolder source,
  required AlbumMediaAsset asset,
}) {
  if (!albumAssetBelongsToSource(asset, source)) {
    throw const AlbumBackupException('媒体不属于所选备份源');
  }
  final root = normalizeAlbumRemoteRoot(source.remoteBasePath);
  if (root.isEmpty) {
    throw const AlbumBackupException('相册目标目录为空');
  }

  final rawDeviceId = source.deviceId.replaceAll(_albumDeviceIdCharacters, '');
  final deviceSuffix = (rawDeviceId.isEmpty
          ? albumStableKey(source.deviceName)
          : rawDeviceId)
      .substring(0, (rawDeviceId.isEmpty ? 8 : rawDeviceId.length.clamp(1, 8)));
  final deviceDirectory =
      '${safeAlbumPathSegment(source.deviceName, fallback: 'Android')}-$deviceSuffix';
  final sourceDirectory =
      '${safeAlbumPathSegment(source.displayName, fallback: 'Photos')}-${albumStableKey(source.id).substring(0, 6)}';

  final sourcePath = normalizeAlbumRelativePath(source.relativePath);
  final assetPath = normalizeAlbumRelativePath(asset.relativePath);
  final relativeWithinSource =
      sourcePath.isEmpty ? assetPath : assetPath.substring(sourcePath.length);
  final directorySegments = relativeWithinSource
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map((segment) => safeAlbumPathSegment(segment, fallback: 'folder'));
  final filename = safeAlbumPathSegment(
    asset.displayName,
    fallback: 'media_${albumStableKey(asset.id)}',
  );

  return <String>[
    root,
    deviceDirectory,
    sourceDirectory,
    ...directorySegments,
    filename,
  ].join('/').replaceAll(_albumRepeatedSlash, '/');
}
