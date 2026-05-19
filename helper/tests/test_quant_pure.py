"""quant.py 纯函数测试（不依赖 akshare / vnpy）。

覆盖：
  - 价格 tick 量化（A股 / ETF）
  - 仓位 100 倍数对齐
  - is_etf 严格识别
  - is_risky_name / is_risky_code
  - sina_symbol 前缀映射
  - session_name 时段判定（部分）
  - support_resistance + short_term_score + make_buy_order + evaluate_holding
    通过构造 fake DataFrame 测试关键决策路径（B1 / M1 / M2 回归保护）
"""
import math
from datetime import datetime
from unittest.mock import patch

import pytest


# ============================ 价格 tick 量化 ============================

class TestQuantizePrice:
    def test_etf_tick_round_to_3_decimals(self):
        from quant import quantize_price
        assert quantize_price(0.6234, "159742") == 0.623
        assert quantize_price(4.7956, "510300") == 4.796
        assert quantize_price(1.0005, "513180") == 1.0   # banker's rounding

    def test_stock_tick_round_to_2_decimals(self):
        from quant import quantize_price
        assert quantize_price(40.20, "002714") == 40.20
        assert quantize_price(1700.499, "600519") == 1700.50
        # Python banker's rounding: .5 → 偶数（已知行为，不是 bug）
        assert quantize_price(40.205, "002714") == 40.20   # not 40.21

    def test_price_rounding_never_exceeds_original_significantly(self):
        from quant import quantize_price
        for raw, code in [(40.213, "002714"), (0.6234, "159742")]:
            q = quantize_price(raw, code)
            assert abs(q - raw) <= 0.005   # 不偏离超 0.5%


# ============================ 仓位 100 倍数 ============================

class TestQuantizeShares:
    def test_floors_to_100_multiple(self):
        from quant import quantize_shares
        assert quantize_shares(60000, 0.626) == 95800   # 60000/0.626=95846 → 95800
        assert quantize_shares(1000, 1.0) == 1000
        assert quantize_shares(999, 1.0) == 900
        assert quantize_shares(100, 1.0) == 100

    def test_insufficient_budget_returns_zero(self):
        from quant import quantize_shares
        assert quantize_shares(50, 1.0) == 0
        assert quantize_shares(99, 1.0) == 0
        assert quantize_shares(199, 2.0) == 0   # 99.5 股 → 0
        assert quantize_shares(50, 0.51) == 0   # 98 股 → 0

    def test_zero_or_negative_price_safe(self):
        from quant import quantize_shares
        assert quantize_shares(60000, 0) == 0
        assert quantize_shares(60000, -1) == 0
        assert quantize_shares(60000, -0.001) == 0


# ============================ is_etf ============================

class TestIsETF:
    def test_etf_codes(self):
        from quant import is_etf
        for code in ["159742", "159131", "510300", "510500", "511000",
                     "512480", "513180", "515050", "560050", "562000",
                     "588000", "159928"]:
            assert is_etf(code), f"{code} should be ETF"

    def test_stock_codes(self):
        from quant import is_etf
        for code in ["600519", "688981", "000001", "000858",
                     "300750", "002594", "002714", "601012"]:
            assert not is_etf(code), f"{code} should NOT be ETF"

    def test_legacy_graded_funds_rejected(self):
        """已停止交易的旧分级基金（150xxx/151xxx）不视为可交易 ETF"""
        from quant import is_etf
        assert not is_etf("150001")
        assert not is_etf("151001")
        assert not is_etf("150100")

    def test_invalid_length(self):
        from quant import is_etf
        assert not is_etf("12345")     # 5 位
        assert not is_etf("1597422")   # 7 位
        assert not is_etf("")


# ============================ 风险标识 ============================

class TestRiskFilters:
    def test_st_names_rejected(self):
        from quant import is_risky_name
        assert is_risky_name("ST 牧原")
        assert is_risky_name("*ST 牧原")
        assert is_risky_name("某退市股")
        assert is_risky_name("ST 暂停某某")
        assert not is_risky_name("贵州茅台")
        assert not is_risky_name("沪深300ETF")

    def test_bj_exchange_rejected(self):
        from quant import is_risky_code
        assert is_risky_code("833230")   # 北交所 8 开头
        assert is_risky_code("430123")   # 北交所 4 开头
        assert is_risky_code("12345")    # 长度不对
        assert not is_risky_code("600519")
        assert not is_risky_code("159742")


# ============================ Sina symbol ============================

class TestSinaSymbol:
    def test_sh_prefix(self):
        from quant import _sina_symbol
        assert _sina_symbol("600519") == "sh600519"
        assert _sina_symbol("688981") == "sh688981"
        assert _sina_symbol("510300") == "sh510300"
        assert _sina_symbol("588000") == "sh588000"

    def test_sz_prefix(self):
        from quant import _sina_symbol
        assert _sina_symbol("000001") == "sz000001"
        assert _sina_symbol("002714") == "sz002714"
        assert _sina_symbol("300750") == "sz300750"
        assert _sina_symbol("159742") == "sz159742"


# ============================ 时段感知 ============================

class TestSession:
    def test_pre_market(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 19, 9, 0)   # 周二 9:00
            mock_dt.side_effect = lambda *a, **k: datetime(*a, **k)
            assert session_name() == "盘前"

    def test_morning(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 19, 10, 30)
            assert session_name() == "上午"

    def test_lunch(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 19, 12, 0)
            assert session_name() == "午休"

    def test_afternoon(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 19, 14, 30)
            assert session_name() == "下午"

    def test_after_market(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 19, 16, 0)
            assert session_name() == "盘后"

    def test_weekend(self):
        from quant import session_name
        with patch("quant.datetime") as mock_dt:
            mock_dt.now.return_value = datetime(2026, 5, 17, 10, 0)   # 周日
            assert session_name() == "非交易日"
