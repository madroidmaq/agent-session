import XCTest
@testable import AgentSession

final class SearchIndexTests: XCTestCase {
    private var dbPath: String!
    private var index: SearchIndex!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchIndexTests-\(UUID().uuidString).db").path
        index = SearchIndex(dbPath: dbPath)
        XCTAssertNotNil(index)
    }

    override func tearDown() {
        index = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    private func entry(_ path: String, mtime: Date = Date(), size: Int = 1,
                       text: String) -> SearchIndex.Entry {
        SearchIndex.Entry(path: path, mtime: mtime, size: size) { text }
    }

    // 测试均在 waitForPendingSync 后调用，索引 ready 返回非 nil，强制解包。
    private func search(_ q: String) -> [String: String] { index.search(q)! }

    func testBasicSubstringSearch() {
        index.scheduleSync([
            entry("/a", text: "hello AgentSession world"),
            entry("/b", text: "nothing to see here"),
        ])
        index.waitForPendingSync()

        let hits = search("agentsession")   // 大小写不敏感
        XCTAssertEqual(Array(hits.keys), ["/a"])
        XCTAssertTrue(hits["/a"]!.contains("AgentSession"))
        // 词中缀也能命中（trigram 子串语义，与原线性 grep 一致）
        XCTAssertEqual(Array(search("gentSess").keys), ["/a"])
        XCTAssertTrue(search("missing-term").isEmpty)
    }

    func testCJKSearch() {
        index.scheduleSync([
            entry("/a", text: "支持加载 Codex 会话记录，来源用官方图标区分"),
            entry("/b", text: "no chinese content"),
        ])
        index.waitForPendingSync()

        XCTAssertEqual(Array(search("会话记录").keys), ["/a"])   // ≥3 字符走 MATCH
        XCTAssertEqual(Array(search("会话").keys), ["/a"])       // <3 字符走 LIKE
    }

    func testShortQueryLike() {
        index.scheduleSync([
            entry("/a", text: "percent 100% done"),
            entry("/b", text: "plain text"),
        ])
        index.waitForPendingSync()

        XCTAssertEqual(Array(search("0%").keys), ["/a"])   // LIKE 通配符需转义
        let ascii = search("PL")
        XCTAssertEqual(Array(ascii.keys), ["/b"])                // 短查询 ASCII 大小写不敏感
    }

    func testIncrementalUpdateAndDelete() {
        let t1 = Date(timeIntervalSince1970: 1000)
        index.scheduleSync([
            entry("/a", mtime: t1, size: 10, text: "alpha-token"),
            entry("/b", mtime: t1, size: 10, text: "beta-token"),
        ])
        index.waitForPendingSync()
        XCTAssertEqual(Array(search("alpha-token").keys), ["/a"])

        // mtime/size 未变 → 不重建（extractText 不应被调用）
        var extracted = false
        index.scheduleSync([
            SearchIndex.Entry(path: "/a", mtime: t1, size: 10) { extracted = true; return "changed" },
            entry("/b", mtime: t1, size: 10, text: "beta-token"),
        ])
        index.waitForPendingSync()
        XCTAssertFalse(extracted)
        XCTAssertEqual(Array(search("alpha-token").keys), ["/a"])

        // 文件变化 → 重建；文件消失 → 移除
        let t2 = Date(timeIntervalSince1970: 2000)
        index.scheduleSync([
            entry("/a", mtime: t2, size: 20, text: "gamma-token"),
        ])
        index.waitForPendingSync()
        XCTAssertTrue(search("alpha-token").isEmpty)
        XCTAssertEqual(Array(search("gamma-token").keys), ["/a"])
        XCTAssertTrue(search("beta-token").isEmpty)
    }

    func testPersistenceAcrossReopen() {
        index.scheduleSync([entry("/a", text: "durable-content")])
        index.waitForPendingSync()
        index = nil

        let reopened = SearchIndex(dbPath: dbPath)
        XCTAssertNotNil(reopened)
        XCTAssertEqual(Array(reopened!.search("durable-content")!.keys), ["/a"])
        index = reopened
    }

    func testSearchableTextExtraction() {
        var parsed = ParsedFile()
        parsed.turns = [
            ["role": "user", "kind": "message", "text": ["text": "用户提问内容", "clipped": false]],
            ["role": "user", "kind": "slash", "cmd": "commit", "text": "", "args": ["text": "参数文本", "clipped": false]],
            ["role": "assistant", "kind": "text", "text": ["text": "assistant reply", "clipped": false]],
            ["role": "assistant", "kind": "tool_use", "name": "Bash", "summary": "ls -la",
             "input": ["command": "ls -la"]],
            ["role": "tool", "kind": "tool_result", "content": ["text": "total 42", "clipped": false]],
        ]
        let text = searchableText(parsed)
        for expected in ["用户提问内容", "/commit", "参数文本", "assistant reply", "Bash", "ls -la", "total 42"] {
            XCTAssertTrue(text.contains(expected), "missing: \(expected)")
        }
    }

    // 索引未 ready（空库、从未同步）时 search 返回 nil，调用方据此回退线性扫描，
    // 避免空索引导致搜索 0 命中。
    func testSearchReturnsNilUntilSynced() {
        XCTAssertNil(index.search("anything"))        // 空 db → nil，触发回退
        index.scheduleSync([entry("/a", text: "ready now")])
        index.waitForPendingSync()
        XCTAssertEqual(Array(search("ready now").keys), ["/a"])
    }
}
