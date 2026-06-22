# AgentSession

一个自包含的原生 macOS App，用来回看 **Claude Code** 的会话记录。读取 `~/.claude/projects`
下的 JSONL transcript，用 WKWebView 渲染三栏阅读界面（会话列表 / 对话主线 / 工具详情）。

[English](README.md)

![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

![AgentSession —— Claude Code 会话的三栏阅读界面](docs/screenshot.png)

## 特性

- **纯 Swift 解析**，不依赖 node —— 启动即扫描，运行时把数据注入 WebView（不再生成 11MB HTML 快照）。
- **三栏阅读**：会话列表、对话主线、逐工具详情。
- **侧栏筛选**：时间范围（7天 / 24小时 / 30天 / 全部）、项目筛选。
- **文件监听自动刷新**：FSEvents 监听 `~/.claude/projects`，有新消息约 1s 内自动重载（保持当前选中）。
- **原生暗色外壳**：暗色统一标题栏，与内容融为一体。

## 隐私

AgentSession **纯本地、只读**。仅读取本机的 `~/.claude/projects`，不联网、不上传任何内容。

## 安装

### 下载（推荐）

到 [Releases](https://github.com/madroidmaq/agent-session/releases/latest) 下载最新的
`AgentSession.dmg`，打开后把 **AgentSession** 拖进 **Applications** 即可。

> 当前为 ad-hoc 签名、未做公证，首次打开请用**右键 → 打开**绕过 Gatekeeper。

### 从源码构建

```sh
./build.sh                 # swift build -c release + 打包 AgentSession.app + ad-hoc 签名
open AgentSession.app
./make-dmg.sh              # 可选：生成可拖拽安装的 AgentSession.dmg
```

开发期也可直接：`swift build && swift run`。

快捷键：`⌘R` 刷新 · `⌘Q` 退出 · `⌘C/⌘A` 复制/全选。

## 架构

| 文件 | 职责 |
|---|---|
| `Sources/AgentSession/main.swift` | 启动入口；`--dump-json` headless 模式打印全量 JSON（验证/脚本用） |
| `AppDelegate.swift` | 窗口 / WKWebView / NSToolbar / 菜单 / 加载时序与数据注入 |
| `TranscriptParser.swift` | JSONL → 结构化数据 |
| `Models.swift` | `Session` / `Usage` / `Scope`，`toDict()` 产出与网页一致的 JSON schema |
| `SessionStore.swift` | 全量扫描+缓存、按 scope 内存过滤、序列化 |
| `FileWatcher.swift` | FSEvents 监听 + 防抖 |
| `Resources/template.html` | 渲染层；暴露 `window.__agentSession.load()` 作为注入入口（向后兼容仍可当独立网页） |

数据流：启动 → 后台全量解析缓存 → WebView 加载 template → 注入当前 scope 的 JSON。
切换筛选只在内存过滤+重注入（秒级，不重扫盘）；文件变化才后台重扫。

## 验证

解析逻辑移植自上游的 `extract-session.mjs` 网页 skill（不在本仓库内）。正确性靠 golden
对照保证：对任一已结束（不再变化）的 session，`AgentSession --dump-json` 的输出与
`node extract-session.mjs --session <id>` 逐字段一致：

```sh
ID=<sessionId>
node /path/to/extract-session.mjs --session "$ID" \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/g.json
.build/release/AgentSession --dump-json \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/s.json
diff /tmp/g.json /tmp/s.json   # 期望无差异
```

## 已知边界 / 后续

- 分发给他人需 notarize（当前仅 ad-hoc 签名，本地运行）。
- tool_result 内容恰为 JSON 对象时，其 key 顺序可能与网页版不同（无序序列化，纯展示无影响）。

## 许可

[MIT](LICENSE) © madroid
