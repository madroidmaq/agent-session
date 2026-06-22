import Foundation

// 扫描 ~/.claude/projects，全量解析并缓存所有 session；scope 切换只在内存过滤，
// 不重扫盘。对应 extract-session.mjs 的 main() 组装 + scope/排序/截断逻辑。
final class SessionStore {
    let root: String
    private(set) var sessions: [Session] = []   // 全量缓存（未过滤）

    init(root: String) { self.root = root }

    // 全量扫描 + 解析（耗时，调用方应放后台线程）。
    func reload() {
        let parser = TranscriptParser(root: root)
        let files = TranscriptParser.walk(root).map { ($0, parser.classify($0)) }

        // subagent 文件按父 sessionId 分组
        var subByParent: [String: [(String, FileInfo)]] = [:]
        for f in files where f.1.kind == .subagent {
            subByParent[f.1.sessionId, default: []].append(f)
        }

        var result: [Session] = []
        for (path, info) in files where info.kind == .main {
            let parsed = parser.parseFile(path)
            if parsed.turns.isEmpty && parsed.firstTs == nil { continue }

            var turns = parsed.turns
            var orphans: [[String: Any]] = []
            let subs = subByParent[info.sessionId] ?? []
            for (subPath, subInfo) in subs {
                let sp = parser.parseFile(subPath)
                if sp.turns.isEmpty { continue }
                let nested: [String: Any] = [
                    "agent_type": subInfo.agentType ?? "subagent",
                    "agent_id": subInfo.agentId ?? "",
                    "turns": sp.turns,
                    "num_user": sp.numUser,
                    "num_assistant": sp.numAssistant,
                    "num_tools": sp.numTools,
                ]
                if let agentId = subInfo.agentId, let idx = parsed.agentIdToTurnIndex[agentId],
                   idx < turns.count {
                    var subList = turns[idx]["subagents"] as? [[String: Any]] ?? []
                    subList.append(nested)
                    turns[idx]["subagents"] = subList
                } else {
                    orphans.append(nested)
                }
            }

            result.append(Session(
                id: info.sessionId,
                project: info.project,
                projectLabel: prettyProject(info.project),
                cwd: parsed.cwd,
                gitBranch: parsed.gitBranch,
                firstTs: parsed.firstTs,
                lastTs: parsed.lastTs,
                numUser: parsed.numUser,
                numAssistant: parsed.numAssistant,
                numTools: parsed.numTools,
                numSubagents: subs.count,
                usage: parsed.usage,
                skills: parsed.skills,
                preview: firstHumanPreview(turns),
                turns: turns,
                orphanSubagents: orphans
            ))
        }
        sessions = result
    }

    // 缓存里出现过的项目标签（供工具栏下拉），按会话数多→少排序。
    func projectLabels() -> [String] {
        var count: [String: Int] = [:]
        for s in sessions { count[s.projectLabel, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.map { $0.key }
    }

    // 按 scope 过滤 + 排序 + 截断，产出与 extract-session.mjs 一致的顶层 JSON 字符串。
    func json(scope: Scope) -> String {
        let sinceDate = scope.since.date
        var matched = sessions.filter { s in
            if let p = scope.projectLabel, s.projectLabel != p { return false }
            if let since = sinceDate, let last = s.lastTs, last < since { return false }
            return true
        }
        matched.sort { (a, b) in
            (a.lastTs ?? .distantPast) > (b.lastTs ?? .distantPast)
        }
        let capped = Array(matched.prefix(scope.maxSessions))

        let scopeDict: [String: Any] = [
            "project": scope.projectLabel ?? NSNull(),
            "session": NSNull(),
            "since": sinceDate.map(isoString) ?? NSNull(),
            "all": scope.projectLabel == nil,
            "total_matched": matched.count,
            "shown": capped.count,
        ]
        // 侧栏筛选下拉所需的元信息：当前选中 + 全量项目列表（不随 scope 收窄而消失，
        // 这样切到空结果时仍能切回来）。
        let controls: [String: Any] = [
            "since": scope.since.rawValue,
            "project": scope.projectLabel ?? NSNull(),
            "projects": projectLabels(),
        ]
        let top: [String: Any] = [
            "generated_at": isoString(Date()),
            "root": root,
            "scope": scopeDict,
            "controls": controls,
            "sessions": capped.map { $0.toDict() },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: top),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
