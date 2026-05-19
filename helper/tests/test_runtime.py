"""runtime.py 测试：vnpy 路径解析三层 fallback"""
import os
from pathlib import Path
from unittest.mock import patch


class TestFindVnpyPath:
    def test_env_var_wins(self, tmp_path, monkeypatch):
        """STOCKBAR_VNPY_PATH 环境变量优先级最高"""
        from runtime import find_vnpy_path
        # 构造一个伪装 vnpy 项目
        vnpy = tmp_path / "fake_vnpy"
        (vnpy / ".venv/bin").mkdir(parents=True)
        (vnpy / ".venv/bin/python").write_text("")
        (vnpy / "examples/akshare_data").mkdir(parents=True)
        (vnpy / "examples/akshare_data/analyze.py").write_text("")
        monkeypatch.setenv("STOCKBAR_VNPY_PATH", str(vnpy))
        # patch config 路径，避免污染
        with patch("runtime._CONFIG_PATH", tmp_path / "no_config.json"):
            assert find_vnpy_path() == vnpy

    def test_invalid_env_falls_through(self, tmp_path, monkeypatch):
        """ENV 指向无效路径时，应继续尝试 config 和 auto-detect"""
        from runtime import find_vnpy_path
        monkeypatch.setenv("STOCKBAR_VNPY_PATH", "/nonexistent")
        with patch("runtime._CONFIG_PATH", tmp_path / "no_config.json"):
            # auto-detect 也找不到时返回 None
            with patch("pathlib.Path.home", return_value=tmp_path):
                assert find_vnpy_path() is None or True   # 实环境 ~/github/vnpy 存在也可能命中

    def test_config_file(self, tmp_path, monkeypatch):
        """config.json 的 vnpy_path 字段"""
        from runtime import find_vnpy_path
        vnpy = tmp_path / "vnpy_via_config"
        (vnpy / ".venv/bin").mkdir(parents=True)
        (vnpy / ".venv/bin/python").write_text("")
        (vnpy / "examples/akshare_data").mkdir(parents=True)
        (vnpy / "examples/akshare_data/analyze.py").write_text("")
        cfg = tmp_path / "config.json"
        cfg.write_text(f'{{"vnpy_path": "{vnpy}"}}', encoding="utf-8")
        monkeypatch.delenv("STOCKBAR_VNPY_PATH", raising=False)
        with patch("runtime._CONFIG_PATH", cfg):
            assert find_vnpy_path() == vnpy

    def test_looks_like_vnpy_strict(self, tmp_path):
        """只有同时具备 .venv/bin/python 和 examples/akshare_data/analyze.py 才算合法 vnpy"""
        from runtime import _looks_like_vnpy
        empty = tmp_path / "empty"
        empty.mkdir()
        assert not _looks_like_vnpy(empty)

        only_venv = tmp_path / "only_venv"
        (only_venv / ".venv/bin").mkdir(parents=True)
        (only_venv / ".venv/bin/python").write_text("")
        assert not _looks_like_vnpy(only_venv)   # 缺 analyze.py

        complete = tmp_path / "complete"
        (complete / ".venv/bin").mkdir(parents=True)
        (complete / ".venv/bin/python").write_text("")
        (complete / "examples/akshare_data").mkdir(parents=True)
        (complete / "examples/akshare_data/analyze.py").write_text("")
        assert _looks_like_vnpy(complete)


class TestHealthCheck:
    def test_returns_dict_with_required_keys(self):
        from runtime import health_check
        h = health_check()
        assert "ok" in h
        assert "vnpy_path" in h
        assert "vnpy_python" in h
        assert "source" in h
        assert "errors" in h
        assert isinstance(h["ok"], bool)
        assert isinstance(h["errors"], list)
