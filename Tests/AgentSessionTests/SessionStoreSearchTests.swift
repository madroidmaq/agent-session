import XCTest
@testable import AgentSession

final class SessionStoreSearchTests: XCTestCase {
    private func tempRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionSearch-")
            .appendingPathComponent(UUID().uuidString).path
    }

    private func write(root: String, project: String, session: String, text: String) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(session).jsonl")
        let row: [String: Any] = [
            "uuid": "\(session)-1", "type": "user", "timestamp": isoString(Date()),
            "message": ["content": text],
        ]
        let data = try JSONSerialization.data(withJSONObject: row)
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func decode(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testFindsSessionsContainingQueryInBody() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root: root, project: "-Users-x-dev-a", session: "a", text: "let us talk about quantum entanglement here")
        try write(root: root, project: "-Users-x-dev-b", session: "b", text: "completely unrelated grocery list")

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)

        let result = try decode(store.searchJSON(query: "Quantum", scope: scope))   // 大小写不敏感
        XCTAssertEqual(result["count"] as? Int, 1)
        let sessions = try XCTUnwrap(result["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["id"] as? String, "a")
        let snippet = try XCTUnwrap(sessions.first?["snippet"] as? String)
        XCTAssertTrue(snippet.lowercased().contains("quantum"))
    }

    func testEmptyQueryReturnsNothing() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root: root, project: "-Users-x-dev-a", session: "a", text: "hello world")

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)

        let result = try decode(store.searchJSON(query: "   ", scope: scope))
        XCTAssertEqual(result["count"] as? Int, 0)
    }

    func testRespectsProjectScope() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root: root, project: "-Users-x-dev-a", session: "a", text: "shared keyword apple")
        try write(root: root, project: "-Users-x-dev-b", session: "b", text: "shared keyword apple")

        let store = SessionStore(root: root)
        var scope = Scope(); scope.since = .all
        scope.projectLabel = "dev-a"
        store.reload(scopeHint: scope)

        let result = try decode(store.searchJSON(query: "apple", scope: scope))
        XCTAssertEqual(result["count"] as? Int, 1)
        let sessions = try XCTUnwrap(result["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions.first?["id"] as? String, "a")
    }
}
