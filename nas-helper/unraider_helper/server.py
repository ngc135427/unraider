from __future__ import annotations

import hmac
import json
import logging
import signal
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

from . import __version__
from .config import HelperConfig
from .jobs import JobRunner, SUPPORTED_JOB_TYPES
from .storage import HelperStore


LOGGER = logging.getLogger("unraider-helper.http")
MAX_REQUEST_BYTES = 64 * 1024


class HelperApplication:
    def __init__(self, config: HelperConfig):
        self.config = config
        self.store = HelperStore(config.state_dir / "album-helper.sqlite3")
        self.jobs = JobRunner(config, self.store)

    def start(self) -> None:
        self.jobs.start()

    def stop(self) -> None:
        self.jobs.stop()


class HelperRequestHandler(BaseHTTPRequestHandler):
    server_version = "UnraiderAlbumHelper/0.2"

    @property
    def application(self) -> HelperApplication:
        return self.server.application  # type: ignore[attr-defined]

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            self._json(HTTPStatus.OK, {"status": "ok", "service": "unraider-album-helper", "version": __version__})
            return
        if not self._authorized():
            return
        query = parse_qs(parsed.query)
        if parsed.path == "/api/v1/capabilities":
            self._json(
                HTTPStatus.OK,
                {
                    "apiVersion": 1,
                    "helperVersion": __version__,
                    "capabilities": [
                        "asset-index-v1",
                        "smart-search-v1",
                        "ocr-jobs-v1",
                        "thumbnail-jobs-v1",
                        "video-poster-jobs-v1",
                        "integrity-jobs-v1",
                        "job-control-v1",
                    ]
                    + (["semantic-caption-jobs-v1"] if self.application.config.vision_url else []),
                    "intelligence": {
                        "ocr": True,
                        "ocrLanguages": self.application.config.ocr_languages,
                        "semantic": bool(self.application.config.vision_url),
                        "visionModel": self.application.config.vision_model or None,
                    },
                    "roots": [
                        {"id": root.id, "remotePrefix": root.remote_prefix}
                        for root in self.application.config.roots
                    ],
                },
            )
            return
        if parsed.path == "/api/v1/search":
            try:
                assets, next_cursor = self.application.store.search_assets(
                    query=self._query(query, "q") or "",
                    limit=self._int_query(query, "limit", 50),
                    cursor=self._query(query, "cursor"),
                    prefix=self._query(query, "prefix"),
                    media_kind=self._query(query, "kind"),
                    from_ms=self._optional_int_query(query, "fromMs"),
                    to_ms=self._optional_int_query(query, "toMs"),
                )
            except (ValueError, UnicodeError) as error:
                self._error(HTTPStatus.BAD_REQUEST, "invalid_search", str(error))
                return
            self._json(HTTPStatus.OK, {"items": assets, "nextCursor": next_cursor})
            return
        if parsed.path == "/api/v1/assets":
            try:
                assets, next_cursor = self.application.store.list_assets(
                    limit=self._int_query(query, "limit", 100),
                    cursor=self._query(query, "cursor"),
                    root_id=self._query(query, "rootId"),
                    prefix=self._query(query, "prefix"),
                    media_kind=self._query(query, "kind"),
                )
            except (ValueError, UnicodeError) as error:
                self._error(HTTPStatus.BAD_REQUEST, "invalid_cursor", str(error))
                return
            self._json(HTTPStatus.OK, {"items": assets, "nextCursor": next_cursor})
            return
        if parsed.path == "/api/v1/jobs":
            self._json(
                HTTPStatus.OK,
                {"items": self.application.store.list_jobs(self._int_query(query, "limit", 50))},
            )
            return
        job_action = self._job_route(parsed.path)
        if job_action and job_action[1] is None:
            try:
                self._json(HTTPStatus.OK, self.application.store.get_job(job_action[0]))
            except KeyError:
                self._error(HTTPStatus.NOT_FOUND, "job_not_found", "job does not exist")
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "endpoint does not exist")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        parsed = urlparse(self.path)
        if not self._authorized():
            return
        if parsed.path == "/api/v1/jobs":
            body = self._read_json()
            if body is None:
                return
            job_type = str(body.get("type", ""))
            if job_type not in SUPPORTED_JOB_TYPES:
                self._error(HTTPStatus.BAD_REQUEST, "unsupported_job_type", f"supported types: {sorted(SUPPORTED_JOB_TYPES)}")
                return
            if job_type == "semantic" and not self.application.config.vision_url:
                self._error(
                    HTTPStatus.CONFLICT,
                    "semantic_not_configured",
                    "configure UNRAIDER_VISION_URL and UNRAIDER_VISION_MODEL first",
                )
                return
            payload = body.get("payload") or {}
            if not isinstance(payload, dict):
                self._error(HTTPStatus.BAD_REQUEST, "invalid_payload", "payload must be an object")
                return
            root_id = payload.get("rootId")
            if root_id and root_id not in {root.id for root in self.application.config.roots}:
                self._error(HTTPStatus.BAD_REQUEST, "unknown_root", "rootId is not configured")
                return
            job, created = self.application.store.create_job(
                job_type,
                payload,
                self.headers.get("Idempotency-Key"),
            )
            self._json(HTTPStatus.ACCEPTED if created else HTTPStatus.OK, job)
            return
        job_action = self._job_route(parsed.path)
        if job_action:
            job_id, action = job_action
            try:
                if action == "retry":
                    self._json(HTTPStatus.ACCEPTED, self.application.store.retry_job(job_id))
                elif action == "cancel":
                    self._json(HTTPStatus.ACCEPTED, self.application.store.request_cancel(job_id))
                else:
                    self._error(HTTPStatus.METHOD_NOT_ALLOWED, "method_not_allowed", "unsupported job action")
            except KeyError:
                self._error(HTTPStatus.NOT_FOUND, "job_not_found", "job does not exist")
            except ValueError as error:
                self._error(HTTPStatus.CONFLICT, "job_not_retryable", str(error))
            return
        self._error(HTTPStatus.NOT_FOUND, "not_found", "endpoint does not exist")

    def do_OPTIONS(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API.
        self.send_response(HTTPStatus.NO_CONTENT)
        self.send_header("Allow", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Origin", self.application.config.cors_origin)
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type, Idempotency-Key")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        LOGGER.info("%s - %s", self.client_address[0], format % args)

    def _authorized(self) -> bool:
        authorization = self.headers.get("Authorization", "")
        expected = f"Bearer {self.application.config.token}"
        if hmac.compare_digest(authorization, expected):
            return True
        self._error(HTTPStatus.UNAUTHORIZED, "unauthorized", "valid bearer token required")
        return False

    def _read_json(self) -> dict[str, Any] | None:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_length", "invalid Content-Length")
            return None
        if length <= 0 or length > MAX_REQUEST_BYTES:
            self._error(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "invalid_body_size", "request body must be 1..65536 bytes")
            return None
        try:
            value = json.loads(self.rfile.read(length).decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as error:
            self._error(HTTPStatus.BAD_REQUEST, "invalid_json", str(error))
            return None
        if not isinstance(value, dict):
            self._error(HTTPStatus.BAD_REQUEST, "invalid_json", "JSON body must be an object")
            return None
        return value

    def _json(self, status: HTTPStatus, value: object) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", self.application.config.cors_origin)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _error(self, status: HTTPStatus, code: str, message: str) -> None:
        self._json(status, {"error": {"code": code, "message": message}})

    @staticmethod
    def _query(query: dict[str, list[str]], name: str) -> str | None:
        values = query.get(name)
        return values[0] if values else None

    def _int_query(self, query: dict[str, list[str]], name: str, fallback: int) -> int:
        value = self._query(query, name)
        try:
            return fallback if value is None else int(value)
        except ValueError:
            return fallback

    def _optional_int_query(self, query: dict[str, list[str]], name: str) -> int | None:
        value = self._query(query, name)
        if value is None:
            return None
        return int(value)

    @staticmethod
    def _job_route(path: str) -> tuple[str, str | None] | None:
        parts = [part for part in path.split("/") if part]
        if len(parts) == 4 and parts[:3] == ["api", "v1", "jobs"]:
            return parts[3], None
        if len(parts) == 5 and parts[:3] == ["api", "v1", "jobs"]:
            return parts[3], parts[4]
        return None


class AlbumHelperHttpServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, address: tuple[str, int], application: HelperApplication):
        self.application = application
        super().__init__(address, HelperRequestHandler)


def serve(config: HelperConfig) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    application = HelperApplication(config)
    server = AlbumHelperHttpServer((config.host, config.port), application)
    stop = threading.Event()

    def request_stop(_signum: int, _frame: object) -> None:
        stop.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    application.start()
    LOGGER.info("listening on %s:%s with %s media root(s)", config.host, config.port, len(config.roots))
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        application.stop()
