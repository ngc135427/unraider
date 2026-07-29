part of 'music_page.dart';

List<String> _candidateMusicRoots(String preferred) {
  final candidates = <String>[
    preferred,
    '/mnt/user/music',
    '/mnt/user/Music',
    '/mnt/user/media/music',
    '/mnt/user/Media/Music',
    '/mnt/user/音频',
    '/mnt/user/音乐',
  ];
  final seen = <String>{};
  return candidates
      .map((path) => path.trim().replaceAll(RegExp(r'/+$'), ''))
      .where((path) => path.isNotEmpty && seen.add(path))
      .toList(growable: false);
}

/// Process-local album-name cache: large libraries call [_albumName] from
/// filters, stats, and tile builds on every keystroke otherwise.
final Map<String, String> _albumNameCache = <String, String>{};
const _maxAlbumNameCacheEntries = 2048;

String _albumName(String path, String rootPath) {
  final cacheKey = '$rootPath\u0000$path';
  final cached = _albumNameCache[cacheKey];
  if (cached != null) {
    // LRU touch so hot library paths stay under the cap.
    _albumNameCache.remove(cacheKey);
    _albumNameCache[cacheKey] = cached;
    return cached;
  }

  final normalized = path.replaceAll(r'\', '/');
  final root = rootPath.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  var relative = normalized;
  if (normalized.startsWith('$root/')) {
    relative = normalized.substring(root.length + 1);
  }
  final parts = relative.split('/').where((part) => part.isNotEmpty).toList();
  late final String album;
  if (parts.length >= 2) {
    album = parts[parts.length - 2];
  } else if (parts.isNotEmpty) {
    final rootName = root.split('/').last;
    album = rootName.isEmpty ? '音乐库' : rootName;
  } else {
    album = '音乐库';
  }

  if (_albumNameCache.length >= _maxAlbumNameCacheEntries) {
    _albumNameCache.remove(_albumNameCache.keys.first);
  }
  _albumNameCache[cacheKey] = album;
  return album;
}

/// Process-local display-title cache for music tiles/player headers.
final Map<String, String> _displayTitleCache = <String, String>{};
const _maxDisplayTitleCacheEntries = 2048;

String _displayTitle(String fileName) {
  final cached = _displayTitleCache[fileName];
  if (cached != null) {
    _displayTitleCache.remove(fileName);
    _displayTitleCache[fileName] = cached;
    return cached;
  }
  final dot = fileName.lastIndexOf('.');
  final title = dot <= 0 ? fileName : fileName.substring(0, dot);
  if (_displayTitleCache.length >= _maxDisplayTitleCacheEntries) {
    _displayTitleCache.remove(_displayTitleCache.keys.first);
  }
  _displayTitleCache[fileName] = title;
  return title;
}
