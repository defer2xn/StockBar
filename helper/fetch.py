"""StockBar Python helper.

Stdin / stdout 协议：

    refresh           → {"ok":true,"type":"snapshot",...}
    news <code>       → {"ok":true,"type":"news","code":"<code>","items":[...]}
    chart <code>      → {"ok":true,"type":"chart","code":"<code>","ticks":[...]}
    article <url>     → {"ok":true,"type":"article","url":"...","title":"...","paragraphs":[...],...}
    quant             → {"ok":true,"type":"quant","session":...,"market":...,"orders":[...]}
    quit              → 退出

错误：{"ok":false,"type":"...","ts":"...","error":"..."}

数据源：
  - 行情：新浪 hq.sinajs.cn（批量、~80ms）
  - 新闻：东方财富 search-api-web（关键词 = 股票代码）
  - 分时：腾讯 web.ifzq.gtimg.cn（一天 ~242 个 minute tick）
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import requests

import holdings as holdings_mod
import article as article_mod


# ----------------- 日志 / IO -----------------

def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


# 与 quant worker 共用同一把锁，避免主线程 respond 与 worker emit 交叉
import threading as _threading_for_stdout
_stdout_lock = _threading_for_stdout.Lock()


def respond(payload: dict) -> None:
    line = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    with _stdout_lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ----------------- 新浪行情 -----------------

SINA_URL = "https://hq.sinajs.cn/list={}"
SINA_HEADERS = {
    # 新浪要求 referer，否则返回 403
    "Referer": "https://finance.sina.com.cn/",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605 Safari/605",
}
SINA_LINE_RE = re.compile(r'var hq_str_([a-z0-9]+)="([^"]*)"\s*;')


def sina_symbol(code: str) -> str:
    """6 位代码 → 新浪带前缀的 symbol。指数返回 sh000001 这种。
    如果输入已经带 sh/sz/bj 前缀，原样返回。
    """
    if code[:2].lower() in ("sh", "sz", "bj"):
        return code.lower()
    if code.startswith(("60", "68", "51", "5", "11", "13")):
        return "sh" + code
    if code.startswith(("00", "30", "20", "159", "12", "15")):
        return "sz" + code
    if code.startswith(("8", "4")):
        return "bj" + code
    return "sh" + code


def fetch_sina(symbols: List[str]) -> Dict[str, List[str]]:
    """批量请求新浪行情，返回 {symbol: 字段列表}。"""
    if not symbols:
        return {}

    out: Dict[str, List[str]] = {}
    # 每批 80 个，避免 URL 过长
    BATCH = 80
    for i in range(0, len(symbols), BATCH):
        batch = symbols[i:i + BATCH]
        url = SINA_URL.format(",".join(batch))
        try:
            resp = requests.get(url, headers=SINA_HEADERS, timeout=5)
            resp.encoding = "gbk"
            for m in SINA_LINE_RE.finditer(resp.text):
                symbol = m.group(1)
                fields = m.group(2).split(",")
                out[symbol] = fields
        except Exception as e:
            log(f"sina fetch failed for batch {i}: {e}")
    return out


def parse_stock_fields(fields: List[str]) -> dict:
    """新浪股票/ETF 字段表（共 32 字段）。
    [0]名称 [1]今开 [2]昨收 [3]当前价 [4]最高 [5]最低 ... [30]日期 [31]时间
    停牌时 1-6 全为 0，要按此判断。
    """
    if len(fields) < 4:
        return {"name": "", "price": None, "prev_close": None, "change_pct": None}
    name = fields[0]
    try:
        prev_close = float(fields[2])
        price = float(fields[3])
    except (ValueError, IndexError):
        return {"name": name, "price": None, "prev_close": None, "change_pct": None}
    if price == 0:
        price = prev_close  # 停牌时取昨收
        change_pct = 0.0
    else:
        change_pct = (price - prev_close) / prev_close * 100 if prev_close else 0.0
    return {"name": name, "price": price, "prev_close": prev_close, "change_pct": change_pct}


# 注意：新浪指数（不带 s_ 前缀）返回的字段布局与股票相同（[1]今开 [2]昨收 [3]当前价），
# 所以指数也复用 parse_stock_fields。


# ----------------- 大盘指数 -----------------

INDEX_DEFS: List[Tuple[str, str]] = [
    # (display_name, sina_symbol)
    ("上证", "sh000001"),
    ("深证", "sz399001"),
    ("创业板", "sz399006"),
    ("沪深300", "sh000300"),
]


# ----------------- 新闻 / 公告：东方财富 search-api -----------------

EM_NEWS_URL = "https://search-api-web.eastmoney.com/search/jsonp"
EM_HEADERS = {
    "Referer": "https://www.eastmoney.com/",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) AppleWebKit/605 Safari/605",
}


def fetch_news(code: str, page_size: int = 30) -> List[dict]:
    """拉某只股票的最新新闻（按时间倒序）。"""
    payload = (
        '{"uid":"","keyword":"%s","type":["cmsArticleWebOld"],'
        '"client":"web","clientVersion":"curr","clientType":"web",'
        '"param":{"cmsArticleWebOld":{"searchScope":"default","sort":"time",'
        '"pageIndex":1,"pageSize":%d,"preTag":"","postTag":""}}}'
    ) % (code, page_size)
    try:
        r = requests.get(
            EM_NEWS_URL,
            params={"cb": "jq", "param": payload, "_": "1"},
            headers=EM_HEADERS,
            timeout=8,
        )
        body = r.text[r.text.index("(") + 1: r.text.rindex(")")]
        data = json.loads(body)
        items = data.get("result", {}).get("cmsArticleWebOld", []) or []
    except Exception as e:
        log(f"news fetch failed {code}: {e}")
        return []

    out = []
    for it in items:
        out.append({
            "title": _strip_html(it.get("title", "")),
            "url": it.get("url", ""),
            "date": it.get("date", ""),
            "source": it.get("mediaName") or it.get("source") or "",
            "summary": _strip_html(it.get("content", "")),
        })
    return out


_TAG_RE = re.compile(r"<[^>]+>")


def _strip_html(s: str) -> str:
    return _TAG_RE.sub("", s or "").strip()


# ----------------- 分时图：腾讯 minute API -----------------

QQ_MINUTE_URL = "https://web.ifzq.gtimg.cn/appstock/app/minute/query"
QQ_HEADERS = {"Referer": "https://gu.qq.com/", "User-Agent": "Mozilla/5.0"}


def fetch_chart(code: str) -> dict:
    """返回今日分时数据：
    {"ticks": [{"time":"0930","price":4120.14,"volume":7018698}, ...],
     "prev_close": float, "name": str}
    """
    symbol = sina_symbol(code)
    ticks: List[dict] = []
    name = ""
    try:
        r = requests.get(QQ_MINUTE_URL, params={"code": symbol}, headers=QQ_HEADERS, timeout=5)
        data = r.json()
        node = data.get("data", {}).get(symbol, {}).get("data", {})
        for line in node.get("data", []) or []:
            parts = line.split()
            if len(parts) < 3:
                continue
            try:
                ticks.append({
                    "time": parts[0],
                    "price": float(parts[1]),
                    "volume": int(float(parts[2])),
                })
            except (ValueError, IndexError):
                continue
    except Exception as e:
        log(f"chart fetch failed {code}: {e}")

    # 顺手从新浪拉一次 prev_close + name
    prev_close: Optional[float] = None
    sina_raw = fetch_sina([symbol])
    fields = sina_raw.get(symbol)
    if fields:
        parsed = parse_stock_fields(fields)
        prev_close = parsed.get("prev_close")
        name = parsed.get("name", "")

    return {"ticks": ticks, "prev_close": prev_close, "name": name}


# ----------------- 主流程 -----------------

def build_snapshot(holdings_path: Path) -> dict:
    """holdings_path 现在指 portfolio.json（App 维护的）。
    如果是 .md 后缀，则按旧的 Markdown 解析器读，作向后兼容。
    """
    ts = _now()
    try:
        if holdings_path.suffix == ".json":
            h = holdings_mod.load_json(holdings_path)
        else:
            h = holdings_mod.load(holdings_path)
    except FileNotFoundError:
        # 文件不存在 → 当作空仓，不报错（App 首次启动可能还没创建）
        h = holdings_mod.Holdings()
    except Exception as e:
        return {"ok": False, "ts": ts, "error": f"持仓解析失败: {e}"}

    # 合并所有要查询的 symbol
    stock_codes = [p.code for p in h.positions] + [p.code for p in h.watchlist]
    stock_symbols = [sina_symbol(c) for c in stock_codes]
    index_symbols = [s for _, s in INDEX_DEFS]
    all_symbols = list(dict.fromkeys(stock_symbols + index_symbols))  # 去重保序

    raw = fetch_sina(all_symbols)

    # 解析股票/ETF
    quotes: Dict[str, dict] = {}
    for code in stock_codes:
        sym = sina_symbol(code)
        fields = raw.get(sym)
        if fields:
            quotes[code] = parse_stock_fields(fields)
        else:
            quotes[code] = {"name": "", "price": None, "prev_close": None, "change_pct": None}

    # 拼装持仓
    positions_out = []
    total_market_value = 0.0
    total_pnl_today = 0.0
    total_cost = 0.0

    for p in h.positions:
        q = quotes.get(p.code, {})
        price = q.get("price")
        prev = q.get("prev_close")
        shares = p.shares
        if shares is None and p.cost_amount and p.cost_price:
            shares = p.cost_amount / p.cost_price

        market_value = price * shares if price and shares else None
        pnl_today = (price - prev) * shares if price is not None and prev is not None and shares else None
        pnl_total = (price - p.cost_price) * shares if price is not None and p.cost_price and shares else None
        cost_value = p.cost_price * shares if p.cost_price and shares else p.cost_amount

        if market_value is not None:
            total_market_value += market_value
        if pnl_today is not None:
            total_pnl_today += pnl_today
        if cost_value is not None:
            total_cost += cost_value

        positions_out.append({
            "code": p.code,
            "name": p.name or q.get("name", ""),
            "shares": shares,
            "cost_price": p.cost_price,
            "price": price,
            "change_pct": q.get("change_pct"),
            "market_value": market_value,
            "pnl_today": pnl_today,
            "pnl_total": pnl_total,
        })

    # 拼装自选
    watchlist_out = []
    for p in h.watchlist:
        q = quotes.get(p.code, {})
        watchlist_out.append({
            "code": p.code,
            "name": p.name or q.get("name", ""),
            "price": q.get("price"),
            "change_pct": q.get("change_pct"),
        })

    # 拼装指数
    indices_out = []
    for name, sym in INDEX_DEFS:
        fields = raw.get(sym)
        if fields:
            parsed = parse_stock_fields(fields)
            indices_out.append({
                "name": name,
                "code": sym,
                "price": parsed["price"],
                "change_pct": parsed["change_pct"],
            })

    total_pnl_today_pct = None
    base = total_market_value - total_pnl_today
    if base > 0:
        total_pnl_today_pct = total_pnl_today / base * 100

    return {
        "ok": True,
        "type": "snapshot",
        "ts": ts,
        "holdings": {
            "positions": positions_out,
            "cash": h.cash,
            "total_market_value": total_market_value if h.positions else 0.0,
            "total_pnl_today": total_pnl_today if h.positions else 0.0,
            "total_pnl_today_pct": total_pnl_today_pct,
            "total_cost": total_cost if h.positions else 0.0,
        },
        "watchlist": watchlist_out,
        "indices": indices_out,
    }


# ----------------- 量化引擎子进程包装（异步）-----------------
# quant.py 跑在 vnpy 的 venv（akshare/talib），通过 subprocess 调
# 关键：subprocess 在后台线程跑，避免阻塞 fetch.py 主 stdin/stdout 循环
import subprocess
import threading

from runtime import find_vnpy_python, health_check

QUANT_SCRIPT = str(Path(__file__).parent / "quant.py")

_quant_in_flight = False


def _emit(payload: dict) -> None:
    """线程安全地把一行 JSON 写到 stdout（与 respond 共用 _stdout_lock）。"""
    respond(payload)


def _quant_worker() -> None:
    """后台线程：跑 quant.py 并 emit 结果。"""
    global _quant_in_flight
    try:
        vnpy_python = find_vnpy_python()
        if vnpy_python is None:
            _emit({"ok": False, "type": "quant", "ts": _now(),
                   "error": "未找到 vnpy 项目。设置 STOCKBAR_VNPY_PATH 或在 config.json 配置 vnpy_path"})
            return
        if not Path(QUANT_SCRIPT).exists():
            _emit({"ok": False, "type": "quant", "ts": _now(),
                   "error": f"quant.py 不存在: {QUANT_SCRIPT}"})
            return
        try:
            result = subprocess.run(
                [str(vnpy_python), QUANT_SCRIPT],
                capture_output=True, text=True, timeout=180,
            )
        except subprocess.TimeoutExpired:
            _emit({"ok": False, "type": "quant", "ts": _now(), "error": "量化引擎超时 (>180s)"})
            return
        except Exception as e:
            _emit({"ok": False, "type": "quant", "ts": _now(), "error": f"调用失败: {e}"})
            return

        if result.returncode != 0:
            _emit({"ok": False, "type": "quant", "ts": _now(),
                   "error": f"量化引擎退出码 {result.returncode}: {result.stderr[-300:]}"})
            return
        out = result.stdout.strip().split("\n")[-1] if result.stdout else ""
        try:
            payload = json.loads(out)
        except Exception as e:
            _emit({"ok": False, "type": "quant", "ts": _now(),
                   "error": f"解析量化结果失败: {e}; raw={out[:200]}"})
            return
        _emit(payload)
    finally:
        _quant_in_flight = False


def _run_quant() -> dict:
    """启动 quant 后台线程，立即返回 pending 状态。
    真正结果由 _quant_worker 通过 _emit 写到 stdout。
    """
    global _quant_in_flight
    if _quant_in_flight:
        return {"ok": False, "type": "quant_pending", "ts": _now(),
                "error": "上一次量化扫描还在跑，请等它完成"}
    _quant_in_flight = True
    threading.Thread(target=_quant_worker, daemon=True).start()
    return {"ok": True, "type": "quant_pending", "ts": _now()}


def main() -> int:
    # 优先用 STOCKBAR_PORTFOLIO (JSON) ；老变量 STOCKBAR_HOLDINGS 作向后兼容
    portfolio_env = os.environ.get("STOCKBAR_PORTFOLIO")
    legacy_env = os.environ.get("STOCKBAR_HOLDINGS")
    if portfolio_env:
        holdings_path = Path(portfolio_env)
    elif legacy_env:
        holdings_path = Path(legacy_env)
    else:
        holdings_path = Path.home() / "Library/Application Support/StockBar/portfolio.json"
    log(f"holdings: {holdings_path}")
    log("ready")

    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        parts = line.split()
        cmd = parts[0].lower()
        args = parts[1:]

        if cmd in ("quit", "exit"):
            log("bye")
            return 0

        t0 = time.time()
        try:
            if cmd == "refresh":
                resp = build_snapshot(holdings_path)
            elif cmd == "news":
                if not args:
                    resp = {"ok": False, "type": "news", "ts": _now(), "error": "missing code"}
                else:
                    items = fetch_news(args[0])
                    resp = {"ok": True, "type": "news", "ts": _now(),
                            "code": args[0], "items": items}
            elif cmd == "chart":
                if not args:
                    resp = {"ok": False, "type": "chart", "ts": _now(), "error": "missing code"}
                else:
                    data = fetch_chart(args[0])
                    resp = {"ok": True, "type": "chart", "ts": _now(),
                            "code": args[0], **data}
            elif cmd == "article":
                if not args:
                    resp = {"ok": False, "type": "article", "ts": _now(), "error": "missing url"}
                else:
                    # URL 里可能带空格，把后面 join 回来
                    art_url = " ".join(args)
                    data = article_mod.fetch(art_url)
                    resp = {"type": "article", "ts": _now(), **data}
            elif cmd == "quant":
                resp = _run_quant()
            elif cmd == "health":
                hc = health_check()
                resp = {"ok": hc["ok"], "type": "health", "ts": _now(), **hc}
            else:
                resp = {"ok": False, "type": "unknown", "ts": _now(),
                        "error": f"unknown command: {cmd}"}
        except Exception:
            log(traceback.format_exc())
            resp = {"ok": False, "type": cmd, "ts": _now(), "error": "internal error"}

        log(f"{cmd} done in {time.time() - t0:.2f}s")
        respond(resp)

    return 0


if __name__ == "__main__":
    sys.exit(main())
