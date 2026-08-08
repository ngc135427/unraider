# 相册备份与远端预览实施计划

## Task execution map

父任务不直接作为实现目标。按以下顺序启动和验收子任务，括号内为阻塞依赖：

1. `photo-backup-foundation`（无）
2. `photo-transfer-engine`（foundation）
3. `photo-preview-gallery`（foundation；sidecar 集成依赖 transfer）
4. `photo-background-operations`（foundation + transfer）
5. `photo-management-basics`（foundation + preview + background）
6. `photo-nas-helper`（foundation + preview；可选，不阻塞纯客户端核心）
7. `photo-intelligence`、`photo-sharing`、`photo-video-transcoding`（非 MVP；依赖详见各自 PRD）

每个子任务独立执行 planning → start → implement → check → archive。父任务仅在所有核心子任务完成后执行跨任务回归和最终验收。

## Phase 0 — Measurement and safety baseline

- [ ] Add transfer metrics: local read, connect, mkdir, upload, verify, thumbnail and remote scan durations.
- [ ] Add benchmark fixtures for many small images, large JPEG/RAW and long videos.
- [ ] Add regression coverage for interrupted uploads, duplicate names and stale remote files.
- [ ] Document current throughput and time-to-first-thumbnail on LAN SMB, WebDAV and SFTP fallback.
- [ ] Define the versioned, capability-negotiated optional-helper contract and explicit pure-client fallback behavior before implementing either side.

## Phase 1 — Persistent local model

- [ ] Add SQLite schema for source folders, media assets, backup records, remote assets and derived media.
- [ ] Extend Android MediaStore projection with volume, `RELATIVE_PATH`, MIME, dimensions, duration and capture time.
- [ ] Implement incremental discovery checkpoints and reconciliation.
- [ ] Migrate existing preferences into the new source-folder model.
- [ ] Add task/status UI backed by the database.

## Phase 2 — Safe high-throughput upload

- [ ] Define transport capability and progress contracts.
- [ ] Implement native Android SMB streaming upload with connection reuse.
- [ ] Implement WebDAV streaming upload and capability-aware verification.
- [ ] Adapt the existing SFTP uploader to the shared safety/progress contract and retain it as a compatibility fallback.
- [ ] Add controlled per-destination concurrency, pause/cancel and exponential retry.
- [ ] Write to `.part`, verify size, atomically rename, then mark complete.
- [ ] Remove per-batch full remote rescan from the normal success path.
- [ ] Add explicit manual integrity scan and repair flow.

## Phase 3 — Thumbnail and preview pipeline

- [ ] Generate local image thumbnails and video posters for new uploads.
- [ ] Define `.unraider` derived-media layout and exclusion rules.
- [ ] Upload and resolve sidecar thumbnails independently from originals.
- [ ] Add persistent disk cache with byte budget, LRU and version invalidation.
- [ ] Replace full-original tile downloads with thumbnail requests.
- [ ] Add on-demand historical thumbnail generation and retry states.
- [ ] Keep fullscreen still caching and Range video playback as separate paths.

## Phase 4 — Gallery UI scalability

- [ ] Replace raw full-list consumption with repository pagination.
- [ ] Implement virtualized timeline and folder views.
- [ ] Add local/queued/uploading/verified/failed badges.
- [ ] Add photos/videos filters, date jump and folder navigation.
- [ ] Add limited viewport prefetch and cancellation when tiles leave scope.
- [ ] Validate scrolling and memory use with at least 50,000 indexed assets.

## Phase 5 — Background reliability

- [ ] Add WorkManager discovery and constrained incremental backup.
- [ ] Add focused foreground backup for initial import.
- [ ] Restore queues after reboot/process death.
- [ ] Surface battery optimization, Wi-Fi, space, permission and authentication blockers.
- [ ] Add notification progress and failure actions.

## Phase 6 — Photo management features

- [ ] Add logical albums and optional phone-album mapping.
- [ ] Add favorite/archive/tag/description/rating metadata.
- [ ] Add basic EXIF, date, folder and filename search/filter.
- [ ] Add exact duplicate review and guarded free-up-space flow.
- [ ] Add offline recent-media cache policy.

## Phase 7 — Optional helper and advanced capabilities

- [ ] Implement and package the optional NAS helper API defined in Phase 0.
- [ ] Add bulk historical thumbnail and video-poster generation.
- [ ] Keep compatibility transcodes, face/location/scene/OCR/semantic analysis and sharing behind versioned extension points; implement them only in their follow-up tasks.

## Validation

- Flutter: `flutter analyze`, targeted unit/widget tests, then full `flutter test`.
- Android: Gradle/Kotlin build and native transfer tests against disposable SMB/WebDAV fixtures.
- Device tests: process kill, reboot, network handoff, Wi-Fi loss, low battery, storage full and permission revocation.
- Integrity: compare local and remote size/hash samples; confirm no final-path partial files.
- Performance: record MB/s, CPU, memory, battery impact, initial scan time and time-to-first-thumbnail.

## Risky areas and rollback points

- Android scoped storage and MediaStore identity changes across delete/recreate or device restore.
- SMB/WebDAV atomic rename and mtime behavior differs by server.
- Multiple workers must not upload the same record concurrently.
- Thumbnail generation for HEIC/RAW/large panoramas can exhaust memory without decode bounds.
- Old date-based and new folder-preserving layouts may coexist for a long time.
- Background execution behavior differs across OEM Android builds.

## Parent review gate

- [x] Resolve the helper/no-helper MVP boundary: mandatory pure-client baseline plus optional helper acceleration.
- [x] Confirm first-release writable transports: SMB and WebDAV first-class, SFTP compatibility fallback.
- [x] Confirm product boundary: basic photo management remains in core MVP; AI, map, sharing and compatibility transcodes become follow-up tasks.
- [x] Run the PRD convergence pass.
- [ ] Have the user approve PRD, design and implementation scope.
- [ ] After approval, start `photo-backup-foundation`; do not start this parent task.
