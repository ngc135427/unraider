import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unraider/services/app_logger.dart';
import 'package:unraider/services/unraid_client.dart';

void main() {
  group('SSH directory listing parsing', () {
    test('maps nul-delimited find output to sorted file entries', () {
      final output = [
        '/mnt/user/media/Zeta.mp4',
        'f',
        '1572864',
        '1700000000.0',
        'Zeta.mp4',
        '/mnt/user/media/Alpha',
        'd',
        '4096',
        '1700000060.0',
        'Alpha',
        '/mnt/user/media/photo.jpg',
        'f',
        '1024',
        '1700000120.0',
        'photo.jpg',
        '',
      ].join('\u0000');

      final entries = parseSshDirectoryListing(output, '/mnt/user/media');

      expect(entries.map((entry) => entry.name), [
        'Alpha',
        'photo.jpg',
        'Zeta.mp4',
      ]);
      expect(entries.first.isDirectory, isTrue);
      expect(entries.first.size, isEmpty);
      expect(entries[1].sizeBytes, 1024);
      expect(entries[1].size, '1.0 KB');
      expect(entries[1].modifiedDate?.millisecondsSinceEpoch, 1700000120000);
    });

    test('preserves whitespace in remote paths and names', () {
      final output = [
        '/mnt/user/media/ spaced .jpg',
        'f',
        '1',
        '1700000000.0',
        ' spaced .jpg',
        '',
      ].join('\u0000');

      final entries = parseSshDirectoryListing(output, '/mnt/user/media');

      expect(entries.single.path, '/mnt/user/media/ spaced .jpg');
      expect(entries.single.name, ' spaced .jpg');
    });
  });

  test('quotes shell arguments safely', () {
    expect(shellQuote('/mnt/user/media'), "'/mnt/user/media'");
    expect(shellQuote("it's here"), "'it'\"'\"'s here'");
    expect(shellQuote(''), "''");
  });

  test('builds directory list command with normalized quoted path', () {
    final command = buildSshDirectoryListCommand(r'mnt\user//media/');

    expect(command, contains("find '/mnt/user/media'"));
    expect(command, contains('-mindepth 1'));
    expect(command, contains('-maxdepth 1'));
    expect(command, contains(r"-printf '%p\0%y\0%s\0%T@\0%f\0'"));
  });

  test('builds media scan command with recursive maxdepth', () {
    final command = buildSshMediaScanCommand(
      r'mnt\user//photos/mobile/',
      maxDepth: 6,
    );

    expect(command, contains("find '/mnt/user/photos/mobile'"));
    expect(command, contains('-mindepth 1'));
    expect(command, contains('-maxdepth 6'));
    expect(command, contains('-type f'));
    expect(command, contains(r"-printf '%p\0%y\0%s\0%T@\0%f\0'"));
  });

  test('async listing parse matches sync for small payloads', () async {
    final output = [
      '/mnt/user/media/Zeta.mp4',
      'f',
      '1572864',
      '1700000000.0',
      'Zeta.mp4',
      '/mnt/user/media/Alpha',
      'd',
      '4096',
      '1700000060.0',
      'Alpha',
      '/mnt/user/media/photo.jpg',
      'f',
      '1024',
      '1700000120.0',
      'photo.jpg',
      '',
    ].join('\u0000');

    final sync = parseSshDirectoryListing(output, '/mnt/user/media');
    final async = await parseSshDirectoryListingAsync(output, '/mnt/user/media');
    expect(async.map((e) => e.name).toList(), sync.map((e) => e.name).toList());
    expect(async.map((e) => e.path).toList(), sync.map((e) => e.path).toList());
  });

  test('dashboard overview parse returns stable row layout', () async {
    const html = '''
<tbody><i class="icon-cpu"></i><h3 class="tile-header-main">Processor</h3>
Intel&#174; Core&#8482; i3-10105F<span class="cpu-load">0%</span></tbody>
<title>Tower | Unraid</title>
Unraid OS 7.0.0
<tbody id="array_list"><h3 class="tile-header-main">Started</h3><span>10 GB / 20 GB 50%</span></tbody>
''';
    final row = await parseDashboardOverviewAsync(html);
    expect(row.length, 7);
    expect(row[0], isA<String>());
    expect(row[1], contains('7.0.0'));
    expect(row[2], 'Intel® Core™ i3-10105F');
    expect(row[6], isA<double>());
  });

  test('file entry media flags are fixed at construction', () {
    final photo = UnraidFileEntry(
      name: 'IMG.JPG',
      path: '/mnt/user/a/IMG.JPG',
      isDirectory: false,
      sizeBytes: 10,
      size: '10 B',
      modified: '',
      modifiedDate: null,
    );
    final song = UnraidFileEntry(
      name: 'track.flac',
      path: '/mnt/user/a/track.flac',
      isDirectory: false,
      sizeBytes: 10,
      size: '10 B',
      modified: '',
      modifiedDate: null,
    );
    final mp3 = UnraidFileEntry(
      name: 'pop.mp3',
      path: '/mnt/user/a/pop.mp3',
      isDirectory: false,
      sizeBytes: 10,
      size: '10 B',
      modified: '',
      modifiedDate: null,
    );
    expect(photo.isImage, isTrue);
    expect(photo.isVideo, isFalse);
    expect(photo.isAudio, isFalse);
    expect(photo.nameLower, 'img.jpg');
    expect(song.isAudio, isTrue);
    expect(song.isLossless, isTrue);
    expect(song.isMedia, isTrue);
    expect(mp3.isAudio, isTrue);
    expect(mp3.isLossless, isFalse);
    expect(mp3.nameLower, 'pop.mp3');
  });

  test('byte listing parse matches string parse for small payloads', () async {
    final output = [
      '/mnt/user/media/Zeta.mp4',
      'f',
      '1572864',
      '1700000000.0',
      'Zeta.mp4',
      '/mnt/user/media/Alpha',
      'd',
      '4096',
      '1700000060.0',
      'Alpha',
      '',
    ].join('\u0000');
    final bytes = Uint8List.fromList(utf8.encode(output));
    final fromString = await parseSshDirectoryListingAsync(output, '/mnt/user/media');
    final fromBytes =
        await parseSshDirectoryListingBytesAsync(bytes, '/mnt/user/media');
    expect(
      fromBytes.map((e) => e.name).toList(),
      fromString.map((e) => e.name).toList(),
    );
  });

  test('docker parser extracts containers from push script', () {
    final body = "prefix\u0000"
        "docker.push({name:'Plex',id:'abc123',state:1,pause:0,update:1});"
        "docker.push({name:'Stopped',id:'def',state:0,pause:0,update:0});";
    final items = parseDockerItems(body);
    expect(items.length, 2);
    expect(items.first.title, 'Plex');
    expect(items.first.status, '运行中');
    expect(items.first.tags, contains('有更新'));
    expect(items.last.status, '已停止');
  });

  test('vm parser maps names and states without O(n^2) scan', () {
    final body = "addVMContext('Home','uuid-1');\u0000"
        "kvm.push({id:'uuid-1',state:'running'});"
        "kvm.push({id:'uuid-2',state:'shutoff'});";
    final items = parseVmItems(body);
    expect(items.map((item) => item.id).toList(), ['uuid-1', 'uuid-2']);
    expect(items.first.title, 'Home');
    expect(items.first.status, isNotEmpty);
    expect(items.last.title, 'uuid-2');
  });

  test('async media filter keeps images and videos only', () async {
    final output = [
      '/mnt/user/media/song.mp3',
      'f',
      '100',
      '1700000000.0',
      'song.mp3',
      '/mnt/user/media/photo.jpg',
      'f',
      '1024',
      '1700000120.0',
      'photo.jpg',
      '/mnt/user/media/clip.mp4',
      'f',
      '2048',
      '1700000060.0',
      'clip.mp4',
      '/mnt/user/media/notes.txt',
      'f',
      '10',
      '1700000030.0',
      'notes.txt',
      '',
    ].join('\u0000');

    final media = await parseSshDirectoryListingAsync(
      output,
      '/mnt/user/media',
      mediaOnly: true,
      includeImages: true,
      includeVideos: true,
      includeAudio: false,
    );

    expect(media.map((e) => e.name).toList(), ['photo.jpg', 'clip.mp4']);
    expect(media.every((e) => e.isImage || e.isVideo), isTrue);
  });

  test('builds file stream URI under the WebGUI base URL', () {
    final client = UnraidWebGuiClient(
      baseUrl: 'http://tower.local',
      username: 'root',
      password: 'secret',
    );
    addTearDown(client.close);

    final uri = client.fileStreamUri('/mnt/user/photos/a b.jpg');
    expect(uri.scheme, 'http');
    expect(uri.host, 'tower.local');
    expect(uri.path, '/mnt/user/photos/a%20b.jpg');
  });

  test('builds modified time command from source timestamp', () {
    final command = buildSetModifiedTimeCommand(
      "/mnt/user/media/it's here.jpg",
      DateTime.fromMillisecondsSinceEpoch(1700000123456, isUtc: true),
    );

    expect(command,
        "touch -m -d @1700000123 -- '/mnt/user/media/it'\"'\"'s here.jpg'");
  });

  test('maps Unraid user share paths to SMB share paths', () {
    final mapped = smbSharePathFromUnraidPath(
      r'\mnt\user\photos\Mobile Backup\IMG.jpg',
    );

    expect(mapped?.share, 'photos');
    expect(mapped?.relativePath, 'Mobile Backup/IMG.jpg');
    expect(smbSharePathFromUnraidPath('/mnt/user/photos'), isNull);
    expect(smbSharePathFromUnraidPath('/mnt/disk1/photos/IMG.jpg'), isNull);
  });

  test('login page detector avoids full-body lowercasing', () {
    const login = '''
<html><body>
<form action="/login">
<input name="username" />
<input name="password" />
</form>
</body></html>
''';
    const dashboard = '''
<html><body>
<div id="dashboard">CPU</div>
<input name="search" />
</body></html>
''';
    expect(looksLikeLoginPage(login), isTrue);
    expect(looksLikeLoginPage(dashboard), isFalse);
  });

  test('identifies unsafe destructive paths', () {
    expect(isUnsafeDestructivePath('/'), isTrue);
    expect(isUnsafeDestructivePath('/mnt'), isTrue);
    expect(isUnsafeDestructivePath('/mnt/user'), isTrue);
    expect(isUnsafeDestructivePath('/mnt/disk1'), isTrue);
    expect(isUnsafeDestructivePath('/mnt/cache'), isTrue);
    expect(isUnsafeDestructivePath('/boot'), isTrue);

    expect(isUnsafeDestructivePath('/mnt/user/media'), isFalse);
    expect(isUnsafeDestructivePath('/mnt/disk1/media'), isFalse);
    expect(isUnsafeDestructivePath('/boot/config'), isFalse);
  });

  test('AppLogger formats and flushes without throwing', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await AppLogger.log('wave4_logger_smoke');
    await AppLogger.flush();
  });
}
