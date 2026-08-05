import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'embedded_lyrics.dart';
import 'unraid_client.dart';

/// One timed (or plain) lyric line.
class LyricLine {
  const LyricLine({
    required this.time,
    required this.text,
  });

  /// Offset from track start. Zero for untimed plain-text lines.
  final Duration time;
  final String text;
}

/// Parsed lyrics document for one track.
class LyricsDocument {
  const LyricsDocument({
    required this.lines,
    required this.sourcePath,
    this.title,
    this.artist,
    this.album,
    this.timed = true,
  });

  final List<LyricLine> lines;
  final String sourcePath;
  final String? title;
  final String? artist;
  final String? album;
  final bool timed;

  bool get isEmpty => lines.isEmpty;
}

enum LyricsLoadStatus {
  idle,
  loading,
  ready,
  missing,
  error,
}

class LyricsLoadState {
  const LyricsLoadState({
    this.status = LyricsLoadStatus.idle,
    this.document,
    this.message,
  });

  static const idle = LyricsLoadState();
  static const loading = LyricsLoadState(status: LyricsLoadStatus.loading);
  static const missing = LyricsLoadState(
    status: LyricsLoadStatus.missing,
    message: '未找到内嵌歌词或同名 .lrc',
  );

  final LyricsLoadStatus status;
  final LyricsDocument? document;
  final String? message;

  bool get hasLines =>
      document != null && document!.lines.isNotEmpty;
}

/// Loads lyrics for a track: **embedded tags first**, then sidecar `.lrc`/`.txt`.
class LyricsService {
  LyricsService._();

  static const maxLyricsBytes = 512 * 1024;

  /// Process-local cache: audio path -> load result (including missing).
  static final Map<String, LyricsLoadState> _cache =
      <String, LyricsLoadState>{};
  static const _maxCacheEntries = 48;

  /// In-flight loads so concurrent player opens share one fetch.
  static final Map<String, Future<LyricsLoadState>> _inflight =
      <String, Future<LyricsLoadState>>{};

  @visibleForTesting
  static void clearCacheForTest() {
    _cache.clear();
    _inflight.clear();
  }

  /// Binary-search the active line for [position] (last line with time <= pos).
  static int activeIndexAt(List<LyricLine> lines, Duration position) {
    if (lines.isEmpty) {
      return -1;
    }
    if (!lines.first.time.isNegative &&
        lines.every((line) => line.time == Duration.zero) &&
        lines.length > 1) {
      // Untimed plain text: no highlight progression.
      return 0;
    }
    var lo = 0;
    var hi = lines.length - 1;
    var best = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= position) {
        best = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return best;
  }

  static Future<LyricsLoadState> loadForTrack({
    required UnraidClient client,
    required UnraidFileEntry track,
    bool forceRefresh = false,
  }) async {
    if (kIsWeb) {
      return const LyricsLoadState(
        status: LyricsLoadStatus.missing,
        message: 'Web 端暂不支持歌词',
      );
    }

    final key = track.path;
    if (!forceRefresh) {
      final cached = _cache[key];
      if (cached != null) {
        return cached;
      }
      final inflight = _inflight[key];
      if (inflight != null) {
        return inflight;
      }
    } else {
      _cache.remove(key);
    }

    final future = _loadUncached(client: client, track: track);
    _inflight[key] = future;
    try {
      final result = await future;
      _storeCache(key, result);
      return result;
    } finally {
      if (identical(_inflight[key], future)) {
        _inflight.remove(key);
      }
    }
  }

  static Future<LyricsLoadState> _loadUncached({
    required UnraidClient client,
    required UnraidFileEntry track,
  }) async {
    // 1) Embedded lyrics inside the audio file (USLT/SYLT, Vorbis, ©lyr…).
    try {
      final embedded = await EmbeddedLyrics.loadFromTrack(
        client: client,
        track: track,
      );
      if (embedded != null && embedded.lines.isNotEmpty) {
        return LyricsLoadState(
          status: LyricsLoadStatus.ready,
          document: embedded,
        );
      }
    } on Object {
      // Fall through to sidecar files — tag probe failures are common.
    }

    // 2) Sidecar .lrc / .txt next to the track.
    final candidates = candidateLyricsPaths(track.path);
    for (final path in candidates) {
      try {
        final bytes = await client.fetchFileBytes(path);
        if (bytes.isEmpty) {
          continue;
        }
        if (bytes.length > maxLyricsBytes) {
          return LyricsLoadState(
            status: LyricsLoadStatus.error,
            message: '歌词文件过大（>${maxLyricsBytes ~/ 1024} KB）',
          );
        }
        final text = _decodeLyricsBytes(bytes);
        final document = parseLyrics(text, sourcePath: path);
        if (document.lines.isEmpty) {
          continue;
        }
        return LyricsLoadState(
          status: LyricsLoadStatus.ready,
          document: document,
        );
      } on UnraidClientException {
        continue;
      } on Object {
        continue;
      }
    }

    return LyricsLoadState.missing;
  }

  static void _storeCache(String key, LyricsLoadState state) {
    _cache.remove(key);
    if (_cache.length >= _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = state;
  }

  /// Sidecar paths tried in order for an audio file path.
  static List<String> candidateLyricsPaths(String audioPath) {
    final normalized = audioPath.replaceAll(r'\', '/');
    final slash = normalized.lastIndexOf('/');
    final parent = slash <= 0 ? '/' : normalized.substring(0, slash);
    final fileName = slash < 0 ? normalized : normalized.substring(slash + 1);
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    if (base.isEmpty) {
      return const <String>[];
    }
    return <String>[
      '$parent/$base.lrc',
      '$parent/$base.LRC',
      '$parent/lyrics/$base.lrc',
      '$parent/Lyrics/$base.lrc',
      '$parent/$base.txt',
    ];
  }

  static String _decodeLyricsBytes(Uint8List bytes) {
    // Prefer UTF-8; fall back to latin1 so older Chinese LRC (GBK mislabeled)
    // still shows something rather than throwing.
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  /// Parse LRC or plain-text lyrics.
  static LyricsDocument parseLyrics(
    String raw, {
    required String sourcePath,
  }) {
    final lines = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
    final timed = <LyricLine>[];
    String? title;
    String? artist;
    String? album;

    final tagRe = RegExp(r'^\[(ti|ar|al|by|offset|length):([^\]]*)\]\s*$',
        caseSensitive: false);
    final timeRe = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:\.(\d{1,3}))?\]');

    for (final original in lines) {
      final line = original.trim();
      if (line.isEmpty) {
        continue;
      }

      final tag = tagRe.firstMatch(line);
      if (tag != null) {
        final key = tag.group(1)!.toLowerCase();
        final value = tag.group(2)!.trim();
        switch (key) {
          case 'ti':
            title = value;
          case 'ar':
            artist = value;
          case 'al':
            album = value;
          default:
            break;
        }
        continue;
      }

      final matches = timeRe.allMatches(line).toList(growable: false);
      if (matches.isEmpty) {
        continue;
      }
      final text = line.replaceAll(timeRe, '').trim();
      if (text.isEmpty) {
        continue;
      }
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final frac = match.group(3);
        var ms = 0;
        if (frac != null && frac.isNotEmpty) {
          // .1 -> 100ms, .12 -> 120ms, .123 -> 123ms
          final padded = frac.length >= 3
              ? frac.substring(0, 3)
              : frac.padRight(3, '0');
          ms = int.parse(padded);
        }
        timed.add(
          LyricLine(
            time: Duration(
              minutes: minutes,
              seconds: seconds,
              milliseconds: ms,
            ),
            text: text,
          ),
        );
      }
    }

    if (timed.isNotEmpty) {
      timed.sort((a, b) {
        final byTime = a.time.compareTo(b.time);
        if (byTime != 0) {
          return byTime;
        }
        return a.text.compareTo(b.text);
      });
      return LyricsDocument(
        lines: List<LyricLine>.unmodifiable(timed),
        sourcePath: sourcePath,
        title: title,
        artist: artist,
        album: album,
        timed: true,
      );
    }

    // Plain text fallback (e.g. .txt without timestamps).
    final plain = <LyricLine>[];
    for (final original in lines) {
      final line = original.trim();
      if (line.isEmpty) {
        continue;
      }
      if (tagRe.hasMatch(line)) {
        continue;
      }
      plain.add(LyricLine(time: Duration.zero, text: line));
    }
    return LyricsDocument(
      lines: List<LyricLine>.unmodifiable(plain),
      sourcePath: sourcePath,
      title: title,
      artist: artist,
      album: album,
      timed: false,
    );
  }
}
