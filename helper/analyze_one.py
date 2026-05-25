#!/usr/bin/env python3
"""StockBar 单股 / 指数分析 — 输出一行 JSON 到 stdout。

运行环境：vnpy venv（与 quant.py 同，带 akshare + talib + pandas）。
用法：python analyze_one.py <code> [cost_price] [shares]
  - 给 cost_price>0 → 持仓分析（kind=holding）
  - 指数代码（见 INDEX_SET）→ 大盘研判（kind=index）
  - 否则 → 自选买点分析（kind=watch）

调试日志走 stderr；stdout 只输出最后一行 JSON。
"""
from __future__ import annotations

import json
import sys
from datetime import datetime

import quant  # 同目录，复用其分析函数

# 指数代码 → (名称, 新浪指数 symbol)。硬编码绕开 detect_type/get_prefix：
# get_prefix("000001") 会给 "sz"（→ sz000001 是个股价位），上证综指实际是 sh000001。
INDEX_SET = {
    "000001": ("上证", "sh000001"),
    "399001": ("深成", "sz399001"),
    "399006": ("创业板", "sz399006"),
    "000300": ("沪深300", "sh000300"),
}

_HOLD_ACTION = {"止盈卖出": "止盈", "止损卖出": "止损", "清仓": "清仓"}
_DIR_VERDICT = {1: "多", -1: "空", 0: "震荡"}
_DIR_REASON = {1: "多头排列 趋势向上", -1: "空头排列 趋势向下", 0: "均线纠缠 震荡整理"}


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def _emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _err(code: str, msg: str) -> dict:
    return {"ok": False, "type": "analyze", "ts": _now(), "code": code, "error": msg}


def _verdict_from_score(score: int) -> str:
    if score >= 75:
        return "买入"
    if score >= 60:
        return "观望"
    return "回避"


def _index_direction(df) -> int:
    """从指数 df 的均线排列判方向：1 多 / -1 空 / 0 震荡。"""
    close = float(df["close"].iloc[-1])
    ma5 = float(df["ma5"].iloc[-1])
    ma10 = float(df["ma10"].iloc[-1])
    ma20 = float(df["ma20"].iloc[-1])
    if close > ma5 > ma10 > ma20:
        return 1
    if close < ma5 < ma10 < ma20:
        return -1
    return 0


def _index_signals(df) -> list[str]:
    """指数研判信号：均线排列 + 量能，2 条。"""
    direction = _index_direction(df)
    vol_today = float(df["volume"].iloc[-1])
    vol_avg5 = float(df["volume"].iloc[-6:-1].mean())
    vol_ratio = vol_today / vol_avg5 if vol_avg5 > 0 else 1.0
    arr = ("均线多头排列（收盘 > MA5 > MA10 > MA20）" if direction == 1
           else "均线空头排列（收盘 < MA5 < MA10 < MA20）" if direction == -1
           else "均线纠缠，方向未明")
    vol = (f"放量（量比 {vol_ratio:.2f}）" if vol_ratio > 1.2
           else f"缩量（量比 {vol_ratio:.2f}）" if vol_ratio < 0.9
           else f"量能平稳（量比 {vol_ratio:.2f}）")
    return [arr, vol]


def analyze(code: str, cost_price: float | None, shares: int | None) -> dict:
    err = quant._import_analyze()
    if err:
        return _err(code, err)

    is_index = code in INDEX_SET

    # ---- 指数：大盘研判（用正确指数 symbol 直接抓，绕开 get_prefix 的 sz 误判）----
    if is_index:
        name, sym = INDEX_SET[code]
        try:
            import akshare as ak
            import pandas as pd
            df = ak.stock_zh_index_daily(symbol=sym)
            if df is None or len(df) < 25:
                return _err(code, "指数数据不足")
            # 与 analyze.py fetch_hist_data 一致：排序 + 截断 + 数值化（避免 talib 吃到字符串列 / 全历史）
            df["date"] = pd.to_datetime(df["date"])
            df = df.sort_values("date").tail(60).reset_index(drop=True)
            for col in ("open", "high", "low", "close", "volume"):
                if col in df.columns:
                    df[col] = pd.to_numeric(df[col], errors="coerce")
            df = quant.compute_indicators(df)
        except Exception as e:
            return _err(code, f"指数行情获取失败: {e}")
        direction = _index_direction(df)
        S, R = quant.support_resistance(df)
        return {
            "ok": True, "type": "analyze", "ts": _now(), "code": code,
            "kind": "index", "name": name,
            "verdict": _DIR_VERDICT[direction], "reason": _DIR_REASON[direction],
            "score": None,
            "levels": {"buy": None, "tp": None, "sl": None,
                       "support": round(S, 2), "resistance": round(R, 2)},
            "signals": _index_signals(df),
            "newsSentiment": None, "newsSignals": [],
            "pnlPct": None, "pnlAmount": None, "error": None,
        }

    # ---- 个股 / ETF：取数 + 评分 + 信号 + 价位 + 消息面 ----
    _, df, rt = quant.fetch_one(code)
    if df is None:
        return _err(code, "行情数据不足（不足 25 个交易日或接口失败）")
    name = str((rt or {}).get("name") or "")
    market_dir, _desc = quant.market_direction()
    dec = 3 if quant.is_etf(code) else 2
    S, R = quant.support_resistance(df)
    score, reason, detail = quant.short_term_score(df, rt, market_dir)
    signals = detail.get("signals", [])[:5]
    P = quant.current_price(df, rt)
    atr_frac = max(detail.get("indicators", {}).get("atr_pct", 2.0) / 100, 0.015)

    d6, news_sigs = quant.score_stock_news(code)
    sentiment = "bull" if d6 >= 8 else "bear" if d6 <= 5 else "neutral"

    if cost_price is not None and cost_price > 0:
        # 持仓：verdict 由 evaluate_holding 决定（None=持有），价位/盈亏自算
        ev = quant.evaluate_holding(code, name, int(shares or 0), cost_price, df, rt)
        verdict = "持有" if ev is None else _HOLD_ACTION.get(ev.get("action", ""), "持有")
        tp = quant.quantize_price(min(R, P * (1 + atr_frac)), code)
        sl = quant.quantize_price(max(S, P * (1 - atr_frac)), code)
        pnl_pct = (P - cost_price) / cost_price * 100
        pnl_amount = (P - cost_price) * (shares or 0)
        return {
            "ok": True, "type": "analyze", "ts": _now(), "code": code,
            "kind": "holding", "name": name,
            "verdict": verdict, "reason": reason, "score": score,
            "levels": {"buy": None, "tp": tp, "sl": sl,
                       "support": round(S, dec), "resistance": round(R, dec)},
            "signals": signals,
            "newsSentiment": sentiment, "newsSignals": news_sigs,
            "pnlPct": round(pnl_pct, 2), "pnlAmount": round(pnl_amount, 1),
            "error": None,
        }

    # 自选：score 映射 verdict，给建议买点
    return {
        "ok": True, "type": "analyze", "ts": _now(), "code": code,
        "kind": "watch", "name": name,
        "verdict": _verdict_from_score(score), "reason": reason, "score": score,
        "levels": {"buy": quant.quantize_price(S * 1.003, code), "tp": None, "sl": None,
                   "support": round(S, dec), "resistance": round(R, dec)},
        "signals": signals,
        "newsSentiment": sentiment, "newsSignals": news_sigs,
        "pnlPct": None, "pnlAmount": None, "error": None,
    }


def main() -> int:
    if len(sys.argv) < 2:
        _emit(_err("", "用法: analyze_one.py <code> [cost_price] [shares]"))
        return 1
    code = sys.argv[1].strip()
    cost_price = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
    shares = int(float(sys.argv[3])) if len(sys.argv) > 3 and sys.argv[3] else None
    try:
        _emit(analyze(code, cost_price, shares))
    except Exception as e:
        import traceback
        quant.log(traceback.format_exc())
        _emit(_err(code, f"分析异常: {e}"))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
