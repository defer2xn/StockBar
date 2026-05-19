"""新闻正文抓取与清洗。

输入：文章 URL（目前主要支持东方财富 finance.eastmoney.com / stock.eastmoney.com 等）
输出：dict {title, summary, date, source, author, paragraphs[], images[], url}

提取策略：
  1. 东财专用 selector（精准）
  2. 通用 fallback：og:meta + 找最大文本块
"""
from __future__ import annotations

import re
from typing import List, Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup, Tag


HEADERS = {
    "Referer": "https://www.eastmoney.com/",
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) "
                  "AppleWebKit/605.1.15 Safari/605",
    "Accept-Language": "zh-CN,zh;q=0.9",
}


def fetch(url: str) -> dict:
    try:
        r = requests.get(url, headers=HEADERS, timeout=10)
        r.encoding = r.apparent_encoding or "utf-8"
    except Exception as e:
        return _err(url, f"请求失败: {e}")

    if r.status_code != 200:
        return _err(url, f"HTTP {r.status_code}")

    soup = BeautifulSoup(r.text, "lxml")

    # 路由：东财用专用提取器，其它走通用
    if "eastmoney.com" in url:
        return _extract_eastmoney(url, soup)
    return _extract_generic(url, soup)


# -------------------- 东方财富 --------------------

def _extract_eastmoney(url: str, soup: BeautifulSoup) -> dict:
    # Title
    raw_title = (soup.title.get_text(strip=True) if soup.title else "")
    title = re.sub(r"\s*[_|·\-]\s*(东方财富网|东方财富).*$", "", raw_title).strip()

    # Summary（用 meta description 当摘要）
    summary = _meta(soup, "description", "og:description") or ""

    # Date / source / author
    date, source, author = _parse_infos(soup.select_one(".infos"))

    # 正文
    paragraphs: List[str] = []
    body = soup.select_one("#ContentBody") or soup.select_one(".ContentBody")
    images: List[str] = []
    if body:
        paragraphs = _clean_paragraphs(body)
        images = _collect_images(body, url)

    # 兜底
    if not paragraphs:
        paragraphs = [summary] if summary else ["（未提取到正文，可点右上角在浏览器打开查看）"]

    return {
        "ok": True,
        "url": url,
        "title": title,
        "summary": summary,
        "date": date,
        "source": source,
        "author": author,
        "paragraphs": paragraphs,
        "images": images,
    }


def _parse_infos(infos: Optional[Tag]) -> tuple[str, str, str]:
    """解析 .infos 文本里的「日期 / 作者 / 来源」。
    示例: "2026年05月18日 16:56 作者：数据宝 来源：证券时报网"
    """
    if not infos:
        return "", "", ""
    text = infos.get_text(" ", strip=True)
    # 日期：第一段日期+时间
    date_m = re.search(r"(\d{4}[-年]\d{1,2}[-月]\d{1,2}\D?\s*\d{1,2}:\d{2}(?::\d{2})?)", text)
    date = (date_m.group(1) if date_m else "").replace("年", "-").replace("月", "-").replace("日", "")
    # 作者
    author_m = re.search(r"作者[：:]\s*([^\s来]+)", text)
    author = (author_m.group(1).strip() if author_m else "")
    # 来源
    source_m = re.search(r"来源[：:]\s*(\S+)", text)
    source = (source_m.group(1).strip() if source_m else "")
    return date, source, author


# -------------------- 通用 fallback --------------------

def _extract_generic(url: str, soup: BeautifulSoup) -> dict:
    title = (_meta(soup, "og:title")
             or (soup.title.get_text(strip=True) if soup.title else "")
             or "")
    summary = _meta(soup, "description", "og:description") or ""

    # 找正文：常见容器 + 找出文本量最大的 <article>/<div>
    body = (soup.select_one("article")
            or _largest_text_block(soup))
    paragraphs = _clean_paragraphs(body) if body else []
    images = _collect_images(body, url) if body else []
    if not paragraphs and summary:
        paragraphs = [summary]
    return {
        "ok": True,
        "url": url,
        "title": title,
        "summary": summary,
        "date": "",
        "source": "",
        "author": "",
        "paragraphs": paragraphs or ["（未提取到正文）"],
        "images": images,
    }


def _largest_text_block(soup: BeautifulSoup) -> Optional[Tag]:
    """挑出 <p> 标签最密集的容器作为正文（极简 readability）。"""
    best, best_score = None, 0
    for div in soup.find_all(["div", "section"]):
        ps = div.find_all("p", recursive=False)
        if not ps:
            continue
        score = sum(len(p.get_text(strip=True)) for p in ps)
        if score > best_score:
            best_score, best = score, div
    return best


# -------------------- 工具 --------------------

def _meta(soup: BeautifulSoup, *keys: str) -> str:
    for k in keys:
        for attr in ("property", "name"):
            m = soup.find("meta", {attr: k})
            if m and m.get("content"):
                return m["content"].strip()
    return ""


def _clean_paragraphs(node: Tag) -> List[str]:
    """从容器节点抽取段落文本，过滤广告/分享/版权等。"""
    paras: List[str] = []
    for p in node.find_all("p"):
        # 跳过含 <img> 但无文本的占位段
        text = p.get_text(" ", strip=True)
        text = re.sub(r"\s+", " ", text)
        if not text:
            continue
        if _is_junk(text):
            continue
        paras.append(text)
    return paras


_JUNK_PATTERNS = [
    r"^扫码下载",
    r"^关注东方财富",
    r"^责任编辑",
    r"^免责声明",
    r"^风险提示",
    r"^来源：?\s*$",
    r"^分享到",
    r"^点击查看",
    r"^东方财富APP",
    r"^本文.{0,20}仅代表作者",
]
_JUNK_RE = re.compile("|".join(_JUNK_PATTERNS))


def _is_junk(text: str) -> bool:
    if _JUNK_RE.match(text):
        return True
    if len(text) < 6 and not re.search(r"[一-鿿]{2,}", text):
        return True
    return False


def _collect_images(node: Optional[Tag], base_url: str) -> List[str]:
    if not node:
        return []
    out: List[str] = []
    seen = set()
    for img in node.find_all("img"):
        src = (img.get("src") or img.get("data-src") or "").strip()
        if not src:
            continue
        # 1x1 像素 / 表情 / 二维码 过滤
        if "qr" in src.lower() or "1x1" in src.lower() or src.endswith(".gif"):
            continue
        full = urljoin(base_url, src)
        if full not in seen:
            seen.add(full)
            out.append(full)
    return out


def _err(url: str, msg: str) -> dict:
    return {
        "ok": False,
        "url": url,
        "error": msg,
        "title": "",
        "summary": "",
        "date": "",
        "source": "",
        "author": "",
        "paragraphs": [],
        "images": [],
    }


if __name__ == "__main__":
    import json
    import sys

    if len(sys.argv) < 2:
        print("usage: article.py <url>", file=sys.stderr)
        sys.exit(1)
    print(json.dumps(fetch(sys.argv[1]), ensure_ascii=False, indent=2))
