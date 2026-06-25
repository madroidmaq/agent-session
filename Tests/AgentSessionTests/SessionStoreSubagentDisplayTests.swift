import XCTest
@testable import AgentSession

final class SessionStoreSubagentDisplayTests: XCTestCase {
    func testSubagentDisplayMetadataComesFromParentTool() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let project = "-Users-madroid-dev-active"
        let session = "session-1"
        let parentTs = "2026-06-25T10:00:00.000Z"
        let subFirstTs = "2026-06-25T10:00:12.000Z"
        try writeMainTranscriptWithAgentTool(root: root, project: project, session: session,
                                             agentId: "a123", parentTs: parentTs,
                                             subagentType: "Explore",
                                             description: "实现开发者模式 Foundation")
        try writeSubagentTranscript(root: root, project: project, session: session,
                                    fileBase: "agent-a123", firstTs: subFirstTs,
                                    text: "subagent prompt")

        let detail = try detailObject(root: root, session: session)
        let subagent = try firstAttachedSubagent(in: detail)

        XCTAssertEqual(subagent["agent_name"] as? String, "Explore")
        XCTAssertEqual(subagent["agent_description"] as? String, "实现开发者模式 Foundation")
        XCTAssertEqual(subagent["created_ts"] as? String, parentTs)
        XCTAssertEqual(subagent["parent_ts"] as? String, parentTs)
        XCTAssertEqual(subagent["label"] as? String, "Explore")
    }

    func testOrphanSubagentFallsBackToFirstTsAndOrphanLabel() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let project = "-Users-madroid-dev-active"
        let session = "session-1"
        let firstTs = "2026-06-25T10:01:00.000Z"
        try writeMainTranscript(root: root, project: project, session: session,
                                rows: [userRow(uuid: "main-user", timestamp: "2026-06-25T10:00:00.000Z", text: "main prompt")])
        try writeSubagentTranscript(root: root, project: project, session: session,
                                    fileBase: "agent-orphan", firstTs: firstTs,
                                    text: "orphan prompt", agentType: "Explore")

        let detail = try detailObject(root: root, session: session)
        let orphans = try XCTUnwrap(detail["orphan_subagents"] as? [[String: Any]])
        let orphan = try XCTUnwrap(orphans.first)

        XCTAssertEqual(orphan["agent_name"] as? String, "Explore")
        XCTAssertEqual(orphan["created_ts"] as? String, firstTs)
        XCTAssertEqual(orphan["label"] as? String, "Explore (orphan)")
        XCTAssertTrue(orphan["agent_description"] is NSNull)
    }

    private func detailObject(root: String, session: String) throws -> [String: Any] {
        let store = SessionStore(root: root)
        var scope = Scope()
        scope.since = .all
        store.reload(scopeHint: scope)
        let json = try XCTUnwrap(store.detailJSON(id: session))
        return try decodedObject(json)
    }

    private func firstAttachedSubagent(in detail: [String: Any]) throws -> [String: Any] {
        let turns = try XCTUnwrap(detail["turns"] as? [[String: Any]])
        for turn in turns {
            if let subagents = turn["subagents"] as? [[String: Any]], let first = subagents.first {
                return first
            }
        }
        XCTFail("Expected an attached subagent")
        return [:]
    }

    private func temporaryRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionTests-")
            .appendingPathComponent(UUID().uuidString).path
    }

    private func writeMainTranscriptWithAgentTool(root: String, project: String, session: String,
                                                  agentId: String, parentTs: String,
                                                  subagentType: String, description: String) throws {
        let toolUseId = "toolu-agent"
        let toolUse: [String: Any] = [
            "uuid": "main-agent-tool",
            "type": "assistant",
            "timestamp": parentTs,
            "message": [
                "content": [[
                    "type": "tool_use",
                    "id": toolUseId,
                    "name": "Agent",
                    "input": [
                        "subagent_type": subagentType,
                        "description": description,
                        "prompt": "run subagent",
                    ],
                ]],
            ],
        ]
        let toolResult: [String: Any] = [
            "uuid": "main-agent-result",
            "type": "user",
            "timestamp": parentTs,
            "toolUseResult": ["agentId": agentId],
            "message": [
                "content": [[
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": "subagent finished",
                ]],
            ],
        ]
        try writeMainTranscript(root: root, project: project, session: session, rows: [toolUse, toolResult])
    }

    private func writeSubagentTranscript(root: String, project: String, session: String,
                                         fileBase: String, firstTs: String, text: String,
                                         agentType: String? = nil) throws {
        let projectDir = (root as NSString).appendingPathComponent(project)
        let sessionDir = (projectDir as NSString).appendingPathComponent(session)
        let dir = (sessionDir as NSString).appendingPathComponent("subagents")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(fileBase).jsonl")
        try writeRows([userRow(uuid: "\(fileBase)-user", timestamp: firstTs, text: text)], to: path)
        if let agentType {
            let metaPath = (dir as NSString).appendingPathComponent("\(fileBase).meta.json")
            let data = try JSONSerialization.data(withJSONObject: ["agentType": agentType])
            try data.write(to: URL(fileURLWithPath: metaPath))
        }
    }

    private func writeMainTranscript(root: String, project: String, session: String,
                                     rows: [[String: Any]]) throws {
        let dir = (root as NSString).appendingPathComponent(project)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(session).jsonl")
        try writeRows(rows, to: path)
    }

    private func userRow(uuid: String, timestamp: String, text: String) -> [String: Any] {
        [
            "uuid": uuid,
            "type": "user",
            "timestamp": timestamp,
            "message": ["content": text],
        ]
    }

    private func writeRows(_ rows: [[String: Any]], to path: String) throws {
        let lines = try rows.map { row -> String in
            let data = try JSONSerialization.data(withJSONObject: row)
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n") + "\n"
        try lines.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func decodedObject(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
