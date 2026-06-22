import Foundation

// 扫描 ~/.claude/projects，GUI 路径先解析轻量摘要，详情页再按需解析完整 turns/subagents。
// --dump-json 仍走 reloadFull()，保持原完整 JSON schema。
final class SessionStore {
    let root: String
    private(set) var sessions: [Session] = []             // full dump 用完整缓存
    private(set) var summaries: [SessionSummary] = []     // GUI 首屏用摘要缓存

    private var detailCache: [String: Session] = [:]
    private var allProjectCounts: [String: Int] = [:]
    private var generation = 0
    private let lock = NSLock()

    init(root: String) { self.root = root }

    // GUI 路径：只解析 main transcript 摘要；subagent 仅记录引用，点击详情时再解析。
    func reload(scopeHint: Scope = Scope()) {
        let parser = TranscriptParser(root: root)
        let files = TranscriptParser.walk(root).map { ($0, parser.classify($0)) }

        var subByParent: [String: [SubagentRef]] = [:]
        var projectCounts: [String: Int] = [:]
        for (path, info) in files {
            if info.kind == .main {
                projectCounts[prettyProject(info.project), default: 0] += 1
            } else {
                subByParent[info.sessionId, default: []].append(SubagentRef(
                    path: path,
                    agentId: info.agentId,
                    agentType: info.agentType
                ))
            }
        }

        let sinceDate = scopeHint.since.date
        let fm = FileManager.default
        var next: [SessionSummary] = []
        for (path, info) in files where info.kind == .main {
            let label = prettyProject(info.project)
            if let p = scopeHint.projectLabel, label != p { continue }
            if let since = sinceDate,
               let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified < since {
                continue
            }

            let parsed = parser.parseSummaryFile(path)
            if parsed.firstTs == nil && parsed.numUser == 0 && parsed.numAssistant == 0 && parsed.numTools == 0 { continue }
            if let since = sinceDate, let last = parsed.lastTs, last < since { continue }

            next.append(SessionSummary(
                id: info.sessionId,
                project: info.project,
                projectLabel: label,
                mainPath: path,
                subagents: subByParent[info.sessionId] ?? [],
                cwd: parsed.cwd,
                gitBranch: parsed.gitBranch,
                firstTs: parsed.firstTs,
                lastTs: parsed.lastTs,
                numUser: parsed.numUser,
                numAssistant: parsed.numAssistant,
                numTools: parsed.numTools,
                usage: parsed.usage,
                skills: parsed.skills,
                preview: parsed.preview
            ))
        }

        next.sort { (a, b) in (a.lastTs ?? .distantPast) > (b.lastTs ?? .distantPast) }

        lock.lock()
        summaries = next
        allProjectCounts = projectCounts
        detailCache.removeAll()
        generation += 1
        lock.unlock()
    }

    // 完整扫描 + 解析（耗时）：用于 --dump-json / golden 对照。
    func reloadFull() {
        let parser = TranscriptParser(root: root)
        let files = TranscriptParser.walk(root).map { ($0, parser.classify($0)) }

        var subByParent: [String: [SubagentRef]] = [:]
        var projectCounts: [String: Int] = [:]
        for (path, info) in files {
            if info.kind == .main {
                projectCounts[prettyProject(info.project), default: 0] += 1
            } else {
                subByParent[info.sessionId, default: []].append(SubagentRef(
                    path: path,
                    agentId: info.agentId,
                    agentType: info.agentType
                ))
            }
        }

        var result: [Session] = []
        for (path, info) in files where info.kind == .main {
            if let session = buildSession(path: path, info: info, subagents: subByParent[info.sessionId] ?? [], parser: parser) {
                result.append(session)
            }
        }

        lock.lock()
        sessions = result
        allProjectCounts = projectCounts
        detailCache.removeAll()
        generation += 1
        lock.unlock()
    }

    // 缓存里出现过的项目标签（供工具栏下拉），按会话数多→少排序。
    func projectLabels() -> [String] {
        lock.lock()
        let counts = allProjectCounts
        let currentSummaries = summaries
        let fullSessions = sessions
        lock.unlock()

        if !counts.isEmpty {
            return counts.sorted { $0.value > $1.value }.map { $0.key }
        }
        if !currentSummaries.isEmpty {
            var count: [String: Int] = [:]
            for s in currentSummaries { count[s.projectLabel, default: 0] += 1 }
            return count.sorted { $0.value > $1.value }.map { $0.key }
        }
        var count: [String: Int] = [:]
        for s in fullSessions { count[s.projectLabel, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.map { $0.key }
    }

    // GUI 首屏：按 scope 过滤 + 排序 + 截断，输出摘要 JSON。
    func indexJSON(scope: Scope) -> String {
        lock.lock()
        let source = summaries
        let projects = projectLabelsLocked()
        lock.unlock()

        let sinceDate = scope.since.date
        var matched = source.filter { s in
            if let p = scope.projectLabel, s.projectLabel != p { return false }
            if let since = sinceDate, let last = s.lastTs, last < since { return false }
            return true
        }
        matched.sort { (a, b) in (a.lastTs ?? .distantPast) > (b.lastTs ?? .distantPast) }
        let capped = Array(matched.prefix(scope.maxSessions))
        return topJSON(scope: scope, totalMatched: matched.count, shown: capped.count,
                       controlsProjects: projects, sessions: capped.map { $0.toDict() })
    }

    // 详情页按需解析单个 session，返回完整 Session JSON 文本。
    func detailJSON(id: String) -> String? {
        lock.lock()
        if let cached = detailCache[id] {
            lock.unlock()
            return jsonString(cached.toDict())
        }
        guard let summary = summaries.first(where: { $0.id == id }) else {
            lock.unlock()
            return nil
        }
        let capturedGeneration = generation
        lock.unlock()

        let info = FileInfo(project: summary.project, sessionId: summary.id, kind: .main)
        let parser = TranscriptParser(root: root)
        guard let session = buildSession(path: summary.mainPath, info: info,
                                         subagents: summary.subagents, parser: parser) else { return nil }

        lock.lock()
        guard capturedGeneration == generation else { lock.unlock(); return nil }
        detailCache[id] = session
        lock.unlock()
        return jsonString(session.toDict())
    }

    // 完整 JSON：保留原 dump-json 行为。
    func json(scope: Scope) -> String {
        lock.lock()
        let source = sessions
        let projects = projectLabelsLocked()
        lock.unlock()

        let sinceDate = scope.since.date
        var matched = source.filter { s in
            if let p = scope.projectLabel, s.projectLabel != p { return false }
            if let since = sinceDate, let last = s.lastTs, last < since { return false }
            return true
        }
        matched.sort { (a, b) in
            (a.lastTs ?? .distantPast) > (b.lastTs ?? .distantPast)
        }
        let capped = Array(matched.prefix(scope.maxSessions))
        return topJSON(scope: scope, totalMatched: matched.count, shown: capped.count,
                       controlsProjects: projects, sessions: capped.map { $0.toDict() })
    }

    private func buildSession(path: String, info: FileInfo,
                              subagents: [SubagentRef], parser: TranscriptParser) -> Session? {
        let parsed = parser.parseFile(path)
        if parsed.turns.isEmpty && parsed.firstTs == nil { return nil }

        var turns = parsed.turns
        var orphans: [[String: Any]] = []
        for sub in subagents {
            let sp = parser.parseFile(sub.path)
            if sp.turns.isEmpty { continue }
            let nested: [String: Any] = [
                "agent_type": sub.agentType ?? "subagent",
                "agent_id": sub.agentId ?? "",
                "turns": sp.turns,
                "num_user": sp.numUser,
                "num_assistant": sp.numAssistant,
                "num_tools": sp.numTools,
            ]
            if let agentId = sub.agentId, let idx = parsed.agentIdToTurnIndex[agentId], idx < turns.count {
                var subList = turns[idx]["subagents"] as? [[String: Any]] ?? []
                subList.append(nested)
                turns[idx]["subagents"] = subList
            } else {
                orphans.append(nested)
            }
        }

        return Session(
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
            numSubagents: subagents.count,
            usage: parsed.usage,
            skills: parsed.skills,
            preview: firstHumanPreview(turns),
            turns: turns,
            orphanSubagents: orphans
        )
    }

    private func projectLabelsLocked() -> [String] {
        if !allProjectCounts.isEmpty {
            return allProjectCounts.sorted { $0.value > $1.value }.map { $0.key }
        }
        var count: [String: Int] = [:]
        for s in summaries { count[s.projectLabel, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.map { $0.key }
    }

    private func topJSON(scope: Scope, totalMatched: Int, shown: Int,
                         controlsProjects: [String], sessions: [[String: Any]]) -> String {
        let sinceDate = scope.since.date
        let scopeDict: [String: Any] = [
            "project": scope.projectLabel ?? NSNull(),
            "session": NSNull(),
            "since": sinceDate.map(isoString) ?? NSNull(),
            "all": scope.projectLabel == nil,
            "total_matched": totalMatched,
            "shown": shown,
        ]
        let controls: [String: Any] = [
            "since": scope.since.rawValue,
            "project": scope.projectLabel ?? NSNull(),
            "projects": controlsProjects,
        ]
        let top: [String: Any] = [
            "generated_at": isoString(Date()),
            "root": root,
            "scope": scopeDict,
            "controls": controls,
            "sessions": sessions,
        ]
        return jsonString(top)
    }

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
