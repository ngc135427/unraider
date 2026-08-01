# SSH/SFTP File Manager Backend

## Goal

Restore file-management reliability by replacing the current Unraid WebGUI file endpoints with an app-side SSH/SFTP client for remote file operations.

## Background

The existing Flutter app has a single service layer at `lib/services/unraid_client.dart`. Dashboard, Docker, VM, and authentication flows use Unraid WebGUI HTTP endpoints. File and media flows currently use these methods on `UnraidWebGuiClient`:

- `fetchDirectory(String path)` reads `/webGui/include/Browse.php`.
- `ensureDirectory(String path)` creates directories through `/webGui/include/Control.php`.
- `fetchFileBytes(String path)` reads files through a raw HTTP URL.
- `uploadFile(...)` uploads chunks through `/webGui/include/Control.php`.

Callers already depend on those methods:

- Share browser in `lib/pages/main_shell_page.dart` calls `fetchDirectory` and `fetchFileBytes`.
- Album sync in `lib/pages/album_page.dart` calls `ensureDirectory`, `uploadFile`, `fetchDirectory`, and `fetchFileBytes`.

The requested temporary approach is to use SSH/SFTP instead of the broken file manager endpoints:

- File list, move, delete, and rename are sent as native SSH commands.
- Upload and download use standard SFTP.

`dart pub add dartssh2 --dry-run` resolves `dartssh2 2.21.0`, a pure Dart package with SSH exec and SFTP support. It is not available for Flutter Web because native TCP sockets are unavailable in browsers; the current code already rejects file operations on Web.

## Requirements

- Keep existing WebGUI login and management APIs for connection check, dashboard, Docker, VM, and power operations.
- Add an SSH/SFTP transport for file operations without changing current page-level method calls where possible.
- Use the existing login host, username, and password as SSH credentials.
- Resolve the SSH/SFTP connection target from the existing `baseUrl` host and the WebUI-reported SSH port when available.
- Read SSH service state and port from WebUI/API configuration where possible. Repository knowledge files show `config.vars.useSsh` and `config.vars.portssh` fields in `knowledge/query.txt`.
- Fall back to port `22` when the WebUI/API configuration cannot be read or returns an invalid port.
- Keep Web builds unsupported for direct file operations with clear user-facing errors.
- Implement directory listing over SSH command output, producing the existing `UnraidFileEntry` model sorted directories-first and case-insensitive by name.
- Implement create-directory support for album sync with SSH commands and the existing writable path restrictions.
- Implement file download through SFTP for `fetchFileBytes`.
- Implement upload through SFTP for `uploadFile`, preserving the existing chunk-reader contract used by album sync.
- Add public service-layer methods for move, delete, and rename so UI can call them later; the implementation should use SSH native commands.
- Preserve writable operation safety for `/mnt/...` and `/boot/...` paths. Destructive commands must reject unsafe root paths.
- Map SSH/SFTP failures to `UnraidClientException` with concise Chinese messages consistent with existing service errors.
- Avoid logging or persisting the root password.

## Acceptance Criteria

- [x] Share browsing no longer calls `Browse.php` for directory listings.
- [x] Image/media preview no longer downloads files through the raw WebGUI file URL.
- [x] Album backup upload no longer calls `Control.php` upload endpoints.
- [x] Directory creation no longer calls `Control.php`.
- [x] Existing share browser and album flows continue using the same high-level client methods.
- [x] Move, delete, and rename service methods exist and execute via SSH command helpers.
- [x] SSH/SFTP connection uses WebUI/API `portssh` when it can be retrieved, with a `22` fallback.
- [x] Invalid paths, empty names, and destructive operations on `/`, `/mnt`, `/mnt/user`, or `/boot` are rejected before command execution where applicable.
- [x] `flutter test` passes.
- [x] `dart analyze` passes or any unrelated pre-existing findings are documented.

## Out Of Scope

- Replacing WebGUI login, dashboard, Docker, VM, or power-management APIs.
- Building a full file-operation UI for move, delete, and rename in this task unless explicitly requested during planning.
- Supporting SSH private-key authentication.
- Supporting Flutter Web direct SSH/SFTP without a proxy.
