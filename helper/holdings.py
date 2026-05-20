"""解析 持仓.md。

支持的格式（容错）：

    股票持仓：
    - 159742 恒指科技：0.653（30000 元）            # 成本价 + 投入金额
    - 600519 贵州茅台 100股 @1700.50                 # 股数 + 成本价
    - 159742 恒指科技 50000份 0.653                  # 份额 + 成本价

    或：股票持仓：（空仓）

    剩余资金：760,716 元

    关注：
    - 159742 恒指科技
    - 159131 港股通信息技术ETF华宝

「已平仓 / 历史 / 备注」等段落自动跳过。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import List, Optional


CODE_RE = re.compile(r"\b(\d{6})\b")
NUMBER_RE = re.compile(r"-?\d+(?:,\d{3})*(?:\.\d+)?")

# 一行持仓的典型片段
SHARES_RE = re.compile(r"(\d+(?:\.\d+)?)\s*(?:股|份)")
COST_AT_RE = re.compile(r"[@＠]\s*(\d+(?:\.\d+)?)")
COST_COLON_RE = re.compile(r"[:：]\s*(\d+(?:\.\d+)?)")
AMOUNT_PAREN_RE = re.compile(r"[（(]\s*(\d+(?:,\d{3})*(?:\.\d+)?)\s*元\s*[)）]")


@dataclass
class Position:
    code: str
    name: str
    cost_price: Optional[float] = None      # 成本价（全部份额加权）
    shares: Optional[float] = None          # 总份额/股数（含今日批次）
    cost_amount: Optional[float] = None     # 投入金额 (元)
    cost_date: Optional[str] = None         # 整笔买入日期；当日买入则今日盈亏走 (price - cost_price)
    intraday_shares: Optional[float] = None # 今日新买入的股数（应 <= shares）
    intraday_cost: Optional[float] = None   # 今日新买入的成本价；剩余部分按 (price - 昨收) 算今日盈亏


@dataclass
class Holdings:
    positions: List[Position] = field(default_factory=list)
    cash: Optional[float] = None
    watchlist: List[Position] = field(default_factory=list)  # 只用 code/name 字段


def _to_float(s: str) -> float:
    return float(s.replace(",", ""))


def _parse_position_line(line: str) -> Optional[Position]:
    """解析一行形如 `- 159742 恒指科技：0.653（30000 元）` 的持仓/关注行。"""
    line = line.strip().lstrip("-•*").strip()
    if not line:
        return None

    m = CODE_RE.search(line)
    if not m:
        return None
    code = m.group(1)

    # 名称：代码后到第一个分隔符 (：:@＠ 数字 空白+数字) 之间
    rest = line[m.end():].strip()
    # 名称取直到遇到 ： : @ ＠ 数字 或 行尾
    name_match = re.match(r"\s*([^\s:：@＠]+(?:\s+[^\s:：@＠\d][^\s:：@＠]*)*)", rest)
    name = name_match.group(1).strip() if name_match else ""

    pos = Position(code=code, name=name)

    # cost_price: ：0.653 / @0.653
    if m_at := COST_AT_RE.search(line):
        pos.cost_price = _to_float(m_at.group(1))
    elif m_colon := COST_COLON_RE.search(rest):
        # 第一个 :/： 后的数字 = 成本价 (排除掉"剩余资金:"那种)
        pos.cost_price = _to_float(m_colon.group(1))

    # shares: NN股 / NN份
    if m_sh := SHARES_RE.search(line):
        pos.shares = _to_float(m_sh.group(1))

    # cost_price fallback: 「100股 42.50」格式 —— 数字+股/份 后紧跟另一个数字 = 成本价
    if pos.cost_price is None and pos.shares is not None:
        if m_after := re.search(r"\d+(?:\.\d+)?\s*(?:股|份)\s+(\d+(?:\.\d+)?)", line):
            pos.cost_price = _to_float(m_after.group(1))

    # cost_amount: （30000 元）
    if m_amt := AMOUNT_PAREN_RE.search(line):
        pos.cost_amount = _to_float(m_amt.group(1))

    return pos


def parse(text: str) -> Holdings:
    """从 持仓.md 文本解析。"""
    h = Holdings()
    section: Optional[str] = None  # 'positions' | 'cash' | 'watchlist' | 'skip' | None

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped:
            continue

        # ---- 段落标题识别 ----
        title_match = re.match(r"^([^：:#\-•*]+)[：:]\s*(.*)$", stripped)
        is_section_header = (
            title_match and not stripped.startswith(("-", "•", "*"))
        )
        if is_section_header:
            title = title_match.group(1).strip()
            tail = title_match.group(2).strip()

            if "持仓" in title and "已平仓" not in title and "历史" not in title:
                section = "positions"
                # 标题同行可能含「空仓」
                if "空仓" in tail or tail.startswith("("):
                    section = "skip-positions"
                continue
            if "剩余资金" in title or "现金" in title:
                # 标题行本身带数字
                if m := NUMBER_RE.search(tail):
                    h.cash = _to_float(m.group())
                section = "cash"
                continue
            if "关注" in title or "自选" in title or "观察" in title:
                section = "watchlist"
                continue
            if "已平仓" in title or "历史" in title or "备注" in title or "已清仓" in title:
                section = "skip"
                continue
            # 未识别的标题：进入 skip
            section = "skip"
            continue

        # ---- 段落内行 ----
        if section == "positions":
            if "空仓" in stripped:
                continue
            if pos := _parse_position_line(stripped):
                h.positions.append(pos)
        elif section == "watchlist":
            if pos := _parse_position_line(stripped):
                # 关注列表只保留 code/name
                h.watchlist.append(Position(code=pos.code, name=pos.name))
        elif section == "cash" and h.cash is None:
            if m := NUMBER_RE.search(stripped):
                h.cash = _to_float(m.group())
        # skip / skip-positions / None: 忽略

    return h


def load(path: Path) -> Holdings:
    return parse(path.read_text(encoding="utf-8"))


def to_dict(h: Holdings) -> dict:
    return {
        "positions": [asdict(p) for p in h.positions],
        "cash": h.cash,
        "watchlist": [{"code": p.code, "name": p.name} for p in h.watchlist],
    }


# --------------------------------------------------------------------
# JSON portfolio (App 内管理的新数据源 — 后续优先用它)
# --------------------------------------------------------------------

import json


def load_json(path: Path) -> Holdings:
    """读取 App 维护的 portfolio.json:
    {"cash": float, "positions": [{code, name?, shares, cost_price}], "watchlist": [{code, name?}]}
    """
    if not path.exists():
        return Holdings()
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return Holdings()

    h = Holdings()
    h.cash = data.get("cash")
    for raw in data.get("positions", []) or []:
        code = str(raw.get("code", "")).strip()
        if not code:
            continue
        # 字段名兼容 camelCase（App 端 Swift Codable 默认写出的格式）和 snake_case
        h.positions.append(Position(
            code=code,
            name=str(raw.get("name", "")),
            cost_price=_safe_float(raw.get("costPrice") if raw.get("costPrice") is not None else raw.get("cost_price")),
            shares=_safe_float(raw.get("shares")),
            cost_amount=_safe_float(raw.get("costAmount") if raw.get("costAmount") is not None else raw.get("cost_amount")),
            cost_date=(raw.get("costDate") or raw.get("cost_date") or None),
            intraday_shares=_safe_float(raw.get("intradayShares") if raw.get("intradayShares") is not None else raw.get("intraday_shares")),
            intraday_cost=_safe_float(raw.get("intradayCost") if raw.get("intradayCost") is not None else raw.get("intraday_cost")),
        ))
    for raw in data.get("watchlist", []) or []:
        code = str(raw.get("code", "")).strip()
        if not code:
            continue
        h.watchlist.append(Position(code=code, name=str(raw.get("name", ""))))
    return h


def _safe_float(v):
    try:
        return float(v) if v is not None else None
    except (TypeError, ValueError):
        return None


if __name__ == "__main__":
    import sys

    target = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("持仓.md")
    if target.suffix == ".json":
        print(json.dumps(to_dict(load_json(target)), ensure_ascii=False, indent=2))
    else:
        print(json.dumps(to_dict(load(target)), ensure_ascii=False, indent=2))
