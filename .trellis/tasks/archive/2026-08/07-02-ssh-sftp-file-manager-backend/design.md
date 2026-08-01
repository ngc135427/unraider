# SSH/SFTP File Manager Backend Design

## Architecture

Keep `UnraidWebGuiClient` as the app-facing client to minimize front-end churn. Add an internal SSH/SFTP file transport used only by file methods. HTTP remains responsible for WebGUI authentication and management APIs.

The client will derive SSH connection settings from existing constructor values:

- Host: `Uri.parse(baseUrl).host`
- Port: WebUI/API-reported SSH port when available; otherwise `22`
- Username: existing `username`
- Password: existing password callback

The repository's Unraid API knowledge files include `config.vars.useSsh` and `config.vars.portssh`. Add a small configuration lookup before the first SSH connection. If the lookup succeeds and `useSsh` is enabled with a valid `portssh`, use that port. If the lookup fails, the fields are absent, or the port is invalid, continue with port `22` and let the SSH connection error surface naturally if the server is not listening there.

`dartssh2` will be added as a direct dependency. The SSH connection is opened lazily the first time a file operation needs it and reused while the `UnraidWebGuiClient` instance lives. `close()` will close both HTTP and SSH resources.

## Data Flow

Directory list:

```text
UI -> UnraidWebGuiClient.fetchDirectory(path)
   -> SSH exec command
   -> parse delimited rows
   -> List<UnraidFileEntry>
```

Download:

```text
UI -> UnraidWebGuiClient.fetchFileBytes(path)
   -> SFTP open/readBytes
   -> Uint8List
```

Upload:

```text
Album sync -> UnraidWebGuiClient.uploadFile(targetPath, readChunk)
   -> ensure parent directory
   -> SFTP open create/truncate/write
   -> stream chunks from existing readChunk callback
```

Create/move/delete/rename:

```text
UI/service caller -> client method
   -> validate path/name
   -> SSH exec native command
   -> non-zero exit becomes UnraidClientException
```

## SSH Commands

Commands should be built from shell-quoted absolute paths. Listing should avoid localized `ls` formats by using `find`/`stat` with tab-delimited output, e.g. one level below the target directory with fields for path, type, byte size, and modified epoch. The implementation should parse only the agreed delimiter format, not human-readable `ls -l`.

Mutation commands:

- Create directory: `mkdir -p -- <path>`
- Move/rename: `mv -- <source> <target>`
- Delete file: `rm -f -- <path>`
- Delete directory: `rm -rf -- <path>` after stricter unsafe-path rejection

## Safety Boundaries

Existing write constraints remain:

- Writable file paths must have a parent under `/mnt/...` or `/boot/...`.
- Writable directory paths must be under `/mnt/...` or `/boot/...`.
- Destructive targets reject `/`, `/mnt`, `/mnt/user`, `/mnt/disk*`, `/mnt/cache*`, `/boot`, and empty paths unless the operation clearly targets a child path.
- Path normalization keeps absolute POSIX paths and collapses duplicate separators.
- File or directory names used for create/rename must not contain `/`, `\`, empty strings, or `..`.

Shell quoting must be centralized and tested.

## Compatibility

Existing pages can continue calling `fetchDirectory`, `ensureDirectory`, `fetchFileBytes`, and `uploadFile`. Web remains unsupported for direct file operations, matching the existing behavior.

## Rollback

The old WebGUI file endpoint code can be removed or kept as private fallback only if needed. If SSH/SFTP causes regressions, rollback consists of reverting the service-layer transport change and dependency addition.
