# StockBar

macOS 菜单栏 + 主窗口 A 股桌面 App。读取 `vnpy/持仓.md`，本地纯自用。

**功能**
- **菜单栏快瞥**：左键开主窗口，右键弹快速菜单（持仓/自选/指数）
- **主窗口 4 个 Tab（SwiftUI）**：
  - 持仓：汇总卡片 + 持仓表格 + 点行右侧分时图
  - 自选：自选股表格 + 分时图
  - 大盘：上证/深证/创业板/沪深300 大卡片 + 分时图
  - 新闻：左侧选股票 → 中间新闻列表 → 右侧 WebView 渲染正文
- 行情：新浪 `hq.sinajs.cn`（80ms 一次拉全部）
- 新闻：东方财富 `search-api-web`（每只 30 条）
- 分时：腾讯 `web.ifzq.gtimg.cn`（240+ minute tick）+ 新浪 hq 拿昨收
- 交易时段 10s 刷新，非交易时段 5min
- 开机自启（`SMAppService`）

**技术栈**
- Swift 5.9 / macOS 14+
- AppKit (NSStatusItem, NSWindow) + SwiftUI (Table, Chart, NavigationSplitView, WKWebView)
- SPM executable（`Package.swift`，Xcode 直接打开即可调试 + 用 SwiftUI Preview）
- Python helper（venv 自举，requests）

## 构建 & 运行

```bash
cd ~/github/stock-bar
bash scripts/build.sh release      # 产出 ./StockBar.app
open StockBar.app                  # 首次启动会自动 bootstrap venv
mv StockBar.app /Applications/     # 可选：装到应用程序目录
```

首次启动时 App 会在 `~/Library/Application Support/StockBar/venv/` 创建一个隔离的 Python 虚拟环境并 `pip install requests`。后续启动直接复用。

## 在 Xcode 里开发

Xcode 14+ 原生支持 SPM 包，直接打开 `Package.swift` 即可：

```bash
open Package.swift     # 用 Xcode 打开
```

- SwiftUI Preview 在 Xcode 里可用（任何 View 文件按 ⌥+⌘+P 即可看预览）
- ⌘R 直接 build & 运行
- 想看主窗口而不只是菜单栏：Edit Scheme → Run → Arguments，可以加 `STOCKBAR_HOLDINGS` 环境变量切换持仓文件

## 持仓 .md 格式

默认读取 `/Users/wepie/github/vnpy/持仓.md`。可通过环境变量覆盖：

```bash
STOCKBAR_HOLDINGS=/path/to/holdings.md open StockBar.app
```

解析器接受这几种持仓写法（容错）：

```markdown
股票持仓：
- 159742 恒指科技：0.653（30000 元）           # 成本价 + 投入金额
- 600519 贵州茅台 100股 @1700.50                # 股数 + 成本价
- 002714 牧原股份 1000股 42.50                  # 股数 + 成本价（空格分隔）

# 或者：
股票持仓：（空仓）

剩余资金：760,716 元

关注：
- 159742 恒指科技
- 159131 港股通信息技术ETF华宝
```

> ⚠️ "已平仓 / 历史 / 备注" 段落会被跳过，不会被当成持仓或自选解析。

## 自选股

直接编辑 `持仓.md` 的「关注」段落即可，App 会在下次刷新时同步。

## 项目结构

```
~/github/stock-bar/
├── Package.swift                    SPM 可执行包
├── Sources/StockBar/
│   ├── main.swift                   入口，设置 .accessory 模式
│   ├── AppDelegate.swift            生命周期、venv 自举
│   ├── HelperProcess.swift          Python 子进程 + IPC + 自动重启
│   ├── StatusItemController.swift   NSStatusItem + NSMenu
│   ├── Models.swift                 Snapshot/Position/Quote
│   └── Resources/Info.plist         CFBundle*、LSUIElement
├── helper/
│   ├── fetch.py                     主程序：stdin 触发 → stdout 一行 JSON
│   ├── holdings.py                  持仓.md 解析器（独立可测）
│   └── requirements.txt             requests
└── scripts/build.sh                 SPM build + 打包 .app + ad-hoc 签名
```

## IPC 协议

```
Swift  → Python: refresh\n
Python → Swift : {"ok":true,"ts":"...","holdings":{...},"watchlist":[...],"indices":[...]}\n

Swift  → Python: quit\n   # 也可以直接关 stdin
```

错误：`{"ok":false,"ts":"...","error":"..."}`。

## 调试

```bash
# 直接跑二进制，stderr 能看到 NSLog + Python 日志
./StockBar.app/Contents/MacOS/StockBar

# 单独测 Python helper
echo refresh | helper/.venv/bin/python helper/fetch.py
python3 helper/holdings.py /path/to/持仓.md   # 解析器测试
```

## 已知限制

- 数据源走新浪 `hq.sinajs.cn`，A 股节假日返回的是上一交易日收盘价（菜单显示数据不变即可推断）。
- 当前不支持港股/美股/期货。
- 持仓.md 没有股数 + 成本价时，无法计算今日盈亏（会显示 `---`）。
