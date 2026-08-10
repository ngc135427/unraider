from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class MediaRoot:
    id: str
    path: Path
    remote_prefix: str

    @classmethod
    def from_mapping(cls, value: dict[str, object]) -> "MediaRoot":
        root_id = str(value.get("id", "")).strip()
        configured_path = Path(str(value.get("path", ""))).expanduser()
        if not configured_path.is_absolute():
            raise ValueError(f"root {root_id or '<unknown>'} path must be absolute")
        local_path = configured_path.resolve()
        remote_prefix = "/" + str(value.get("remotePrefix", "")).strip().strip("/")
        if not root_id or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" for character in root_id):
            raise ValueError("root id must contain only letters, numbers, '-' or '_'")
        if remote_prefix == "/":
            raise ValueError(f"root {root_id} remotePrefix must not be empty")
        return cls(id=root_id, path=local_path, remote_prefix=remote_prefix.rstrip("/"))


@dataclass(frozen=True)
class HelperConfig:
    host: str
    port: int
    token: str
    state_dir: Path
    roots: tuple[MediaRoot, ...]
    cors_origin: str = "*"
    workers: int = 2
    ffmpeg: str = "ffmpeg"

    @classmethod
    def from_env(cls) -> "HelperConfig":
        token = os.environ.get("UNRAIDER_HELPER_TOKEN", "").strip()
        if len(token) < 16:
            raise ValueError("UNRAIDER_HELPER_TOKEN must contain at least 16 characters")
        roots_raw = os.environ.get(
            "UNRAIDER_ROOTS_JSON",
            '[{"id":"photos","path":"/media/photos","remotePrefix":"/mnt/user/photos"}]',
        )
        roots_value = json.loads(roots_raw)
        if not isinstance(roots_value, list) or not roots_value:
            raise ValueError("UNRAIDER_ROOTS_JSON must be a non-empty JSON array")
        roots = tuple(MediaRoot.from_mapping(value) for value in roots_value)
        if len({root.id for root in roots}) != len(roots):
            raise ValueError("media root ids must be unique")
        if len({root.path for root in roots}) != len(roots):
            raise ValueError("media root paths must be unique")
        if len({root.remote_prefix.lower() for root in roots}) != len(roots):
            raise ValueError("media root remotePrefix values must be unique")
        for index, root in enumerate(roots):
            for other in roots[index + 1 :]:
                if root.path in other.path.parents or other.path in root.path.parents:
                    raise ValueError("media root paths must not overlap")
                root_prefix = root.remote_prefix.lower()
                other_prefix = other.remote_prefix.lower()
                if root_prefix.startswith(f"{other_prefix}/") or other_prefix.startswith(f"{root_prefix}/"):
                    raise ValueError("media root remotePrefix values must not overlap")
        state_dir = Path(os.environ.get("UNRAIDER_STATE_DIR", "/data")).expanduser().resolve()
        cors_origin = os.environ.get("UNRAIDER_CORS_ORIGIN", "*").strip() or "*"
        if "\r" in cors_origin or "\n" in cors_origin:
            raise ValueError("UNRAIDER_CORS_ORIGIN must be a single HTTP header value")
        return cls(
            host=os.environ.get("UNRAIDER_HELPER_HOST", "0.0.0.0"),
            port=int(os.environ.get("UNRAIDER_HELPER_PORT", "9487")),
            token=token,
            state_dir=state_dir,
            roots=roots,
            cors_origin=cors_origin,
            workers=max(1, min(4, int(os.environ.get("UNRAIDER_HELPER_WORKERS", "2")))),
            ffmpeg=os.environ.get("UNRAIDER_FFMPEG", "ffmpeg"),
        )
