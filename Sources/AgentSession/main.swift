import Cocoa

// AgentSession — 原生 macOS 壳，运行时把 ~/.claude/projects 解析出的会话数据
// 注入打包进 bundle 的 template.html（与 session-viewer 网页同一套渲染逻辑）。

// Headless 模式：--dump-json 仅扫描并打印全量 JSON（用于 golden 对照/脚本），不启动 GUI。
if CommandLine.arguments.contains("--dump-json") {
    let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    let codex = ("~/.codex/sessions" as NSString).expandingTildeInPath
    let codexRoot = FileManager.default.fileExists(atPath: codex) ? codex : nil
    let store = SessionStore(claudeRoot: root, codexRoot: codexRoot)
    store.reloadFull()
    var scope = Scope()
    scope.since = .all
    scope.maxSessions = Int.max
    print(store.json(scope: scope))
    exit(0)
}

// Headless 性能回归基准：--bench [查询词…] 测冷/热 reload、linear vs FTS 搜索耗时与索引体积。
// 长期保留，用于监控解析/索引改动的性能影响。
// 注意：逻辑必须放在函数里，不能写成 main.swift 顶层语句 ——
// 顶层全局变量被闭包捕获在 -O 下会触发 swift_retain 段错误。
private func runBench(afterFlagIndex benchIdx: Int) -> Never {
    setvbuf(stdout, nil, _IONBF, 0)
    let root = ("~/.claude/projects" as NSString).expandingTildeInPath
    let codex = ("~/.codex/sessions" as NSString).expandingTildeInPath
    let codexRoot = FileManager.default.fileExists(atPath: codex) ? codex : nil
    var queries = Array(CommandLine.arguments[(benchIdx + 1)...]).filter { !$0.hasPrefix("--") }
    if queries.isEmpty { queries = ["SQLite", "会话", "reload"] }

    func ms(_ block: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        block()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    let store = SessionStore(claudeRoot: root, codexRoot: codexRoot)
    var scope = Scope()
    scope.since = .all
    scope.maxSessions = Int.max

    let cold = ms { store.reload(scopeHint: scope) }
    let warm = ms { store.reload(scopeHint: scope) }
    print(String(format: "reload cold: %8.1f ms  (%d sessions)", cold, store.summaries.count))
    print(String(format: "reload warm: %8.1f ms", warm))

    func benchSearches(_ label: String) {
        for q in queries {
            var json = ""
            let t = ms { json = store.searchJSON(query: q, scope: scope) }
            let count = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                .flatMap { ($0["count"] as? NSNumber)?.intValue } ?? -1
            print("search[\(label)] '\(q)': " + String(format: "%8.1f ms  (%d hits)", t, count))
        }
    }
    benchSearches("linear")

    // FTS 索引：临时 DB 冷建 → 热同步 → FTS 搜索
    let dbPath = NSTemporaryDirectory() + "agentsession-bench-\(UUID().uuidString).db"
    defer {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
    }
    guard let index = SearchIndex(dbPath: dbPath) else {
        print("SearchIndex open failed"); exit(1)
    }
    store.searchIndex = index
    let indexCold = ms { store.reload(scopeHint: scope); index.waitForPendingSync() }
    let indexWarm = ms { store.reload(scopeHint: scope); index.waitForPendingSync() }
    let dbSize = ["", "-wal"].reduce(0.0) { acc, suffix in
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: dbPath + suffix))?[.size] as? NSNumber)?.doubleValue ?? 0
        return acc + bytes / 1_048_576
    }
    print(String(format: "index build cold: %8.1f ms  (db %.1f MB)", indexCold, dbSize))
    print(String(format: "index sync warm:  %8.1f ms", indexWarm))
    benchSearches("fts")
    exit(0)
}

if let benchIdx = CommandLine.arguments.firstIndex(of: "--bench") {
    runBench(afterFlagIndex: benchIdx)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = buildMainMenu(target: delegate)
app.run()
