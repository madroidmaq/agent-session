import Foundation

// 扫描 ~/.claude/projects，GUI 路径先解析轻量摘要，详情页再按需解析完整 turns/subagents。
// --dump-json 仍走 reloadFull()，保持原完整 JSON schema。
final class SessionStore {
    let root: String
    private(set) var sessions: [Session] = []             // full dump 用完整缓存
    private(set) var summaries: [SessionSummary] = []     // GUI 首屏用摘要缓存

    private var detailCache: [String: Session] = [:]
    private var allProjectCounts: [String: Int] = [:]
    private var sessionIndexSummaries: [String: [String: String]] = [:]
    private var generation = 0
    private let lock = NSLock()

    init(root: String) { self.root = root }

    // GUI 路径：只解析 main transcript 摘要；subagent 仅记录引用，点击详情时再解析。
    func reload(scopeHint: Scope = Scope()) {
        let parser = TranscriptParser(root: root)
        let files = TranscriptParser.walk(root).map { ($0, parser.classify($0)) }
        let summariesByProject = loadAllSessionIndexSummaries()

        var subByParent: [String: [SubagentRef]] = [:]
        for (path, info) in files where info.kind == .subagent {
            subByParent[info.sessionId, default: []].append(SubagentRef(
                path: path,
                agentId: info.agentId,
                agentType: info.agentType
            ))
        }

        // 只按时间预过滤、不按项目预过滤：缓存该时间范围的全部项目，
        // 切项目时由 indexJSON 在内存里过滤（无需重扫）。
        let sinceDate = scopeHint.since.date
        let fm = FileManager.default
        var projectCounts: [String: Int] = [:]
        var next: [SessionSummary] = []
        for (path, info) in files where info.kind == .main {
            let label = prettyProject(info.project)
            if let since = sinceDate,
               let attrs = try? fm.attributesOfItem(atPath: path),
               let modified = attrs[.modificationDate] as? Date,
               modified < since {
                continue
            }

            let parsed = parser.parseSummaryFile(path)
            if parsed.firstTs == nil && parsed.numUser == 0 && parsed.numAssistant == 0 && parsed.numTools == 0 { continue }
            if let since = sinceDate, let last = parsed.lastTs, last < since { continue }

            projectCounts[label, default: 0] += 1
            next.append(SessionSummary(
                id: info.sessionId,
                project: info.project,
                projectLabel: label,
                rawProject: info.rawProject,
                rawProjectLabel: prettyProject(info.rawProject),
                isWorktree: info.isWorktree,
                worktreeName: info.worktreeName,
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
                preview: preferredPreview(for: info, fallback: parsed.preview, summariesByProject: summariesByProject)
            ))
        }

        next.sort { (a, b) in (a.lastTs ?? .distantPast) > (b.lastTs ?? .distantPast) }

        lock.lock()
        summaries = next
        allProjectCounts = projectCounts
        sessionIndexSummaries = summariesByProject
        detailCache.removeAll()
        generation += 1
        lock.unlock()
    }

    // 完整扫描 + 解析（耗时）：用于 --dump-json / golden 对照。
    func reloadFull() {
        let parser = TranscriptParser(root: root)
        let files = TranscriptParser.walk(root).map { ($0, parser.classify($0)) }
        let summariesByProject = loadAllSessionIndexSummaries()

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
            if let session = buildSession(path: path, info: info, subagents: subByParent[info.sessionId] ?? [],
                                          parser: parser, summariesByProject: summariesByProject) {
                result.append(session)
            }
        }

        lock.lock()
        sessions = result
        allProjectCounts = projectCounts
        sessionIndexSummaries = summariesByProject
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
                       controlsProjects: projects, sessions: capped.map { $0.toDict() },
                       matched: matchedAggregate(matched))
    }

    // 概览统计：对「命中池全量」（未受 maxSessions 截断）求聚合，前端概览直接用，
    // 不再受「加载更多」影响。
    private func matchedAggregate(_ list: [SessionSummary]) -> [String: Any] {
        var turns = 0, tools = 0, tokens = 0
        var minTs: Date? = nil, maxTs: Date? = nil
        var byProj: [String: Int] = [:]
        for s in list {
            turns += s.numUser
            tools += s.numTools
            tokens += s.usage.total
            if let f = s.firstTs { minTs = min(minTs ?? f, f) }
            if let l = s.lastTs { maxTs = max(maxTs ?? l, l) }
            byProj[s.projectLabel, default: 0] += 1
        }
        let projects = byProj.sorted { $0.value > $1.value }.map { [$0.key, $0.value] as [Any] }
        return [
            "turns": turns, "tools": tools, "tokens": tokens,
            "span_start": minTs.map(isoString) ?? NSNull(),
            "span_end": maxTs.map(isoString) ?? NSNull(),
            "projects": projects,
        ]
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
        let summariesByProject = sessionIndexSummaries
        lock.unlock()

        let info = FileInfo(project: summary.project, rawProject: summary.rawProject,
                            worktreeName: summary.worktreeName,
                            sessionId: summary.id, kind: .main)
        let parser = TranscriptParser(root: root)
        guard let session = buildSession(path: summary.mainPath, info: info,
                                         subagents: summary.subagents, parser: parser,
                                         summariesByProject: summariesByProject) else { return nil }

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
                              subagents: [SubagentRef], parser: TranscriptParser,
                              summariesByProject: [String: [String: String]]) -> Session? {
        let parsed = parser.parseFile(path)
        if parsed.turns.isEmpty && parsed.firstTs == nil { return nil }

        var turns = parsed.turns
        var records: [(sub: SubagentRef, parsed: ParsedFile, key: String)] = []
        for (i, sub) in subagents.enumerated() {
            let sp = parser.parseFile(sub.path)
            if sp.turns.isEmpty { continue }
            records.append((sub, sp, subagentKey(sub, fallbackIndex: i)))
        }

        var parentOwner = Array(repeating: -2, count: records.count) // -2 = orphan, -1 = main, >=0 = subagent index
        var parentTurn = Array(repeating: -1, count: records.count)
        for i in records.indices {
            guard let agentId = records[i].sub.agentId else { continue }
            if let idx = parsed.agentIdToTurnIndex[agentId], idx < turns.count {
                parentOwner[i] = -1
                parentTurn[i] = idx
                continue
            }
            for j in records.indices where j != i {
                if let idx = records[j].parsed.agentIdToTurnIndex[agentId], idx < records[j].parsed.turns.count {
                    parentOwner[i] = j
                    parentTurn[i] = idx
                    break
                }
            }
        }

        var mainChildren: [(child: Int, turnIndex: Int)] = []
        var childrenByParent = Array(repeating: [(child: Int, turnIndex: Int)](), count: records.count)
        for i in records.indices {
            if parentOwner[i] == -1 {
                mainChildren.append((i, parentTurn[i]))
            } else if parentOwner[i] >= 0 {
                childrenByParent[parentOwner[i]].append((i, parentTurn[i]))
            }
        }

        func buildPayload(_ index: Int, visiting: Set<Int> = []) -> [String: Any] {
            var nested = subagentPayload(sub: records[index].sub, parsed: records[index].parsed,
                                         key: records[index].key, isOrphan: parentOwner[index] == -2,
                                         info: info)
            if visiting.contains(index) { return nested }
            var childTurns = records[index].parsed.turns
            var nextVisiting = visiting
            nextVisiting.insert(index)
            for child in childrenByParent[index] where child.turnIndex < childTurns.count {
                var childPayload = buildPayload(child.child, visiting: nextVisiting)
                addParentMetadata(to: &childPayload, from: childTurns[child.turnIndex], index: child.turnIndex)
                appendSubagent(childPayload, to: &childTurns, at: child.turnIndex)
            }
            nested["turns"] = childTurns
            nested["num_subagents"] = childrenByParent[index].count
            return nested
        }

        var orphans: [[String: Any]] = []
        for child in mainChildren where child.turnIndex < turns.count {
            var nested = buildPayload(child.child)
            addParentMetadata(to: &nested, from: turns[child.turnIndex], index: child.turnIndex)
            appendSubagent(nested, to: &turns, at: child.turnIndex)
        }
        for i in records.indices where parentOwner[i] == -2 {
            orphans.append(buildPayload(i))
        }

        return Session(
            id: info.sessionId,
            project: info.project,
            projectLabel: prettyProject(info.project),
            rawProject: info.rawProject,
            rawProjectLabel: prettyProject(info.rawProject),
            isWorktree: info.isWorktree,
            worktreeName: info.worktreeName,
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
            preview: preferredPreview(for: info, fallback: firstHumanPreview(turns), summariesByProject: summariesByProject),
            turns: turns,
            orphanSubagents: orphans
        )
    }

    private func appendSubagent(_ nested: [String: Any], to turns: inout [[String: Any]], at idx: Int) {
        var subList = turns[idx]["subagents"] as? [[String: Any]] ?? []
        subList.append(nested)
        turns[idx]["subagents"] = subList
    }

    private func addParentMetadata(to nested: inout [String: Any], from turn: [String: Any], index: Int) {
        nested["parent_turn_index"] = index
        nested["parent_tool_name"] = turn["name"] ?? NSNull()
        nested["parent_tool_summary"] = turn["summary"] ?? NSNull()
        let parentTs = turn["ts"] ?? NSNull()
        nested["parent_ts"] = parentTs
        if let createdTs = nonEmptyString(parentTs) {
            nested["created_ts"] = createdTs
        }

        if let input = turn["input"] as? [String: Any] {
            if let agentName = nonEmptyString(input["subagent_type"]) {
                nested["agent_name"] = agentName
            }
            if let description = nonEmptyString(input["description"]) {
                nested["agent_description"] = description
            }
        }

        let agentName = nonEmptyString(nested["agent_name"])
            ?? nonEmptyString(nested["agent_type"])
            ?? "subagent"
        let isOrphan = (nested["is_orphan"] as? Bool)
            ?? (nested["is_orphan"] as? NSNumber)?.boolValue
            ?? false
        nested["label"] = isOrphan ? "\(agentName) (orphan)" : agentName
    }

    private func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func subagentKey(_ sub: SubagentRef, fallbackIndex: Int) -> String {
        if let id = sub.agentId, !id.isEmpty { return "agent:\(id)" }
        let base = (sub.path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
        return "orphan:\(base.isEmpty ? String(fallbackIndex) : base)"
    }

    private func subagentPayload(sub: SubagentRef, parsed: ParsedFile,
                                 key: String, isOrphan: Bool, info: FileInfo) -> [String: Any] {
        let agentType = sub.agentType ?? "subagent"
        let agentId = sub.agentId ?? ""
        let agentName = agentType
        return [
            "key": key,
            "id": agentId.isEmpty ? key : agentId,
            "label": isOrphan ? "\(agentName) (orphan)" : agentName,
            "agent_name": agentName,
            "agent_description": NSNull(),
            "created_ts": parsed.firstTs.map(isoString) ?? NSNull(),
            "agent_type": agentType,
            "agent_id": agentId,
            "is_orphan": isOrphan,
            "project": info.project,
            "project_label": prettyProject(info.project),
            "raw_project": info.rawProject,
            "raw_project_label": prettyProject(info.rawProject),
            "is_worktree": info.isWorktree,
            "worktree_name": info.worktreeName ?? NSNull(),
            "cwd": parsed.cwd ?? NSNull(),
            "git_branch": parsed.gitBranch ?? NSNull(),
            "first_ts": parsed.firstTs.map(isoString) ?? NSNull(),
            "last_ts": parsed.lastTs.map(isoString) ?? NSNull(),
            "duration_ms": durationMs(first: parsed.firstTs, last: parsed.lastTs),
            "num_user": parsed.numUser,
            "num_assistant": parsed.numAssistant,
            "num_tools": parsed.numTools,
            "num_user_msgs": parsed.numUser,
            "num_assistant_msgs": parsed.numAssistant,
            "num_tool_calls": parsed.numTools,
            "num_subagents": 0,
            "usage": parsed.usage.toDict(),
            "skills": parsed.skills,
            "preview": firstHumanPreview(parsed.turns),
            "turns": parsed.turns,
            "orphan_subagents": [],
        ]
    }

    private func durationMs(first: Date?, last: Date?) -> Int {
        guard let first, let last else { return 0 }
        return Int(((last.timeIntervalSince1970 - first.timeIntervalSince1970) * 1000).rounded())
    }

    private func projectLabelsLocked() -> [String] {
        if !allProjectCounts.isEmpty {
            return allProjectCounts.sorted { $0.value > $1.value }.map { $0.key }
        }
        var count: [String: Int] = [:]
        for s in summaries { count[s.projectLabel, default: 0] += 1 }
        return count.sorted { $0.value > $1.value }.map { $0.key }
    }

    private func loadAllSessionIndexSummaries() -> [String: [String: String]] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [:] }
        var summaries: [String: [String: String]] = [:]
        for name in names {
            let path = (root as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let indexPath = (path as NSString).appendingPathComponent("sessions-index.json")
            let entries = loadSessionIndexSummaries(at: indexPath)
            if !entries.isEmpty { summaries[name] = entries }
        }
        return summaries
    }

    private func loadSessionIndexSummaries(at path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [Any] else { return [:] }

        var summaries: [String: String] = [:]
        for case let entry as [String: Any] in entries {
            guard let sessionId = entry["sessionId"] as? String,
                  let summary = entry["summary"] as? String,
                  let preview = normalizePreviewText(summary) else { continue }
            summaries[sessionId] = preview
        }
        return summaries
    }

    private func preferredPreview(for info: FileInfo, fallback: String,
                                  summariesByProject: [String: [String: String]]) -> String {
        if let preview = summariesByProject[info.rawProject]?[info.sessionId] { return preview }
        if info.project != info.rawProject,
           let preview = summariesByProject[info.project]?[info.sessionId] { return preview }
        return fallback
    }

    private func topJSON(scope: Scope, totalMatched: Int, shown: Int,
                         controlsProjects: [String], sessions: [[String: Any]],
                         matched: [String: Any]? = nil) -> String {
        let sinceDate = scope.since.date
        var scopeDict: [String: Any] = [
            "project": scope.projectLabel ?? NSNull(),
            "session": NSNull(),
            "since": sinceDate.map(isoString) ?? NSNull(),
            "all": scope.projectLabel == nil,
            "total_matched": totalMatched,
            "shown": shown,
        ]
        if let matched = matched { scopeDict["matched"] = matched }
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
