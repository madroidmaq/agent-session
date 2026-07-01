# AgentSession

A self-contained native macOS app for reading back your **Claude Code** and **Codex**
session history. It reads the JSONL transcripts under `~/.claude/projects` and
`~/.codex/sessions` and renders them in a clean three-pane reading UI
(session list / conversation thread / tool details) via WKWebView.

[简体中文](README.zh-CN.md)

![Platform](https://img.shields.io/badge/platform-macOS%2012%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/license-MIT-blue)

![AgentSession — three-pane reader for Claude Code sessions](docs/screenshot.png)

## Features

- **Pure-Swift parsing**, no Node required — scans on launch and injects data straight
  into the WebView (no more 11 MB generated HTML snapshots).
- **Dual sources** — loads both Claude Code (`~/.claude/projects`) and Codex
  (`~/.codex/sessions`); Codex sessions are tagged with a `codex` badge.
- **Three-pane reader** — session list, conversation thread, and per-tool details.
- **Sidebar filters** — time range (7d / 24h / 30d / all) and per-project filtering.
- **Live auto-refresh** — FSEvents watches `~/.claude/projects`; new messages reload in
  ~1s while keeping your current selection.
- **Native dark chrome** — dark unified titlebar that blends into the content.

## Known limitations

Only the **official default directories** are scanned: Claude Code = `~/.claude/projects`,
Codex = `~/.codex/sessions`. Both can be relocated via environment variables, in which case
those sessions live elsewhere and this app won't see them:

- **Codex**: `CODEX_HOME` overrides `~/.codex`. For example, internal/custom-provider
  tooling may point it at something like `~/.zepp/codex` (to isolate the custom provider's
  `config.toml` / `auth.json` / session history), so those sessions land under
  `~/.zepp/codex/sessions`.
- **Claude Code**: `CLAUDE_CONFIG_DIR` overrides `~/.claude`.

A GUI app launched from Finder doesn't inherit shell-`export`ed variables, so custom
directories aren't auto-discovered for now. If needed, this could read those env vars or
add a setting to point at extra roots.

## Privacy

AgentSession is **fully local and read-only**. It only reads `~/.claude/projects` and
`~/.codex/sessions` on your machine — it makes no network calls and uploads nothing.

## Install

### Download (recommended)

Grab the latest `AgentSession.dmg` from the
[Releases](https://github.com/madroidmaq/agent-session/releases/latest) page, open it, and drag
**AgentSession** into **Applications**.

> The build is ad-hoc signed and not notarized yet, so on first launch use
> **right-click → Open** to get past Gatekeeper.

### Build from source

```sh
./build.sh                 # swift build -c release + package AgentSession.app + ad-hoc sign
open AgentSession.app
./make-dmg.sh              # optional: produce a draggable AgentSession.dmg
```

During development you can also just run: `swift build && swift run`.

Shortcuts: `⌘R` refresh · `⌘Q` quit · `⌘C/⌘A` copy/select-all.

## Architecture

| File | Responsibility |
|---|---|
| `Sources/AgentSession/main.swift` | Entry point; `--dump-json` headless mode prints the full JSON (for validation/scripts) |
| `AppDelegate.swift` | Window / WKWebView / NSToolbar / menu / load sequencing & data injection |
| `TranscriptParser.swift` | JSONL → structured data |
| `Models.swift` | `Session` / `Usage` / `Scope`; `toDict()` emits the JSON schema the web layer expects |
| `SessionStore.swift` | Full scan + cache, in-memory filtering by scope, serialization |
| `FileWatcher.swift` | FSEvents watching + debounce |
| `Resources/template.html` | Render layer; exposes `window.__agentSession.load()` as the injection entry point (stays backward-compatible as a standalone web page) |

Data flow: launch → background full parse & cache → WebView loads `template.html` → inject
the JSON for the current scope. Changing a filter only does in-memory filtering + re-injection
(sub-second, no disk rescan); a file change triggers a background rescan.

## Validation

The parser is a port of an upstream `extract-session.mjs` web skill (not included in this
repo). Correctness is held with a golden comparison — for any settled (no longer changing)
session, `AgentSession --dump-json` matches `node extract-session.mjs --session <id>`
field-by-field:

```sh
ID=<sessionId>
node /path/to/extract-session.mjs --session "$ID" \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/g.json
.build/release/AgentSession --dump-json \
  | jq -S --arg id "$ID" '.sessions[]|select(.id==$id)' > /tmp/s.json
diff /tmp/g.json /tmp/s.json   # expect no diff
```

## Known limitations / Roadmap

- Distribution to others needs notarization (currently ad-hoc signed for local use).
- When a `tool_result` body is itself a JSON object, its key order may differ from the web
  version (unordered serialization; display-only, no functional impact).

## License

[MIT](LICENSE) © madroid
