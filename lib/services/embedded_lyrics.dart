import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'lyrics_service.dart';
import 'unraid_client.dart';

/// Extracts lyrics embedded in common audio containers without a full download.
///
/// Priority formats:
/// - MP3 / AIFF-style ID3v2: `USLT` (plain) and `SYLT` (timed)
/// - FLAC: Vorbis comment `LYRICS` / `UNSYNCEDLYRICS`
/// - Ogg Vorbis: comment packet `LYRICS` / `UNSYNCEDLYRICS`
/// - MP4/M4A: `©lyr` atom
class EmbeddedLyrics {
  EmbeddedLyrics._();

  /// How much of the file head to pull for tag scanning.
  static const headProbeBytes = 768 * 1024;

  /// Extra probe near EOF for late moov / rare trailing tags (small).
  static const tailProbeBytes = 256 * 1024;

  /// Max accepted embedded lyrics payload.
  static const maxLyricsBytes = 512 * 1024;

  /// Read remote ranges and parse embedded lyrics when present.
  static Future<LyricsDocument?> loadFromTrack({
    required UnraidClient client,
    required UnraidFileEntry track,
  }) async {
    final path = track.path;
    final total = track.sizeBytes > 0 ? track.sizeBytes : null;
    final headLen = total == null
        ? headProbeBytes
        : math.min(total, headProbeBytes);
    if (headLen <= 0) {
      return null;
    }

    final head = await client.fetchFileRange(
      path,
      offset: 0,
      length: headLen,
    );
    if (head.isEmpty) {
      return null;
    }

    // ID3v2 size may exceed the first probe — fetch the full tag when needed.
    final id3Need = id3v2TagLength(head);
    Uint8List probe = head;
    if (id3Need != null && id3Need > head.length && id3Need <= maxLyricsBytes + 64 * 1024) {
      final more = await client.fetchFileRange(
        path,
        offset: 0,
        length: id3Need,
      );
      if (more.length > probe.length) {
        probe = more;
      }
    }

    final fromHead = parseBytes(
      probe,
      sourceLabel: 'embedded:$path',
      fileName: track.name,
    );
    if (fromHead != null && fromHead.lines.isNotEmpty) {
      return fromHead;
    }

    // MP4 moov sometimes sits at the end — small tail probe.
    if (total != null &&
        total > headLen &&
        _looksLikeMp4(head) &&
        total > tailProbeBytes) {
      final tailOffset = total - tailProbeBytes;
      final tail = await client.fetchFileRange(
        path,
        offset: tailOffset,
        length: tailProbeBytes,
      );
      final fromTail = parseMp4Lyrics(
        tail,
        sourceLabel: 'embedded-tail:$path',
      );
      if (fromTail != null && fromTail.lines.isNotEmpty) {
        return fromTail;
      }
    }

    return null;
  }

  /// Parse lyrics from already-fetched bytes (tests + callers with local data).
  static LyricsDocument? parseBytes(
    Uint8List bytes, {
    required String sourceLabel,
    String? fileName,
  }) {
    if (bytes.isEmpty) {
      return null;
    }

    final lower = (fileName ?? '').toLowerCase();
    final tryId3 = lower.isEmpty ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.aiff') ||
        lower.endsWith('.aif') ||
        _hasId3Header(bytes);
    final tryFlac = lower.isEmpty ||
        lower.endsWith('.flac') ||
        _hasFlacHeader(bytes);
    final tryOgg = lower.isEmpty ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.oga') ||
        lower.endsWith('.opus') ||
        _hasOggHeader(bytes);
    final tryMp4 = lower.isEmpty ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.m4b') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.aac') ||
        _looksLikeMp4(bytes);

    if (tryId3) {
      final id3 = parseId3v2Lyrics(bytes, sourceLabel: sourceLabel);
      if (id3 != null && id3.lines.isNotEmpty) {
        return id3;
      }
    }
    if (tryFlac) {
      final flac = parseFlacVorbisLyrics(bytes, sourceLabel: sourceLabel);
      if (flac != null && flac.lines.isNotEmpty) {
        return flac;
      }
    }
    if (tryOgg) {
      final ogg = parseOggVorbisLyrics(bytes, sourceLabel: sourceLabel);
      if (ogg != null && ogg.lines.isNotEmpty) {
        return ogg;
      }
    }
    if (tryMp4) {
      final mp4 = parseMp4Lyrics(bytes, sourceLabel: sourceLabel);
      if (mp4 != null && mp4.lines.isNotEmpty) {
        return mp4;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // ID3v2
  // ---------------------------------------------------------------------------

  static bool _hasId3Header(Uint8List b) =>
      b.length >= 10 && b[0] == 0x49 && b[1] == 0x44 && b[2] == 0x33;

  /// Total ID3v2 tag length including 10-byte header, or null if not ID3.
  static int? id3v2TagLength(Uint8List bytes) {
    if (!_hasId3Header(bytes)) {
      return null;
    }
    final size = _synchsafeSize(bytes, 6);
    final footer = (bytes[5] & 0x10) != 0 ? 10 : 0;
    return 10 + size + footer;
  }

  static LyricsDocument? parseId3v2Lyrics(
    Uint8List bytes, {
    required String sourceLabel,
  }) {
    if (!_hasId3Header(bytes)) {
      return null;
    }
    final version = bytes[3];
    if (version < 2 || version > 4) {
      return null;
    }
    final tagSize = _synchsafeSize(bytes, 6);
    final tagEnd = math.min(bytes.length, 10 + tagSize);
    if (tagEnd <= 10) {
      return null;
    }

    // Prefer timed SYLT over plain USLT.
    LyricsDocument? sylt;
    LyricsDocument? uslt;
    var offset = 10;
    // Skip extended header when present (v3/v4).
    if ((bytes[5] & 0x40) != 0 && offset + 4 <= tagEnd) {
      final extSize = version == 4
          ? _synchsafeSize(bytes, offset)
          : _u32be(bytes, offset);
      offset += version == 4 ? extSize : 4 + extSize;
    }

    while (offset + 10 <= tagEnd) {
      if (bytes[offset] == 0) {
        break;
      }
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      offset += 4;
      final frameSize = version == 4
          ? _synchsafeSize(bytes, offset)
          : _u32be(bytes, offset);
      offset += 4;
      // skip flags
      offset += 2;
      if (frameSize <= 0 || offset + frameSize > tagEnd) {
        break;
      }
      final body = Uint8List.sublistView(bytes, offset, offset + frameSize);
      offset += frameSize;

      if (id == 'SYLT' || id == 'SLT') {
        sylt ??= _parseSyltFrame(body, sourceLabel: sourceLabel);
      } else if (id == 'USLT' || id == 'ULT') {
        uslt ??= _parseUsltFrame(body, sourceLabel: sourceLabel);
      } else if (id == 'TXXX') {
        final txxx = _parseTxxxLyrics(body, sourceLabel: sourceLabel);
        uslt ??= txxx;
      }
    }

    if (sylt != null && sylt.lines.isNotEmpty) {
      return sylt;
    }
    if (uslt != null && uslt.lines.isNotEmpty) {
      return uslt;
    }
    return null;
  }

  static LyricsDocument? _parseUsltFrame(
    Uint8List body, {
    required String sourceLabel,
  }) {
    if (body.isEmpty) {
      return null;
    }
    final encoding = body[0];
    var i = 1;
    // language (3 bytes)
    if (i + 3 > body.length) {
      return null;
    }
    i += 3;
    final desc = _readEncodedString(body, i, encoding);
    i = desc.nextOffset;
    final text = _readEncodedString(body, i, encoding, toEnd: true).value.trim();
    if (text.isEmpty) {
      return null;
    }
    return LyricsService.parseLyrics(text, sourcePath: sourceLabel);
  }

  static LyricsDocument? _parseSyltFrame(
    Uint8List body, {
    required String sourceLabel,
  }) {
    if (body.length < 6) {
      return null;
    }
    final encoding = body[0];
    var i = 1;
    i += 3; // language
    if (i >= body.length) {
      return null;
    }
    final stampFormat = body[i];
    i += 1;
    // content type
    i += 1;
    final desc = _readEncodedString(body, i, encoding);
    i = desc.nextOffset;

    final lines = <LyricLine>[];
    while (i < body.length) {
      final part = _readEncodedString(body, i, encoding);
      i = part.nextOffset;
      if (i + 4 > body.length) {
        break;
      }
      final stamp = _u32be(body, i);
      i += 4;
      final text = part.value.trim();
      if (text.isEmpty) {
        continue;
      }
      // stampFormat: 1 = MPEG frames, 2 = milliseconds. Absolute stamps are
      // treated as ms (frame clocks are uncommon for phone libraries).
      if (stampFormat != 1 && stampFormat != 2) {
        // Unknown timestamp unit — still surface the line ordered by raw stamp.
      }
      lines.add(LyricLine(time: Duration(milliseconds: stamp), text: text));
    }
    if (lines.isEmpty) {
      return null;
    }
    lines.sort((a, b) => a.time.compareTo(b.time));
    return LyricsDocument(
      lines: List<LyricLine>.unmodifiable(lines),
      sourcePath: sourceLabel,
      timed: true,
    );
  }

  static LyricsDocument? _parseTxxxLyrics(
    Uint8List body, {
    required String sourceLabel,
  }) {
    if (body.isEmpty) {
      return null;
    }
    final encoding = body[0];
    final desc = _readEncodedString(body, 1, encoding);
    final key = desc.value.toLowerCase();
    if (key != 'lyrics' &&
        key != 'unsynced lyrics' &&
        key != 'unsyncedlyrics' &&
        key != 'lyric' &&
        !key.contains('lyric')) {
      return null;
    }
    final text =
        _readEncodedString(body, desc.nextOffset, encoding, toEnd: true)
            .value
            .trim();
    if (text.isEmpty) {
      return null;
    }
    return LyricsService.parseLyrics(text, sourcePath: sourceLabel);
  }

  // ---------------------------------------------------------------------------
  // FLAC Vorbis comments
  // ---------------------------------------------------------------------------

  static bool _hasFlacHeader(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0x66 &&
      b[1] == 0x4c &&
      b[2] == 0x61 &&
      b[3] == 0x43; // fLaC

  static LyricsDocument? parseFlacVorbisLyrics(
    Uint8List bytes, {
    required String sourceLabel,
  }) {
    if (!_hasFlacHeader(bytes)) {
      return null;
    }
    var offset = 4;
    while (offset + 4 <= bytes.length) {
      final header = bytes[offset];
      final isLast = (header & 0x80) != 0;
      final type = header & 0x7f;
      final length = (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      offset += 4;
      if (offset + length > bytes.length) {
        break;
      }
      if (type == 4) {
        // VORBIS_COMMENT
        final block =
            Uint8List.sublistView(bytes, offset, offset + length);
        final doc = _lyricsFromVorbisComment(block, sourceLabel: sourceLabel);
        if (doc != null) {
          return doc;
        }
      }
      offset += length;
      if (isLast) {
        break;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Ogg Vorbis identification + comment packet (first ~pages in probe)
  // ---------------------------------------------------------------------------

  static bool _hasOggHeader(Uint8List b) =>
      b.length >= 4 &&
      b[0] == 0x4f &&
      b[1] == 0x67 &&
      b[2] == 0x67 &&
      b[3] == 0x53; // OggS

  static LyricsDocument? parseOggVorbisLyrics(
    Uint8List bytes, {
    required String sourceLabel,
  }) {
    if (!_hasOggHeader(bytes)) {
      return null;
    }
    // Scan for Vorbis comment packet: 0x03 + "vorbis"
    for (var i = 0; i + 7 < bytes.length; i++) {
      if (bytes[i] == 0x03 &&
          bytes[i + 1] == 0x76 &&
          bytes[i + 2] == 0x6f &&
          bytes[i + 3] == 0x72 &&
          bytes[i + 4] == 0x62 &&
          bytes[i + 5] == 0x69 &&
          bytes[i + 6] == 0x73) {
        final comment = Uint8List.sublistView(bytes, i + 7);
        final doc =
            _lyricsFromVorbisComment(comment, sourceLabel: sourceLabel);
        if (doc != null) {
          return doc;
        }
      }
      // OpusTags
      if (i + 8 < bytes.length &&
          bytes[i] == 0x4f &&
          bytes[i + 1] == 0x70 &&
          bytes[i + 2] == 0x75 &&
          bytes[i + 3] == 0x73 &&
          bytes[i + 4] == 0x54 &&
          bytes[i + 5] == 0x61 &&
          bytes[i + 6] == 0x67 &&
          bytes[i + 7] == 0x73) {
        final comment = Uint8List.sublistView(bytes, i + 8);
        final doc =
            _lyricsFromVorbisComment(comment, sourceLabel: sourceLabel);
        if (doc != null) {
          return doc;
        }
      }
    }
    return null;
  }

  static LyricsDocument? _lyricsFromVorbisComment(
    Uint8List data, {
    required String sourceLabel,
  }) {
    if (data.length < 8) {
      return null;
    }
    var o = 0;
    final vendorLen = _u32le(data, o);
    o += 4;
    if (o + vendorLen > data.length) {
      return null;
    }
    o += vendorLen;
    if (o + 4 > data.length) {
      return null;
    }
    final count = _u32le(data, o);
    o += 4;
    String? best;
    for (var n = 0; n < count; n++) {
      if (o + 4 > data.length) {
        break;
      }
      final len = _u32le(data, o);
      o += 4;
      if (len < 0 || o + len > data.length) {
        break;
      }
      final entry = utf8.decode(
        data.sublist(o, o + len),
        allowMalformed: true,
      );
      o += len;
      final eq = entry.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      final key = entry.substring(0, eq).toUpperCase();
      final value = entry.substring(eq + 1).trim();
      if (value.isEmpty) {
        continue;
      }
      if (key == 'LYRICS' ||
          key == 'UNSYNCEDLYRICS' ||
          key == 'UNSYNCED_LYRICS' ||
          key == 'SYNCEDLYRICS' ||
          key == 'SYNCED_LYRICS') {
        // Prefer longer / timed-looking payloads.
        if (best == null ||
            value.length > best.length ||
            (value.contains('[') && !best.contains('['))) {
          best = value;
        }
      }
    }
    if (best == null || best.isEmpty) {
      return null;
    }
    if (best.length > maxLyricsBytes) {
      return null;
    }
    return LyricsService.parseLyrics(best, sourcePath: sourceLabel);
  }

  // ---------------------------------------------------------------------------
  // MP4 / M4A ©lyr
  // ---------------------------------------------------------------------------

  static bool _looksLikeMp4(Uint8List b) {
    if (b.length < 12) {
      return false;
    }
    // ftyp box commonly at start
    return b[4] == 0x66 &&
        b[5] == 0x74 &&
        b[6] == 0x79 &&
        b[7] == 0x70; // ftyp
  }

  static LyricsDocument? parseMp4Lyrics(
    Uint8List bytes, {
    required String sourceLabel,
  }) {
    // Hunt for iTunes-style ©lyr (0xA9 'lyr') then nested 'data' atom.
    for (var i = 0; i + 8 < bytes.length; i++) {
      final isLyr = bytes[i] == 0xA9 &&
          bytes[i + 1] == 0x6c &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x72;
      if (!isLyr) {
        continue;
      }
      final dataIdx =
          _findAscii(bytes, i, math.min(bytes.length, i + 64), 'data');
      if (dataIdx < 0 || dataIdx + 16 > bytes.length) {
        continue;
      }
      // data atom: size(4) 'data'(4) version/flags(8) payload
      final atomStart = dataIdx - 4;
      if (atomStart < 0) {
        continue;
      }
      final atomSize = _u32be(bytes, atomStart);
      if (atomSize < 16 || atomStart + atomSize > bytes.length) {
        continue;
      }
      final payload = bytes.sublist(atomStart + 16, atomStart + atomSize);
      final text = _decodeMp4DataText(payload).trim();
      if (text.isEmpty) {
        continue;
      }
      return LyricsService.parseLyrics(text, sourcePath: sourceLabel);
    }
    return null;
  }

  static String _decodeMp4DataText(Uint8List payload) {
    try {
      return utf8.decode(payload);
    } on FormatException {
      return latin1.decode(payload);
    }
  }

  static int _findAscii(Uint8List bytes, int start, int end, String ascii) {
    final codes = ascii.codeUnits;
    outer:
    for (var i = start; i + codes.length <= end; i++) {
      for (var j = 0; j < codes.length; j++) {
        if (bytes[i + j] != codes[j]) {
          continue outer;
        }
      }
      return i;
    }
    return -1;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static int _synchsafeSize(Uint8List b, int offset) {
    return ((b[offset] & 0x7f) << 21) |
        ((b[offset + 1] & 0x7f) << 14) |
        ((b[offset + 2] & 0x7f) << 7) |
        (b[offset + 3] & 0x7f);
  }

  static int _u32be(Uint8List b, int offset) =>
      (b[offset] << 24) |
      (b[offset + 1] << 16) |
      (b[offset + 2] << 8) |
      b[offset + 3];

  static int _u32le(Uint8List b, int offset) =>
      b[offset] |
      (b[offset + 1] << 8) |
      (b[offset + 2] << 16) |
      (b[offset + 3] << 24);

  static ({String value, int nextOffset}) _readEncodedString(
    Uint8List body,
    int offset,
    int encoding, {
    bool toEnd = false,
  }) {
    if (offset >= body.length) {
      return (value: '', nextOffset: offset);
    }
    switch (encoding) {
      case 1: // UTF-16 with BOM
      case 2: // UTF-16BE
        if (toEnd) {
          final value = _decodeUtf16(body, offset, body.length, encoding);
          return (value: value, nextOffset: body.length);
        }
        var end = offset;
        while (end + 1 < body.length) {
          if (body[end] == 0 && body[end + 1] == 0) {
            break;
          }
          end += 2;
        }
        final value = _decodeUtf16(body, offset, end, encoding);
        final next = end + 2 <= body.length ? end + 2 : body.length;
        return (value: value, nextOffset: next);
      case 3: // UTF-8
        if (toEnd) {
          return (
            value: utf8.decode(
              body.sublist(offset),
              allowMalformed: true,
            ),
            nextOffset: body.length,
          );
        }
        var end = offset;
        while (end < body.length && body[end] != 0) {
          end++;
        }
        return (
          value: utf8.decode(
            body.sublist(offset, end),
            allowMalformed: true,
          ),
          nextOffset: end < body.length ? end + 1 : end,
        );
      default: // ISO-8859-1
        if (toEnd) {
          return (
            value: latin1.decode(body.sublist(offset)),
            nextOffset: body.length,
          );
        }
        var end = offset;
        while (end < body.length && body[end] != 0) {
          end++;
        }
        return (
          value: latin1.decode(body.sublist(offset, end)),
          nextOffset: end < body.length ? end + 1 : end,
        );
    }
  }

  static String _decodeUtf16(
    Uint8List body,
    int start,
    int end,
    int encoding,
  ) {
    if (end <= start) {
      return '';
    }
    var s = start;
    var bigEndian = encoding == 2;
    if (encoding == 1 && end - s >= 2) {
      if (body[s] == 0xFF && body[s + 1] == 0xFE) {
        bigEndian = false;
        s += 2;
      } else if (body[s] == 0xFE && body[s + 1] == 0xFF) {
        bigEndian = true;
        s += 2;
      }
    }
    final codeUnits = <int>[];
    for (var i = s; i + 1 < end; i += 2) {
      final unit = bigEndian
          ? (body[i] << 8) | body[i + 1]
          : body[i] | (body[i + 1] << 8);
      if (unit == 0) {
        break;
      }
      codeUnits.add(unit);
    }
    return String.fromCharCodes(codeUnits);
  }
}
