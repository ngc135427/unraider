# Database Guidelines

> Executable SQLite contracts used by persistent client-side indexes.

---

## Scenario: Persistent album index and resumable queue

### 1. Scope / Trigger

- Apply these rules when Flutter state must survive process death, when a worker
  claims resumable work, or when MediaStore/remote metadata is reconciled.
- The current implementation uses `sqflite`; tests use
  `sqflite_common_ffi` with the same schema and repository contract.
- UI widgets must consume a service/repository API. They must not issue SQL or
  perform file I/O directly.

### 2. Signatures

The album database is `album_backup_v1.db`, schema version `1`. Its durable
identity and queue APIs are:

```dart
AlbumBackupRepository.open({String? databasePath, DatabaseFactory? factory})
replaceSourceFolders(List<AlbumSourceFolder> sources)
reconcileAssets({
  required List<AlbumMediaAsset> assets,
  required List<AlbumSourceFolder> sources,
  bool fullScan = true,
  DateTime? now,
})
claimQueued({required String leaseOwner, int limit = 10, ...})
transitionBackupState({
  required String assetId,
  required String destinationId,
  required AlbumBackupState state,
  ...
})
listMediaPage({int limit = 100, int offset = 0, ...})
listRemotePage({required String destinationId, int limit = 100, int offset = 0})
```

Schema ownership:

- `source_folders`: stable device/source/destination configuration.
- `media_assets`: MediaStore identity and local metadata.
- `backup_records`: one state machine per `(asset_id, destination_id)`.
- `remote_assets`: read-only/imported remote metadata.
- `derived_media`: rebuildable preview/thumbnail state.
- `discovery_checkpoints`: monotonic incremental-scan high-water marks.

### 3. Contracts

- Enable `PRAGMA foreign_keys = ON` in `onConfigure`.
- Store enum values by their Dart `name`; parse unknown/null values to the
  model's safe default rather than casting in the UI.
- Local media identity is stable across renames: `(volume_name, media_kind,
  media_store_id)` is unique, while path/name remain mutable metadata.
- A backup record is unique by `(asset_id, destination_id)`, and remote paths
  are unique within a destination. Sanitized filename collisions receive a
  deterministic asset-ID hash suffix; they are never overwritten silently.
- `fullScan: false` may add/update records but must not mark unseen assets as
  missing. Use `fullScan: true` only when media permission is complete.
- Discovery checkpoints are monotonic. An overlap query may return older rows,
  but neither `last_modified_ms` nor its tie-break `last_media_store_id` may
  move backwards.
- `claimQueued` is transactional and assigns a bounded lease. Reconciliation
  must preserve active `uploading`/`verifying` leases.
- Batch large reconciliations in bounded groups (currently 500 operations) so
  Dart can yield between database calls and memory does not grow with the full
  library.
- Existing preferences and remote originals are retained during migration.
  Repository-open/reconcile failures must leave the legacy view available.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Empty `leaseOwner` | Throw `AlbumBackupException`; do not claim rows |
| Unknown backup record | Throw `AlbumBackupException('找不到备份记录')` |
| Illegal state transition | Throw `AlbumBackupException`; keep the old row |
| Parent path segment (`..`) | Reject before persistence/path construction |
| Same sanitized remote path | Add deterministic suffix; preserve both rows |
| Asset disappears in a full scan | Mark asset/record `missingLocal` |
| Asset is unseen in an incremental/partial-permission scan | Preserve prior state |
| Media path changes after completion | Mark `remoteConflict`; retain old remote path |
| Database open/reconcile failure | Log the error and fall back to legacy page behavior |

### 5. Good / Base / Bad Cases

- Good: 10,000 MediaStore rows are reconciled in bounded batches, then read
  through pages of at most 500 rows.
- Base: an empty incremental scan only advances scan timestamps and preserves
  its previous high-water identity.
- Bad: a partial-permission query is treated as a full scan and thousands of
  inaccessible photos are marked missing.

### 6. Tests Required

- Reopen a file-backed database and assert completed/failed state persists.
- Reconcile new, changed, moved, missing, and overlap-window assets; assert the
  exact queue/conflict/missing state and checkpoint high-water values.
- Claim the same queue from two owners; assert an unexpired lease is not stolen.
- Insert names that sanitize identically; assert two distinct remote paths.
- Reconcile at least 10,000 fixtures; assert bounded page sizes and complete
  state counts.
- Import legacy remote metadata; assert only database rows change and no remote
  file mutation API is called.

### 7. Wrong vs Correct

#### Wrong

```dart
// SQLite implements REPLACE as DELETE + INSERT. This may cascade or violate
// foreign keys when the row is a parent of backup_records/checkpoints.
await txn.insert('source_folders', row,
    conflictAlgorithm: ConflictAlgorithm.replace);

// sqflite Batch retains this map until commit; mutating it changes queued data.
batch.insert('media_assets', row);
row.remove('id');
batch.update('media_assets', row, where: 'id = ?', whereArgs: [id]);
```

#### Correct

```dart
await txn.insert('source_folders', row,
    conflictAlgorithm: ConflictAlgorithm.ignore);
await txn.update(
  'source_folders',
  <String, Object?>{...row}..remove('id'),
  where: 'id = ?',
  whereArgs: <Object?>[id],
);
```

Use insert-ignore plus update for parent upserts, and copy maps before queuing a
different batch operation. This avoids SQLite's delete semantics and delayed
batch-payload mutation.
