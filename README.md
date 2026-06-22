# AgentSession

一个自包含的原生 macOS App，用来回看 Claude Code 的会话记录。读取 `~/.claude/projects`
下的 JSONL transcript，用 WKWebView 渲染三栏阅读界面（会话列表 / 对话主线 / 工具详情）。

由 [session-viewer skill](../madroid-skills/plugin/skills/session-viewer) 的网页版演进而来：
- **纯 Swift 解析**，不依赖 node —— 启动即扫描，运行时把数据注入 WebView（不再生成 11MB HTML 快照）。
- **原生工具栏**：时间范围（7天/24小时/30天/全部）、项目筛选、刷新。
- **文件监听自动刷新**：FSEvents 监听 `~/.claude/projects`，有新消息约 1s 内自动重载（保持当前选中）。

## 构建 & 运行

```sh
./build.sh                 # swift build -c release + 打包 AgentSession.app + ad-hoc 签名
open AgentSession.app
```

开发期也可直接：`swift build && swift run`。

快捷键：`⌘R` 刷新、`⌘Q` 退出、`⌘C/⌘A` 复制/全选。

## 架构

| 文件 | 职责 |
|---|---|
| `Sources/AgentSession/main.swift` | 启动入口；`--dump-json` headless 模式打印全量 JSON（验证/脚本用） |
| `AppDelegate.swift` | 窗口 / WKWebView / NSToolbar / 菜单 / 加载时序与数据注入 |
| `TranscriptParser.swift` | JSONL → 结构化数据（1:1 移植自 `extract-session.mjs`） |
| `Models.swift` | `Session` / `Usage` / `Scope`，`toDict()` 产出与网页一致的 JSON schema |
| `SessionStore.swift` | 全量扫描+缓存、按 scope 内存过滤、序列化 |
| `FileWatcher.swift` | FSEvents 监听 + 防抖 |
| `Resources/template.html` | 渲染层（复用网页版；加了 `window.__agentSession.load()` 注入入口，向后兼容仍可当独立网页） |

数据流：启动 → 后台全量解析缓存 → WebView 加载 template → 注入当前 scope 的 JSON。
切换工具栏只在内存过滤+重注入（秒级，不重扫盘）；文件变化才后台重扫。

## 与 session-viewer skill 的关系

- 解析逻辑移植自 `extract-session.mjs`，二者是**两套需手动同步**的实现。
  正确性靠 golden 对照保证：`AgentSession --dump-json` 的输出与 `node extract-session.mjs --session <id>`
  对同一静止会话逐字段一致（已验证）。
- `template.html` 是从 skill 版复制的副本，独立演进；设计改进需手动 port。

## 验证

```sh
# golden 对照：选一个已结束（不再变化）的 session
ID=<sessionId>
node ../madroid-skills/plugin/skills/session-viewer/extract-session.mjs --session "$ID" \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/g.json
.build/release/AgentSession --dump-json \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/s.json
diff /tmp/g.json /tmp/s.json   # 期望无差异
```

## 已知边界 / 后续

- 分发给他人需 notarize（当前仅 ad-hoc 签名，本地运行）。
- App 图标暂用默认，可后续加 `.icns`。
- tool_result 内容恰为 JSON 对象时，其 key 顺序可能与网页版不同（无序序列化，纯展示无影响）。
