from __future__ import annotations

import logging
import threading
from typing import Any

from .config import HelperConfig
from .intelligence import describe_image, extract_ocr, ocr_model_version, semantic_model_version
from .media import (
    derived_paths,
    generate_preview,
    local_asset_path,
    roots_by_id,
    scan_root,
    selected_roots,
    sha256_file,
)
from .storage import HelperStore


LOGGER = logging.getLogger("unraider-helper.jobs")
SUPPORTED_JOB_TYPES = {"scan", "previews", "integrity", "rebuild", "ocr", "semantic", "intelligence"}


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
        if job_type in {"ocr", "semantic", "intelligence"}:
            result["intelligence"] = self._intelligence(
                str(job["id"]),
                root_id,
                include_ocr=job_type in {"ocr", "intelligence"},
                include_semantic=job_type == "semantic" or (job_type == "intelligence" and bool(self.config.vision_url)),
                force=bool(payload.get("force")),
            )
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

    def _intelligence(
        self,
        job_id: str,
        root_id: str | None,
        *,
        include_ocr: bool,
        include_semantic: bool,
        force: bool,
    ) -> dict[str, Any]:
        if include_semantic and (not self.config.vision_url or not self.config.vision_model):
            raise ValueError("local vision model is not configured")
        assets = self.store.assets_for_job(root_id)
        roots = roots_by_id(self.config)
        ocr_version = ocr_model_version(self.config)
        semantic_version = semantic_model_version(self.config) if include_semantic else None
        selected: list[dict[str, Any]] = []
        skipped = 0
        for asset in assets:
            needs_ocr = include_ocr and (force or asset.get("ocr_version") != ocr_version)
            needs_semantic = include_semantic and (
                force or asset.get("semantic_version") != semantic_version
            )
            if needs_ocr or needs_semantic:
                asset["needs_ocr"] = needs_ocr
                asset["needs_semantic"] = needs_semantic
                selected.append(asset)
            else:
                skipped += 1
        indexed = 0
        failed = 0
        failures: list[dict[str, str]] = []
        total = len(selected)
        for index, asset in enumerate(selected):
            if self.store.is_cancel_requested(job_id):
                raise InterruptedError("job cancelled")
            root = roots[str(asset["root_id"])]
            target, _ = derived_paths(root, asset)
            errors: list[str] = []
            ocr: tuple[str, str] | None = None
            semantic: tuple[str, list[str], str] | None = None
            try:
                if not target.is_file() or target.stat().st_size <= 0:
                    remote_path = generate_preview(self.config, root, asset)
                    self.store.update_asset_derived(
                        str(asset["root_id"]),
                        str(asset["relative_path"]),
                        remote_path,
                    )
                if bool(asset["needs_ocr"]):
                    try:
                        ocr = (extract_ocr(self.config, target), ocr_version)
                    except Exception as error:  # noqa: BLE001 - preserve partial semantic result.
                        errors.append(f"OCR: {error}")
                if bool(asset["needs_semantic"]):
                    try:
                        caption, labels = describe_image(self.config, target)
                        semantic = (caption, labels, str(semantic_version))
                    except Exception as error:  # noqa: BLE001 - preserve partial OCR result.
                        errors.append(f"semantic: {error}")
                self.store.update_asset_intelligence(
                    str(asset["root_id"]),
                    str(asset["relative_path"]),
                    str(asset["version_key"]),
                    ocr=ocr,
                    semantic=semantic,
                    error="; ".join(errors) or None,
                )
                if ocr is not None or semantic is not None:
                    indexed += 1
                if errors:
                    failed += 1
            except Exception as error:  # noqa: BLE001 - continue batch and report each asset.
                failed += 1
                errors.append(str(error))
            if errors and len(failures) < 50:
                failures.append({"path": str(asset["remote_path"]), "error": "; ".join(errors)})
            self.store.update_job(
                job_id,
                processed=index + 1,
                total=total,
                message=f"intelligence {index + 1}/{total}",
            )
        return {
            "indexed": indexed,
            "failed": failed,
            "skipped": skipped,
            "ocr": include_ocr,
            "semantic": include_semantic,
            "failures": failures,
        }
