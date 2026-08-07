import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/media_cache.dart';

void main() {
  group('MediaCache video buffering policy', () {
    test('keeps startup threshold small for large videos', () {
      expect(MediaCache.adaptiveReadyBytes(16 * 1024 * 1024), 1024 * 1024);
      expect(MediaCache.adaptiveReadyBytes(100 * 1024 * 1024), 1024 * 1024);
      expect(
          MediaCache.adaptiveReadyBytes(1024 * 1024 * 1024), 2 * 1024 * 1024);
    });

    test('uses larger sustained chunks as video size grows', () {
      expect(MediaCache.adaptiveChunkBytes(16 * 1024 * 1024), 2 * 1024 * 1024);
      expect(MediaCache.adaptiveChunkBytes(100 * 1024 * 1024), 4 * 1024 * 1024);
      expect(
          MediaCache.adaptiveChunkBytes(1024 * 1024 * 1024), 8 * 1024 * 1024);
    });
  });
}
