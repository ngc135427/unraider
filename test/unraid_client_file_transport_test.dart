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
