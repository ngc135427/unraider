from __future__ import annotations

import logging
import threading
from typing import Any

from .config import HelperConfig
from .media import generate_preview, local_asset_path, roots_by_id, scan_root, selected_roots, sha256_file
from .storage import HelperStore


LOGGER = logging.getLogger("unraider-helper.jobs")
SUPPORTED_JOB_TYPES = {"scan", "previews", "integrity", "rebuild"}


class JobRunner:
    def __init__(self, config: HelperConfig, store: HelperStore):
        self.config = config
        self.store = store
        self._stop = threading.Event()
        self._scan_lock = threading.Lock()
        self._threads: list[threading.Thread] = []

    def start(self) -> None:
        for index in range(self.config.workers):
            thread = threading.Thread(target=self._worker, name=f"album-job-{index + 1}", daemon=True)
            thread.start()
            self._threads.append(thread)

    def stop(self) -> None:
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=5)

    def _worker(self) -> None:
        while not self._stop.is_set():
            job = self.store.claim_job()
            if job is None:
                self._stop.wait(0.5)
                continue
            job_id = str(job["id"])
            try:
                result = self._run(job)
                if self.store.is_cancel_requested(job_id):
                    self.store.cancel_job(job_id)
                else:
                    self.store.complete_job(job_id, result)
            except InterruptedError:
                self.store.cancel_job(job_id)
            except Exception as error:  # noqa: BLE001 - job boundary must persist every failure.
                LOGGER.exception("job %s failed", job_id)
                self.store.fail_job(job_id, str(error))

    def _run(self, job: dict[str, Any]) -> dict[str, Any]:
        job_type = str(job["type"])
        payload = dict(job.get("payload") or {})
        root_id = str(payload.get("rootId") or "") or None
        result: dict[str, Any] = {}
        if job_type in {"scan", "rebuild"}:
            with self._scan_lock:
                result["scan"] = self._scan(str(job["id"]), root_id)
        if job_type in {"previews", "rebuild"}:
            result["previews"] = self._previews(
                str(job["id"]),
                root_id,
                job_type == "rebuild" or bool(payload.get("force")),
            )
        if job_type == "integrity":
            result["integrity"] = self._integrity(str(job["id"]), root_id, bool(payload.get("force")))
        return result

    def _scan(self, job_id: str, root_id: str | None) -> dict[str, int]:
        totals = {"scanned": 0, "indexed": 0, "removed": 0}
        roots = tuple(selected_roots(self.config, root_id))
        for root_index, root in enumerate(roots):
            result = scan_root(
                self.store,
                root,
                on_progress=lambda count, detail, current=root_index: self.store.update_job(
                    job_id,
                    processed=current,
                    total=len(roots),
                    message=f"{root.id}: {count} indexed · {detail}",
                ),
                is_cancelled=lambda: self.store.is_cancel_requested(job_id),
            )
            for key, value in result.items():
                totals[key] += value
            self.store.update_job(job_id, processed=root_index + 1, total=len(roots), message=f"{root.id}: indexed")
        return totals

    def _previews(self, job_id: str, root_id: str | None, force: bool) -> dict[str, Any]:
        assets = self.store.assets_for_job(root_id)
        if not force:
            assets = [asset for asset in assets if not asset.get("thumbnail_path")]
        roots = roots_by_id(self.config)
        generated = 0
        failed = 0
        failures: list[dict[str, str]] = []
        total = len(assets)
        for index, asset in enumerate(assets):
            if self.store.is_cancel_requested(job_id):
                raise InterruptedError("job cancelled")
            try:
                remote_path = generate_preview(self.config, roots[str(asset["root_id"])], asset)
                self.store.update_asset_derived(str(asset["root_id"]), str(asset["relative_path"]), remote_path)
                generated += 1
            except Exception as error:  # noqa: BLE001 - continue batch and report per-asset failures.
                failed += 1
                if len(failures) < 50:
                    failures.append({"path": str(asset["remote_path"]), "error": str(error)})
            self.store.update_job(
                job_id,
                processed=index + 1,
                total=total,
                message=f"previews {index + 1}/{total}",
            )
        return {"generated": generated, "failed": failed, "failures": failures}

    def _integrity(self, job_id: str, root_id: str | None, force: bool) -> dict[str, int]:
        assets = self.store.assets_for_job(root_id)
        if not force:
            assets = [asset for asset in assets if not asset.get("content_hash")]
        roots = roots_by_id(self.config)
        hashed = 0
        failed = 0
        total = len(assets)
        for index, asset in enumerate(assets):
            if self.store.is_cancel_requested(job_id):
                raise InterruptedError("job cancelled")
            try:
                digest = sha256_file(local_asset_path(roots[str(asset["root_id"])], str(asset["relative_path"])))
                self.store.update_asset_hash(str(asset["root_id"]), str(asset["relative_path"]), digest)
                hashed += 1
            except OSError:
                failed += 1
            self.store.update_job(job_id, processed=index + 1, total=total, message=f"integrity {index + 1}/{total}")
        return {"hashed": hashed, "failed": failed}
