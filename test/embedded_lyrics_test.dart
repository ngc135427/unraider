import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/embedded_lyrics.dart';

void main() {
  group('EmbeddedLyrics ID3v2 USLT', () {
    test('extracts UTF-8 unsynced lyrics', () {
      final bytes = _buildId3WithUslt(
        'Line one\n[00:05.00]Timed line',
      );
      final doc = EmbeddedLyrics.parseBytes(
        bytes,
        sourceLabel: 'embedded:test.mp3',
        fileName: 'test.mp3',
      );
      expect(doc, isNotNull);
      expect(doc!.lines, isNotEmpty);
      expect(doc.timed, isTrue);
      expect(doc.lines.any((l) => l.text == 'Timed line'), isTrue);
      expect(
        doc.lines.where((l) => l.text == 'Timed line').first.time,
        const Duration(seconds: 5),
      );
    });

    test('extracts plain USLT without timestamps', () {
      final bytes = _buildId3WithUslt('Hello world\nSecond');
      final doc = EmbeddedLyrics.parseId3v2Lyrics(
        bytes,
        sourceLabel: 'embedded:plain.mp3',
      );
      expect(doc, isNotNull);
      expect(doc!.timed, isFalse);
      expect(doc.lines.map((l) => l.text), ['Hello world', 'Second']);
    });
  });

  group('EmbeddedLyrics FLAC Vorbis', () {
    test('reads LYRICS comment', () {
      final bytes = _buildFlacWithLyrics('FLAC line A\nFLAC line B');
      final doc = EmbeddedLyrics.parseFlacVorbisLyrics(
        bytes,
        sourceLabel: 'embedded:test.flac',
      );
      expect(doc, isNotNull);
      expect(doc!.lines.map((l) => l.text), ['FLAC line A', 'FLAC line B']);
    });
  });

  group('EmbeddedLyrics Ogg', () {
    test('reads LYRICS from vorbis comment marker', () {
      final comment = _vorbisCommentBytes({'LYRICS': 'Ogg lyric'});
      final packet = Uint8List.fromList([
        0x03,
        ...'vorbis'.codeUnits,
        ...comment,
      ]);
      // Prefix with OggS so header sniffing succeeds.
      final bytes = Uint8List.fromList([
        ...'OggS'.codeUnits,
        0, 0, 0, 0,
        ...packet,
      ]);
      final doc = EmbeddedLyrics.parseOggVorbisLyrics(
        bytes,
        sourceLabel: 'embedded:test.ogg',
      );
      expect(doc, isNotNull);
      expect(doc!.lines.single.text, 'Ogg lyric');
    });
  });

  group('EmbeddedLyrics MP4', () {
    test('reads ©lyr data atom', () {
      final payload = utf8.encode('M4A lyric text');
      final dataAtom = BytesBuilder()
        ..add(_u32be(16 + payload.length))
        ..add('data'.codeUnits)
        ..add([0, 0, 0, 1, 0, 0, 0, 0]) // type flag + locale
        ..add(payload);
      final lyr = BytesBuilder()
        ..add([0xA9, 0x6c, 0x79, 0x72])
        ..add(dataAtom.toBytes());
      final bytes = Uint8List.fromList([
        0, 0, 0, 20,
        ...'ftyp'.codeUnits,
        ...'M4A '.codeUnits,
        0, 0, 0, 0,
        ...lyr.toBytes(),
      ]);
      final doc = EmbeddedLyrics.parseMp4Lyrics(
        bytes,
        sourceLabel: 'embedded:test.m4a',
      );
      expect(doc, isNotNull);
      expect(doc!.lines.single.text, 'M4A lyric text');
    });
  });
}

List<int> _u32be(int value) => [
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ];

List<int> _synchsafe(int value) => [
      (value >> 21) & 0x7f,
      (value >> 14) & 0x7f,
      (value >> 7) & 0x7f,
      value & 0x7f,
    ];

Uint8List _buildId3WithUslt(String text) {
  // encoding UTF-8 (3), lang eng, empty desc, text
  final body = BytesBuilder()
    ..addByte(3)
    ..add('eng'.codeUnits)
    ..addByte(0) // empty description
    ..add(utf8.encode(text));
  final bodyBytes = body.toBytes();
  final frame = BytesBuilder()
    ..add('USLT'.codeUnits)
    ..add(_u32be(bodyBytes.length))
    ..add([0, 0]) // flags
    ..add(bodyBytes);
  final frames = frame.toBytes();
  final tag = BytesBuilder()
    ..add('ID3'.codeUnits)
    ..add([3, 0]) // v2.3
    ..addByte(0) // flags
    ..add(_synchsafe(frames.length))
    ..add(frames);
  return Uint8List.fromList(tag.toBytes());
}

Uint8List _vorbisCommentBytes(Map<String, String> comments) {
  final b = BytesBuilder();
  const vendor = 'unraider-test';
  final vendorBytes = utf8.encode(vendor);
  b.add(_u32le(vendorBytes.length));
  b.add(vendorBytes);
  b.add(_u32le(comments.length));
  for (final entry in comments.entries) {
    final s = utf8.encode('${entry.key}=${entry.value}');
    b.add(_u32le(s.length));
    b.add(s);
  }
  return Uint8List.fromList(b.toBytes());
}

List<int> _u32le(int value) => [
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
    ];

Uint8List _buildFlacWithLyrics(String lyrics) {
  final comment = _vorbisCommentBytes({'LYRICS': lyrics});
  // last-metadata | type 4
  final header = 0x80 | 0x04;
  final len = comment.length;
  final blockHeader = [
    header,
    (len >> 16) & 0xff,
    (len >> 8) & 0xff,
    len & 0xff,
  ];
  return Uint8List.fromList([
    ...'fLaC'.codeUnits,
    ...blockHeader,
    ...comment,
  ]);
}
