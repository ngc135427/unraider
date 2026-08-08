# 相册备份与远端预览重构设计

## 1. Architecture goals

- 保持原始媒体为普通文件，可被 SMB/WebDAV/文件管理器直接访问。
- 基础备份与预览不强制依赖完整照片服务器。
- 将传输、索引、派生媒体和图库 UI 解耦，使每层可以独立优化或替换。
- 为可选 NAS 端助手预留协议，但不让其成为基础数据恢复的单点依赖。

## 2. Proposed layers

```text
Android MediaStore
  └─ Local asset discovery / relative paths
          ↓
Persistent backup index + task queue
          ↓
Transport adapters
  ├─ SMB writer
  ├─ WebDAV writer
  ├─ SFTP compatibility writer
  └─ future adapters
          ↓
Remote original files
  └─ .unraider/
      ├─ manifest/
      ├─ thumbnails/
      └─ video-posters/

Gallery repository
  ├─ local MediaStore index
  ├─ persistent remote index
  ├─ disk thumbnail cache
  └─ optional NAS helper API
          ↓
Timeline / Folder / Album UI
```

## 3. Data model

### SourceFolder

- stable id
- Android volume and relative path
- display name
- enabled flag
- destination profile and remote base path
- include images/videos policy
- network, charging and battery constraints
- initial backup mode: all or new-only

### MediaAsset

- stable local identity: volume + MediaStore id, with fallback fingerprint
- source folder id and `RELATIVE_PATH`
- display name, MIME type, media kind
- size, date added, date modified, capture time
- width, height, duration, orientation when available
- optional content hash and paired Live Photo identity

### BackupRecord

- source asset id + destination id
- resolved remote original path
- state: discovered, queued, uploading, verifying, completed, failed, paused, missing-local, remote-conflict
- uploaded and total bytes
- retry count, next retry, last error
- remote size, mtime, etag/hash when available
- thumbnail/poster state

### RemoteAsset

- destination and normalized remote path
- media metadata needed by timeline/folder views
- version key derived from size + mtime/etag
- thumbnail and preview locations
- origin: uploaded-by-device or imported-existing

## 4. Transfer state machine

```text
discovered → queued → uploading .part → verifying → atomic rename → completed
                   ↘ failed ── retry/backoff ────────↗
                   ↘ paused/cancelled
```

Rules:

- Never write directly to the final path for non-empty files.
- Successful transport completion is not enough; size must be verified before `completed`.
- Hash verification is optional for routine uploads and mandatory for explicit integrity checks.
- A name collision creates a deterministic disambiguated name or a conflict state; it never silently overwrites.
- Queue state is committed transactionally before starting network I/O.

## 5. Transport boundary

- First-release transport scope is fixed: SMB and WebDAV are first-class read/write adapters; SFTP remains a compatibility fallback for existing configurations. Other cloud/object-storage adapters are outside this MVP.
- Move local URI → remote streaming into Android native code where possible.
- One channel call should represent a transfer job or a coarse progress stream, not each 1 MiB block.
- Each destination owns a small worker pool; start with concurrency 2 and adapt after measurement.
- Reuse SMB/WebDAV sessions and directories.
- Expose transport capabilities: range read, atomic move, etag, mtime write, free-space query, resumable upload.
- Fall back safely when a capability is absent instead of pretending all transports behave identically.
- All three adapters share queue, temporary-path, verification and status contracts, while concurrency and resume behavior may vary according to advertised capabilities.

## 6. Thumbnail and preview design

### New uploads

- Generate a small grid thumbnail and video poster from the local MediaStore asset before or after original upload.
- Store derived media under `.unraider/` using a collision-safe key based on original relative path and version.
- Derived upload failures do not invalidate a verified original backup; they remain retryable jobs.

### Existing remote media

- Try remote sidecar first.
- Then try persistent local disk cache.
- If neither exists, schedule an on-demand generation job with strict concurrency.
- Pure-client mode may need a one-time original read; optional helper mode generates server-side without sending originals to the phone.

### Cache policy

- Cache key includes destination, normalized path and version key.
- Store metadata separately from bytes so corrupt or stale cache entries can be detected.
- Enforce byte-based disk budget, LRU eviction and manual clear/rebuild controls.
- Never index `.unraider/` as user media.

## 7. Gallery query model

- UI queries a repository, not raw recursive directory listings.
- Repository returns cursor/page-based results with stable ordering.
- Required initial views: timeline, folder, photos, videos.
- Logical albums reference asset IDs and never duplicate originals.
- Filters and grouping execute off the UI isolate or in SQLite.
- Thumbnail prefetch is limited to the visible viewport plus a small look-ahead window.

## 8. Background execution

- Use Android WorkManager for periodic discovery and constrained daily incremental work.
- Use a foreground service with persistent notification for initial/full backup or user-requested focused backup.
- Observe MediaStore changes where reliable, but keep periodic reconciliation as a fallback.
- OEM battery restrictions must surface as actionable diagnostics.
- Reboot and app upgrade must preserve queued and failed work.

## 9. Optional NAS helper boundary

Decision: the first-release architecture uses a mandatory pure-client baseline plus an optional lightweight Unraid helper. The helper is an accelerator and capability extension, not a prerequisite for backup or recovery.

An optional helper may provide:

- indexed directory change detection;
- thumbnail, preview and video poster generation;
- compatible video transcoding;
- content hashing and integrity verification;
- future AI search and face/object pipelines.

The helper must not own the only copy of critical metadata needed to locate originals. Removing it may lose derived/search features, but originals, incremental backup state, newly uploaded sidecars, timeline and folder browsing remain usable. Helper discovery and API negotiation must be capability-based; unavailable or incompatible helpers produce an explicit degraded state and retry path rather than blocking original-file work.

## 10. Compatibility and migration

- Existing `YYYY/MM/DD` backups remain readable and can be imported into `RemoteAsset` without moving files.
- New folder-preserving layout applies only to new jobs unless the user starts an explicit migration.
- A migration must be resumable, collision-aware and reversible through a generated move manifest.
- Existing in-memory caches can be discarded; originals must not be mutated during cache migration.

## 11. Rollback and operations

- Feature flags separate the new index, transfer engine and thumbnail pipeline.
- The old album view remains available during staged migration until parity checks pass.
- Database migrations require forward migration and development-time downgrade fixtures.
- Provide index rebuild and derived-cache rebuild operations.
- Log throughput and latency per stage so regressions are measurable.

## 12. Resolved architecture decision

- The MVP contract guarantees a zero-server pure-client path while allowing an optional lightweight Unraid helper from the first architecture/release.
- Pure-client responsibilities: MediaStore discovery, persistent queue/index, folder-preserving upload, new-media sidecars, disk cache, timeline/folder browsing and direct original access.
- Helper responsibilities: bulk indexing of pre-existing remote files, server-side thumbnails/posters, optional transcodes and hashes, plus future search/AI jobs.
- All helper outputs are rebuildable; helper failure must degrade gracefully and never block verified original backup or restore.

## 13. Product capability boundary

- Core MVP includes reliable folder-preserving backup, incremental state, SMB/WebDAV first-class transport, SFTP compatibility, thumbnails/posters, scalable timeline/folder browsing, background execution, logical albums, basic metadata search, duplicate review and guarded free-up-space.
- Face/object/scene recognition, OCR, semantic search, map clustering, multi-user collaboration, public share links and compatibility transcodes are separate follow-up deliverables.
- Extension fields and capability negotiation may be defined now, but core tables, queues and UI must not require advanced services to be present.
