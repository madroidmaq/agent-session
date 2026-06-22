import Cocoa

// AgentSession — 原生 macOS 壳，运行时把 ~/.claude/projects 解析出的会话数据
// 注入打包进 bundle 的 template.html（与 session-viewer 网页同一套渲染逻辑）。

// Headless 模式：--dump-json 仅扫描并打印全量 JSON（用于 golden 对照/脚本），不启动 GUI。
if CommandLine.arguments.contains("--dump-json") {
    let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    let store = SessionStore(root: root)
    store.reloadFull()
    var scope = Scope()
    scope.since = .all
    scope.maxSessions = Int.max
    print(store.json(scope: scope))
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = buildMainMenu(target: delegate)
app.run()
