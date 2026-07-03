import Foundation

// SessionStore 需要的最小解析能力抽象。Claude / Codex 各自实现，产出同一套
// ParsedFile / ParsedSummary（turns schema 与 template.html 对齐）。
protocol TranscriptParsing: AnyObject {
    var root: String { get }
    func walk() -> [String]
    func classify(_ path: String) -> FileInfo
    func parseSummaryFile(_ path: String) -> ParsedSummary
    func parseFile(_ path: String) -> ParsedFile
}

// Codex CLI/Desktop 的 rollout 记录解析器。
// 目录布局：<root>/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl（无项目编码目录、无 subagent、
// 无 sessions-index）。项目归属来自 session_meta.cwd。
//
// 行结构是 { timestamp, type, payload }，两套并行表示：
//   - response_item：API 级规范记录（message / function_call / function_call_output /
//     custom_tool_call(+output) / web_search_call / reasoning(加密)）—— 对话主干取自这里。
//   - event_msg：UI 事件流（agent_message / user_message 是 response_item 的重复投影，
//     跳过；agent_reasoning 是明文思考，response_item.reasoning 是加密的，故思考取自这里；
//     token_count 提供累计用量）。
final class CodexParser: TranscriptParsing {
    let root: String
    init(root: String) { self.root = root }

    func walk() -> [String] { TranscriptParser.walk(root) }

    // session_meta 在首行，携带 session_id + cwd；据此确定会话 id 与项目归属。
    func classify(_ path: String) -> FileInfo {
        let meta = firstSessionMeta(path)
        let sessionId = (meta?["session_id"] as? String)
            ?? (meta?["id"] as? String)
            ?? sessionIdFromFilename(path)
        let cwd = meta?["cwd"] as? String
        let rawProject = cwd.map(cwdToProjectDir) ?? "codex"
        return FileInfo(project: rawProject, rawProject: rawProject,
                        worktreeName: nil, sessionId: sessionId, kind: .main, source: "codex")
    }

    // session_meta 是首行，但其 base_instructions 可长达数 KB —— 必须完整读第一行
    //（按固定字节截断会切断 UTF-8 序列导致整体解码失败）。
    private func firstSessionMeta(_ path: String) -> [String: Any]? {
        guard let line = readFirstLine(path), let data = line.data(using: .utf8),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              e["type"] as? String == "session_meta",
              let p = e["payload"] as? [String: Any] else { return nil }
        return p
    }

    private func readFirstLine(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        while buffer.count < 1_048_576 {   // 上限 1MB，避免异常无换行文件读爆内存
            guard let chunk = try? handle.read(upToCount: 16_384), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let idx = buffer.firstIndex(of: newline) {
                return String(data: buffer[..<idx], encoding: .utf8)
            }
        }
        return String(data: buffer, encoding: .utf8)
    }

    private func sessionIdFromFilename(_ path: String) -> String {
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        if let id = firstGroup(base, #"([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$"#) {
            return id
        }
        return base
    }

    // MARK: - 摘要解析（首屏轻量）

    func parseSummaryFile(_ path: String) -> ParsedSummary {
        var p = ParsedSummary()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return p }
        var usage = Usage()
        var maxContext = 0
        var hasPreview = false

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let e = parseLine(line) else { continue }
            let payload = e["payload"] as? [String: Any]
            applyCommon(e, payload: payload, cwd: &p.cwd, firstTs: &p.firstTs, lastTs: &p.lastTs)
            let type = e["type"] as? String
            guard let pt = payload?["type"] as? String else { continue }

            if type == "response_item" {
                switch pt {
                case "message":
                    let role = payload?["role"] as? String
                    let text = textFromContent(payload?["content"])
                    if role == "user", !isCodexNoiseUserText(text) {
                        p.numUser += 1
                        if !hasPreview, let pv = normalizePreviewText(text) { p.preview = pv; hasPreview = true }
                    } else if role == "assistant", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.numAssistant += 1
                    }
                case "function_call", "custom_tool_call", "web_search_call":
                    p.numTools += 1
                default: break
                }
            } else if type == "event_msg", pt == "token_count" {
                if let u = tokenUsage(payload) { usage = u }
                if let c = lastRequestContext(payload) { maxContext = max(maxContext, c) }
            }
        }
        usage.contextSize = maxContext
        p.usage = usage
        return p
    }

    // MARK: - 完整解析（详情页）

    func parseFile(_ path: String) -> ParsedFile {
        var p = ParsedFile()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return p }
        var usage = Usage()
        var maxContext = 0

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let e = parseLine(line) else { continue }
            let payload = e["payload"] as? [String: Any]
            applyCommon(e, payload: payload, cwd: &p.cwd, firstTs: &p.firstTs, lastTs: &p.lastTs)
            let tsStr = e["timestamp"] as? String
            let type = e["type"] as? String
            guard let pt = payload?["type"] as? String else { continue }

            if type == "event_msg" {
                switch pt {
                case "agent_reasoning":
                    // 明文思考（response_item.reasoning 是加密的，故取自这里）。
                    if let t = payload?["text"] as? String,
                       !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.turns.append(["role": "assistant", "kind": "thinking",
                                        "text": clip(t, MAX_TEXT_CHARS), "ts": tsStr ?? NSNull()])
                    }
                case "token_count":
                    if let u = tokenUsage(payload) { usage = u }
                    if let c = lastRequestContext(payload) { maxContext = max(maxContext, c) }
                default: break  // agent_message / user_message 是 response_item 的重复投影，跳过
                }
                continue
            }

            guard type == "response_item" else { continue }
            switch pt {
            case "message":
                let role = payload?["role"] as? String
                let text = textFromContent(payload?["content"])
                if role == "user" {
                    if isCodexNoiseUserText(text) { continue }
                    p.turns.append(["role": "user", "kind": "message",
                                    "text": clip(text, MAX_TEXT_CHARS), "ts": tsStr ?? NSNull()])
                    p.numUser += 1
                } else if role == "assistant", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    p.turns.append(["role": "assistant", "kind": "text",
                                    "text": clip(text, MAX_TEXT_CHARS), "ts": tsStr ?? NSNull()])
                    p.numAssistant += 1
                }

            case "function_call":
                let name = payload?["name"] as? String ?? "tool"
                let input = decodeArguments(payload?["arguments"])
                p.turns.append(["role": "assistant", "kind": "tool_use",
                                "id": payload?["call_id"] as? String ?? NSNull(),
                                "name": name,
                                "summary": codexToolSummary(name, input),
                                "input": clipInputObject(input),
                                "ts": tsStr ?? NSNull()])
                p.numTools += 1

            case "custom_tool_call":
                let name = payload?["name"] as? String ?? "tool"
                let raw = payload?["input"] as? String ?? ""
                p.turns.append(["role": "assistant", "kind": "tool_use",
                                "id": payload?["call_id"] as? String ?? NSNull(),
                                "name": name,
                                "summary": codexToolSummary(name, raw),
                                "input": clipInputObject(raw),
                                "ts": tsStr ?? NSNull()])
                p.numTools += 1

            case "web_search_call":
                let action = payload?["action"] as? [String: Any]
                let query = action?["query"] as? String ?? ""
                p.turns.append(["role": "assistant", "kind": "tool_use",
                                "id": payload?["call_id"] as? String ?? NSNull(),
                                "name": "web_search",
                                "summary": query,
                                "input": clipInputObject(action ?? [:]),
                                "ts": tsStr ?? NSNull()])
                p.numTools += 1

            case "function_call_output", "custom_tool_call_output":
                let out = codexOutputText(payload?["output"])
                p.turns.append(["role": "tool", "kind": "tool_result",
                                "tool_use_id": payload?["call_id"] as? String ?? NSNull(),
                                "is_error": false,
                                "content": clip(out, MAX_RESULT_CHARS),
                                "ts": tsStr ?? NSNull()])

            default: break  // reasoning(加密) 等跳过
            }
        }
        usage.contextSize = maxContext
        p.usage = usage
        return p
    }

    // MARK: - helpers

    private func parseLine(_ line: Substring) -> [String: Any]? {
        if line.isEmpty { return nil }
        guard let data = line.data(using: .utf8),
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return e
    }

    private func applyCommon(_ e: [String: Any], payload: [String: Any]?,
                             cwd: inout String?, firstTs: inout Date?, lastTs: inout Date?) {
        if cwd == nil, let c = payload?["cwd"] as? String, !c.isEmpty { cwd = c }
        if let ts = parseTimestamp(e["timestamp"] as? String) {
            if firstTs == nil { firstTs = ts }
            lastTs = ts
        }
    }

    // token_count.info.total_token_usage 是累计值 —— 每次覆盖，最终取最后一条。
    private func tokenUsage(_ payload: [String: Any]?) -> Usage? {
        guard let info = payload?["info"] as? [String: Any],
              let t = info["total_token_usage"] as? [String: Any] else { return nil }
        let input = (t["input_tokens"] as? NSNumber)?.intValue ?? 0
        let cached = (t["cached_input_tokens"] as? NSNumber)?.intValue ?? 0
        var u = Usage()
        u.inputUncached = max(input - cached, 0)
        u.cacheRead = cached
        u.cacheCreate = 0
        u.output = (t["output_tokens"] as? NSNumber)?.intValue ?? 0
        return u
    }

    // token_count.info.last_token_usage 是单次请求用量，input_tokens 已含缓存部分，
    // 即该次请求的完整输入上下文 —— 逐条取 max 得到会话峰值。
    private func lastRequestContext(_ payload: [String: Any]?) -> Int? {
        guard let info = payload?["info"] as? [String: Any],
              let t = info["last_token_usage"] as? [String: Any],
              let input = (t["input_tokens"] as? NSNumber)?.intValue else { return nil }
        return input
    }
}

// content 数组里的 input_text / output_text 文本拼接。
func textFromContent(_ content: Any?) -> String {
    guard let blocks = content as? [Any] else { return content as? String ?? "" }
    var parts: [String] = []
    for case let b as [String: Any] in blocks {
        switch b["type"] as? String {
        case "input_text", "output_text", "text":
            if let t = b["text"] as? String { parts.append(t) }
        default: break
        }
    }
    return parts.joined(separator: "\n")
}

// Codex 的 user 消息里混入大量非用户输入：环境上下文 / 权限说明 / 用户指令块 /
// AGENTS.md 注入 —— 均以 XML 标签或固定前缀开头，过滤掉只留真实 prompt。
func isCodexNoiseUserText(_ text: String) -> Bool {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return true }
    if t.hasPrefix("<") { return true }  // <environment_context> / <permissions instructions> / <user_instructions> …
    if t.hasPrefix("# AGENTS.md instructions") { return true }
    return false
}

// function_call.arguments 是 JSON 字符串；解析为对象，失败则原样返回字符串。
func decodeArguments(_ raw: Any?) -> Any {
    guard let s = raw as? String else { return raw ?? [String: Any]() }
    if let data = s.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
        return obj
    }
    return s
}

func codexOutputText(_ output: Any?) -> String {
    if let s = output as? String { return s }
    if let d = output as? [String: Any] {
        if let t = d["output"] as? String { return t }
        return compactJSON(d)
    }
    return output.map { compactJSON($0) } ?? ""
}

func codexToolSummary(_ name: String, _ input: Any) -> String {
    // apply_patch：input 是补丁文本，提取受影响文件路径。
    if let patch = input as? String {
        let paths = patch.split(separator: "\n").compactMap { line -> String? in
            firstGroup(String(line), #"^\*\*\* (?:Update|Add|Delete) File: (.+)$"#)
        }
        if !paths.isEmpty { return paths.joined(separator: ", ") }
        return name
    }
    guard let d = input as? [String: Any] else { return "" }
    func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let a = v as? [Any] { return a.map { anyToDisplay($0) }.joined(separator: " ") }
        return nil
    }
    switch name {
    case "exec_command", "shell", "local_shell", "write_stdin":
        return str(d["cmd"]) ?? str(d["command"]) ?? ""
    case "update_plan":
        if let plan = d["plan"] as? [Any] {
            let steps = plan.compactMap { ($0 as? [String: Any])?["step"] as? String }
            return steps.joined(separator: " → ")
        }
        return "update plan"
    case "view_image":
        return str(d["path"]) ?? ""
    case "request_user_input":
        if let qs = d["questions"] as? [Any],
           let first = (qs.first as? [String: Any])?["question"] as? String { return first }
        return "ask user"
    default:
        if let one = str(d["query"]) ?? str(d["cmd"]) ?? str(d["command"])
            ?? str(d["path"]) ?? str(d["title"]) { return one }
        let j = compactJSON(d)
        return j.utf16.count > 120 ? String(j.prefix(117)) + "…" : j
    }
}

private func anyToDisplay(_ v: Any) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return compactJSON(v)
}
