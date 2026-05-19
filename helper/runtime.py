"""StockBar Python 运行时配置：跨项目路径软编码 + 健康检查。

三层 fallback 找 vnpy 项目根目录（含 .venv + examples/akshare_data/analyze.py）：
  1. 环境变量 STOCKBAR_VNPY_PATH (项目根 dir)
  2. 配置文件 ~/Library/Application Support/StockBar/config.json
  3. 自动探测常见位置

Swift 端通过设置环境变量或写 config.json 来配置 vnpy 位置。
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Optional


_CONFIG_PATH = Path.home() / "Library/Application Support/StockBar/config.json"


def _read_config() -> dict:
    if not _CONFIG_PATH.exists():
        return {}
    try:
        return json.loads(_CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        return {}


def _looks_like_vnpy(p: Path) -> bool:
    """vnpy 项目根的判定：含 .venv/bin/python 且 examples/akshare_data/analyze.py 存在"""
    return (p / ".venv/bin/python").exists() and (p / "examples/akshare_data/analyze.py").exists()


def find_vnpy_path() -> Optional[Path]:
    """返回 vnpy 项目根 Path，找不到返回 None"""
    # 1. 环境变量
    env = os.environ.get("STOCKBAR_VNPY_PATH")
    if env:
        p = Path(env)
        if _looks_like_vnpy(p):
            return p

    # 2. 配置文件
    cfg = _read_config()
    if cfg.get("vnpy_path"):
        p = Path(cfg["vnpy_path"])
        if _looks_like_vnpy(p):
            return p

    # 3. 自动探测
    for candidate in [
        Path.home() / "github/vnpy",
        Path.home() / "code/vnpy",
        Path.home() / "projects/vnpy",
        Path.home() / "Documents/vnpy",
        Path("/opt/vnpy"),
    ]:
        if _looks_like_vnpy(candidate):
            return candidate
    return None


def find_vnpy_python() -> Optional[Path]:
    """返回 vnpy venv 的 python 可执行文件路径，找不到返回 None"""
    root = find_vnpy_path()
    if root is None:
        return None
    p = root / ".venv/bin/python"
    return p if p.exists() else None


def health_check() -> dict:
    """返回 {ok, vnpy_path, vnpy_python, source, errors}，给 Swift 端启动校验用"""
    errors: list[str] = []
    env = os.environ.get("STOCKBAR_VNPY_PATH")
    cfg_path = _read_config().get("vnpy_path")

    root = find_vnpy_path()
    py = find_vnpy_python()

    source = None
    if env and Path(env) == root:
        source = "env"
    elif cfg_path and Path(cfg_path) == root:
        source = "config"
    elif root is not None:
        source = "auto-detect"

    if root is None:
        errors.append("未找到 vnpy 项目根。请设置 STOCKBAR_VNPY_PATH 环境变量或在 config.json 写 vnpy_path")
    elif py is None:
        errors.append(f"找到 vnpy 项目 {root}，但 venv 不存在；请在 vnpy 项目下跑 python -m venv .venv && pip install akshare talib pandas")

    return {
        "ok": (root is not None and py is not None),
        "vnpy_path": str(root) if root else None,
        "vnpy_python": str(py) if py else None,
        "source": source,
        "errors": errors,
    }


if __name__ == "__main__":
    print(json.dumps(health_check(), ensure_ascii=False, indent=2))
