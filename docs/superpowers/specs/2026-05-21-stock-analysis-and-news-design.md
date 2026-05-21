# StockBar 单股分析 + 大盘研判 + 新闻关联度改造 — 设计文档

**日期**：2026-05-21
**状态**：已通过 PO 代理评审，待实现（peer-review-dev）

## 1. 目标（5 项）

| # | 需求 | 决策摘要 |
|---|------|---------|
| 1 | 持仓页首次进入默认选中第一只 | 补 `autoSelectFirst()`（仅触发分时图，不自动跑分析） |
| 2 | 持仓「股票分析」（最重要） | 按需触发的分析卡（分时图上方堆叠），含可执行价位 |
| 3 | 自选「股票分析」 | 同 2，结论用词改为买入/观望/回避 |
| 4 | 大盘分析 | 仅上证一个总研判卡 |
| 5 | 新闻关联度改造 | 名称搜索+相关度排序+过滤 / 利好利空 tag / 去重 |

非目标（已明确砍掉）：板块新闻、分析卡里的 operation/invalidation 长文本与盈亏比、逐指数大盘分析、分析结果落盘缓存、左右并排布局。

## 2. 架构总览

复用现有 helper 子进程模式（stdin 命令 → stdout 一行 JSON → AppModel 按 type 分发）。

```
新增命令: analyze <code> [cost_price] [shares]
  fetch.py(helper venv)
    └─ 后台线程调 vnpy venv 的 analyze_one.py（与 quant 同款 subprocess 模式）
         └─ 复用 quant.py: fetch_one / short_term_score / support_resistance
                          / evaluate_holding(持仓) / score_stock_news / market_direction
    └─ 3 分钟内存缓存（key = code|cost_price）

改造命令: news <code> <name>   （新增 name 参数）
  fetch.py(helper venv，无需 akshare)
    └─ 按名称搜索 → 不足补代码搜 → 合并去重 → 相关度排序 → 利好/利空打标签
```

### 关键约束
- 单股 analyze 经子进程 ~2-5s，故**按需触发**（非选中即跑），并加 loading/失败降级。
- 新闻情绪标签的关键词词典从 quant.py 复制到 fetch.py（纯字符串列表，无 akshare 依赖），在 helper 自身 venv 内完成，零额外子进程。

## 3. 数据契约

### 3.1 analyze 响应（type = "analyze"）

```jsonc
{
  "ok": true, "type": "analyze", "ts": "...", "code": "002625",
  "kind": "holding" | "watch" | "index",
  "name": "光启技术",
  "verdict": "持有",            // 持仓:持有/止盈/止损/清仓; 自选:买入/观望/回避; 大盘:多/空/震荡
  "reason": "浮亏未破位 趋势完好", // ≤ ~20 字
  "score": 62,                  // 0-100 短线评分（大盘为 null）
  "levels": {                   // 关键价位条
    "buy": 37.6, "tp": 41.2, "sl": 36.8, "support": 37.6, "resistance": 41.5
  },
  "signals": ["MA20 上方运行", "MACD 绿柱收窄", "缩量回踩"],  // 3-5 条
  "newsSentiment": "neutral",   // bull/bear/neutral
  "newsSignals": ["近期利好关键词 ×1"],
  "pnlPct": -3.2, "pnlAmount": -1704.9,  // 仅持仓
  "error": null
}
```

**字段来源与映射（analyze_one.py 内自行组装，不直接转发 quant 函数返回）**：
- `score` / `signals` / `dimensions` / `indicators` / `support` / `resistance`：恒由 `short_term_score(df, rt, market_dir)` + `support_resistance(df)` 算出（持仓"持有"情形也有，因为不依赖 evaluate_holding）。
- 持仓 `verdict`：调 `evaluate_holding` → 返回 `None` 即 **"持有"**；返回 dict 按 `action` 映射：`止盈卖出`→`止盈`、`止损卖出`→`止损`、`清仓`→`清仓`。**不做"加仓/减仓"**（超出 evaluate_holding 能力，YAGNI）。
- 持仓 `levels.tp/sl`：**自行用 `support_resistance` + ATR 计算止盈/止损目标价**，不取 evaluate_holding 返回的即时卖价。`pnlPct/pnlAmount` 在 analyze_one 内用 cost_price 自算。
- `newsSentiment`：`score_stock_news` 返回 `(d6:int 1-10, signals:list)`；映射 d6≥8→`bull`、d6≤5→`bear`、其余→`neutral`。`newsSignals` 直接用其 signals 文本（如"近期利好关键词 ×N"）。
- 自选：`levels` 仅 buy/support/resistance（tp/sl 置 null），无 pnl。verdict 由 score 映射（≥75 买入 / 60-74 观望 / <60 回避），"回避"也给支撑位参考。
- 大盘（kind=index）：精简——verdict 由 `market_direction()` 返回的 `(int, str)` 中的 int 映射（`1→多 / -1→空 / 0→震荡`）；levels 仅 support/resistance（对指数 df 跑 support_resistance）；signals = 均线排列/量能描述；reason 一句；**score=null、不跑 score_stock_news**（短线 6 维评分对指数不适用）。

### 3.2 news 响应（沿用 type = "news"，每条新增字段）

```jsonc
{ "title": "...", "url": "...", "date": "...", "source": "...", "summary": "...",
  "sentiment": "bull" | "bear" | "neutral",
  "relevance": 2 }   // 内部排序用：标题含名称=2，含代码=1，其余=0
```

## 4. helper 实现

### 4.1 `helper/analyze_one.py`（新建，跑在 vnpy venv）
- 入参：`code [cost_price] [shares]`。
- `sys.path` 注入 quant.py 目录 + vnpy 的 examples/akshare_data 目录，import quant 的函数及 analyze.py 的 `fetch_hist_data` / `fetch_realtime` / `compute_indicators`。
- **kind 判定（先于取数）**：硬编码指数集合 `{"000001":"上证","399001":"深成","399006":"创业板","000300":"沪深300"}`；命中 → `kind=index`；否则 cost_price>0 → `kind=holding`；否则 `kind=watch`。
- **取数**：
  - index：**不走 detect_type**（`detect_type("000001")` 会误判为 stock=平安银行）；显式 `a_type="index"`，用 `fetch_hist_data(code, "index")` 取指数 K 线（注意 get_prefix 对 000001 给 sz，沿用 quant `market_direction` 的既有取法即可）。
  - 个股/ETF：用 `fetch_one(code)`（其内部 detect_type 对个股/ETF 正确）。
  - 取数失败 → 输出 `{ok:false, type:"analyze", code, error}`。
- **公共计算**（index 外）：`market_dir = market_direction()[0]`；`score, reason, detail = short_term_score(df, rt, market_dir)`；`S, R = support_resistance(df)`；`d6, news_sigs = score_stock_news(code)`。
- **分支组装**：
  - holding：`ev = evaluate_holding(code,name,shares,cost_price,df,rt)`；`verdict = "持有" if ev is None else map(ev["action"])`；tp/sl 用 R/S±ATR 自算；pnl 自算。
  - watch：verdict 由 score 映射；`levels.buy = quantize(S*1.003)`，tp/sl=null。
  - index：verdict 由 `market_direction()[0]` 映射；levels 仅 S/R；signals 取均线/量能；score=null，跳过 news。
- 输出单行 JSON（stdout 最后一行），日志走 stderr。

### 4.2 `fetch.py`
- 新增 `analyze` 命令：仿 `_run_quant` 的后台线程 + `_emit`，调用 `analyze_one.py`；前置 3 分钟内存缓存 `_ANALYZE_CACHE[code] = (ts, payload)`（key 仅 code——同一 code 不会既是持仓又是自选；持仓的 cost/shares 变化由用户编辑后下次刷新覆盖，可接受）。子进程超时设 **30s**（单股应 <10s）。
- 改造 `fetch_news(code, name)`：
  1. 用 `name` 搜 eastmoney CMS；结果 < 5 条则再用 `code` 搜一次。
  2. 合并去重：按 URL **strip 掉 query 参数（from/_ 等）后**比较，避免同文不同参重复。
  3. 计算 `relevance`（标题含 name=2 / 含 code=1 / 否则 0），按 (relevance desc, date desc) 排序；relevance=0（标题既不含 name 也不含 code 的泛市场文）一律下沉到末尾，不删除。
  4. 每条按关键词词典打 `sentiment`（_NEWS_BULL/_NEWS_BEAR 从 quant.py 复制为纯字符串列表，helper venv 内即可，无需 akshare）。
- 命令解析：`news <code> <name...>`（name 取 args[1:] join，兼容含空格的罕见名，如"南 玻Ａ"）。

## 5. Swift 实现

### 5.1 Models
- 新增 `StockAnalysis` struct（含 §3.1 字段）+ 嵌套 `AnalysisLevels`。
- `HelperResponse` 增 `analysis` 相关字段；`NewsItem` 增 `sentiment`、`relevance`。

### 5.2 AppModel
- `@Published analysisByCode: [String: StockAnalysis]`、`analyzingCodes: Set<String>`。
- `requestAnalyze(code:costPrice:shares:)`；ingest `case "analyze"`。
- `requestNews(code:name:)` 改签名带 name。**连带改造现有调用链**（reviewer 指出的遗漏）：
  - `allTrackedCodes()` → 返回 `[(code, name)]`（持仓有 name；自选 Quote.name）。
  - `selectNewsStock(code:)` → `selectNewsStock(code:name:)`；`refreshAllNews()` 内按 (code,name) 调。
  - `newsByCode` 仍以 code 为 key 不变。

### 5.3 HelperProcess
- `requestAnalyze(code:costPrice:shares:)` → `send("analyze \(code) ...")`。
- `requestNews(code:name:)` → `send("news \(code) \(name)")`。

### 5.4 视图
- 新建 `Views/StockAnalysisCard.swift`：共享分析卡（结论徽章 + 一句理由 + 关键价位条 + 信号 3-5 + 评分进度条 + 利好利空 tag），`mode: .holding/.watch`。
- 新建 `Views/MarketBriefCard.swift`：大盘研判卡（方向徽章 + 关键点位 + 一句话建议）。
- `HoldingsTab`：加 `autoSelectFirst()`，触发时机对齐 WatchlistTab——`.onAppear { autoSelectFirst() }` + `.onChange(of: positions.count)`，仅 `selectedCode == nil` 时选第一只并 `requestChart`（不自动 analyze）；分时图卡 header 加「分析」按钮（`wand.and.stars`），点击插入分析卡（loading→内容→可关闭）；切股自动收起分析卡。
- `WatchlistTab`：同款分析卡（watch 模式）。
- `IndicesTab`：indexGrid 与 chartCard 之间插 `MarketBriefCard`（数据来自 `analyze 000001`，**进入页自动拉一次**——这是"按需触发"原则的明确例外：大盘研判是单次固定调用、且跳过 news 较快，故允许自动。个股分析仍严格按需）。
- `NewsTab`：每条新闻标题前显示利好/利空/中性色块 tag（DS.up/DS.down/secondary）。

### 5.5 交互细则
- 分析按需：选中股票仅显示分时图；点「分析」才跑。loading 显示 ProgressView「正在分析…」。
- 失败降级：analyze 返回 ok=false → 分析卡显示「分析暂不可用：<error>」，不卡死。
- 缓存命中即时返回（helper 侧）。

## 6. 错误处理
- vnpy 不可达 / 超时（沿用 quant 的 180s，但单股应 <10s，设 30s 超时）→ ok=false + error，卡片降级。
- 新闻接口失败 → 沿用现有空列表行为。
- 指数无 cost、个股 cost 缺失 → 各自分支默认值，不抛异常。

## 7. 测试
- helper 单测（vnpy venv）：
  - `analyze_one` 对持仓码/自选码/指数码分别产出含必需字段的合法 JSON。
  - `fetch_news` 相关度排序正确（含名称的排前）、sentiment 打标签正确、URL 去重。
- Swift：`swift build` + `bash scripts/build.sh` 通过；人工/agent 验收四个页面渲染。

## 8. 验收标准（PO 代理给定，实现须逐条满足）
1. 持仓/自选首次进入自动选中第一只，分时图立即加载，无空白态。
2. 单股分析必含可执行价位（持仓有止盈/止损价；自选有建议买点）。
3. 个股分析按需触发，切股不自动跑 analyze（大盘研判卡为唯一例外，进入大盘页自动拉一次）。
4. 分析有 loading 状态；失败有降级提示，不卡死。
5. 新闻按相关度排序，标题含名称者靠前；泛市场文下沉/过滤。
6. 新闻显示利好/利空/中性 tag，颜色可辨。
7. analyze 结果 3 分钟内存缓存，重复点击不重跑子进程。
8. 大盘研判仅一个总研判卡（方向 + 关键点位 + 一句建议）。
