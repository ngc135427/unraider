import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/lyrics_service.dart';

void main() {
  group('LyricsService.parseLyrics', () {
    test('parses standard LRC with tags and dual timestamps', () {
      const raw = '''
[ti:Demo Song]
[ar:Artist]
[al:Album]
[00:12.00]First line
[00:15.50][00:16.00]Repeated
[01:02.123]Late line
''';
      final doc = LyricsService.parseLyrics(
        raw,
        sourcePath: '/mnt/user/music/demo.lrc',
      );
      expect(doc.timed, isTrue);
      expect(doc.title, 'Demo Song');
      expect(doc.artist, 'Artist');
      expect(doc.album, 'Album');
      expect(doc.lines.length, 4);
      expect(doc.lines[0].text, 'First line');
      expect(doc.lines[0].time, const Duration(seconds: 12));
      expect(doc.lines[1].text, 'Repeated');
      expect(doc.lines[1].time, const Duration(seconds: 15, milliseconds: 500));
      expect(doc.lines[2].text, 'Repeated');
      expect(doc.lines[2].time, const Duration(seconds: 16));
      expect(doc.lines[3].time, const Duration(minutes: 1, seconds: 2, milliseconds: 123));
    });

    test('falls back to plain text without timestamps', () {
      const raw = '''
Verse one
Verse two

[ti:Ignored for body]
''';
      final doc = LyricsService.parseLyrics(
        raw,
        sourcePath: '/mnt/user/music/demo.txt',
      );
      expect(doc.timed, isFalse);
      expect(doc.lines.map((l) => l.text).toList(), ['Verse one', 'Verse two']);
    });
  });

  group('LyricsService.activeIndexAt', () {
    test('returns last line at or before position', () {
      const lines = [
        LyricLine(time: Duration(seconds: 0), text: 'a'),
        LyricLine(time: Duration(seconds: 10), text: 'b'),
        LyricLine(time: Duration(seconds: 20), text: 'c'),
      ];
      expect(LyricsService.activeIndexAt(lines, const Duration(seconds: 0)), 0);
      expect(LyricsService.activeIndexAt(lines, const Duration(seconds: 9)), 0);
      expect(LyricsService.activeIndexAt(lines, const Duration(seconds: 10)), 1);
      expect(LyricsService.activeIndexAt(lines, const Duration(seconds: 25)), 2);
      expect(LyricsService.activeIndexAt(const [], Duration.zero), -1);
    });
  });

  group('LyricsService.candidateLyricsPaths', () {
    test('builds sidecar candidates next to the audio file', () {
      final paths = LyricsService.candidateLyricsPaths(
        '/mnt/user/music/Album/song.mp3',
      );
      expect(paths, contains('/mnt/user/music/Album/song.lrc'));
      expect(paths, contains('/mnt/user/music/Album/lyrics/song.lrc'));
      expect(paths, contains('/mnt/user/music/Album/song.txt'));
    });
  });
}
