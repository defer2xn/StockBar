"""StockBar Python helper.

Stdin / stdout 协议：

    refresh           → {"ok":true,"type":"snapshot",...}
    news <code> <name>→ {"ok":true,"type":"news","code":"<code>","items":[...]}  # 按名称搜+相关度排序+利好利空
    chart <code>      → {"ok":true,"type":"chart","code":"<code>","ticks":[...]}
    analyze <code> [cost] [shares] → {"ok":true,"type":"analyze",...}  # 单股/指数研判，3 分钟缓存
    article <url>     → {"ok":true,"type":"article","url":"...","title":"...","paragraphs":[...],...}
    sectors           → {"ok":true,"type":"sectors","sectors":[...]}  # 新浪行业板块榜
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


# 新闻情绪关键词（从 quant.py _NEWS_BULL/_NEWS_BEAR 复制；纯字符串，helper venv 内即可用）
_NEWS_BULL = (
    "中标", "订单", "增持", "回购", "预增", "扭亏", "涨价", "提价", "签约", "合作",
    "获批", "量产", "收购", "重组", "利好", "创新高", "超预期", "分红", "入选", "注入",
    "突破", "签订", "投产", "提速", "放量",
)
_NEWS_BEAR = (
    "减持", "亏损", "预减", "商誉", "立案", "调查", "问询", "处罚", "诉讼", "违规",
    "质押", "平仓", "解禁", "退市", "终止", "失败", "风险提示", "变脸", "下滑", "警示",
)


def _news_sentiment(text: str) -> str:
    """标题+摘要关键词净值 → bull / bear / neutral。"""
    bull = sum(text.count(k) for k in _NEWS_BULL)
    bear = sum(text.count(k) for k in _NEWS_BEAR)
    if bull > bear:
        return "bull"
    if bear > bull:
        return "bear"
    return "neutral"


def _em_search(keyword: str, page_size: int) -> List[dict]:
    """东方财富 CMS 关键词搜索，返回原始 item 列表（失败返回 []）。"""
    # 用 json.dumps 转义 keyword，避免名称含引号/反斜杠时拼出非法 JSON
    payload = json.dumps({
        "uid": "", "keyword": keyword, "type": ["cmsArticleWebOld"],
        "client": "web", "clientVersion": "curr", "clientType": "web",
        "param": {"cmsArticleWebOld": {
            "searchScope": "default", "sort": "time",
            "pageIndex": 1, "pageSize": page_size, "preTag": "", "postTag": "",
        }},
    }, ensure_ascii=False)
    try:
        r = requests.get(
            EM_NEWS_URL,
            params={"cb": "jq", "param": payload, "_": "1"},
            headers=EM_HEADERS,
            timeout=8,
        )
        body = r.text[r.text.index("(") + 1: r.text.rindex(")")]
        return json.loads(body).get("result", {}).get("cmsArticleWebOld", []) or []
    except Exception as e:
        log(f"news search failed {keyword}: {e}")
        return []


def fetch_news(code: str, name: str = "", page_size: int = 30) -> List[dict]:
    """拉某只股票的相关新闻：优先按名称搜（关联度高），不足补代码搜，
    按 URL 去重（去掉 query 参数）、相关度+时间排序，并打利好/利空标签。
    """
    raw = _em_search(name, page_size) if name else []
    if len(raw) < 5:   # 名称命中太少时补一轮代码搜
        raw += _em_search(code, page_size)

    seen = set()
    out = []
    for it in raw:
        url = it.get("url", "")
        key = url.split("?", 1)[0]   # 去掉 from/_ 等 query 参数后去重
        if not key or key in seen:
            continue
        seen.add(key)
        title = _strip_html(it.get("title", ""))
        summary = _strip_html(it.get("content", ""))
        # 相关度：标题含名称 > 含代码 > 其他（泛市场文下沉）
        relevance = 2 if (name and name in title) else 1 if code in title else 0
        out.append({
            "title": title,
            "url": url,
            "date": it.get("date", ""),
            "source": it.get("mediaName") or it.get("source") or "",
            "summary": summary,
            "sentiment": _news_sentiment(title + " " + summary),
            "relevance": relevance,
        })
    out.sort(key=lambda x: (x["relevance"], x["date"]), reverse=True)
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

# ----------------- 新浪行业板块 -----------------

SINA_SECTOR_URL = "http://vip.stock.finance.sina.com.cn/q/view/newSinaHy.php"
# 返回 JSON：{"key":"label,板块,公司家数,平均价格,涨跌额,涨跌幅,总成交量,总成交额,股票代码,个股-涨跌幅,个股-当前价,个股-涨跌额,股票名称", ...}
_SECTOR_FIELDS = 13


def _to_float(s: str) -> Optional[float]:
    """安全转 float，失败返回 None。"""
    try:
        return float(s)
    except (TypeError, ValueError):
        return None


def fetch_sectors() -> List[dict]:
    """新浪行业板块实时榜：返回按涨跌幅降序的板块列表。
    与 akshare stock_sector_spot(新浪行业) 同源，单次 HTTP（~100ms），不依赖 akshare。
    """
    resp = requests.get(SINA_SECTOR_URL, headers=SINA_HEADERS, timeout=8)
    resp.encoding = "gbk"
    text = resp.text
    start = text.find("{")
    if start < 0:
        return []
    data = json.loads(text[start:])
    out: List[dict] = []
    for raw in data.values():
        parts = str(raw).split(",")
        if len(parts) < _SECTOR_FIELDS:
            continue
        leader_code = parts[8].strip()
        out.append({
            "label": parts[0].strip(),
            "name": parts[1].strip(),
            "count": int(_to_float(parts[2]) or 0),
            "avgPrice": _to_float(parts[3]),
            "changePct": _to_float(parts[5]),
            "volume": _to_float(parts[6]),
            "turnover": _to_float(parts[7]),
            "leaderCode": leader_code[-6:] if leader_code else None,
            "leaderChangePct": _to_float(parts[9]),
            "leaderPrice": _to_float(parts[10]),
            "leaderName": parts[12].strip(),
        })
    # 涨跌幅降序；缺失值排末尾
    out.sort(key=lambda s: (s["changePct"] is None, -(s["changePct"] or 0)))
    return out


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
    today_str = datetime.now().strftime("%Y-%m-%d")

    for p in h.positions:
        q = quotes.get(p.code, {})
        price = q.get("price")
        prev = q.get("prev_close")
        shares = p.shares
        if shares is None and p.cost_amount and p.cost_price:
            shares = p.cost_amount / p.cost_price

        market_value = price * shares if price and shares else None
        # 今日盈亏跟券商「当日参考盈亏」对齐，三种情况：
        #   1) 设了 intraday_shares + intraday_cost：拆批次算
        #        today_pnl = intraday_shares * (price - intraday_cost)
        #                  + (shares - intraday_shares) * (price - prev_close)
        #   2) 设了 cost_date == 今天：全部按当日买入算，(price - cost_price) * shares
        #   3) 其它（隔夜持仓）：(price - prev_close) * shares
        if price is None or not shares:
            pnl_today = None
        elif p.intraday_shares is not None and p.intraday_cost is not None and prev is not None:
            intra = p.intraday_shares
            overnight = shares - intra
            pnl_today = intra * (price - p.intraday_cost) + overnight * (price - prev)
        elif p.cost_date and p.cost_date == today_str and p.cost_price:
            pnl_today = (price - p.cost_price) * shares
        elif prev is not None:
            pnl_today = (price - prev) * shares
        else:
            pnl_today = None
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
ANALYZE_SCRIPT = str(Path(__file__).parent / "analyze_one.py")

_quant_in_flight = False

# 单股分析 3 分钟内存缓存：key = "code cost shares"（成本价/股数变化即失效，避免命中旧研判）
_ANALYZE_CACHE: Dict[str, Tuple[float, dict]] = {}
_ANALYZE_TTL = 180.0


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


def _analyze_worker(args: List[str], cache_key: str) -> None:
    """后台线程：跑 analyze_one.py，结果写入缓存并 emit。"""
    code = args[0]
    try:
        vnpy_python = find_vnpy_python()
        if vnpy_python is None:
            _emit({"ok": False, "type": "analyze", "ts": _now(), "code": code,
                   "error": "未找到 vnpy 项目。设置 STOCKBAR_VNPY_PATH 或在 config.json 配置 vnpy_path"})
            return
        try:
            result = subprocess.run(
                [str(vnpy_python), ANALYZE_SCRIPT, *args],
                capture_output=True, text=True, timeout=30,
            )
        except subprocess.TimeoutExpired:
            _emit({"ok": False, "type": "analyze", "ts": _now(), "code": code, "error": "分析超时 (>30s)"})
            return
        if result.returncode != 0 and not result.stdout.strip():
            _emit({"ok": False, "type": "analyze", "ts": _now(), "code": code,
                   "error": f"分析引擎退出码 {result.returncode}: {result.stderr[-200:]}"})
            return
        out = result.stdout.strip().split("\n")[-1] if result.stdout else ""
        try:
            payload = json.loads(out)
        except Exception as e:
            _emit({"ok": False, "type": "analyze", "ts": _now(), "code": code,
                   "error": f"解析分析结果失败: {e}; raw={out[:200]}"})
            return
        if payload.get("ok"):
            _ANALYZE_CACHE[cache_key] = (time.time(), payload)
        _emit(payload)
    except Exception as e:
        _emit({"ok": False, "type": "analyze", "ts": _now(), "code": code, "error": f"分析调用失败: {e}"})


def _run_analyze(args: List[str]) -> dict:
    """单股分析：命中 3 分钟缓存则直接返回；否则后台跑 analyze_one.py。
    缓存 key 含 cost/shares —— 改了成本价/股数会重新分析，不命中旧结果。"""
    code = args[0]
    cache_key = " ".join(args)
    hit = _ANALYZE_CACHE.get(cache_key)
    if hit and time.time() - hit[0] < _ANALYZE_TTL:
        return hit[1]
    threading.Thread(target=_analyze_worker, args=(args, cache_key), daemon=True).start()
    return {"ok": True, "type": "analyze_pending", "ts": _now(), "code": code}


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
                    # news <code> <name...>：name 取剩余 join，兼容含空格的罕见名
                    name = " ".join(args[1:]).strip()
                    items = fetch_news(args[0], name)
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
            elif cmd == "sectors":
                resp = {"ok": True, "type": "sectors", "ts": _now(),
                        "sectors": fetch_sectors()}
            elif cmd == "analyze":
                if not args:
                    resp = {"ok": False, "type": "analyze", "ts": _now(), "error": "missing code"}
                else:
                    resp = _run_analyze(args)
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
