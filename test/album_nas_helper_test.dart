import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:unraider/services/album_backup_models.dart';
import 'package:unraider/services/album_nas_helper.dart';

void main() {
  group('Album NAS helper client', () {
    test('classifies unauthorized and incompatible helpers', () async {
      var incompatible = false;
      final client = AlbumNasHelperClient(
        baseUrl: 'http://nas:9487/',
        token: 'wrong',
        httpClient: MockClient((request) async {
          if (request.url.path == '/healthz') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'status': 'ok',
                'service': 'unraider-album-helper',
              }),
              200,
            );
          }
          if (!incompatible) return http.Response('{}', 401);
          return http.Response(
            jsonEncode(<String, Object?>{
              'apiVersion': 99,
              'helperVersion': '9.0.0',
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );

      final unauthorized = await client.probe();
      expect(
        unauthorized.availability,
        AlbumNasHelperAvailability.unauthorized,
      );
      incompatible = true;
      final unsupported = await client.probe();
      expect(
        unsupported.availability,
        AlbumNasHelperAvailability.incompatible,
      );

      incompatible = false;
      final missingCapabilityClient = AlbumNasHelperClient(
        baseUrl: 'http://nas:9487',
        token: 'secret',
        httpClient: MockClient((request) async {
          if (request.url.path == '/healthz') {
            return http.Response(
              '{"status":"ok","service":"unraider-album-helper"}',
              200,
            );
          }
          return http.Response(
            '{"apiVersion":1,"helperVersion":"0.1.0","capabilities":[]}',
            200,
          );
        }),
      );
      final missingCapability = await missingCapabilityClient.probe();
      expect(
        missingCapability.availability,
        AlbumNasHelperAvailability.incompatible,
      );
    });

    test('negotiates capabilities and consumes cursor pages', () async {
      final requestedCursors = <String?>[];
      final client = AlbumNasHelperClient(
        baseUrl: 'nas:9487',
        token: 'secret',
        httpClient: MockClient((request) async {
          if (request.url.path == '/healthz') {
            return http.Response(
              '{"status":"ok","service":"unraider-album-helper"}',
              200,
            );
          }
          if (request.url.path == '/api/v1/capabilities') {
            expect(request.headers['Authorization'], 'Bearer secret');
            return http.Response(
              jsonEncode(<String, Object?>{
                'apiVersion': 1,
                'helperVersion': '0.1.0',
                'capabilities': <String>['asset-index-v1'],
                'roots': <Map<String, String>>[
                  <String, String>{
                    'id': 'photos',
                    'remotePrefix': '/mnt/user/photos',
                  },
                ],
              }),
              200,
            );
          }
          requestedCursors.add(request.url.queryParameters['cursor']);
          final second = request.url.queryParameters['cursor'] != null;
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Map<String, Object?>>[
                <String, Object?>{
                  'remotePath': second
                      ? '/mnt/user/photos/two.mp4'
                      : '/mnt/user/photos/one.jpg',
                  'displayName': second ? 'two.mp4' : 'one.jpg',
                  'mediaKind': second ? 'video' : 'image',
                  'mimeType': second ? 'video/mp4' : 'image/jpeg',
                  'sizeBytes': second ? 20 : 10,
                  'modifiedMs': 1000,
                  'versionKey': second ? '20:1000' : '10:1000',
                  'thumbnailPath': second
                      ? '/mnt/user/photos/.unraider/video-posters/aa/aa.jpg'
                      : null,
                },
              ],
              'nextCursor': second ? null : 'next-page',
            }),
            200,
          );
        }),
      );

      final status = await client.probe();
      final assets = await client.listAllAssets(prefix: '/mnt/user/photos');

      expect(status.isReady, isTrue);
      expect(status.roots.single.id, 'photos');
      expect(assets, hasLength(2));
      expect(assets.last.mediaKind.name, 'video');
      expect(assets.last.thumbnailPath, contains('video-posters'));
      expect(requestedCursors, <String?>[null, 'next-page']);
    });

    test('submits idempotent rebuild and decodes job progress', () async {
      final client = AlbumNasHelperClient(
        baseUrl: 'http://nas:9487',
        token: 'secret',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.headers['Idempotency-Key'], 'mobile-request');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['type'], 'rebuild');
          return http.Response(
            jsonEncode(<String, Object?>{
              'id': 'job-1',
              'type': 'rebuild',
              'state': 'running',
              'progress': 0.5,
              'processed': 5,
              'total': 10,
            }),
            202,
          );
        }),
      );

      final job = await client.submitJob(
        type: 'rebuild',
        rootId: 'photos',
        idempotencyKey: 'mobile-request',
      );

      expect(job.id, 'job-1');
      expect(job.progress, 0.5);
      expect(job.isFinished, isFalse);
    });

    test('decodes smart search intelligence and forwards filters', () async {
      final client = AlbumNasHelperClient(
        baseUrl: 'http://nas:9487',
        token: 'secret',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/search');
          expect(request.url.queryParameters['q'], '咖啡 发票');
          expect(request.url.queryParameters['kind'], 'image');
          expect(request.url.queryParameters['fromMs'], '100');
          return http.Response(
            jsonEncode(<String, Object?>{
              'items': <Map<String, Object?>>[
                <String, Object?>{
                  'remotePath': '/mnt/user/photos/receipt.jpg',
                  'displayName': 'receipt.jpg',
                  'mediaKind': 'image',
                  'mimeType': 'image/jpeg',
                  'sizeBytes': 10,
                  'modifiedMs': 200,
                  'versionKey': '10:200',
                  'intelligence': <String, Object?>{
                    'caption': '桌面上的咖啡发票',
                    'labels': <String>['咖啡', '票据'],
                    'ocrSnippet': '合计 38 元',
                    'ocrVersion': 'tesseract:chi_sim+eng:v1',
                  },
                },
              ],
              'nextCursor': null,
            }),
            200,
            headers: const <String, String>{
              'content-type': 'application/json; charset=utf-8',
            },
          );
        }),
      );

      final results = await client.searchAssets(
        query: '咖啡 发票',
        prefix: '/mnt/user/photos',
        kind: AlbumMediaKind.image,
        fromMs: 100,
      );

      expect(results, hasLength(1));
      expect(results.single.intelligence?.caption, '桌面上的咖啡发票');
      expect(results.single.intelligence?.labels, contains('票据'));
    });
  });
}
