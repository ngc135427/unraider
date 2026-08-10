from __future__ import annotations

import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest.mock import patch

from unraider_helper.config import HelperConfig, MediaRoot
from unraider_helper.media import scan_root, stable_key
from unraider_helper.jobs import JobRunner
from unraider_helper.server import AlbumHelperHttpServer, HelperApplication
from unraider_helper.storage import HelperStore


class HelperStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)
        self.media = self.base / "media"
        self.media.mkdir()
        self.root = MediaRoot("photos", self.media, "/mnt/user/photos")
        self.store = HelperStore(self.base / "state" / "helper.sqlite3")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_scan_excludes_derived_tree_and_pages_assets(self) -> None:
        (self.media / "trip").mkdir()
        (self.media / "trip" / "one.jpg").write_bytes(b"image-one")
        (self.media / "trip" / "two.mp4").write_bytes(b"video-two")
        (self.media / "trip" / "notes.txt").write_text("ignore", encoding="utf-8")
        (self.media / ".unraider" / "thumbnails").mkdir(parents=True)
        (self.media / ".unraider" / "thumbnails" / "ignored.jpg").write_bytes(b"derived")

        result = scan_root(self.store, self.root)

        self.assertEqual(result["indexed"], 2)
        first, cursor = self.store.list_assets(limit=1, prefix="/mnt/user/photos")
        second, final_cursor = self.store.list_assets(limit=1, cursor=cursor, prefix="/mnt/user/photos")
        self.assertEqual(len(first), 1)
        self.assertEqual(len(second), 1)
        self.assertIsNotNone(cursor)
        self.assertIsNone(final_cursor)
        self.assertEqual({first[0]["mediaKind"], second[0]["mediaKind"]}, {"image", "video"})
        self.assertTrue(all(".unraider" not in item["remotePath"] for item in first + second))

    def test_rescan_removes_missing_assets_without_touching_originals(self) -> None:
        original = self.media / "one.jpg"
        original.write_bytes(b"one")
        scan_root(self.store, self.root)
        original.unlink()

        result = scan_root(self.store, self.root)

        assets, _ = self.store.list_assets(limit=10)
        self.assertEqual(result["removed"], 1)
        self.assertEqual(assets, [])

    def test_job_idempotency_is_scoped_to_explicit_key(self) -> None:
        first, created = self.store.create_job("scan", {}, "same-request")
        second, duplicated = self.store.create_job("scan", {}, "same-request")
        third, new_created = self.store.create_job("scan", {}, "another-request")
        self.assertTrue(created)
        self.assertFalse(duplicated)
        self.assertTrue(new_created)
        self.assertEqual(first["id"], second["id"])
        self.assertNotEqual(first["id"], third["id"])

    def test_queued_job_can_be_cancelled_and_retried(self) -> None:
        job, _ = self.store.create_job("scan", {}, "cancel-request")
        cancelled = self.store.request_cancel(job["id"])
        self.assertEqual(cancelled["state"], "cancelled")
        self.assertIsNone(self.store.claim_job())
        retried = self.store.retry_job(job["id"])
        self.assertEqual(retried["state"], "queued")

    def test_stable_key_matches_flutter_fnv_for_ascii(self) -> None:
        self.assertEqual(stable_key("hello"), "4f9f2cab")

    def test_rebuild_regenerates_derived_files_even_when_index_has_old_path(self) -> None:
        original = self.media / "one.jpg"
        original.write_bytes(b"one")
        scan_root(self.store, self.root)
        self.store.update_asset_derived(
            "photos",
            "one.jpg",
            "/mnt/user/photos/.unraider/thumbnails/old.jpg",
        )
        config = HelperConfig(
            host="127.0.0.1",
            port=0,
            token="test-token-123456789",
            state_dir=self.base / "state",
            roots=(self.root,),
            workers=1,
        )
        runner = JobRunner(config, self.store)
        with patch(
            "unraider_helper.jobs.generate_preview",
            return_value="/mnt/user/photos/.unraider/thumbnails/new.jpg",
        ) as generate:
            result = runner._run(
                {
                    "id": "rebuild-test",
                    "type": "rebuild",
                    "payload": {"rootId": "photos"},
                }
            )
        self.assertEqual(result["previews"]["generated"], 1)
        generate.assert_called_once()


class HelperApiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        base = Path(self.temporary.name)
        media = base / "media"
        media.mkdir()
        (media / "photo.jpg").write_bytes(b"photo")
        self.config = HelperConfig(
            host="127.0.0.1",
            port=0,
            token="test-token-123456789",
            state_dir=base / "state",
            roots=(MediaRoot("photos", media, "/mnt/user/photos"),),
            workers=1,
        )
        self.application = HelperApplication(self.config)
        self.server = AlbumHelperHttpServer(("127.0.0.1", 0), self.application)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.application.start()
        self.thread.start()
        self.base_url = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.application.stop()
        self.thread.join(timeout=3)
        self.temporary.cleanup()

    def request(self, path: str, *, method: str = "GET", body: dict[str, object] | None = None, authorized: bool = True) -> tuple[int, dict[str, object]]:
        headers = {"Content-Type": "application/json"}
        if authorized:
            headers["Authorization"] = f"Bearer {self.config.token}"
        data = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(self.base_url + path, method=method, headers=headers, data=data)
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as error:
            return error.code, json.loads(error.read())

    def test_health_capabilities_auth_and_scan_job(self) -> None:
        status, health = self.request("/healthz", authorized=False)
        self.assertEqual(status, 200)
        self.assertEqual(health["service"], "unraider-album-helper")
        status, _ = self.request("/api/v1/capabilities", authorized=False)
        self.assertEqual(status, 401)
        status, capabilities = self.request("/api/v1/capabilities")
        self.assertEqual(status, 200)
        self.assertEqual(capabilities["apiVersion"], 1)

        options = urllib.request.Request(self.base_url + "/api/v1/assets", method="OPTIONS")
        with urllib.request.urlopen(options, timeout=3) as response:
            self.assertEqual(response.headers["Access-Control-Allow-Origin"], "*")

        status, job = self.request(
            "/api/v1/jobs",
            method="POST",
            body={"type": "scan", "payload": {"rootId": "photos"}},
        )
        self.assertEqual(status, 202)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            _, job = self.request(f"/api/v1/jobs/{job['id']}")
            if job["state"] == "completed":
                break
            time.sleep(0.05)
        self.assertEqual(job["state"], "completed")
        _, page = self.request("/api/v1/assets?limit=10")
        self.assertEqual(len(page["items"]), 1)


if __name__ == "__main__":
    unittest.main()
