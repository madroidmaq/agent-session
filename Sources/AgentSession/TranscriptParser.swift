import Foundation

// 1:1 移植 extract-session.mjs 的解析逻辑：JSONL transcript -> 与原 JSON schema
// 一致的结构化数据。markdown 渲染仍由前端 template.html 负责，这里只产数据。

let MAX_RESULT_CHARS = 4000
let MAX_TEXT_CHARS = 20000

// 一个 transcript 文件解析后的中间结果。
struct ParsedFile {
    var turns: [[String: Any]] = []
    var skills: [String] = []          // 保持插入顺序去重
    var firstTs: Date?
    var lastTs: Date?
    var cwd: String?
    var gitBranch: String?
    var numUser = 0
    var numAssistant = 0
    var numTools = 0
    var usage = Usage()
    var agentIdToTurnIndex: [String: Int] = [:]
}

struct ParsedSummary {
    var skills: [String] = []          // 保持插入顺序去重
    var firstTs: Date?
    var lastTs: Date?
    var cwd: String?
    var gitBranch: String?
    var numUser = 0
    var numAssistant = 0
    var numTools = 0
    var usage = Usage()
    var preview: String = "(no text prompt)"
}

struct ProjectIdentity {
    let project: String
    let rawProject: String
    let worktreeName: String?

    var isWorktree: Bool { worktreeName != nil }
}

struct FileInfo {
    let project: String
    let rawProject: String
    let worktreeName: String?
    let sessionId: String
    let kind: Kind
    var agentId: String? = nil
    var agentType: String? = nil

    var isWorktree: Bool { worktreeName != nil }

    enum Kind { case main, subagent }
}

final class TranscriptParser {
    let root: String
    // resumed 会话会重放历史条目，按 uuid 全局去重（一次扫描共用一个实例）。
    private var seenUuids = Set<String>()

    init(root: String) { self.root = root }

    // MARK: - 文件发现 / 分类

    static func walk(_ root: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            out.append((root as NSString).appendingPathComponent(rel))
        }
        return out
    }

    func classify(_ path: String) -> FileInfo {
        var rel = path
        if rel.hasPrefix(root) { rel = String(rel.dropFirst(root.count)) }
        rel = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        let parts = rel.split(separator: "/").map(String.init)
        let identity = canonicalizeProjectDir(parts.first ?? "")
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        if let subIdx = parts.firstIndex(of: "subagents"), subIdx >= 1 {
            let sessionId = parts[subIdx - 1]
            let agentId = base.hasPrefix("agent-") ? String(base.dropFirst("agent-".count)) : base
            let agentType = inferAgentTypeFromMeta(path)
                ?? inferAgentTypeFromFilename(base) ?? "subagent"
            return FileInfo(project: identity.project, rawProject: identity.rawProject,
                            worktreeName: identity.worktreeName,
                            sessionId: sessionId, kind: .subagent,
                            agentId: agentId, agentType: agentType)
        }
        return FileInfo(project: identity.project, rawProject: identity.rawProject,
                        worktreeName: identity.worktreeName, sessionId: base, kind: .main)
    }

    private func inferAgentTypeFromMeta(_ jsonlPath: String) -> String? {
        let metaPath = jsonlPath.replacingOccurrences(of: ".jsonl", with: ".meta.json")
        guard let data = FileManager.default.contents(atPath: metaPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["agentType"] as? String else { return nil }
        return t
    }

    private func inferAgentTypeFromFilename(_ base: String) -> String? {
        guard let m = firstGroup(base, #"^agent-a([a-zA-Z_][\w-]*?)-[0-9a-f]{6,}$"#) else { return nil }
        return m
    }

    // MARK: - 主解析

    func parseSummaryFile(_ path: String) -> ParsedSummary {
        var p = ParsedSummary()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return p }

        var skillSet = Set<String>()
        // usage 按 requestId 去重，保留 output 最大的那条（流式响应会发多行）
        var usageByReq: [String: Usage] = [:]
        var hasPreview = false

        func appendSkill(_ skill: String) {
            skillSet.insert(skill)
            if !p.skills.contains(skill) { p.skills.append(skill) }
        }
        func setPreview(_ text: String) {
            guard !hasPreview else { return }
            let one = re(text, #"\s+"#, " ").trimmingCharacters(in: .whitespaces)
            guard !one.isEmpty else { return }
            p.preview = one.utf16.count > 160 ? substringUTF16(one, 157) + "…" : one
            hasPreview = true
        }
        func handleSummaryUserText(_ raw: String) {
            if isNoiseUserText(raw) { return }
            let cleaned = cleanUserText(raw)
            if let cmd = slashFrom(raw) {
                appendSkill(cmd)
                setPreview("/" + cmd)
                p.numUser += 1
            } else if !cleaned.isEmpty {
                setPreview(cleaned)
                p.numUser += 1
            }
        }

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let uuid = e["uuid"] as? String {
                if seenUuids.contains(uuid) { continue }
                seenUuids.insert(uuid)
            }
            if let c = e["cwd"] as? String, p.cwd == nil { p.cwd = c }
            if let g = e["gitBranch"] as? String, p.gitBranch == nil { p.gitBranch = g }
            if let ts = parseTimestamp(e["timestamp"] as? String) {
                if p.firstTs == nil { p.firstTs = ts }
                p.lastTs = ts
            }
            let type = e["type"] as? String
            let message = e["message"] as? [String: Any]

            if type == "user" {
                let isMeta = (e["isMeta"] as? NSNumber)?.boolValue ?? false
                let isCompact = (e["isCompactSummary"] as? NSNumber)?.boolValue ?? false
                if isMeta || isCompact { continue }

                let content = message?["content"]
                if let str = content as? String {
                    handleSummaryUserText(str)
                } else if let blocks = content as? [Any] {
                    for case let b as [String: Any] in blocks where (b["type"] as? String) == "text" {
                        handleSummaryUserText(b["text"] as? String ?? "")
                    }
                }
                continue
            }

            if type == "assistant" {
                if let u = message?["usage"] as? [String: Any] {
                    let rid = (e["requestId"] as? String) ?? (e["uuid"] as? String) ?? "row\(p.numAssistant + p.numTools)"
                    var rec = Usage()
                    rec.inputUncached = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.cacheCreate = (u["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.cacheRead = (u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.output = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
                    if let prev = usageByReq[rid], prev.output > rec.output {} else { usageByReq[rid] = rec }
                }
                guard let blocks = message?["content"] as? [Any] else { continue }
                for case let b as [String: Any] in blocks {
                    let bt = b["type"] as? String
                    if bt == "text", let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.numAssistant += 1
                    } else if bt == "tool_use" {
                        if let name = b["name"] as? String, name == "Skill",
                           let inp = b["input"] as? [String: Any], let sk = inp["skill"] as? String {
                            appendSkill(sk)
                        }
                        p.numTools += 1
                    }
                }
                continue
            }
        }

        for r in usageByReq.values {
            p.usage.inputUncached += r.inputUncached
            p.usage.cacheCreate += r.cacheCreate
            p.usage.cacheRead += r.cacheRead
            p.usage.output += r.output
        }
        return p
    }

    func parseFile(_ path: String) -> ParsedFile {
        var p = ParsedFile()
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return p }

        var toolUseIndex: [String: Int] = [:]       // tool_use id -> turn index
        var toolUseIdToAgentId: [String: String] = [:]
        var skillSet = Set<String>()
        var lastSlashIdx: Int? = nil
        // usage 按 requestId 去重，保留 output 最大的那条（流式响应会发多行）
        var usageByReq: [String: Usage] = [:]

        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { continue }
            guard let data = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let uuid = e["uuid"] as? String {
                if seenUuids.contains(uuid) { continue }
                seenUuids.insert(uuid)
            }
            if let c = e["cwd"] as? String, p.cwd == nil { p.cwd = c }
            if let g = e["gitBranch"] as? String, p.gitBranch == nil { p.gitBranch = g }
            if let ts = parseTimestamp(e["timestamp"] as? String) {
                if p.firstTs == nil { p.firstTs = ts }
                p.lastTs = ts
            }
            let ts = e["timestamp"] as? String
            let type = e["type"] as? String
            let message = e["message"] as? [String: Any]

            if type == "user" {
                let isMeta = (e["isMeta"] as? NSNumber)?.boolValue ?? false
                let isCompact = (e["isCompactSummary"] as? NSNumber)?.boolValue ?? false
                if isMeta || isCompact {
                    // slash 命令会展开成一条 isMeta 条目，携带 SKILL.md 正文，挂回 slash turn
                    if isMeta, let idx = lastSlashIdx, p.turns[idx]["skill_body"] == nil,
                       let blocks = message?["content"] as? [Any],
                       let tb = blocks.compactMap({ $0 as? [String: Any] })
                            .first(where: { ($0["type"] as? String) == "text" }),
                       let txt = tb["text"] as? String,
                       txt.range(of: #"^\s*Base directory for this skill:"#,
                                 options: .regularExpression) != nil {
                        p.turns[idx]["skill_body"] = clip(txt, MAX_TEXT_CHARS)
                        lastSlashIdx = nil
                    }
                    continue
                }
                // 关联 Agent 的 tool_result -> agentId
                if let tur = e["toolUseResult"] as? [String: Any],
                   let agentId = tur["agentId"] as? String,
                   let c0 = (message?["content"] as? [Any])?.first as? [String: Any],
                   let tuid = c0["tool_use_id"] as? String {
                    toolUseIdToAgentId[tuid] = agentId
                }

                let content = message?["content"]
                if let str = content as? String {
                    handleUserText(str, ts: ts, into: &p, skills: &skillSet, lastSlashIdx: &lastSlashIdx)
                } else if let blocks = content as? [Any] {
                    for case let b as [String: Any] in blocks {
                        let bt = b["type"] as? String
                        if bt == "text" {
                            handleUserText(b["text"] as? String ?? "", ts: ts, into: &p,
                                           skills: &skillSet, lastSlashIdx: &lastSlashIdx)
                        } else if bt == "tool_result" {
                            p.turns.append([
                                "role": "tool", "kind": "tool_result",
                                "tool_use_id": b["tool_use_id"] as? String ?? NSNull(),
                                "is_error": (b["is_error"] as? NSNumber)?.boolValue ?? false,
                                "content": clip(flattenResult(b["content"]), MAX_RESULT_CHARS),
                                "ts": ts ?? NSNull(),
                            ])
                        }
                    }
                }
                continue
            }

            if type == "assistant" {
                if let u = message?["usage"] as? [String: Any] {
                    let rid = (e["requestId"] as? String) ?? (e["uuid"] as? String) ?? "row\(p.turns.count)"
                    var rec = Usage()
                    rec.inputUncached = (u["input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.cacheCreate = (u["cache_creation_input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.cacheRead = (u["cache_read_input_tokens"] as? NSNumber)?.intValue ?? 0
                    rec.output = (u["output_tokens"] as? NSNumber)?.intValue ?? 0
                    if let prev = usageByReq[rid], prev.output > rec.output {} else { usageByReq[rid] = rec }
                }
                guard let blocks = message?["content"] as? [Any] else { continue }
                for case let b as [String: Any] in blocks {
                    let bt = b["type"] as? String
                    if bt == "text", let t = b["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.turns.append(["role": "assistant", "kind": "text", "text": clip(t, MAX_TEXT_CHARS), "ts": ts ?? NSNull()])
                        p.numAssistant += 1
                    } else if bt == "thinking", let t = b["thinking"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        p.turns.append(["role": "assistant", "kind": "thinking", "text": clip(t, MAX_TEXT_CHARS), "ts": ts ?? NSNull()])
                    } else if bt == "tool_use" {
                        let name = b["name"] as? String ?? "tool"
                        let input = b["input"] ?? [String: Any]()
                        if name == "Skill", let inp = input as? [String: Any], let sk = inp["skill"] as? String {
                            skillSet.insert(sk); if !p.skills.contains(sk) { p.skills.append(sk) }
                        }
                        let turn: [String: Any] = [
                            "role": "assistant", "kind": "tool_use",
                            "id": b["id"] as? String ?? NSNull(),
                            "name": name,
                            "summary": toolSummary(name, input),
                            "input": clipInputObject(input),
                            "ts": ts ?? NSNull(),
                        ]
                        p.turns.append(turn)
                        if let id = b["id"] as? String { toolUseIndex[id] = p.turns.count - 1 }
                        p.numTools += 1
                    }
                }
                continue
            }
        }

        // tool_use id -> agentId -> turn index
        for (toolId, idx) in toolUseIndex {
            if let agentId = toolUseIdToAgentId[toolId] { p.agentIdToTurnIndex[agentId] = idx }
        }
        // 汇总 usage
        for r in usageByReq.values {
            p.usage.inputUncached += r.inputUncached
            p.usage.cacheCreate += r.cacheCreate
            p.usage.cacheRead += r.cacheRead
            p.usage.output += r.output
        }
        return p
    }

    // 处理一段 user 文本：slash 命令 or 普通消息，噪音过滤。
    private func handleUserText(_ raw: String, ts: String?, into p: inout ParsedFile,
                                skills: inout Set<String>, lastSlashIdx: inout Int?) {
        if isNoiseUserText(raw) { return }
        let cleaned = cleanUserText(raw)
        if let cmd = slashFrom(raw) {
            skills.insert(cmd); if !p.skills.contains(cmd) { p.skills.append(cmd) }
            p.turns.append(["role": "user", "kind": "slash", "cmd": cmd, "text": cleaned, "ts": ts ?? NSNull()])
            lastSlashIdx = p.turns.count - 1
            p.numUser += 1
        } else if !cleaned.isEmpty {
            p.turns.append(["role": "user", "kind": "message", "text": clip(cleaned, MAX_TEXT_CHARS), "ts": ts ?? NSNull()])
            p.numUser += 1
        }
    }
}

// MARK: - 纯函数 helper（与 extract-session.mjs 同名对照）

func clip(_ s: String?, _ max: Int) -> [String: Any] {
    let str = s ?? ""
    let n = str.utf16.count
    if n <= max { return ["text": str, "clipped": false] }
    return ["text": substringUTF16(str, max), "clipped": true, "full_len": n]
}

private func substringUTF16(_ s: String, _ max: Int) -> String {
    var units = Array(s.utf16.prefix(max))
    // 截断点若落在 surrogate pair 中间，会留下孤立 high surrogate；
    // Swift/JSONSerialization 不接受，去掉它（与 JS 仅差末尾 1 个 code unit）。
    if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
    return String(utf16CodeUnits: units, count: units.count)
}

func clipInputObject(_ input: Any) -> Any {
    if let s = input as? String {
        if s.utf16.count > MAX_RESULT_CHARS {
            return substringUTF16(s, MAX_RESULT_CHARS) + "\n…(truncated, \(s.utf16.count) chars)"
        }
        return s
    }
    if let a = input as? [Any] { return a.map(clipInputObject) }
    if let d = input as? [String: Any] {
        var o = [String: Any]()
        for (k, v) in d { o[k] = clipInputObject(v) }
        return o
    }
    return input
}

func toolSummary(_ name: String, _ inputAny: Any) -> String {
    guard let input = inputAny as? [String: Any] else { return "" }
    func pick(_ keys: [String]) -> String? {
        for k in keys {
            if let v = input[k], !(v is NSNull) {
                let s = anyToString(v)
                if !s.isEmpty { return s }
            }
        }
        return nil
    }
    switch name {
    case "Bash": return pick(["command"]) ?? ""
    case "Read", "Write", "Edit": return pick(["file_path"]) ?? ""
    case "Glob": return pick(["pattern"]) ?? ""
    case "Grep":
        let parts = [pick(["pattern"]), (input["path"] != nil ? "in \(anyToString(input["path"]!))" : nil)]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    case "ToolSearch", "WebSearch": return pick(["query"]) ?? ""
    case "WebFetch": return pick(["url"]) ?? ""
    case "Skill": return pick(["skill"]) ?? ""
    case "Agent", "Task":
        return [pick(["subagent_type"]), pick(["description"])].compactMap { $0 }.joined(separator: " — ")
    case "TaskCreate", "TaskUpdate": return pick(["description", "prompt", "status"]) ?? ""
    default:
        if let one = pick(["description", "prompt", "query", "command", "path", "file_path"]) { return one }
        let j = compactJSON(input)
        return j.utf16.count > 120 ? substringUTF16(j, 117) + "…" : j
    }
}

func isNoiseUserText(_ text: String) -> Bool {
    text.hasPrefix("<task-notification") || text.hasPrefix("<scheduled-wakeup")
        || text.hasPrefix("<background-task") || text.hasPrefix("[Request interrupted")
}

func slashFrom(_ text: String) -> String? {
    guard let g = firstGroup(text, #"<command-(?:name|message)>/?([^<]+)</command-"#) else { return nil }
    return g.trimmingCharacters(in: .whitespacesAndNewlines)
}

func cleanUserText(_ text: String) -> String {
    var s = text
    s = re(s, #"<command-[a-z-]+>[\s\S]*?</command-[a-z-]+>"#, " ")
    s = re(s, #"<system-reminder>[\s\S]*?</system-reminder>"#, " ")
    s = re(s, #"<[^>]+>"#, " ")
    s = re(s, #"[ \t]+\n"#, "\n")
    s = re(s, #"\n{3,}"#, "\n\n")
    s = re(s, #"[ \t]{2,}"#, " ")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

func flattenResult(_ content: Any?) -> String {
    guard let content = content else { return "" }
    if let s = content as? String { return s }
    if let a = content as? [Any] {
        return a.map { x -> String in
            if let s = x as? String { return s }
            if let d = x as? [String: Any] {
                if (d["type"] as? String) == "text" { return d["text"] as? String ?? "" }
                if (d["type"] as? String) == "image" { return "[image]" }
                return compactJSON(d)
            }
            return String(describing: x)
        }.joined(separator: "\n")
    }
    return compactJSON(content)
}

func prettyProject(_ dir: String) -> String {
    var s = re(dir, #"^-Users-[^-]+-"#, "")
    s = re(s, #"^-"#, "")
    return s
}

func canonicalizeProjectDir(_ rawProject: String) -> ProjectIdentity {
    guard let marker = rawProject.range(of: "--claude-worktrees-", options: .backwards) else {
        return ProjectIdentity(project: rawProject, rawProject: rawProject, worktreeName: nil)
    }
    let base = String(rawProject[..<marker.lowerBound])
    let worktreeName = String(rawProject[marker.upperBound...])
    guard !base.isEmpty, !worktreeName.isEmpty else {
        return ProjectIdentity(project: rawProject, rawProject: rawProject, worktreeName: nil)
    }
    return ProjectIdentity(project: base, rawProject: rawProject, worktreeName: worktreeName)
}

func cwdToProjectDir(_ cwd: String) -> String {
    re(cwd, #"[^a-zA-Z0-9]"#, "-")
}

func firstHumanPreview(_ turns: [[String: Any]]) -> String {
    for t in turns where (t["role"] as? String) == "user" {
        let kind = t["kind"] as? String
        guard kind == "message" || kind == "slash" else { continue }
        let txt: String
        if kind == "slash" { txt = "/" + (t["cmd"] as? String ?? "") }
        else { txt = (t["text"] as? [String: Any])?["text"] as? String ?? "" }
        let one = re(txt, #"\s+"#, " ").trimmingCharacters(in: .whitespaces)
        return one.utf16.count > 160 ? substringUTF16(one, 157) + "…" : one
    }
    return "(no text prompt)"
}

// MARK: - 小工具

private func anyToString(_ v: Any) -> String {
    if let s = v as? String { return s }
    if let n = v as? NSNumber { return n.stringValue }
    return compactJSON(v)
}

func compactJSON(_ v: Any) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]),
          let s = String(data: d, encoding: .utf8) else { return "" }
    return s
}

private func re(_ s: String, _ pat: String, _ rep: String) -> String {
    s.replacingOccurrences(of: pat, with: rep, options: .regularExpression)
}

func firstGroup(_ s: String, _ pat: String) -> String? {
    guard let rx = try? NSRegularExpression(pattern: pat) else { return nil }
    let range = NSRange(s.startIndex..., in: s)
    guard let m = rx.firstMatch(in: s, range: range), m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}
