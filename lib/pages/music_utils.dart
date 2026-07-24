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

String _albumName(String path, String rootPath) {
  final normalized = path.replaceAll(r'\', '/');
  final root = rootPath.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  var relative = normalized;
  if (normalized.startsWith('$root/')) {
    relative = normalized.substring(root.length + 1);
  }
  final parts = relative.split('/').where((part) => part.isNotEmpty).toList();
  if (parts.length >= 2) {
    return parts[parts.length - 2];
  }
  if (parts.isNotEmpty) {
    return root.split('/').last.isEmpty ? '音乐库' : root.split('/').last;
  }
  return '音乐库';
}

String _displayTitle(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot <= 0) {
    return fileName;
  }
  return fileName.substring(0, dot);
}
