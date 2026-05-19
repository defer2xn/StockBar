"""holdings.py 测试：portfolio.json 加载 + 旧 持仓.md 解析容忍度。"""
import json
import pytest
from pathlib import Path


def _write_json(tmp_path: Path, content: dict) -> Path:
    p = tmp_path / "portfolio.json"
    p.write_text(json.dumps(content, ensure_ascii=False), encoding="utf-8")
    return p


def _write_md(tmp_path: Path, content: str) -> Path:
    p = tmp_path / "持仓.md"
    p.write_text(content, encoding="utf-8")
    return p


# ============================ JSON 加载 ============================

class TestLoadJSON:
    def test_load_complete(self, tmp_path):
        from holdings import load_json
        p = _write_json(tmp_path, {
            "cash": 60500,
            "positions": [{"code": "159742", "name": "恒指科技", "shares": 107400, "cost_price": 0.626}],
            "watchlist": [{"code": "600519", "name": "贵州茅台"}],
        })
        h = load_json(p)
        assert h.cash == 60500
        assert len(h.positions) == 1
        assert h.positions[0].code == "159742"
        assert h.positions[0].shares == 107400
        assert h.positions[0].cost_price == 0.626
        assert len(h.watchlist) == 1
        assert h.watchlist[0].code == "600519"

    def test_load_empty_file(self, tmp_path):
        from holdings import load_json
        # 文件不存在
        h = load_json(tmp_path / "missing.json")
        assert h.cash is None
        assert h.positions == []
        assert h.watchlist == []

    def test_load_malformed_json(self, tmp_path):
        from holdings import load_json
        p = tmp_path / "bad.json"
        p.write_text("{not valid json", encoding="utf-8")
        h = load_json(p)
        # 损坏 → 返回空 Holdings，不崩溃
        assert h.cash is None
        assert h.positions == []
        assert h.watchlist == []

    def test_load_missing_fields(self, tmp_path):
        """JSON 缺字段时 fallback 到默认值"""
        from holdings import load_json
        p = _write_json(tmp_path, {"cash": 1000})  # 缺 positions / watchlist
        h = load_json(p)
        assert h.cash == 1000
        assert h.positions == []
        assert h.watchlist == []

    def test_load_position_without_optional_fields(self, tmp_path):
        """positions 只给 code 也能解析"""
        from holdings import load_json
        p = _write_json(tmp_path, {
            "cash": 100,
            "positions": [{"code": "002714"}],
            "watchlist": [],
        })
        h = load_json(p)
        assert h.positions[0].code == "002714"
        assert h.positions[0].shares is None
        assert h.positions[0].cost_price is None

    def test_load_skips_position_without_code(self, tmp_path):
        from holdings import load_json
        p = _write_json(tmp_path, {
            "positions": [
                {"code": "159742", "shares": 100},
                {"name": "无代码"},               # 无 code → 跳过
                {"code": "", "shares": 200},       # 空 code → 跳过
            ],
        })
        h = load_json(p)
        assert len(h.positions) == 1
        assert h.positions[0].code == "159742"

    def test_load_invalid_numbers(self, tmp_path):
        """shares / cost_price 非数字时 _safe_float 返回 None"""
        from holdings import load_json
        p = _write_json(tmp_path, {
            "positions": [{"code": "159742", "shares": "abc", "cost_price": None}],
        })
        h = load_json(p)
        assert h.positions[0].shares is None
        assert h.positions[0].cost_price is None


# ============================ 旧 MD 解析 ============================

class TestParseMD:
    def test_empty_position(self):
        from holdings import parse
        text = """
股票持仓：（空仓）

剩余资金：760,716 元

关注：
- 159742 恒指科技
- 159131 港股通信息技术ETF华宝
"""
        h = parse(text)
        assert h.cash == 760716
        assert h.positions == []
        assert len(h.watchlist) == 2
        assert h.watchlist[0].code == "159742"

    def test_position_with_shares_and_cost(self):
        from holdings import parse
        text = """
股票持仓：
- 600519 贵州茅台 100股 @1700.50

剩余资金：50000 元
"""
        h = parse(text)
        assert len(h.positions) == 1
        p = h.positions[0]
        assert p.code == "600519"
        assert p.name == "贵州茅台"
        assert p.shares == 100
        assert p.cost_price == 1700.50

    def test_skips_closed_positions(self):
        """已平仓 / 历史 段落必须跳过"""
        from holdings import parse
        text = """
股票持仓：
- 159742 恒指科技 50000份 0.653

已平仓：
- 2026-05-12  159742 恒指科技：0.659（40000 元）→ 0.653 清仓

关注：
- 600519 贵州茅台
"""
        h = parse(text)
        # 已平仓里的 159742 不该被当成 当前持仓重复
        assert len(h.positions) == 1
        assert h.positions[0].code == "159742"
        assert len(h.watchlist) == 1

    def test_cash_with_thousand_separator(self):
        from holdings import parse
        h = parse("剩余资金：1,234,567.89 元")
        assert h.cash == 1234567.89

    def test_position_with_amount_not_shares(self):
        """旧格式：159742 恒指科技：0.653（30000 元）"""
        from holdings import parse
        text = """
股票持仓：
- 159742 恒指科技：0.653（30000 元）
"""
        h = parse(text)
        assert len(h.positions) == 1
        p = h.positions[0]
        assert p.code == "159742"
        assert p.cost_price == 0.653
        assert p.cost_amount == 30000


# ============================ to_dict 转换 ============================

class TestToDict:
    def test_serialization(self):
        from holdings import Holdings, Position, to_dict
        h = Holdings(
            positions=[Position(code="600519", name="贵州茅台", shares=100, cost_price=1700.0)],
            cash=50000,
            watchlist=[Position(code="159742", name="恒指科技")],
        )
        d = to_dict(h)
        assert d["cash"] == 50000
        assert len(d["positions"]) == 1
        assert d["positions"][0]["code"] == "600519"
        assert d["watchlist"][0]["code"] == "159742"
        # watchlist 不应含 cost/shares 字段
        assert "shares" not in d["watchlist"][0]
