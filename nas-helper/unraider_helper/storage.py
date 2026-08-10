from __future__ import annotations

import base64
import json
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterable


def _now_ms() -> int:
    return int(time.time() * 1000)


class HelperStore:
    def __init__(self, database_path: Path):
        database_path.parent.mkdir(parents=True, exist_ok=True)
        self.database_path = database_path
        self._lock = threading.RLock()
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.database_path, timeout=30)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 30000")
        return connection

    @contextmanager
    def _connection(self):
        connection = self._connect()
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._connection() as database:
            database.execute("PRAGMA journal_mode = WAL")
            database.executescript(
                """
                CREATE TABLE IF NOT EXISTS assets (
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    remote_path TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    media_kind TEXT NOT NULL,
                    mime_type TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL,
                    modified_ms INTEGER NOT NULL,
                    version_key TEXT NOT NULL,
                    thumbnail_path TEXT,
                    content_hash TEXT,
                    seen_scan TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(root_id, relative_path)
                );
                CREATE UNIQUE INDEX IF NOT EXISTS assets_remote_path ON assets(remote_path);
                CREATE INDEX IF NOT EXISTS assets_page ON assets(root_id, relative_path);
                CREATE TABLE IF NOT EXISTS asset_intelligence (
                    root_id TEXT NOT NULL,
                    relative_path TEXT NOT NULL,
                    version_key TEXT NOT NULL,
                    ocr_text TEXT NOT NULL DEFAULT '',
                    ocr_version TEXT,
                    caption TEXT NOT NULL DEFAULT '',
                    labels_json TEXT NOT NULL DEFAULT '[]',
                    semantic_version TEXT,
                    last_error TEXT,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY(root_id, relative_path),
                    FOREIGN KEY(root_id, relative_path)
                        REFERENCES assets(root_id, relative_path) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    idempotency_key TEXT NOT NULL UNIQUE,
                    type TEXT NOT NULL,
                    state TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    progress REAL NOT NULL DEFAULT 0,
                    processed INTEGER NOT NULL DEFAULT 0,
                    total INTEGER NOT NULL DEFAULT 0,
                    message TEXT,
                    result_json TEXT,
                    last_error TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    cancel_requested INTEGER NOT NULL DEFAULT 0,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    started_at_ms INTEGER,
                    completed_at_ms INTEGER
                );
                CREATE INDEX IF NOT EXISTS jobs_queue ON jobs(state, created_at_ms);
                """
            )
            try:
                database.executescript(
                    """
                    CREATE VIRTUAL TABLE IF NOT EXISTS asset_intelligence_fts USING fts5(
                        root_id UNINDEXED,
                        relative_path UNINDEXED,
                        search_text,
                        tokenize='unicode61 remove_diacritics 2'
                    );
                    CREATE TRIGGER IF NOT EXISTS asset_intelligence_ai AFTER INSERT ON asset_intelligence BEGIN
                        INSERT INTO asset_intelligence_fts(root_id,relative_path,search_text)
                        SELECT new.root_id,new.relative_path,
                               a.display_name || ' ' || a.relative_path || ' ' ||
                               new.ocr_text || ' ' || new.caption || ' ' || new.labels_json
                        FROM assets a
                        WHERE a.root_id=new.root_id AND a.relative_path=new.relative_path;
                    END;
                    CREATE TRIGGER IF NOT EXISTS asset_intelligence_ad AFTER DELETE ON asset_intelligence BEGIN
                        DELETE FROM asset_intelligence_fts
                        WHERE root_id=old.root_id AND relative_path=old.relative_path;
                    END;
                    CREATE TRIGGER IF NOT EXISTS asset_intelligence_au AFTER UPDATE ON asset_intelligence BEGIN
                        DELETE FROM asset_intelligence_fts
                        WHERE root_id=old.root_id AND relative_path=old.relative_path;
                        INSERT INTO asset_intelligence_fts(root_id,relative_path,search_text)
                        SELECT new.root_id,new.relative_path,
                               a.display_name || ' ' || a.relative_path || ' ' ||
                               new.ocr_text || ' ' || new.caption || ' ' || new.labels_json
                        FROM assets a
                        WHERE a.root_id=new.root_id AND a.relative_path=new.relative_path;
                    END;
                    """
                )
                self._fts_enabled = True
            except sqlite3.OperationalError:
                self._fts_enabled = False
            database.execute(
                """
                INSERT OR IGNORE INTO asset_intelligence (
                    root_id,relative_path,version_key,updated_at_ms
                )
                SELECT root_id,relative_path,version_key,updated_at_ms FROM assets
                """
            )

    def upsert_assets(self, assets: Iterable[dict[str, Any]], scan_id: str) -> int:
        count = 0
        now = _now_ms()
        with self._lock, self._connection() as database:
            for asset in assets:
                stale = database.execute(
                    "SELECT 1 FROM asset_intelligence WHERE root_id=? AND relative_path=? AND version_key<>?",
                    (asset["rootId"], asset["relativePath"], asset["versionKey"]),
                ).fetchone()
                database.execute(
                    """
                    INSERT INTO assets (
                        root_id,relative_path,remote_path,display_name,media_kind,mime_type,
                        size_bytes,modified_ms,version_key,thumbnail_path,content_hash,
                        seen_scan,updated_at_ms
                    ) VALUES (?,?,?,?,?,?,?,?,?,NULL,NULL,?,?)
                    ON CONFLICT(root_id,relative_path) DO UPDATE SET
                        remote_path=excluded.remote_path,
                        display_name=excluded.display_name,
                        media_kind=excluded.media_kind,
                        mime_type=excluded.mime_type,
                        size_bytes=excluded.size_bytes,
                        modified_ms=excluded.modified_ms,
                        thumbnail_path=CASE
                            WHEN assets.version_key=excluded.version_key THEN assets.thumbnail_path
                            ELSE NULL END,
                        content_hash=CASE
                            WHEN assets.version_key=excluded.version_key THEN assets.content_hash
                            ELSE NULL END,
                        version_key=excluded.version_key,
                        seen_scan=excluded.seen_scan,
                        updated_at_ms=excluded.updated_at_ms
                    """,
                    (
                        asset["rootId"],
                        asset["relativePath"],
                        asset["remotePath"],
                        asset["displayName"],
                        asset["mediaKind"],
                        asset["mimeType"],
                        asset["sizeBytes"],
                        asset["modifiedMs"],
                        asset["versionKey"],
                        scan_id,
                        now,
                    ),
                )
                if stale:
                    database.execute(
                        "DELETE FROM asset_intelligence WHERE root_id=? AND relative_path=?",
                        (asset["rootId"], asset["relativePath"]),
                    )
                database.execute(
                    """
                    INSERT OR IGNORE INTO asset_intelligence (
                        root_id,relative_path,version_key,updated_at_ms
                    ) VALUES (?,?,?,?)
                    """,
                    (
                        asset["rootId"],
                        asset["relativePath"],
                        asset["versionKey"],
                        now,
                    ),
                )
                count += 1
        return count

    def finish_scan(self, root_id: str, scan_id: str) -> int:
        with self._lock, self._connection() as database:
            cursor = database.execute(
                "DELETE FROM assets WHERE root_id=? AND seen_scan<>?",
                (root_id, scan_id),
            )
            return cursor.rowcount

    def list_assets(
        self,
        *,
        limit: int,
        cursor: str | None = None,
        root_id: str | None = None,
        prefix: str | None = None,
        media_kind: str | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        clauses: list[str] = []
        arguments: list[Any] = []
        if root_id:
            clauses.append("root_id=?")
            arguments.append(root_id)
        if prefix:
            normalized = prefix.rstrip("/")
            clauses.append("(remote_path=? OR remote_path LIKE ? ESCAPE '\\')")
            arguments.extend((normalized, normalized.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "/%"))
        if media_kind:
            clauses.append("media_kind=?")
            arguments.append(media_kind)
        if cursor:
            decoded = base64.urlsafe_b64decode(cursor.encode("ascii")).decode("utf-8")
            cursor_root, cursor_path = decoded.split("\0", 1)
            clauses.append("(root_id>? OR (root_id=? AND relative_path>?))")
            arguments.extend((cursor_root, cursor_root, cursor_path))
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        bounded_limit = max(1, min(500, limit))
        with self._connection() as database:
            rows = database.execute(
                f"SELECT * FROM assets{where} ORDER BY root_id,relative_path LIMIT ?",
                (*arguments, bounded_limit + 1),
            ).fetchall()
        has_more = len(rows) > bounded_limit
        rows = rows[:bounded_limit]
        values = [self._asset_json(row) for row in rows]
        next_cursor = None
        if has_more and rows:
            marker = f"{rows[-1]['root_id']}\0{rows[-1]['relative_path']}"
            next_cursor = base64.urlsafe_b64encode(marker.encode("utf-8")).decode("ascii")
        return values, next_cursor

    def assets_for_job(self, root_id: str | None, media_kind: str | None = None) -> list[dict[str, Any]]:
        clauses: list[str] = []
        arguments: list[Any] = []
        if root_id:
            clauses.append("a.root_id=?")
            arguments.append(root_id)
        if media_kind:
            clauses.append("a.media_kind=?")
            arguments.append(media_kind)
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self._connection() as database:
            rows = database.execute(
                "SELECT a.*,i.ocr_text,i.ocr_version,i.caption,i.labels_json,"
                "i.semantic_version,i.last_error AS intelligence_error "
                f"FROM assets a LEFT JOIN asset_intelligence i USING(root_id,relative_path){where} "
                "ORDER BY a.root_id,a.relative_path",
                arguments,
            ).fetchall()
        return [dict(row) for row in rows]

    def update_asset_intelligence(
        self,
        root_id: str,
        relative_path: str,
        version_key: str,
        *,
        ocr: tuple[str, str] | None = None,
        semantic: tuple[str, list[str], str] | None = None,
        error: str | None = None,
    ) -> None:
        with self._lock, self._connection() as database:
            existing = database.execute(
                "SELECT * FROM asset_intelligence WHERE root_id=? AND relative_path=?",
                (root_id, relative_path),
            ).fetchone()
            same_version = bool(existing and existing["version_key"] == version_key)
            ocr_text = str(existing["ocr_text"]) if same_version else ""
            ocr_version = existing["ocr_version"] if same_version else None
            caption = str(existing["caption"]) if same_version else ""
            labels_json = str(existing["labels_json"]) if same_version else "[]"
            semantic_version = existing["semantic_version"] if same_version else None
            if ocr is not None:
                ocr_text, ocr_version = ocr
            if semantic is not None:
                caption, labels, semantic_version = semantic
                labels_json = json.dumps(labels, ensure_ascii=False, separators=(",", ":"))
            database.execute(
                """
                INSERT INTO asset_intelligence (
                    root_id,relative_path,version_key,ocr_text,ocr_version,
                    caption,labels_json,semantic_version,last_error,updated_at_ms
                ) VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(root_id,relative_path) DO UPDATE SET
                    version_key=excluded.version_key,
                    ocr_text=excluded.ocr_text,
                    ocr_version=excluded.ocr_version,
                    caption=excluded.caption,
                    labels_json=excluded.labels_json,
                    semantic_version=excluded.semantic_version,
                    last_error=excluded.last_error,
                    updated_at_ms=excluded.updated_at_ms
                """,
                (
                    root_id,
                    relative_path,
                    version_key,
                    ocr_text,
                    ocr_version,
                    caption,
                    labels_json,
                    semantic_version,
                    error,
                    _now_ms(),
                ),
            )

    def search_assets(
        self,
        *,
        query: str,
        limit: int,
        cursor: str | None = None,
        prefix: str | None = None,
        media_kind: str | None = None,
        from_ms: int | None = None,
        to_ms: int | None = None,
    ) -> tuple[list[dict[str, Any]], str | None]:
        bounded_limit = max(1, min(200, limit))
        offset = 0
        if cursor:
            offset = int(base64.urlsafe_b64decode(cursor.encode("ascii")).decode("ascii"))
            if offset < 0:
                raise ValueError("cursor offset must not be negative")
        clauses: list[str] = []
        arguments: list[Any] = []
        if prefix:
            normalized = prefix.rstrip("/")
            escaped = normalized.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            clauses.append("(a.remote_path=? OR a.remote_path LIKE ? ESCAPE '\\')")
            arguments.extend((normalized, f"{escaped}/%"))
        if media_kind:
            clauses.append("a.media_kind=?")
            arguments.append(media_kind)
        if from_ms is not None:
            clauses.append("a.modified_ms>=?")
            arguments.append(from_ms)
        if to_ms is not None:
            clauses.append("a.modified_ms<=?")
            arguments.append(to_ms)
        normalized_query = " ".join(query.strip().split())[:500]
        select = (
            "SELECT a.*,i.ocr_text,i.caption,i.labels_json,i.ocr_version,"
            "i.semantic_version,i.last_error AS intelligence_error"
        )
        if normalized_query and self._fts_enabled:
            tokens = [token.replace('"', '""') for token in normalized_query.split()[:12] if token]
            if not tokens:
                return [], None
            clauses.insert(0, "asset_intelligence_fts MATCH ?")
            arguments.insert(0, " AND ".join(f'"{token}"' for token in tokens))
            source = (
                " FROM asset_intelligence_fts f "
                "JOIN assets a ON a.root_id=f.root_id AND a.relative_path=f.relative_path "
                "JOIN asset_intelligence i ON i.root_id=a.root_id AND i.relative_path=a.relative_path"
            )
            order = " ORDER BY bm25(asset_intelligence_fts),a.modified_ms DESC,a.remote_path"
        else:
            source = (
                " FROM assets a LEFT JOIN asset_intelligence i "
                "ON i.root_id=a.root_id AND i.relative_path=a.relative_path"
            )
            if normalized_query:
                haystack = (
                    "lower(a.display_name || ' ' || a.relative_path || ' ' || "
                    "coalesce(i.ocr_text,'') || ' ' || coalesce(i.caption,'') || ' ' || "
                    "coalesce(i.labels_json,''))"
                )
                for token in normalized_query.lower().split()[:12]:
                    escaped_token = token.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                    clauses.append(f"{haystack} LIKE ? ESCAPE '\\'")
                    arguments.append(f"%{escaped_token}%")
            order = " ORDER BY a.modified_ms DESC,a.remote_path"
        where = " WHERE " + " AND ".join(clauses) if clauses else ""
        with self._connection() as database:
            rows = database.execute(
                f"{select}{source}{where}{order} LIMIT ? OFFSET ?",
                (*arguments, bounded_limit + 1, offset),
            ).fetchall()
        has_more = len(rows) > bounded_limit
        rows = rows[:bounded_limit]
        values = [self._asset_json(row, include_intelligence=True) for row in rows]
        next_cursor = None
        if has_more:
            next_cursor = base64.urlsafe_b64encode(str(offset + bounded_limit).encode("ascii")).decode("ascii")
        return values, next_cursor

    def update_asset_derived(self, root_id: str, relative_path: str, thumbnail_path: str) -> None:
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE assets SET thumbnail_path=?,updated_at_ms=? WHERE root_id=? AND relative_path=?",
                (thumbnail_path, _now_ms(), root_id, relative_path),
            )

    def update_asset_hash(self, root_id: str, relative_path: str, content_hash: str) -> None:
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE assets SET content_hash=?,updated_at_ms=? WHERE root_id=? AND relative_path=?",
                (content_hash, _now_ms(), root_id, relative_path),
            )

    def create_job(self, job_type: str, payload: dict[str, Any], idempotency_key: str | None) -> tuple[dict[str, Any], bool]:
        key = idempotency_key or str(uuid.uuid4())
        now = _now_ms()
        with self._lock, self._connection() as database:
            existing = database.execute(
                "SELECT * FROM jobs WHERE idempotency_key=?", (key,)
            ).fetchone()
            if existing:
                return self._job_json(existing), False
            job_id = str(uuid.uuid4())
            database.execute(
                "INSERT INTO jobs (id,idempotency_key,type,state,payload_json,created_at_ms,updated_at_ms) VALUES (?,?,?,?,?,?,?)",
                (job_id, key, job_type, "queued", json.dumps(payload, separators=(",", ":")), now, now),
            )
        return self.get_job(job_id), True

    def get_job(self, job_id: str) -> dict[str, Any]:
        with self._connection() as database:
            row = database.execute("SELECT * FROM jobs WHERE id=?", (job_id,)).fetchone()
        if not row:
            raise KeyError(job_id)
        return self._job_json(row)

    def list_jobs(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._connection() as database:
            rows = database.execute(
                "SELECT * FROM jobs ORDER BY created_at_ms DESC LIMIT ?", (max(1, min(200, limit)),)
            ).fetchall()
        return [self._job_json(row) for row in rows]

    def claim_job(self) -> dict[str, Any] | None:
        with self._lock, self._connection() as database:
            database.execute("BEGIN IMMEDIATE")
            row = database.execute(
                "SELECT * FROM jobs WHERE state='queued' ORDER BY created_at_ms LIMIT 1"
            ).fetchone()
            if not row:
                database.rollback()
                return None
            now = _now_ms()
            database.execute(
                "UPDATE jobs SET state='running',attempts=attempts+1,started_at_ms=?,updated_at_ms=?,last_error=NULL,cancel_requested=0 WHERE id=?",
                (now, now, row["id"]),
            )
            database.commit()
        return self.get_job(str(row["id"]))

    def update_job(self, job_id: str, *, processed: int, total: int, message: str) -> None:
        progress = 0 if total <= 0 else min(1.0, processed / total)
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE jobs SET processed=?,total=?,progress=?,message=?,updated_at_ms=? WHERE id=?",
                (processed, total, progress, message, _now_ms(), job_id),
            )

    def complete_job(self, job_id: str, result: dict[str, Any]) -> None:
        now = _now_ms()
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE jobs SET state='completed',progress=1,result_json=?,message='completed',updated_at_ms=?,completed_at_ms=? WHERE id=?",
                (json.dumps(result, separators=(",", ":")), now, now, job_id),
            )

    def fail_job(self, job_id: str, error: str) -> None:
        now = _now_ms()
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE jobs SET state='failed',last_error=?,message='failed',updated_at_ms=?,completed_at_ms=? WHERE id=?",
                (error, now, now, job_id),
            )

    def request_cancel(self, job_id: str) -> dict[str, Any]:
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE jobs SET state=CASE WHEN state='queued' THEN 'cancelled' ELSE state END,"
                "cancel_requested=CASE WHEN state='running' THEN 1 ELSE cancel_requested END,"
                "completed_at_ms=CASE WHEN state='queued' THEN ? ELSE completed_at_ms END,updated_at_ms=? "
                "WHERE id=? AND state IN ('queued','running')",
                (_now_ms(), _now_ms(), job_id),
            )
        return self.get_job(job_id)

    def is_cancel_requested(self, job_id: str) -> bool:
        with self._connection() as database:
            row = database.execute("SELECT cancel_requested FROM jobs WHERE id=?", (job_id,)).fetchone()
        return bool(row and row[0])

    def cancel_job(self, job_id: str) -> None:
        now = _now_ms()
        with self._lock, self._connection() as database:
            database.execute(
                "UPDATE jobs SET state='cancelled',message='cancelled',updated_at_ms=?,completed_at_ms=? WHERE id=?",
                (now, now, job_id),
            )

    def retry_job(self, job_id: str) -> dict[str, Any]:
        with self._lock, self._connection() as database:
            cursor = database.execute(
                "UPDATE jobs SET state='queued',progress=0,processed=0,total=0,message=NULL,result_json=NULL,last_error=NULL,cancel_requested=0,updated_at_ms=?,completed_at_ms=NULL WHERE id=? AND state IN ('failed','completed','cancelled')",
                (_now_ms(), job_id),
            )
            if cursor.rowcount == 0:
                raise ValueError("job is not retryable")
        return self.get_job(job_id)

    @staticmethod
    def _asset_json(row: sqlite3.Row, *, include_intelligence: bool = False) -> dict[str, Any]:
        value = {
            "rootId": row["root_id"],
            "relativePath": row["relative_path"],
            "remotePath": row["remote_path"],
            "displayName": row["display_name"],
            "mediaKind": row["media_kind"],
            "mimeType": row["mime_type"],
            "sizeBytes": row["size_bytes"],
            "modifiedMs": row["modified_ms"],
            "versionKey": row["version_key"],
            "thumbnailPath": row["thumbnail_path"],
            "contentHash": row["content_hash"],
        }
        if include_intelligence:
            keys = set(row.keys())
            labels_raw = row["labels_json"] if "labels_json" in keys else None
            value["intelligence"] = {
                "caption": row["caption"] if "caption" in keys else "",
                "labels": json.loads(labels_raw) if labels_raw else [],
                "ocrSnippet": str(row["ocr_text"] or "")[:500] if "ocr_text" in keys else "",
                "ocrVersion": row["ocr_version"] if "ocr_version" in keys else None,
                "semanticVersion": row["semantic_version"] if "semantic_version" in keys else None,
                "lastError": row["intelligence_error"] if "intelligence_error" in keys else None,
            }
        return value

    @staticmethod
    def _job_json(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "id": row["id"],
            "type": row["type"],
            "state": row["state"],
            "payload": json.loads(row["payload_json"]),
            "progress": row["progress"],
            "processed": row["processed"],
            "total": row["total"],
            "message": row["message"],
            "result": json.loads(row["result_json"]) if row["result_json"] else None,
            "lastError": row["last_error"],
            "attempts": row["attempts"],
            "cancelRequested": bool(row["cancel_requested"]),
            "createdAtMs": row["created_at_ms"],
            "updatedAtMs": row["updated_at_ms"],
            "startedAtMs": row["started_at_ms"],
            "completedAtMs": row["completed_at_ms"],
        }
