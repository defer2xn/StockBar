#!/usr/bin/env python3
"""StockBar 量化引擎 — 输出可粘到券商的订单 JSON

设计参考 ~/.claude/skills/stock-analyse/SKILL.md（订单引擎版）。

运行环境：必须用 vnpy 的 venv (已带 akshare + talib + pandas)
    /Users/wepie/github/vnpy/.venv/bin/python helper/quant.py

输入：无 (读 portfolio.json)
输出：单行 JSON 到 stdout

调试日志：stderr
"""
from __future__ import annotations

import json
import os
import re
import sys
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

import requests

# 复用 vnpy 的 analyze.py —— 延迟到 main() 调用时再 import，方便单元测试纯函数
# 测试环境（pytest 跑纯逻辑测试）不需要真实 akshare
detect_type = None  # type: ignore
get_prefix = None
fetch_hist_data = None
fetch_realtime = None
compute_indicators = None


def _import_analyze() -> str | None:
    """import vnpy/analyze.py；返回 error 字符串或 None。
    成功后把 5 个函数注入到模块全局，供后续用。
    """
    global detect_type, get_prefix, fetch_hist_data, fetch_realtime, compute_indicators
    if detect_type is not None:
        return None    # 已 import
    try:
        # 路径软编码：优先 ENV，其次 ~/Library/.../config.json，最后自动探测
        from runtime import find_vnpy_path
        vnpy_path = find_vnpy_path()
        if vnpy_path is None:
            return "未找到 vnpy 项目路径（设 STOCKBAR_VNPY_PATH 环境变量或 config.json）"
        sys.path.insert(0, str(vnpy_path / "examples/akshare_data"))
        from analyze import (   # noqa: E402
            detect_type as _dt,
            get_prefix as _gp,
            fetch_hist_data as _fhd,
            fetch_realtime as _fr,
            compute_indicators as _ci,
        )
        detect_type = _dt
        get_prefix = _gp
        fetch_hist_data = _fhd
        fetch_realtime = _fr
        compute_indicators = _ci
        return None
    except Exception as e:
        return f"加载 vnpy/analyze.py 失败: {e}"


# ============================ 配置 ============================

PORTFOLIO_JSON = Path.home() / "Library/Application Support/StockBar/portfolio.json"

# 深扫数量上限（K线 + 评分），平衡覆盖度和速度
MAX_DEEP_SCAN = 80

# 候选 ETF 池（覆盖主要主题板块）
ETF_UNIVERSE = [
    ("510300", "沪深300ETF"),
    ("510500", "中证500ETF"),
    ("588000", "科创50ETF"),
    ("159915", "创业板ETF"),
    ("159928", "消费ETF"),
    ("512010", "医药ETF"),
    ("516160", "新能源ETF"),
    ("515030", "新能源车ETF"),
    ("512480", "半导体ETF"),
    ("159995", "芯片ETF"),
    ("513180", "恒生科技ETF"),
    ("513010", "恒生科技30ETF"),
    ("512660", "军工ETF"),
    ("512070", "证券ETF"),
    ("512170", "医疗ETF"),
    ("159939", "信息技术ETF"),
]

# 候选个股池（各行业龙头 + 高流动性）
STOCK_UNIVERSE = [
    # 白酒消费
    ("600519", "贵州茅台"),
    ("000858", "五粮液"),
    ("000333", "美的集团"),
    ("600887", "伊利股份"),
    # 金融
    ("600036", "招商银行"),
    ("601318", "中国平安"),
    ("000001", "平安银行"),
    ("600030", "中信证券"),
    # 新能源 / 制造
    ("300750", "宁德时代"),
    ("002594", "比亚迪"),
    ("601012", "隆基绿能"),
    ("600900", "长江电力"),
    # 科技 / 半导体
    ("000725", "京东方A"),
    ("002415", "海康威视"),
    ("300059", "东方财富"),
    ("002230", "科大讯飞"),
    # 医药
    ("600276", "恒瑞医药"),
    ("300015", "爱尔眼科"),
    ("000538", "云南白药"),
    # 周期 / 资源
    ("601899", "紫金矿业"),
    ("600028", "中国石化"),
    # 地产 / 基建
    ("600585", "海螺水泥"),
    # 农业
    ("002714", "牧原股份"),
]

# 价格档位
TICK_STOCK = 0.01
TICK_ETF   = 0.001


# ============================ 工具 ============================

def log(msg: str) -> None:
    print(f"[quant {datetime.now().strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def session_name() -> str:
    """A 股交易时段"""
    n = datetime.now()
    h, m, w = n.hour, n.minute, n.weekday()
    if w >= 5:
        return "非交易日"
    if h < 9 or (h == 9 and m < 30):
        return "盘前"
    if h < 11 or (h == 11 and m <= 30):
        return "上午"
    if h < 13:
        return "午休"
    if h < 15:
        return "下午"
    return "盘后"


def is_etf(code: str) -> bool:
    """A 股 ETF 严格识别：
    - 159xxx 深市 ETF
    - 51xxxx / 56xxxx / 58xxxx 沪市 ETF
    排除已停止交易的 150xxx/151xxx 分级基金。
    """
    if len(code) != 6:
        return False
    if code.startswith("159"):
        return True
    return code[:2] in ("51", "56", "58")


def is_risky_name(name: str) -> bool:
    """名称含 ST / 退 / *ST / 暂停等 → 视为高风险，剔除"""
    return any(tag in name for tag in ("ST", "*ST", "退", "暂停"))


def is_risky_code(code: str) -> bool:
    """北交所 (4/8 开头) / 不在 6 位标准范围 → 高风险或非 A 股"""
    if len(code) != 6:
        return True
    if code.startswith(("4", "8")):
        return True
    return False


# ---------- Sina 批量行情（L1 预筛专用，避免对全 300 只跑 K 线）----------

SINA_URL = "https://hq.sinajs.cn/list={}"
SINA_HEADERS = {
    "Referer": "https://finance.sina.com.cn/",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605 Safari/605",
}
SINA_LINE_RE = re.compile(r'var hq_str_([a-z0-9]+)="([^"]*)"\s*;')


def _sina_symbol(code: str) -> str:
    if code.startswith(("60", "68", "11", "13", "51", "56", "58")):
        return "sh" + code
    if code.startswith(("00", "30", "20", "15", "12")):
        return "sz" + code
    return "sh" + code


def fetch_quotes_batch(codes: list[str]) -> dict[str, dict]:
    """批量拉 Sina spot：{code: {price, prev_close, change_pct, name}}。
    1 个请求 80 个 code，~150ms。300 只 ≈ 4 个 batch ≈ 600ms。
    """
    out: dict[str, dict] = {}
    if not codes:
        return out
    code_to_sym = {c: _sina_symbol(c) for c in codes}
    sym_to_code = {v: k for k, v in code_to_sym.items()}
    symbols = list(code_to_sym.values())
    BATCH = 80
    for i in range(0, len(symbols), BATCH):
        batch = symbols[i:i + BATCH]
        url = SINA_URL.format(",".join(batch))
        try:
            r = requests.get(url, headers=SINA_HEADERS, timeout=5)
            r.encoding = "gbk"
            for m in SINA_LINE_RE.finditer(r.text):
                sym = m.group(1)
                code = sym_to_code.get(sym)
                if not code:
                    continue
                fields = m.group(2).split(",")
                if len(fields) < 4:
                    continue
                try:
                    name = fields[0]
                    prev = float(fields[2])
                    price = float(fields[3])
                except (ValueError, IndexError):
                    continue
                if price == 0:
                    # 停牌或异常
                    continue
                pct = (price - prev) / prev * 100 if prev > 0 else 0.0
                out[code] = {
                    "name": name,
                    "price": price,
                    "prev_close": prev,
                    "change_pct": pct,
                }
        except Exception as e:
            log(f"sina batch failed {i}: {e}")
    return out


def fetch_hs300_components() -> list[tuple[str, str]]:
    """拉沪深300成分股 (code, name)；过滤 ST/退市/北交所"""
    try:
        import akshare as _ak
        df = _ak.index_stock_cons_csindex(symbol="000300")
        codes_col = "成分券代码"
        names_col = "成分券名称"
        result = []
        for _, row in df.iterrows():
            code = str(row[codes_col]).strip().zfill(6)
            name = str(row[names_col]).strip()
            if is_risky_name(name) or is_risky_code(code):
                continue
            result.append((code, name))
        return result
    except Exception as e:
        log(f"hs300 fetch failed: {e}")
        return []


# 沪深300 缓存（本次 quant 调用复用 1 次）
_HS300_CACHE: list[tuple[str, str]] | None = None


def get_hs300() -> list[tuple[str, str]]:
    global _HS300_CACHE
    if _HS300_CACHE is None:
        _HS300_CACHE = fetch_hs300_components()
        log(f"hs300 loaded: {len(_HS300_CACHE)} stocks")
    return _HS300_CACHE


def tick_size(code: str) -> float:
    return TICK_ETF if is_etf(code) else TICK_STOCK


def quantize_price(price: float, code: str) -> float:
    """按 tick 量化"""
    t = tick_size(code)
    return round(round(price / t) * t, 3 if is_etf(code) else 2)


def quantize_shares(budget: float, price: float) -> int:
    """向下取整到 100 倍数；不足 100 返回 0"""
    if price <= 0:
        return 0
    raw = budget / price
    return int(raw // 100) * 100


# ============================ portfolio ============================

def load_portfolio() -> dict:
    if not PORTFOLIO_JSON.exists():
        return {"cash": 0.0, "positions": [], "watchlist": []}
    try:
        return json.loads(PORTFOLIO_JSON.read_text(encoding="utf-8"))
    except Exception as e:
        log(f"portfolio load failed: {e}")
        return {"cash": 0.0, "positions": [], "watchlist": []}


# ============================ 指标 & 评分 ============================

def fetch_one(code: str) -> tuple[str, "pd.DataFrame | None", dict | None]:
    """拉单只 K线 + 实时数据，失败返回 (code, None, None)"""
    try:
        a_type = detect_type(code)
        df = fetch_hist_data(code, a_type, days=60)
        if df is None or len(df) < 25:
            return code, None, None
        df = compute_indicators(df)
        rt = fetch_realtime(code, a_type)
    except Exception as e:
        log(f"fetch {code} failed: {e}")
        return code, None, None
    return code, df, rt


def current_price(df, rt: dict | None) -> float:
    if rt and rt.get("price"):
        try:
            return float(rt["price"])
        except (TypeError, ValueError):
            pass
    return float(df["close"].iloc[-1])


def short_term_score(df, rt: dict | None, market_dir: int) -> tuple[int, str, dict]:
    """6 维短线评分 0-100；返回 (分数, 一句话原因, 详情 dict)"""
    if df is None or len(df) < 22:
        return 0, "数据不足", {}
    close = float(df["close"].iloc[-1])
    ma5 = float(df["ma5"].iloc[-1])
    ma10 = float(df["ma10"].iloc[-1])
    ma20 = float(df["ma20"].iloc[-1])
    high5 = float(df["high"].iloc[-5:].max())
    low20 = float(df["low"].iloc[-20:].min())
    try:
        ma20_slope = (ma20 - float(df["ma20"].iloc[-6])) / float(df["ma20"].iloc[-6])
    except Exception:
        ma20_slope = 0.0
    # 量比
    vol_today = float(df["volume"].iloc[-1])
    vol_avg5 = float(df["volume"].iloc[-6:-1].mean())
    vol_ratio = vol_today / vol_avg5 if vol_avg5 > 0 else 1.0
    # 今日涨跌幅：优先用 rt 实时（盘中准确），fallback 用 K 线（盘外可用）
    pct: float
    if rt and rt.get("change_pct") is not None:
        try:
            pct = float(rt["change_pct"])
        except (TypeError, ValueError):
            prev_close = float(df["close"].iloc[-2])
            pct = (close - prev_close) / prev_close * 100 if prev_close > 0 else 0
    else:
        prev_close = float(df["close"].iloc[-2])
        pct = (close - prev_close) / prev_close * 100 if prev_close > 0 else 0
    # ATR
    try:
        atr = float(df["atr"].iloc[-1])
        atr_pct = atr / close * 100
    except Exception:
        atr = (float(df["high"].iloc[-20:].max()) - low20) / 20
        atr_pct = atr / close * 100

    # ---- 6 维评分（每维 0-10）----
    # 1. 回调深度（权 25）
    drawdown = (high5 - close) / high5 * 100 if high5 > 0 else 0
    if 2 <= drawdown <= 5: d1 = 10
    elif 1 <= drawdown < 2 or 5 < drawdown <= 7: d1 = 7
    elif 0 <= drawdown < 1 or 7 < drawdown <= 10: d1 = 4
    else: d1 = 1

    # 2. 趋势强度（权 20）
    d2 = 0
    if ma5 > ma10 > ma20: d2 += 5
    if ma20_slope > 0.005: d2 += 3
    elif ma20_slope > 0: d2 += 2
    if close < ma5: d2 += 2
    d2 = min(d2, 10)

    # 3. 支撑接近（权 20）
    dist_ma20 = abs(close - ma20) / ma20 * 100 if ma20 > 0 else 100
    if dist_ma20 <= 1.5: d3 = 10
    elif dist_ma20 <= 3: d3 = 7
    elif dist_ma20 <= 5: d3 = 4
    else: d3 = 1

    # 4. 热点强度（权 15）—— 简化版（用市场方向 + 量能代理）
    d4 = 5
    if vol_ratio > 1.2: d4 += 2
    if market_dir > 0: d4 += 2

    # 5. 量价配合（权 10）
    if pct < 0 and vol_ratio < 0.9: d5 = 10
    elif pct < 0 and vol_ratio < 1.1: d5 = 7
    elif pct >= 0: d5 = 4
    else: d5 = 1

    # 6. 消息面（权 10）—— 当前默认中性偏多
    d6 = 7

    total = (d1 * 25 + d2 * 20 + d3 * 20 + d4 * 15 + d5 * 10 + d6 * 10) / 10

    # 行为型短原因（≤25 字）
    parts = []
    if drawdown >= 2: parts.append(f"回撤{drawdown:.1f}%")
    if dist_ma20 <= 1.5: parts.append("近MA20")
    elif close < ma5: parts.append("回踩MA5")
    if pct < 0 and vol_ratio < 0.9: parts.append("缩量")
    if not parts: parts.append("趋势回调")
    reason = " ".join(parts)[:25]

    # 详情 dict —— 给 UI 详情面板用
    ma_state = "MA5>MA10>MA20" if (ma5 > ma10 > ma20) else \
               "MA10>MA5,MA20" if (ma10 > ma5 and ma10 > ma20) else \
               "MA20>MA10>MA5" if (ma20 > ma10 > ma5) else "MA 混乱"

    # 收集触发的信号（可读化）
    signals = []
    if 2 <= drawdown <= 5:
        signals.append(f"已从 5 日高回撤 {drawdown:.1f}%（最佳买点区间 2-5%）")
    elif drawdown > 0:
        signals.append(f"已从 5 日高回撤 {drawdown:.1f}%")
    if ma5 > ma10 > ma20:
        signals.append(f"均线多头排列（{ma_state}）")
    elif ma_state != "MA 混乱":
        signals.append(f"均线状态：{ma_state}")
    if ma20_slope > 0:
        signals.append(f"MA20 上行（5 日斜率 +{ma20_slope*100:.2f}%）")
    elif ma20_slope < 0:
        signals.append(f"⚠️ MA20 下行（5 日斜率 {ma20_slope*100:.2f}%）")
    if close < ma5:
        signals.append("当前价低于 MA5（短期回调中）")
    if dist_ma20 <= 1.5:
        signals.append(f"贴近 MA20 支撑（距离 {dist_ma20:.1f}%）")
    if vol_ratio < 0.9 and pct < 0:
        signals.append(f"缩量回调（量比 {vol_ratio:.2f}），抛压衰减")
    elif vol_ratio > 1.5:
        signals.append(f"⚠️ 放量（量比 {vol_ratio:.2f}），关注方向")
    if pct > 0:
        signals.append(f"今日 +{pct:.2f}%")
    elif pct < 0:
        signals.append(f"今日 {pct:.2f}%")

    detail = {
        "dimensions": {
            "drawdown":  d1,    # 回调深度
            "trend":     d2,    # 趋势强度
            "support":   d3,    # 支撑接近
            "hotness":   d4,    # 热点强度
            "volume":    d5,    # 量价配合
            "news":      d6,    # 消息面
        },
        "signals": signals,
        "indicators": {
            "close":      round(close, 3),
            "ma5":        round(ma5, 3),
            "ma10":       round(ma10, 3),
            "ma20":       round(ma20, 3),
            "ma20_slope": round(ma20_slope * 100, 2),  # 转百分比
            "atr_pct":    round(atr_pct, 2),
            "drawdown":   round(drawdown, 2),
            "vol_ratio":  round(vol_ratio, 2),
            "change_pct": round(pct, 2),
            "high5":      round(high5, 3),
            "low20":      round(low20, 3),
        },
    }
    return int(round(total)), reason, detail


# ============================ 价格量化 ============================

def support_resistance(df) -> tuple[float, float]:
    """从 K 线 + 指标算最近的支撑和阻力"""
    close = float(df["close"].iloc[-1])
    ma20 = float(df["ma20"].iloc[-1])
    low20 = float(df["low"].iloc[-20:].min())
    high20 = float(df["high"].iloc[-20:].max())
    try:
        boll_lo = float(df["lower"].iloc[-1])
        boll_hi = float(df["upper"].iloc[-1])
    except Exception:
        boll_lo = ma20 * 0.97
        boll_hi = ma20 * 1.03

    s_candidates = [v for v in (ma20, boll_lo, low20) if v < close]
    r_candidates = [v for v in (high20, boll_hi, ma20 * 1.05) if v > close]
    S = max(s_candidates) if s_candidates else close * 0.97
    R = min(r_candidates) if r_candidates else close * 1.03
    return S, R


def make_buy_order(code: str, name: str, df, rt, score: int, reason: str, detail: dict, budget: float) -> dict | None:
    """按硬约束生成 1 笔买入订单；不满足返回 None"""
    P = current_price(df, rt)
    S, R = support_resistance(df)
    try:
        atr = float(df["atr"].iloc[-1])
        V = atr / P
    except Exception:
        V = (float(df["high"].iloc[-20:].max()) - float(df["low"].iloc[-20:].min())) / float(df["close"].iloc[-20:].mean())
    V = max(V, 0.005)

    Buy = max(S * 1.003, P * (1 - min(V * 0.5, 0.015)))
    TP = min(R * 0.997, Buy * (1 + max(V, 0.015)))
    SL = min(S * 0.992, Buy * 0.985)

    if not (P * 0.985 <= Buy <= P * 0.997):
        Buy = max(P * 0.985, min(P * 0.997, Buy))
    if not (Buy * 1.010 <= TP <= Buy * 1.035):
        TP = max(Buy * 1.010, min(Buy * 1.035, TP))
    if not (Buy * 0.970 <= SL <= Buy * 0.990):
        SL = max(Buy * 0.970, min(Buy * 0.990, SL))

    if Buy - SL <= 0:
        return None
    rr = (TP - Buy) / (Buy - SL)
    if rr < 1.5:
        return None

    buy_q = quantize_price(Buy, code)
    tp_q = quantize_price(TP, code)
    sl_q = quantize_price(SL, code)
    shares = quantize_shares(budget, buy_q)
    if shares == 0:
        return None

    cost_total = round(shares * buy_q, 2)
    profit_target = round(shares * (tp_q - buy_q), 2)
    loss_limit = round(shares * (buy_q - sl_q), 2)
    invalidation = (
        f"跌破止损 ¥{sl_q} (距买价 -{(buy_q - sl_q) / buy_q * 100:.2f}%) 立即出；"
        f"或 MA20 转头向下；或大盘单日跌 > 1.5%"
    )
    operation = (
        f"以 ¥{buy_q} 限价挂买 {shares} 股（成本 ¥{cost_total:,.0f}）。"
        f"成交后挂 ¥{tp_q} 止盈单（潜在收益 ¥{profit_target:,.0f}，"
        f"即 +{(tp_q - buy_q) / buy_q * 100:.2f}%），"
        f"同时挂 ¥{sl_q} 止损单（最大亏损 ¥{loss_limit:,.0f}，"
        f"即 -{(buy_q - sl_q) / buy_q * 100:.2f}%）。"
        f"盈亏比 {rr:.2f} : 1，1-2 日内若触止盈即获利出。"
    )

    return {
        "code": code,
        "name": name,
        "action": "买入",
        "shares": shares,
        "price": buy_q,
        "type": "LIMIT",
        "reason": reason,
        "score": score,
        "tp": tp_q,
        "sl": sl_q,
        "rr": round(rr, 2),
        "current_price": round(P, 3 if is_etf(code) else 2),
        # 详情字段
        "dimensions":   detail.get("dimensions", {}),
        "signals":      detail.get("signals", []),
        "indicators":   detail.get("indicators", {}),
        "support":      round(S, 3 if is_etf(code) else 2),
        "resistance":   round(R, 3 if is_etf(code) else 2),
        "cost_total":   cost_total,
        "profit_target": profit_target,
        "loss_limit":   loss_limit,
        "buy_pct":      round((buy_q - P) / P * 100, 2),    # 距现价
        "tp_pct":       round((tp_q - buy_q) / buy_q * 100, 2),  # 距买价
        "sl_pct":       round((sl_q - buy_q) / buy_q * 100, 2),  # 距买价
        "operation":    operation,
        "invalidation": invalidation,
    }


def evaluate_holding(code: str, name: str, shares: int, cost_price: float, df, rt) -> dict | None:
    """对持仓返回卖出订单（止盈/止损/清仓）或 None(持有不动)。"""
    if df is None or rt is None:
        return None
    P = current_price(df, rt)
    if cost_price <= 0:
        return None
    pnl_pct = (P - cost_price) / cost_price * 100
    pnl_amount = (P - cost_price) * shares
    try:
        atr = float(df["atr"].iloc[-1])
    except Exception:
        atr = P * 0.02
    atr_pct = atr / P * 100
    S, R = support_resistance(df)
    ma20 = float(df["ma20"].iloc[-1])
    score, _, detail = short_term_score(df, rt, 0)
    shares_int = int(shares // 100) * 100

    def _common_extras(sell_price: float, action: str, kind: str) -> dict:
        gross = sell_price * shares_int
        action_pnl = (sell_price - cost_price) * shares_int
        dist_to_market = (sell_price - P) / P * 100   # 卖价与现价距离
        if kind == "tp":
            op = (
                f"以 ¥{sell_price} 限价挂卖 {shares_int} 股（卖价 {dist_to_market:+.2f}% 现价，等待买盘吃单）。"
                f"成交后回笼 ¥{gross:,.0f}，本次操作锁定盈亏 ¥{action_pnl:+,.0f}，即 {(sell_price-cost_price)/cost_price*100:+.2f}%。"
                f"当前已接近阻力位 ¥{round(R, 3 if is_etf(code) else 2)}，可顺势离场。"
            )
            inv = f"若价格继续突破 ¥{round(R, 3 if is_etf(code) else 2)} 且放量，可分批继续持有"
        elif kind == "sl":
            op = (
                f"⚡ 立即减仓 — 以 ¥{sell_price} 限价挂卖 {shares_int} 股（卖价 {dist_to_market:+.2f}% 现价，限价单可立即成交）。"
                f"成交后回笼 ¥{gross:,.0f}，本次操作锁定亏损 ¥{action_pnl:+,.0f}，即 {(sell_price-cost_price)/cost_price*100:+.2f}%。"
                f"已跌破 MA20 支撑 ¥{round(ma20, 3 if is_etf(code) else 2)}，趋势可能反转，止损保护本金。"
            )
            inv = f"若快速反弹站回 MA20 (¥{round(ma20, 3 if is_etf(code) else 2)}) 之上，可观察再判断；否则维持已止损"
        else:  # clear
            op = (
                f"⚡ 立即清仓 — 以 ¥{sell_price} 限价挂卖 {shares_int} 股（卖价 {dist_to_market:+.2f}% 现价，可立即成交）。"
                f"回笼 ¥{gross:,.0f}，本次操作锁定盈亏 ¥{action_pnl:+,.0f}。"
                f"短线评分仅 {score}（< 50），原有买入逻辑已失效，换股或观望。"
            )
            inv = "短线评分恢复至 70+ 或趋势重新确认再考虑回补"
        return {
            "dimensions": detail.get("dimensions", {}),
            "signals":    detail.get("signals", []),
            "indicators": detail.get("indicators", {}),
            "support":    round(S, 3 if is_etf(code) else 2),
            "resistance": round(R, 3 if is_etf(code) else 2),
            "cost_price": cost_price,
            "pnl_pct":    round(pnl_pct, 2),
            "pnl_amount": round(pnl_amount, 2),
            "atr_pct":    round(atr_pct, 2),
            "sell_pct":   round((sell_price - P) / P * 100, 2),  # 卖价距现价 %
            "operation":  op,
            "invalidation": inv,
        }

    # 止盈：浮盈 ≥ 1× ATR 且【接近但未突破】阻力（R 在 P 上方且距离 ≤ 1%）
    # 卖价可略高于现价（限价单等买盘吃单），但不低于现价 +0.1%
    if pnl_pct >= atr_pct and R > P and (R - P) / P * 100 <= 1:
        sell = quantize_price(min(R * 0.997, P * 1.005), code)
        sell = max(sell, quantize_price(P * 1.001, code))
        return {
            "code": code, "name": name, "action": "止盈卖出",
            "shares": shares_int, "price": sell, "type": "LIMIT",
            "reason": f"浮盈{pnl_pct:.1f}% 触阻力", "score": score,
            "current_price": round(P, 3 if is_etf(code) else 2),
            **_common_extras(sell, "止盈卖出", "tp"),
        }

    # 浮盈 + 破 MA20 → 止盈出局（保住利润，不是止损）
    # 关键修复：之前会误判为"止损卖出 浮亏+20%"自相矛盾
    if pnl_pct > 0 and P < ma20 * 0.99:
        sell = quantize_price(P * 0.998, code)
        sell = max(sell, quantize_price(P * 1.001, code))   # 不低于现价
        return {
            "code": code, "name": name, "action": "止盈卖出",
            "shares": shares_int, "price": sell, "type": "LIMIT",
            "reason": f"浮盈{pnl_pct:.1f}% 破MA20", "score": score,
            "current_price": round(P, 3 if is_etf(code) else 2),
            **_common_extras(sell, "止盈卖出", "tp"),
        }

    # 止损：必须在【浮亏】状态下触发；信号已触发 → 立即减仓
    # 卖价 = 现价 −0.2%（限价单立即成交，A 股盘口足以吃掉）
    if pnl_pct < 0 and (pnl_pct <= -atr_pct or P < ma20 * 0.99):
        sell = quantize_price(P * 0.998, code)
        return {
            "code": code, "name": name, "action": "止损卖出",
            "shares": shares_int, "price": sell, "type": "LIMIT",
            "reason": f"浮亏{pnl_pct:.1f}% 破MA20", "score": score,
            "current_price": round(P, 3 if is_etf(code) else 2),
            **_common_extras(sell, "止损卖出", "sl"),
        }

    # 评分极弱兜底：score < 50 即换股，区分止盈/清仓
    if score < 50:
        sell = quantize_price(P * 0.998, code)
        if pnl_pct > 0:
            # 浮盈状态下走"止盈"语义（注意护栏 ≥ 现价 +0.1%）
            sell = max(sell, quantize_price(P * 1.001, code))
            return {
                "code": code, "name": name, "action": "止盈卖出",
                "shares": shares_int, "price": sell, "type": "LIMIT",
                "reason": f"评分{score}弱 浮盈了结", "score": score,
                "current_price": round(P, 3 if is_etf(code) else 2),
                **_common_extras(sell, "止盈卖出", "tp"),
            }
        return {
            "code": code, "name": name, "action": "清仓",
            "shares": shares_int, "price": sell, "type": "LIMIT",
            "reason": f"评分{score}弱 失去逻辑", "score": score,
            "current_price": round(P, 3 if is_etf(code) else 2),
            **_common_extras(sell, "清仓", "clear"),
        }

    return None


# ============================ 市场方向 ============================

def market_direction() -> tuple[int, str]:
    """读上证指数 MA 排列；返回 (方向, 描述)。方向: 1↑ 0→ -1↓"""
    try:
        df = fetch_hist_data("000001", "index", days=30)
        if df is None or len(df) < 20:
            return 0, "→"
        df = compute_indicators(df)
        ma5 = float(df["ma5"].iloc[-1])
        ma10 = float(df["ma10"].iloc[-1])
        ma20 = float(df["ma20"].iloc[-1])
        close = float(df["close"].iloc[-1])
        if close > ma5 > ma10 > ma20:
            return 1, "↑"
        if close < ma5 < ma10 < ma20:
            return -1, "↓"
        return 0, "→"
    except Exception as e:
        log(f"market_direction failed: {e}")
        return 0, "→"


# ============================ 主流程 ============================

def main():
    # 启动时确保 vnpy/analyze.py 已 import
    err = _import_analyze()
    if err:
        print(json.dumps({
            "ok": False, "type": "quant",
            "ts": now_str(),
            "error": err,
        }, ensure_ascii=False))
        sys.exit(0)

    notes: list[str] = []
    portfolio = load_portfolio()
    cash = float(portfolio.get("cash") or 0)
    positions = portfolio.get("positions") or []
    watchlist = portfolio.get("watchlist") or []
    sess = session_name()

    # 市场方向
    market_dir, market_arrow = market_direction()
    if market_arrow == "→":
        notes.append("市场震荡")
    elif market_dir < 0:
        notes.append("市场弱势 仅推强势")

    # ---- 候选池：自选 + 持仓 + ETF + A 股龙头 + 沪深300 ----
    held_codes = {p.get("code") for p in positions}
    candidates: list[tuple[str, str]] = []
    seen = set()
    forced_codes: set[str] = set()   # 自选 + 持仓必须深扫，跳过 L1 预筛

    # 1) 自选（必扫）
    for w in watchlist:
        c = w.get("code")
        if c and not is_risky_code(c) and c not in seen and c not in held_codes:
            candidates.append((c, w.get("name", c)))
            seen.add(c)
            forced_codes.add(c)
    # 2) ETF 通用池（必扫）
    for c, n in ETF_UNIVERSE:
        if c not in seen and c not in held_codes:
            candidates.append((c, n))
            seen.add(c)
            forced_codes.add(c)
    # 3) A 股龙头池（必扫）
    for c, n in STOCK_UNIVERSE:
        if c not in seen and c not in held_codes and not is_risky_code(c):
            candidates.append((c, n))
            seen.add(c)
            forced_codes.add(c)
    # 4) 沪深300 成分（参与 L1 预筛）
    for c, n in get_hs300():
        if c not in seen and c not in held_codes and not is_risky_name(n):
            candidates.append((c, n))
            seen.add(c)
    log(f"candidates total (incl HS300): {len(candidates)}, forced: {len(forced_codes)}")

    # ---- L1 预筛：用 Sina 批量 spot 一次拉所有当日涨跌幅 ----
    spot_codes = [c for c, _ in candidates if c not in forced_codes]
    spot_map = fetch_quotes_batch(spot_codes) if spot_codes else {}
    log(f"sina batch returned {len(spot_map)}/{len(spot_codes)} quotes")

    # L1 过滤：今日涨幅 ≤ +0.5%（含跌 / 平 / 微涨）
    l1_survivors: list[tuple[str, str, float]] = []   # (code, name, change_pct)
    for c, n in candidates:
        if c in forced_codes:
            l1_survivors.append((c, n, 0.0))   # 不参与 L1 评估，但深扫
            continue
        sp = spot_map.get(c)
        if not sp:
            continue
        if sp["change_pct"] > 0.5:
            continue
        l1_survivors.append((c, n, sp["change_pct"]))

    # 排优先级：forced 优先；其余按今日跌幅（越跌越前）
    forced_part = [t for t in l1_survivors if t[0] in forced_codes]
    other_part = sorted([t for t in l1_survivors if t[0] not in forced_codes], key=lambda x: x[2])
    ranked = forced_part + other_part
    deep_targets = ranked[:MAX_DEEP_SCAN]
    log(f"L1 survivors: {len(l1_survivors)}, deep-scan top {len(deep_targets)}")

    # ---- 并行拉 K 线：deep_targets + 持仓 ----
    held_pairs = [(p.get("code"), p.get("name", p.get("code"))) for p in positions]
    deep_pairs = [(c, n) for c, n, _ in deep_targets] + held_pairs
    # 去重保序
    seen2 = set()
    deep_unique = []
    for c, n in deep_pairs:
        if c not in seen2:
            deep_unique.append((c, n))
            seen2.add(c)

    data_map: dict[str, tuple] = {}
    with ThreadPoolExecutor(max_workers=10) as ex:
        futures = {ex.submit(fetch_one, c): (c, n) for c, n in deep_unique}
        for fut in as_completed(futures):
            try:
                code, df, rt = fut.result(timeout=20)
                data_map[code] = (df, rt)
            except Exception as e:
                c, _n = futures[fut]
                log(f"future {c} failed: {e}")
                data_map[c] = (None, None)

    # ---- 持仓评估 ----
    sell_orders = []
    hold_count = 0
    for p in positions:
        code = p.get("code")
        name = p.get("name", code)
        shares = float(p.get("shares") or 0)
        cost = float(p.get("costPrice") or 0)
        df, rt = data_map.get(code, (None, None))
        order = evaluate_holding(code, name, shares, cost, df, rt)
        if order:
            sell_orders.append(order)
        else:
            hold_count += 1

    # ---- 候选筛选 + 打分（只对深扫成功的）----
    scored: list[tuple[int, str, dict, str, str]] = []   # (score, reason, detail, code, name)
    deep_only = [(c, n) for c, n in deep_unique if c not in {p.get("code") for p in positions}]
    for code, name in deep_only:
        df, rt = data_map.get(code, (None, None))
        if df is None:
            continue
        # L1 兜底（forced 池中的代码可能没跑 L1）
        if rt and rt.get("change_pct") is not None:
            try:
                if float(rt["change_pct"]) > 0.5:
                    continue
            except (TypeError, ValueError):
                pass
        # L3：MA20 上行 + close < MA5
        try:
            ma20_now = float(df["ma20"].iloc[-1])
            ma20_prev = float(df["ma20"].iloc[-6])
            ma5_now = float(df["ma5"].iloc[-1])
            close = float(df["close"].iloc[-1])
            if ma20_now <= ma20_prev:
                continue
            if close >= ma5_now:
                continue
        except Exception:
            continue

        score, reason, detail = short_term_score(df, rt, market_dir)
        if score < 70:
            continue
        scored.append((score, reason, detail, code, name))

    scored.sort(key=lambda x: -x[0])
    log(f"scored (>=70): {len(scored)}")

    # ---- 仓位预算 + 生成买入订单 ----
    # ratio 基于【初始 cash】算（不是 reduce 后），单笔仓位才稳定；
    # 但累积总仓位不超过 cash × CUMULATIVE_CAP（防超额）
    buy_orders = []
    CUMULATIVE_CAP = 0.85
    spent = 0.0
    for score, reason, detail, code, name in scored[:10]:
        if score >= 85:
            ratio = 0.35
        elif score >= 75:
            ratio = 0.25
        else:
            ratio = 0.15
        # 单笔预算 = 初始 cash × ratio，但不超过剩余预算上限
        budget = cash * ratio
        remaining_cap = cash * CUMULATIVE_CAP - spent
        budget = min(budget, remaining_cap)
        if budget <= 0:
            break
        df, rt = data_map[code]
        order = make_buy_order(code, name, df, rt, score, reason, detail, budget)
        if order is None:
            continue
        buy_orders.append(order)
        spent += order["shares"] * order["price"]
        if len(buy_orders) >= 5:
            break

    if not buy_orders and not sell_orders:
        if not candidates:
            notes.append("无候选标的")
        else:
            notes.append("无符合条件订单")

    summary = {
        "cash": cash,
        "holdings_count": len(positions),
        "buys": len(buy_orders),
        "sells": len(sell_orders),
        "hold_count": hold_count,
        "candidates_scanned": len(deep_unique),    # 实际深扫数（含持仓）
        "universe_size": len(candidates),           # 候选总池子
    }

    response = {
        "ok": True,
        "type": "quant",
        "ts": now_str(),
        "session": sess,
        "market": market_arrow,
        "orders": sell_orders + buy_orders,
        "quant_summary": summary,    # 跟 article 的 summary 字段区分（HelperResponse 是统一 struct）
        "notes": notes,
    }
    print(json.dumps(response, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        log(traceback.format_exc())
        print(json.dumps({
            "ok": False, "type": "quant",
            "ts": now_str(),
            "error": "internal error",
        }, ensure_ascii=False))
        sys.exit(0)
