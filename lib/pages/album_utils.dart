part of 'album_page.dart';

Future<bool> _requestMediaAccess() async {
  final results = await <Permission>[
    Permission.photos,
    Permission.videos,
  ].request();
  final modernGranted =
      (results[Permission.photos]?.isGranted ?? false) &&
      (results[Permission.videos]?.isGranted ?? false);
  if (modernGranted) {
    return true;
  }

  // Android 13+ uses granular media permissions; older releases use storage.
  // Limited / partial access is treated as usable so the album can still open.
  try {
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();
    if (photos.isGranted ||
        photos.isLimited ||
        videos.isGranted ||
        videos.isLimited) {
      return true;
    }
  } catch (_) {
    // Some platforms do not expose photos/videos permissions.
  }

  try {
    final storage = await Permission.storage.request();
    if (storage.isGranted || storage.isLimited) {
      return true;
    }
  } catch (_) {
    // Fall through to denied.
  }

  return false;
}

List<LocalMediaAsset> _findPendingUploads({
  required List<LocalMediaAsset> local,
  required List<UnraidFileEntry> remote,
  required String targetDir,
  required List<String> sourceIds,
}) {
  final remotePaths = remote
      .map((entry) => _relativePath(targetDir, entry.path).toLowerCase())
      .toSet();
  final sourceFilter = sourceIds.toSet();
  return local
      .where(
        (asset) =>
            sourceFilter.isEmpty || sourceFilter.contains(asset.bucketId),
      )
      .where((asset) {
        final relative =
            _relativePath(targetDir, _targetPathFor(targetDir, asset));
        return !remotePaths.contains(relative.toLowerCase());
      })
      .toList(growable: false);
}

List<_LocalSection> _groupLocalByDate(List<LocalMediaAsset> media) {
  final buckets = <String, List<LocalMediaAsset>>{};
  for (final asset in media) {
    final title = _dateTitle(asset.dateModified);
    buckets.putIfAbsent(title, () => <LocalMediaAsset>[]).add(asset);
  }
  return buckets.entries
      .map((entry) => _LocalSection(title: entry.key, items: entry.value))
      .toList(growable: false);
}

List<_RemoteSection> _groupRemoteByDate(List<UnraidFileEntry> entries) {
  final buckets = <String, List<UnraidFileEntry>>{};
  for (final entry in entries) {
    final date = entry.modifiedDate ?? DateTime.fromMillisecondsSinceEpoch(0);
    final title = date.millisecondsSinceEpoch == 0 ? '未知日期' : _dateTitle(date);
    buckets.putIfAbsent(title, () => <UnraidFileEntry>[]).add(entry);
  }
  return buckets.entries
      .map((entry) => _RemoteSection(title: entry.key, items: entry.value))
      .toList(growable: false);
}

String _targetPathFor(String targetDir, LocalMediaAsset asset) {
  final base = _trimSlash(_normalizeLocalPath(targetDir));
  final date = asset.dateModified;
  final year = date.year.toString().padLeft(4, '0');
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '$base/$year/$month/$day/${_safeRemoteName(asset.name)}';
}

String _dateTitle(DateTime date) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final value = DateTime(date.year, date.month, date.day);
  if (value == today) {
    return '今天';
  }
  if (value == today.subtract(const Duration(days: 1))) {
    return '昨天';
  }
  return '${date.year}年${date.month.toString().padLeft(2, '0')}月${date.day.toString().padLeft(2, '0')}日';
}

String _safeRemoteName(String name) {
  final sanitized = name
      .replaceAll('/', '_')
      .replaceAll(r'\', '_')
      .replaceAll(RegExp(r'[\x00-\x1F]'), '_')
      .trim();
  if (sanitized.isEmpty) {
    return 'media_${DateTime.now().millisecondsSinceEpoch}';
  }
  return sanitized;
}

String _relativePath(String base, String path) {
  final normalizedBase = _trimSlash(_normalizeLocalPath(base));
  final normalizedPath = _normalizeLocalPath(path);
  if (normalizedPath == normalizedBase) {
    return '';
  }
  if (normalizedPath.startsWith('$normalizedBase/')) {
    return normalizedPath.substring(normalizedBase.length + 1);
  }
  return normalizedPath;
}

String _parentPath(String path) {
  final normalized = _normalizeLocalPath(path);
  final slash = normalized.lastIndexOf('/');
  if (slash <= 0) {
    return '/';
  }
  return normalized.substring(0, slash);
}

String _trimSlash(String path) {
  var value = path;
  while (value.length > 1 && value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

String _normalizeLocalPath(String path) {
  var normalized = path.trim().replaceAll(r'\', '/');
  if (normalized.isEmpty) {
    return '';
  }
  if (!normalized.startsWith('/')) {
    normalized = '/$normalized';
  }
  return _trimSlash(normalized.replaceAll(RegExp(r'/+'), '/'));
}
