from __future__ import annotations

import base64
import json
import subprocess
import urllib.request
from pathlib import Path
from typing import Any

from .config import HelperConfig


def ocr_model_version(config: HelperConfig) -> str:
    return f"tesseract:{config.ocr_languages}:v1"


def semantic_model_version(config: HelperConfig) -> str:
    return f"ollama:{config.vision_model}:v1"


def extract_ocr(config: HelperConfig, image_path: Path) -> str:
    result = subprocess.run(
        [
            config.tesseract,
            str(image_path),
            "stdout",
            "-l",
            config.ocr_languages,
            "--psm",
            "6",
        ],
        capture_output=True,
        text=True,
        timeout=180,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip()[-1000:] or "tesseract failed"
        raise RuntimeError(detail)
    return " ".join(result.stdout.replace("\x00", " ").split())[:20000]


def describe_image(config: HelperConfig, image_path: Path) -> tuple[str, list[str]]:
    if not config.vision_url or not config.vision_model:
        raise RuntimeError("local vision model is not configured")
    image_base64 = base64.b64encode(image_path.read_bytes()).decode("ascii")
    payload = json.dumps(
        {
            "model": config.vision_model,
            "stream": False,
            "format": "json",
            "messages": [
                {
                    "role": "user",
                    "content": (
                        "分析这张相册预览图。只返回 JSON 对象："
                        '{"caption":"一段简洁中文描述","labels":["中文标签"]}。'
                        "描述可见人物数量、场景、物体、活动、颜色和可辨识文字，"
                        "不要猜测真实姓名、身份或敏感属性。标签最多 20 个。"
                    ),
                    "images": [image_base64],
                }
            ],
        },
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    endpoint = config.vision_url if config.vision_url.endswith("/api/chat") else f"{config.vision_url}/api/chat"
    request = urllib.request.Request(
        endpoint,
        method="POST",
        data=payload,
        headers={"Content-Type": "application/json", "Accept": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=config.vision_timeout_seconds) as response:
        response_value = json.loads(response.read().decode("utf-8"))
    content = response_value.get("message", {}).get("content", "")
    if not isinstance(content, str) or not content.strip():
        raise RuntimeError("vision model returned an empty description")
    value = _json_object(content)
    caption = " ".join(str(value.get("caption", "")).split())[:2000]
    raw_labels = value.get("labels", [])
    labels = []
    if isinstance(raw_labels, list):
        for item in raw_labels:
            label = " ".join(str(item).split())[:80]
            if label and label not in labels:
                labels.append(label)
            if len(labels) >= 20:
                break
    if not caption and not labels:
        raise RuntimeError("vision model returned no searchable content")
    return caption, labels


def _json_object(value: str) -> dict[str, Any]:
    normalized = value.strip()
    if normalized.startswith("```"):
        lines = normalized.splitlines()
        normalized = "\n".join(lines[1:-1]).strip()
    decoded = json.loads(normalized)
    if not isinstance(decoded, dict):
        raise RuntimeError("vision model response must be a JSON object")
    return decoded
