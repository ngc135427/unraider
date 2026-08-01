# SSH/SFTP File Manager Backend Implementation Plan

## Checklist

- [x] Add `dartssh2` dependency and resolve lockfile.
- [x] Read the relevant backend/front-end spec indexes before editing code.
- [x] Add a WebUI/API SSH-port lookup that reads `config.vars.portssh`/`useSsh` when available and falls back to `22`.
- [x] Add an internal SSH connection helper to `UnraidWebGuiClient`.
- [x] Replace `fetchDirectory` with SSH command listing and parser.
- [x] Replace `ensureDirectory` / `_createDirectory` with SSH command creation.
- [x] Replace `fetchFileBytes` with SFTP read.
- [x] Replace `uploadFile` with SFTP write using the existing chunk callback.
- [x] Add service methods for move, delete, and rename using SSH command helpers.
- [x] Centralize shell quoting and unsafe-path checks.
- [x] Update README file/media data-flow notes.
- [x] Add focused service tests for parsing, quoting, and validation helpers.
- [x] Run `dart format`.
- [x] Run `flutter test`.
- [x] Run `dart analyze`.

## Validation Commands

```powershell
dart format lib test
flutter test
dart analyze
```

## Risk Points

- `dartssh2` uses native sockets, so direct file operations stay unsupported on Flutter Web.
- Authentication currently accepts only root for WebGUI. SSH will use the same username/password unless requirements change.
- Real SSH/SFTP integration cannot be fully verified without an Unraid host; local tests should cover command construction, parsing, and safety checks.
- Existing working tree already has unrelated uncommitted changes; edits should stay scoped.

## Rollback Points

- Revert dependency addition in `pubspec.yaml` / `pubspec.lock`.
- Revert service-layer changes in `lib/services/unraid_client.dart`.
- Revert README data-flow text if needed.
