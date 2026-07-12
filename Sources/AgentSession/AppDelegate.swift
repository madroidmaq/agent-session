import Cocoa
import WebKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate,
                         NSToolbarDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let store: SessionStore
    private let codexRoot: String?
    private var watcher: FileWatcher?
    private var codexWatcher: FileWatcher?

    private var scope = Scope()
    private var webReady = false
    private var pendingInject = false
    private let loadQueue = DispatchQueue(label: "dev.madroid.agentsession.load", qos: .userInitiated)
    private var reloadSeq = 0
    private var activeReloadSeq = 0
    private var detailRequestSeq = 0
    private var activeDetailRequestSeq = 0
    private var searchSeq = 0
    private var activeSearchSeq = 0
    // 同一时间只允许一个重扫真正执行；期间的新请求合并成一次后续补跑。
    private var reloadInFlight = false
    private var reloadPending = false
    private var pendingChangedSessionIds = Set<String>()
    private var pendingUnknownReload = false
    // 摘要缓存覆盖到的时间下界：nil = 尚未加载；.some(nil) = 已加载全部；
    // .some(date) = 缓存到 date 为止。请求范围比它更旧才需重扫。
    private var loaded = false
    private var loadedSinceDate: Date?

    private let paneLeftWidthKey = "AgentSessionPaneLeftWidth"
    private let paneRightWidthKey = "AgentSessionPaneRightWidth"
    private let paneLeftDefault = 256
    private let paneRightDefault = 360
    private let paneLeftMin = 200
    private let paneLeftMax = 420
    private let paneRightMin = 280
    private let paneRightMax = 640

    private static let repositoryURL = URL(string: "https://github.com/madroidmaq/agent-session")!

    override init() {
        let root = ("~/.claude/projects" as NSString).expandingTildeInPath
        // 只扫官方默认目录：Claude Code = ~/.claude/projects，Codex = ~/.codex/sessions。
        //
        // 已知局限：这两个目录都可被环境变量改写，此时会话不在默认位置、本 app 看不到：
        //   - Codex：CODEX_HOME 改写 ~/.codex（例如内网 provider 工具会把它指到
        //     ~/.zepp/codex 以隔离自定义 provider 的 config.toml / auth.json / 会话记录）。
        //   - Claude Code：CLAUDE_CONFIG_DIR 改写 ~/.claude。
        // GUI 从 Finder 启动时拿不到 shell 里 export 的这些变量，故暂不自动发现。
        // 如需支持：读取上述环境变量 / 提供设置项让用户手动指定额外根目录，再并入数据源。
        let codex = ("~/.codex/sessions" as NSString).expandingTildeInPath
        codexRoot = FileManager.default.fileExists(atPath: codex) ? codex : nil
        store = SessionStore(claudeRoot: root, codexRoot: codexRoot)
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first {
            let dbPath = appSupport.appendingPathComponent("AgentSession/search-index.db").path
            store.searchIndex = SearchIndex(dbPath: dbPath)
        }
        super.init()
    }

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "AgentSession"
        window.center()
        window.setFrameAutosaveName("AgentSessionMain")
        window.backgroundColor = NSColor(red: 0.102, green: 0.098, blue: 0.094, alpha: 1) // #1a1918，避免加载时白屏
        // 暗色标题栏：透明融入窗口背景，与暗色内容一体，告别白色标题栏。
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true

        // 告诉页面它运行在原生壳里：CSS 用 `html.native` 拍平网页自带的模拟窗口外壳
        // （红绿灯圆点 / 圆角卡片 / 阴影 / 假标题栏），避免“窗口套窗口”。
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(
            source: "document.documentElement.classList.add('native');",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // 侧栏的时间范围 / 项目下拉通过这条桥回调，更新 scope 后重新加载摘要索引。
        config.userContentController.add(self, name: "scope")
        // 详情页按需请求完整 turns / subagents，避免启动时解析全量历史。
        config.userContentController.add(self, name: "sessionDetail")
        // 左右侧栏宽度是纯 UI 偏好，由页面拖拽、原生 UserDefaults 持久化。
        config.userContentController.add(self, name: "paneLayout")
        // 全局正文搜索：扫描当前 scope 全部会话原文，异步回注命中结果。
        config.userContentController.add(self, name: "search")
        // 会话动作：在终端继续会话 / 导出为 Markdown。
        config.userContentController.add(self, name: "resume")
        config.userContentController.add(self, name: "export")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        if #available(macOS 12.0, *) { webView.underPageBackgroundColor = window.backgroundColor }
        window.contentView = webView

        setupToolbar()
        loadTemplate()

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        reloadInBackground()
        startWatching()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { watcher?.stop(); codexWatcher?.stop() }

    // MARK: - WebView

    private func loadTemplate() {
        guard let url = Bundle.module.url(forResource: "template", withExtension: "html") else {
            webView.loadHTMLString("<h2 style='font-family:sans-serif;padding:40px'>找不到 template.html 资源</h2>", baseURL: nil)
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webReady = true
        injectPaneLayout()
        if pendingInject { pendingInject = false; inject() }
    }

    // MARK: - 数据流

    private func reloadInBackground(changedPaths: [String]? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.reloadInBackground(changedPaths: changedPaths) }
            return
        }

        if let changedPaths {
            pendingChangedSessionIds.formUnion(classifyChangedSessionIds(from: changedPaths))
        } else {
            pendingUnknownReload = true
        }

        let currentScope = scope
        reloadSeq += 1
        let token = reloadSeq
        activeDetailRequestSeq += 1

        if reloadInFlight {
            reloadPending = true
            return
        }

        let changedSessionIds: Set<String>?
        if pendingUnknownReload {
            changedSessionIds = nil
            pendingUnknownReload = false
            pendingChangedSessionIds.removeAll()
        } else {
            changedSessionIds = pendingChangedSessionIds
            pendingChangedSessionIds.removeAll()
        }

        activeReloadSeq = token
        reloadInFlight = true
        loadQueue.async {
            self.store.reload(scopeHint: currentScope)
            DispatchQueue.main.async {
                if token == self.activeReloadSeq && self.scopeSince(currentScope.since, covers: self.scope.since) {
                    self.loaded = true
                    self.loadedSinceDate = currentScope.since.date
                    self.refreshUI(changedSessionIds: changedSessionIds)
                }
                self.finishReload()
            }
        }
    }

    private func finishReload() {
        reloadInFlight = false
        guard reloadPending else { return }

        reloadPending = false
        reloadInBackground(changedPaths: [])
    }

    // 当前摘要缓存是否已覆盖请求的时间范围（覆盖则切换只需内存过滤、无需重扫）。
    private func cacheCovers(_ since: Scope.Since) -> Bool {
        guard loaded else { return false }
        guard let cached = loadedSinceDate else { return true }   // 已缓存全部
        guard let req = since.date else { return false }          // 请求全部、缓存仅部分
        return req >= cached                                       // 请求范围更窄或相等
    }

    private func scopeSince(_ cached: Scope.Since, covers requested: Scope.Since) -> Bool {
        guard let cachedDate = cached.date else { return true }       // 已加载全部
        guard let requestedDate = requested.date else { return false } // 请求全部、缓存仅部分
        return requestedDate >= cachedDate                            // 请求范围更窄或相等
    }

    // 重扫后：若当前选中的项目已不存在则回退到“全部项目”，再重新注入
    //（项目下拉选项由页面从注入的 controls 自行渲染）。
    private func refreshUI(changedSessionIds: Set<String>? = nil) {
        if let p = scope.projectLabel, !store.projectLabels().contains(p) {
            scope.projectLabel = nil
        }
        inject(changedSessionIds: changedSessionIds)
    }

    private func classifyChangedSessionIds(from paths: [String]) -> Set<String> {
        let parser = TranscriptParser(root: store.root)
        return Set(paths.compactMap { path in
            let jsonlPath: String
            if path.hasSuffix(".jsonl") {
                jsonlPath = path
            } else if path.hasSuffix(".meta.json") {
                jsonlPath = String(path.dropLast(".meta.json".count)) + ".jsonl"
            } else {
                return nil
            }
            guard jsonlPath.hasPrefix(store.root) else { return nil }
            return parser.classify(jsonlPath).sessionId
        })
    }

    // 把当前 scope 的摘要 JSON 注入网页；完整详情由页面按需请求。
    private func inject(changedSessionIds: Set<String>? = nil) {
        guard webReady else { pendingInject = true; return }
        let json = store.indexJSON(scope: scope)
        let changedArg = changedSessionIds.map { jsJSONLiteral(Array($0).sorted()) } ?? "null"
        webView.evaluateJavaScript("window.__agentSession && window.__agentSession.loadIndex(\(jsStringLiteral(json)), \(changedArg));",
                                   completionHandler: nil)
    }

    private func clamp(_ value: Int, min minValue: Int, max maxValue: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    private func paneWidths() -> (left: Int, right: Int) {
        let defaults = UserDefaults.standard
        let left = defaults.object(forKey: paneLeftWidthKey) as? Int ?? paneLeftDefault
        let right = defaults.object(forKey: paneRightWidthKey) as? Int ?? paneRightDefault
        return (clamp(left, min: paneLeftMin, max: paneLeftMax),
                clamp(right, min: paneRightMin, max: paneRightMax))
    }

    private func injectPaneLayout() {
        guard webReady else { return }
        let widths = paneWidths()
        webView.evaluateJavaScript(
            "window.__agentSession && window.__agentSession.setPaneLayout && window.__agentSession.setPaneLayout(\(widths.left), \(widths.right));",
            completionHandler: nil)
    }

    private func savePaneLayout(_ body: [String: Any]) {
        guard let leftNumber = body["left"] as? NSNumber,
              let rightNumber = body["right"] as? NSNumber else { return }
        let left = clamp(leftNumber.intValue, min: paneLeftMin, max: paneLeftMax)
        let right = clamp(rightNumber.intValue, min: paneRightMin, max: paneRightMax)
        let defaults = UserDefaults.standard
        defaults.set(left, forKey: paneLeftWidthKey)
        defaults.set(right, forKey: paneRightWidthKey)
    }

    private func loadDetailInBackground(id: String, frontendToken: Int) {
        detailRequestSeq += 1
        let token = detailRequestSeq
        activeDetailRequestSeq = token
        loadQueue.async {
            let json = self.store.detailJSON(id: id)
            DispatchQueue.main.async {
                guard token == self.activeDetailRequestSeq else { return }
                let payload = json.map(jsStringLiteral) ?? "null"
                self.webView.evaluateJavaScript(
                    "window.__agentSession && window.__agentSession.loadDetail(\(jsStringLiteral(id)), \(payload), \(frontendToken));",
                    completionHandler: nil)
            }
        }
    }

    // 全局正文搜索：后台扫描当前 scope，回注最新一次请求的结果（旧请求作废）。
    private func searchInBackground(query: String) {
        searchSeq += 1
        let token = searchSeq
        activeSearchSeq = token
        let currentScope = scope
        loadQueue.async {
            let json = self.store.searchJSON(query: query, scope: currentScope)
            DispatchQueue.main.async {
                guard token == self.activeSearchSeq else { return }
                self.webView.evaluateJavaScript(
                    "window.__agentSession && window.__agentSession.loadSearchResults && window.__agentSession.loadSearchResults(\(jsStringLiteral(json)));",
                    completionHandler: nil)
            }
        }
    }

    // 在终端继续会话：打开 Terminal，cd 到会话目录后运行 claude --resume。
    private func openResumeInTerminal(id: String, cwd: String?, source: String) {
        let dir = (cwd?.isEmpty == false ? cwd! : NSHomeDirectory())
        func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let resumeCmd = source == "codex"
            ? "codex resume \(shellQuote(id))"
            : "claude --resume \(shellQuote(id))"
        let command = "cd \(shellQuote(dir)) && \(resumeCmd)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Terminal\"\n  activate\n  do script \"\(escaped)\"\nend tell"
        guard let apple = NSAppleScript(source: script) else { return }
        var err: NSDictionary?
        apple.executeAndReturnError(&err)
        if let err = err {
            let alert = NSAlert()
            alert.messageText = "无法打开终端继续会话"
            alert.informativeText = (err[NSAppleScript.errorMessage] as? String) ?? "请确认已授权控制「终端」。"
            alert.runModal()
        }
    }

    // 导出 Markdown：前端生成文本，原生弹保存面板写盘。
    private func saveMarkdown(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if let md = UTType(filenameExtension: "md") { panel.allowedContentTypes = [md] }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func startWatching() {
        watcher = FileWatcher(path: store.root) { [weak self] paths in
            self?.reloadInBackground(changedPaths: paths)
        }
        watcher?.start()
        // Codex 根：变更路径无法用 Claude 的目录分类还原 sessionId，直接触发一次全量重扫
        //（增量摘要缓存仍会跳过未变文件，成本可控）。
        if let codexRoot {
            codexWatcher = FileWatcher(path: codexRoot) { [weak self] _ in
                self?.reloadInBackground()
            }
            codexWatcher?.start()
        }
    }

    // MARK: - 工具栏

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: "AgentSessionToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        if #available(macOS 11.0, *) { window.toolbarStyle = .unified }
        window.toolbar = toolbar
    }

    private let idRefresh = NSToolbarItem.Identifier("refresh")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, idRefresh]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [idRefresh, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case idRefresh:
            let btn = NSButton(title: "刷新", target: self, action: #selector(refresh))
            btn.bezelStyle = .texturedRounded
            item.label = "刷新"; item.view = btn
        default:
            return nil
        }
        return item
    }

    // MARK: - Actions

    @objc func refresh() { reloadInBackground() }

    @objc func showAbout() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "未知"
        let build = info["CFBundleVersion"] as? String ?? "未知"

        let alert = NSAlert()
        alert.messageText = "AgentSession"
        alert.informativeText = "Version \(version) (\(build))\n\nGitHub 项目：\n\(Self.repositoryURL.absoluteString)"
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "打开 GitHub")
        alert.addButton(withTitle: "关闭")

        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.repositoryURL)
        }
    }

    // 侧栏下拉回调：{ since, project } → 更新 scope → 重新加载摘要索引。
    // 详情页通过 sessionDetail 按需请求完整 turns / subagents。
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if message.name == "scope" {
            if let s = body["since"] as? String, let v = Scope.Since(rawValue: s) { scope.since = v }
            scope.projectLabel = body["project"] as? String   // null / 缺省 → nil（全部项目）
            if let limit = (body["limit"] as? NSNumber)?.intValue {
                // 「加载更多」：仅扩大分页上限，复用内存里的摘要重新注入，无需重扫磁盘。
                scope.maxSessions = limit
                inject()
            } else {
                // 时间 / 项目筛选变化：重置分页。缓存已覆盖该范围则只内存过滤+注入，
                // 否则重扫（仅在请求更旧数据时发生）。
                scope.maxSessions = Scope.defaultMaxSessions
                if cacheCovers(scope.since) { inject() } else { reloadInBackground() }
            }
        } else if message.name == "sessionDetail", let id = body["id"] as? String {
            let token = (body["token"] as? NSNumber)?.intValue ?? 0
            loadDetailInBackground(id: id, frontendToken: token)
        } else if message.name == "paneLayout" {
            savePaneLayout(body)
        } else if message.name == "search", let query = body["query"] as? String {
            searchInBackground(query: query)
        } else if message.name == "resume", let id = body["id"] as? String {
            openResumeInTerminal(id: id, cwd: body["cwd"] as? String,
                                 source: (body["source"] as? String) ?? "claude")
        } else if message.name == "export", let markdown = body["markdown"] as? String {
            saveMarkdown(markdown, suggestedName: (body["filename"] as? String) ?? "session.md")
        }
    }
    @objc func toggleInfo() {
        webView.evaluateJavaScript(
            "window.__agentSession && window.__agentSession.toggleInfo && window.__agentSession.toggleInfo();",
            completionHandler: nil)
    }
}

// 把 JSON 文本安全编码成可嵌入 JS 源码的字符串字面量。
private func jsStringLiteral(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]),
          var lit = String(data: data, encoding: .utf8) else { return "\"\"" }
    lit = lit.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
             .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return lit
}

private func jsJSONLiteral(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object),
          var lit = String(data: data, encoding: .utf8) else { return "null" }
    lit = lit.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
             .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    return lit
}

// 命令行启动的 app 没有默认菜单，手动建一个，让 ⌘Q / ⌘R 与复制/全选可用。
func buildMainMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    let about = NSMenuItem(title: "关于 AgentSession",
                           action: #selector(AppDelegate.showAbout),
                           keyEquivalent: "")
    about.target = target
    appMenu.addItem(about)
    appMenu.addItem(.separator())

    let reload = NSMenuItem(title: "刷新", action: #selector(AppDelegate.refresh), keyEquivalent: "r")
    reload.target = target
    appMenu.addItem(reload)
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 AgentSession",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    return main
}
