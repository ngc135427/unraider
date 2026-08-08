# Quality Guidelines

> Code quality standards for backend development.

---

## Overview

Backend code currently lives in the Flutter service layer under `lib/services/`.
Unraid management APIs may still use WebGUI HTTP, but remote filesystem access
has a dedicated SSH/SFTP contract.

---

## Forbidden Patterns

- Do not use Unraid WebGUI file-manager endpoints for filesystem access:
  `/webGui/include/Browse.php`, file-upload `Control.php`, or raw WebGUI file
  URLs.
- Do not download binary file contents through SSH command stdout, including
  `base64 < file` pipelines. Use SFTP `open` plus `read`/`readBytes` so binary
  previews are not limited by remote shell tools or stdout buffering.
- Do not use `SftpFile.readBytes()` defaults for mobile previews. Read remote
  files with a small chunk size and `maxPendingRequests: 1`, and serialize SFTP
  transfers per client. Some Android/Unraid combinations can terminate the app
  while a default concurrent SFTP read is in flight.
- Do not build shell commands by string interpolation without `shellQuote`.
- Do not parse human-readable `ls -l` output. It is locale- and format-sensitive.
- Do not execute destructive operations against `/`, `/mnt`, `/mnt/user`,
  `/mnt/disk*`, `/mnt/cache*`, or `/boot`.

---

## Required Patterns

### Scenario: Android Release SMB Reflection

#### 1. Scope / Trigger

- Trigger: an Android dependency used by the remote-file transport discovers
  classes or constructors through reflection in a minified Release build.

#### 2. Signatures

- Android transport entry point: `readSmbFileRange`.
- MBassador reflection target:
  `ReflectiveHandlerInvocation(SubscriptionContext)`.

#### 3. Contracts

- `android/app/proguard-rules.pro` must keep both SMBJ and its reflective
  `net.engio.mbassy` dependency.
- Debug success is not evidence that a reflection-based transport works after
  R8 minification.

#### 4. Validation & Error Matrix

- Missing MBassador constructor -> SMB client creation fails, the just_audio
  proxy returns HTTP 500, and ExoPlayer reports `(0) Source error`.
- Retained MBassador constructor -> SMB range requests can reach file I/O.

#### 5. Good/Base/Bad Cases

- Good: a Release APK keeps `net.engio.mbassy.**` and streams an MP3 over SMB.
- Base: Debug playback works without R8 but Release is still built separately.
- Bad: only `com.hierynomus.smbj.**` is kept while MBassador is obfuscated.

#### 6. Tests Required

- Build a minified Release APK.
- Assert R8 `seeds.txt` retains
  `ReflectiveHandlerInvocation(SubscriptionContext)`.
- Smoke-test one SMB range read or remote MP3 on an authorized Android device.

#### 7. Wrong vs Correct

Wrong:

```proguard
-keep class com.hierynomus.smbj.** { *; }
```

Correct:

```proguard
-keep class com.hierynomus.smbj.** { *; }
-keep class net.engio.mbassy.** { *; }
```

### Scenario: Dashboard HTML Entity Decoding

#### 1. Scope / Trigger

- Trigger: text scraped from Unraid WebGUI HTML and exposed through
  `UnraidDashboard`.

#### 2. Signatures

- `Future<List<Object?>> parseDashboardOverviewAsync(String html)`
- `String _decodeHtml(String value)`

#### 3. Contracts

- Decode decimal numeric entities such as `&#174;` and `&#8482;` at the
  service parser boundary before values reach UI widgets.
- Keep existing named-entity decoding in the same shared helper.

#### 4. Validation & Error Matrix

- Valid Unicode code point -> decode with `String.fromCharCode`.
- Invalid or out-of-range number -> preserve the original entity; parsing must
  not throw.

#### 5. Good/Base/Bad Cases

- Good: `Intel&#174; Core&#8482;` becomes `Intel® Core™`.
- Base: plain `Intel Core` remains unchanged.
- Bad: a page widget locally replaces CPU-specific entity strings.

#### 6. Tests Required

- Dashboard parser regression must assert the exact decoded CPU summary from a
  representative CPU `<tbody>` block.

#### 7. Wrong vs Correct

Wrong:

```dart
Text(dashboard.cpuSummary.replaceAll('&#174;', '®'));
```

Correct:

```dart
final codePoint = int.tryParse(match.group(1) ?? '');
return codePoint == null || codePoint > 0x10ffff
    ? match.group(0)!
    : String.fromCharCode(codePoint);
```

### Scenario: Unraid SSH/SFTP File Transport

#### 1. Scope / Trigger

- Trigger: any code that lists, creates, moves, deletes, renames, uploads, or
  downloads files on the remote Unraid host.
- Scope: service-layer methods on `UnraidWebGuiClient`; UI should call the
  service methods instead of knowing transport details.

#### 2. Signatures

- `Future<List<UnraidFileEntry>> fetchDirectory(String path)`
- `Future<void> ensureDirectory(String path)`
- `Future<Uint8List> fetchFileBytes(String path)`
- `Future<void> uploadFile({required String targetPath, required int sizeBytes, required Future<Uint8List> Function(int offset, int length) readChunk, int chunkSize})`
- `Future<void> movePath({required String sourcePath, required String targetPath})`
- `Future<void> renamePath({required String path, required String newName})`
- `Future<void> deletePath(String path)`

#### 3. Contracts

- SSH host comes from `Uri.parse(baseUrl).host`.
- SSH username/password reuse the current WebGUI login credentials.
- SSH port is read from WebUI/API config fields `useSsh` and `portssh` when
  possible; fallback is port `22`.
- Directory listing uses an SSH command with nul-delimited fields:
  path, type, byte size, modified epoch, and name.
- Upload and download use SFTP, not WebGUI HTTP.
- SFTP file transfers are serialized per `UnraidWebGuiClient`; preview
  downloads use sequential chunked `SftpFile.read(...)` rather than default
  concurrent `readBytes()`.
- All paths are normalized as absolute POSIX-style remote paths.

#### 4. Validation & Error Matrix

- Flutter Web file operation -> `UnraidClientException` with a Web unsupported
  message.
- `useSsh == false` from config -> `UnraidClientException` explaining SSH is
  disabled.
- Invalid SSH port or config read failure -> fallback to `22`.
- Path outside `/mnt/...` or `/boot/...` for writes -> reject before transport.
- Path containing `.` or `..` segment -> reject before transport.
- Destructive root path -> reject before command execution.
- SSH/SFTP timeout or non-zero command exit -> map to `UnraidClientException`.

#### 5. Good/Base/Bad Cases

- Good: `/mnt/user/Media/photo.jpg` downloads through SFTP.
- Base: config endpoint is unavailable, so file transport connects to SSH port
  `22`.
- Bad: `deletePath('/mnt/user')` is rejected locally before any SSH command is
  sent.

#### 6. Tests Required

- Parser test for nul-delimited directory-listing output.
- Shell-quote test for apostrophes and empty strings.
- Command-construction test for normalized remote paths.
- Safety test for destructive root paths.
- Existing UI tests should still pass because page-level method calls stay
  stable.

#### 7. Wrong vs Correct

Wrong:

```dart
await _send('GET', '/webGui/include/Browse.php');
await client.run('rm -rf $path');
await _runSshCommand('读取文件', 'base64 < ${shellQuote(path)}');
```

Correct:

```dart
final output = await _runSshCommand(
  '读取目录',
  buildSshDirectoryListCommand(path),
);
await _runSshCommand('删除文件', 'rm -rf -- ${shellQuote(path)}');
final file = await sftp.open(path);
final buffer = BytesBuilder(copy: false);
await for (final chunk in file.read(chunkSize: 64 * 1024, maxPendingRequests: 1)) {
  buffer.add(chunk);
}
final bytes = buffer.takeBytes();
```

---

## Testing Requirements

- Run `dart analyze` after service-layer changes.
- Run `flutter test` after service-layer or UI changes.
- Add focused service tests when introducing parsers, shell command builders, or
  path validation helpers.

---

## Code Review Checklist

- File operations use SSH/SFTP, not WebGUI file-manager endpoints.
- Shell arguments are quoted through `shellQuote`.
- Destructive path checks run before command execution.
- Errors are surfaced as `UnraidClientException` with concise user-facing
  Chinese messages.
- Tests cover parser, quote, command, and validation edge cases.
