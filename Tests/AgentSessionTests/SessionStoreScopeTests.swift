import XCTest
@testable import AgentSession

final class SessionStoreScopeTests: XCTestCase {
    func testProjectLabelsOnlyIncludeLoadedTimeRange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionTests-")
            .appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: root) }

        try writeTranscript(root: root, project: "-Users-madroid-dev-active", session: "active", timestamp: isoString(Date()))
        try writeTranscript(root: root, project: "-Users-madroid-dev-old", session: "old", timestamp: "2000-01-01T00:00:00.000Z")

        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .d7
        store.reload(scopeHint: scope)

        XCTAssertEqual(store.projectLabels(), ["dev-active"])
    }

    private func writeTranscript(root: String, project: String, session: String, timestamp: String) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(session).jsonl")
        let row: [String: Any] = [
            "uuid": "\(project)-\(session)",
            "type": "user",
            "timestamp": timestamp,
            "message": ["content": "hello from \(session)"],
        ]
        let data = try JSONSerialization.data(withJSONObject: row)
        let line = String(decoding: data, as: UTF8.self) + "\n"
        try line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
