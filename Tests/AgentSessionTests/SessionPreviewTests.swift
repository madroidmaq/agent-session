import XCTest
@testable import AgentSession

final class SessionPreviewTests: XCTestCase {
    func testSessionIndexSummaryWinsForIndexAndDetailPreview() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let project = "-Users-madroid-dev-active"
        try writeTranscript(root: root, project: project, session: "session-1", text: "first user prompt")
        try writeSessionIndex(root: root, project: project, entries: [
            ["sessionId": "session-1", "summary": "  Summary title\nfrom index  "],
        ])

        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .all
        store.reload(scopeHint: scope)

        XCTAssertEqual(try firstPreview(in: store.indexJSON(scope: scope)), "Summary title from index")
        XCTAssertEqual(try preview(inDetailJSON: XCTUnwrap(store.detailJSON(id: "session-1"))), "Summary title from index")
    }

    func testBlankSessionIndexSummaryFallsBackToFirstPrompt() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let project = "-Users-madroid-dev-active"
        try writeTranscript(root: root, project: project, session: "session-1", text: "first user prompt")
        try writeSessionIndex(root: root, project: project, entries: [
            ["sessionId": "session-1", "summary": " \n\t "],
        ])

        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .all
        store.reload(scopeHint: scope)

        XCTAssertEqual(try firstPreview(in: store.indexJSON(scope: scope)), "first user prompt")
        XCTAssertEqual(try preview(inDetailJSON: XCTUnwrap(store.detailJSON(id: "session-1"))), "first user prompt")
    }

    func testLongSessionIndexSummaryIsTruncatedLikePreview() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let project = "-Users-madroid-dev-active"
        let longSummary = String(repeating: "a", count: 200)
        try writeTranscript(root: root, project: project, session: "session-1", text: "first user prompt")
        try writeSessionIndex(root: root, project: project, entries: [
            ["sessionId": "session-1", "summary": longSummary],
        ])

        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .all
        store.reload(scopeHint: scope)

        XCTAssertEqual(try firstPreview(in: store.indexJSON(scope: scope)), String(repeating: "a", count: 157) + "…")
    }

    func testWorktreePreviewPrefersRawProjectSessionIndex() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let baseProject = "-Users-madroid-dev-active"
        let rawProject = "\(baseProject)--claude-worktrees-feature-title"
        try writeTranscript(root: root, project: rawProject, session: "session-1", text: "first user prompt")
        try writeSessionIndex(root: root, project: baseProject, entries: [
            ["sessionId": "session-1", "summary": "base summary"],
        ])
        try writeSessionIndex(root: root, project: rawProject, entries: [
            ["sessionId": "session-1", "summary": "raw summary"],
        ])

        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .all
        store.reload(scopeHint: scope)

        XCTAssertEqual(try firstPreview(in: store.indexJSON(scope: scope)), "raw summary")
    }

    private func temporaryRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionTests-")
            .appendingPathComponent(UUID().uuidString).path
    }

    private func writeTranscript(root: String, project: String, session: String, text: String) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(session).jsonl")
        let row: [String: Any] = [
            "uuid": "\(project)-\(session)",
            "type": "user",
            "timestamp": isoString(Date()),
            "message": ["content": text],
        ]
        let data = try JSONSerialization.data(withJSONObject: row)
        try (String(decoding: data, as: UTF8.self) + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func writeSessionIndex(root: String, project: String, entries: [[String: Any]]) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("sessions-index.json")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
        try data.write(to: URL(fileURLWithPath: path))
    }

    private func firstPreview(in indexJSON: String) throws -> String? {
        let obj = try decodedObject(indexJSON)
        let sessions = try XCTUnwrap(obj["sessions"] as? [[String: Any]])
        let first = try XCTUnwrap(sessions.first)
        return first["preview"] as? String
    }

    private func preview(inDetailJSON detailJSON: String) throws -> String? {
        try decodedObject(detailJSON)["preview"] as? String
    }

    private func decodedObject(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
