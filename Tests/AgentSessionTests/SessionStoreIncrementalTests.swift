import XCTest
@testable import AgentSession

final class SessionStoreIncrementalTests: XCTestCase {
    private func tempRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionInc-")
            .appendingPathComponent(UUID().uuidString).path
    }

    // 写一个含 N 条 user 消息的 transcript，uuid 形如 "<session>-<i>"，便于制造跨文件重复。
    private func writeTranscript(root: String, project: String, session: String,
                                 uuids: [String], baseTs: String) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(session).jsonl")
        var lines: [String] = []
        for u in uuids {
            let row: [String: Any] = [
                "uuid": u, "type": "user", "timestamp": baseTs,
                "message": ["content": "msg \(u)"],
            ]
            let data = try JSONSerialization.data(withJSONObject: row)
            lines.append(String(decoding: data, as: UTF8.self))
        }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func stats(_ store: SessionStore, _ id: String) -> (Int, Int, Int)? {
        guard let s = store.summaries.first(where: { $0.id == id }) else { return nil }
        return (s.numUser, s.numAssistant, s.numTools)
    }

    func testCacheHitMatchesColdParse() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ts = isoString(Date())
        try writeTranscript(root: root, project: "-Users-x-dev-a", session: "a",
                            uuids: ["a-1", "a-2", "a-3"], baseTs: ts)

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)
        let first = stats(store, "a")

        // 第二次 reload：无文件变化，应命中缓存，结果完全一致。
        store.reload(scopeHint: scope)
        XCTAssertEqual(first?.0, stats(store, "a")?.0)
        XCTAssertEqual(first?.0, 3)
    }

    func testChangeIsPickedUpAfterCache() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ts = isoString(Date())
        try writeTranscript(root: root, project: "-Users-x-dev-a", session: "a",
                            uuids: ["a-1", "a-2"], baseTs: ts)

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)
        XCTAssertEqual(stats(store, "a")?.0, 2)

        // 追加内容后重写：mtime/size 变化应使缓存失效，反映新内容。
        try writeTranscript(root: root, project: "-Users-x-dev-a", session: "a",
                            uuids: ["a-1", "a-2", "a-3", "a-4"], baseTs: ts)
        store.reload(scopeHint: scope)
        XCTAssertEqual(stats(store, "a")?.0, 4)
    }

    // resume：会话 b 重放了 a 的 uuid。跨文件去重应让 b 不重复计入 a 的条目。
    // 增量缓存（第二次 reload）必须保持同样的去重结果。
    func testCrossFileDedupPreservedAcrossCache() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let ts = isoString(Date())
        // 排序后 "a" 在 "b" 之前，a 拥有 a-1/a-2；b 重放 a-1/a-2 再加自己的 b-1。
        try writeTranscript(root: root, project: "-Users-x-dev-p", session: "a",
                            uuids: ["a-1", "a-2"], baseTs: ts)
        try writeTranscript(root: root, project: "-Users-x-dev-p", session: "b",
                            uuids: ["a-1", "a-2", "b-1"], baseTs: ts)

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)
        // b 去重后只剩 b-1 这一条 user。
        let coldB = stats(store, "b")?.0
        XCTAssertEqual(coldB, 1)
        XCTAssertEqual(stats(store, "a")?.0, 2)

        // 第二次 reload：a、b 均命中缓存，去重结果须不变。
        store.reload(scopeHint: scope)
        XCTAssertEqual(stats(store, "b")?.0, coldB)
        XCTAssertEqual(stats(store, "a")?.0, 2)
    }
}
