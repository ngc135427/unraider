from __future__ import annotations

import hashlib
import mimetypes
import os
import subprocess
import uuid
from pathlib import Path
from typing import Any, Callable, Iterable

from .config import HelperConfig, MediaRoot
from .storage import HelperStore


IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".heic", ".heif", ".avif"}
VIDEO_EXTENSIONS = {".mp4", ".m4v", ".mov", ".mkv", ".avi", ".webm", ".ts", ".mts", ".m2ts", ".3gp"}


def stable_key(value: str) -> str:
    hash_value = 0x811C9DC5
    encoded = value.encode("utf-16-le", errors="surrogatepass")
    for index in range(0, len(encoded), 2):
        unit = encoded[index] | (encoded[index + 1] << 8)
        hash_value ^= unit
        hash_value = (hash_value * 0x01000193) & 0xFFFFFFFF
    return f"{hash_value:08x}"


def _media_kind(path: Path) -> str | None:
    suffix = path.suffix.lower()
    if suffix in IMAGE_EXTENSIONS:
        return "image"
    if suffix in VIDEO_EXTENSIONS:
        return "video"
    return None


def scan_root(
    store: HelperStore,
    root: MediaRoot,
    *,
    on_progress: Callable[[int, str], None] | None = None,
    is_cancelled: Callable[[], bool] | None = None,
) -> dict[str, int]:
    if not root.path.exists() or not root.path.is_dir():
        raise FileNotFoundError(f"media root is unavailable: {root.path}")
    scan_id = str(uuid.uuid4())
    batch: list[dict[str, Any]] = []
    scanned = 0
    indexed = 0
    for directory, directories, files in os.walk(root.path, followlinks=False):
        directories[:] = [name for name in directories if name != ".unraider"]
        if is_cancelled and is_cancelled():
            raise InterruptedError("job cancelled")
        directory_path = Path(directory)
        for name in files:
            local_path = directory_path / name
            kind = _media_kind(local_path)
            if kind is None or local_path.is_symlink():
                continue
            scanned += 1
            try:
                stat = local_path.stat()
            except OSError:
                continue
            relative = local_path.relative_to(root.path).as_posix()
            modified_ms = stat.st_mtime_ns // 1_000_000
            remote_path = f"{root.remote_prefix}/{relative}"
            batch.append(
                {
                    "rootId": root.id,
                    "relativePath": relative,
                    "remotePath": remote_path,
                    "displayName": name,
                    "mediaKind": kind,
                    "mimeType": mimetypes.guess_type(name)[0] or ("image/*" if kind == "image" else "video/*"),
                    "sizeBytes": stat.st_size,
                    "modifiedMs": modified_ms,
                    "versionKey": f"{stat.st_size}:{modified_ms}",
                }
            )
            if len(batch) >= 250:
                indexed += store.upsert_assets(batch, scan_id)
                batch.clear()
                if on_progress:
                    on_progress(indexed, relative)
    if batch:
        indexed += store.upsert_assets(batch, scan_id)
    removed = store.finish_scan(root.id, scan_id)
    if on_progress:
        on_progress(indexed, "scan complete")
    return {"scanned": scanned, "indexed": indexed, "removed": removed}


def local_asset_path(root: MediaRoot, relative_path: str) -> Path:
    candidate = (root.path / relative_path).resolve()
    try:
        candidate.relative_to(root.path)
    except ValueError as error:
        raise ValueError("asset path escapes configured media root") from error
    return candidate


def derived_paths(root: MediaRoot, asset: dict[str, Any]) -> tuple[Path, str]:
    key = stable_key(f"{asset['remote_path']}\0{asset['version_key']}")
    category = "video-posters" if asset["media_kind"] == "video" else "thumbnails"
    relative = Path(".unraider") / category / key[:2] / f"{key}.jpg"
    local = root.path / relative
    remote = f"{root.remote_prefix}/{relative.as_posix()}"
    return local, remote


def generate_preview(config: HelperConfig, root: MediaRoot, asset: dict[str, Any]) -> str:
    source = local_asset_path(root, str(asset["relative_path"]))
    if not source.is_file():
        raise FileNotFoundError(source)
    target, remote_target = derived_paths(root, asset)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f"{target.name}.part-{uuid.uuid4()}")
    command = [config.ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    if asset["media_kind"] == "video":
        command.extend(["-ss", "1"])
    command.extend(
        [
            "-i",
            str(source),
            "-vf",
            "scale='min(480,iw)':-2",
            "-frames:v",
            "1",
            "-q:v",
            "4",
            "-f",
            "image2",
            str(temporary),
        ]
    )
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300, check=False)
        if result.returncode != 0 or not temporary.is_file() or temporary.stat().st_size <= 0:
            detail = result.stderr.strip()[-1000:] or "ffmpeg did not create an image"
            raise RuntimeError(detail)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)
    return remote_target


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def roots_by_id(config: HelperConfig) -> dict[str, MediaRoot]:
    return {root.id: root for root in config.roots}


def selected_roots(config: HelperConfig, root_id: str | None) -> Iterable[MediaRoot]:
    if not root_id:
        return config.roots
    roots = roots_by_id(config)
    if root_id not in roots:
        raise ValueError(f"unknown rootId: {root_id}")
    return (roots[root_id],)
