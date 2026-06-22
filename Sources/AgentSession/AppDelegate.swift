import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate,
                         NSToolbarDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private let store: SessionStore
    private var watcher: FileWatcher?

    private var scope = Scope()
    private var webReady = false
    private var pendingInject = false

    override init() {
        let root = ("~/.claude/projects" as NSString).expandingTildeInPath
        store = SessionStore(root: root)
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
        // 侧栏的时间范围 / 项目下拉通过这条桥回调，更新 scope 后重新过滤注入。
        config.userContentController.add(self, name: "scope")

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
    func applicationWillTerminate(_ notification: Notification) { watcher?.stop() }

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
        if pendingInject { pendingInject = false; inject() }
    }

    // MARK: - 数据流

    private func reloadInBackground() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.store.reload()
            DispatchQueue.main.async { self.refreshUI() }
        }
    }

    // 重扫后：若当前选中的项目已不存在则回退到“全部项目”，再重新注入
    //（项目下拉选项由页面从注入的 controls 自行渲染）。
    private func refreshUI() {
        if let p = scope.projectLabel, !store.projectLabels().contains(p) {
            scope.projectLabel = nil
        }
        inject()
    }

    // 把当前 scope 的 JSON 注入网页（仅内存过滤，秒级）。
    private func inject() {
        guard webReady else { pendingInject = true; return }
        let json = store.json(scope: scope)
        webView.evaluateJavaScript("window.__agentSession && window.__agentSession.load(\(jsStringLiteral(json)));",
                                   completionHandler: nil)
    }

    private func startWatching() {
        watcher = FileWatcher(path: store.root) { [weak self] in self?.reloadInBackground() }
        watcher?.start()
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

    // 侧栏下拉回调：{ since, project } → 更新 scope → 重新过滤注入。
    // 「详细」已是页内按钮（直接调 JS），不再走原生。
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "scope", let body = message.body as? [String: Any] else { return }
        if let s = body["since"] as? String, let v = Scope.Since(rawValue: s) { scope.since = v }
        scope.projectLabel = body["project"] as? String   // null / 缺省 → nil（全部项目）
        inject()
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

// 命令行启动的 app 没有默认菜单，手动建一个，让 ⌘Q / ⌘R 与复制/全选可用。
func buildMainMenu(target: AppDelegate) -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
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
