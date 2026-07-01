import XCTest
@testable import AgentSession

final class CodexParserTests: XCTestCase {
    private func tempRoot() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessionCodex-")
            .appendingPathComponent(UUID().uuidString).path
    }

    // 造一个最小 Codex rollout：session_meta + 用户消息(含噪声) + 思考 + 助手文本 +
    // exec_command 调用与输出 + token_count。
    private func writeRollout(root: String, day: String, file: String,
                             sessionId: String, cwd: String) throws -> String {
        let dir = (root as NSString).appendingPathComponent(day)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent(file)
        let rows: [[String: Any]] = [
            ["timestamp": "2026-06-01T00:00:00.000Z", "type": "session_meta",
             "payload": ["session_id": sessionId, "cwd": cwd,
                         "base_instructions": String(repeating: "x", count: 20000)]],
            // 噪声：环境上下文，应被过滤
            ["timestamp": "2026-06-01T00:00:01.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "<environment_context><cwd>\(cwd)</cwd></environment_context>"]]]],
            // 真实用户输入
            ["timestamp": "2026-06-01T00:00:02.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "user",
                         "content": [["type": "input_text", "text": "帮我看下项目结构"]]]],
            // 明文思考（event_msg）
            ["timestamp": "2026-06-01T00:00:03.000Z", "type": "event_msg",
             "payload": ["type": "agent_reasoning", "text": "**Inspecting layout**"]],
            // 助手文本（response_item）
            ["timestamp": "2026-06-01T00:00:04.000Z", "type": "response_item",
             "payload": ["type": "message", "role": "assistant",
                         "content": [["type": "output_text", "text": "好的，我先列一下目录。"]]]],
            // 与助手文本重复投影的 event_msg，应被跳过（不计入）
            ["timestamp": "2026-06-01T00:00:04.100Z", "type": "event_msg",
             "payload": ["type": "agent_message", "message": "好的，我先列一下目录。"]],
            // 工具调用 + 输出
            ["timestamp": "2026-06-01T00:00:05.000Z", "type": "response_item",
             "payload": ["type": "function_call", "name": "exec_command",
                         "call_id": "call_1", "arguments": "{\"cmd\":\"ls\",\"workdir\":\"\(cwd)\"}"]],
            ["timestamp": "2026-06-01T00:00:06.000Z", "type": "response_item",
             "payload": ["type": "function_call_output", "call_id": "call_1",
                         "output": "src\nREADME.md\n"]],
            ["timestamp": "2026-06-01T00:00:07.000Z", "type": "event_msg",
             "payload": ["type": "token_count",
                         "info": ["total_token_usage":
                                    ["input_tokens": 1000, "cached_input_tokens": 400, "output_tokens": 120]]]],
        ]
        let lines = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func testClassifyReadsSessionMetaWithLargeFirstLine() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let id = "019e0000-0000-7000-8000-000000000001"
        let path = try writeRollout(root: root, day: "2026/06/01",
                                    file: "rollout-2026-06-01T00-00-00-\(id).jsonl",
                                    sessionId: id, cwd: "/Users/x/dev/demo")
        let info = CodexParser(root: root).classify(path)
        XCTAssertEqual(info.source, "codex")
        XCTAssertEqual(info.sessionId, id)
        // 项目归属来自 cwd（首行超 8KB 时仍能读到）。
        XCTAssertEqual(info.project, "-Users-x-dev-demo")
    }

    func testParseFileProducesAlignedTurns() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let id = "019e0000-0000-7000-8000-000000000002"
        let path = try writeRollout(root: root, day: "2026/06/01",
                                    file: "rollout-2026-06-01T00-00-00-\(id).jsonl",
                                    sessionId: id, cwd: "/Users/x/dev/demo")
        let p = CodexParser(root: root).parseFile(path)

        // 噪声用户消息被过滤，只保留 1 条真实输入。
        XCTAssertEqual(p.numUser, 1)
        XCTAssertEqual(p.numAssistant, 1)
        XCTAssertEqual(p.numTools, 1)
        XCTAssertEqual(p.cwd, "/Users/x/dev/demo")

        let kinds = p.turns.map { "\($0["role"] as? String ?? "")/\($0["kind"] as? String ?? "")" }
        XCTAssertEqual(kinds, ["user/message", "assistant/thinking", "assistant/text",
                               "assistant/tool_use", "tool/tool_result"])

        // tool_use 与 tool_result 通过 call_id 配对。
        let toolUse = p.turns[3]
        let toolRes = p.turns[4]
        XCTAssertEqual(toolUse["id"] as? String, "call_1")
        XCTAssertEqual(toolUse["summary"] as? String, "ls")
        XCTAssertEqual(toolRes["tool_use_id"] as? String, "call_1")

        // 用量：input 含 cached，uncached = 1000-400。
        XCTAssertEqual(p.usage.inputUncached, 600)
        XCTAssertEqual(p.usage.cacheRead, 400)
        XCTAssertEqual(p.usage.output, 120)
    }

    func testStoreLoadsCodexAlongsideClaude() throws {
        let claudeRoot = tempRoot()
        let codexRoot = tempRoot()
        defer {
            try? FileManager.default.removeItem(atPath: claudeRoot)
            try? FileManager.default.removeItem(atPath: codexRoot)
        }
        // Claude 侧一条 transcript
        let cdir = (claudeRoot as NSString).appendingPathComponent("-Users-x-dev-a")
        try FileManager.default.createDirectory(atPath: cdir, withIntermediateDirectories: true)
        let crow: [String: Any] = ["uuid": "c1", "type": "user",
                                   "timestamp": "2026-06-01T00:00:00.000Z",
                                   "message": ["content": "claude side"]]
        try (String(decoding: try JSONSerialization.data(withJSONObject: crow), as: UTF8.self) + "\n")
            .write(toFile: (cdir as NSString).appendingPathComponent("claudesess.jsonl"),
                   atomically: true, encoding: .utf8)
        // Codex 侧一条 rollout
        let id = "019e0000-0000-7000-8000-000000000003"
        _ = try writeRollout(root: codexRoot, day: "2026/06/01",
                             file: "rollout-2026-06-01T00-00-00-\(id).jsonl",
                             sessionId: id, cwd: "/Users/x/dev/demo")

        let store = SessionStore(claudeRoot: claudeRoot, codexRoot: codexRoot)
        var scope = Scope(); scope.since = .all
        store.reload(scopeHint: scope)

        let claude = store.summaries.first { $0.source == "claude" }
        let codex = store.summaries.first { $0.source == "codex" }
        XCTAssertNotNil(claude)
        XCTAssertNotNil(codex)
        XCTAssertEqual(codex?.id, id)
        XCTAssertEqual(codex?.preview, "帮我看下项目结构")

        // 详情按 source 路由到 CodexParser，正确产出对齐的 turns。
        let detail = store.detailJSON(id: id)
        XCTAssertNotNil(detail)
        XCTAssertTrue(detail!.contains("\"source\":\"codex\""))
        XCTAssertTrue(detail!.contains("tool_use"))
    }
}
