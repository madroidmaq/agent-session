import Foundation

// 与 extract-session.mjs 输出的 JSON schema 对齐的中间态。
// turns / subagents 是高度异构的数组，直接用 [[String: Any]] 承载，
// 序列化时交给 JSONSerialization —— 比给异构枚举写 Codable 更贴近原 schema。

struct Usage {
    var inputUncached = 0
    var cacheCreate = 0
    var cacheRead = 0
    var output = 0

    var inputTotal: Int { inputUncached + cacheCreate + cacheRead }
    var total: Int { inputTotal + output }
    var cachePct: Int {
        inputTotal > 0 ? Int((Double(cacheRead) / Double(inputTotal) * 100).rounded()) : 0
    }

    func toDict() -> [String: Any] {
        [
            "input_uncached": inputUncached,
            "cache_create": cacheCreate,
            "cache_read": cacheRead,
            "output": output,
            "input_total": inputTotal,
            "total": total,
            "cache_pct": cachePct,
        ]
    }
}

struct SubagentRef {
    var path: String
    var agentId: String?
    var agentType: String?
}

// 首屏列表 / 概览只需要摘要字段；完整 turns 与 subagent 内容点击详情时再解析。
struct SessionSummary {
    var id: String
    var project: String
    var projectLabel: String
    var mainPath: String
    var subagents: [SubagentRef]
    var cwd: String?
    var gitBranch: String?
    var firstTs: Date?
    var lastTs: Date?
    var numUser: Int
    var numAssistant: Int
    var numTools: Int
    var usage: Usage
    var skills: [String]
    var preview: String

    var numSubagents: Int { subagents.count }

    func toDict() -> [String: Any] {
        let durMs: Int = {
            guard let a = firstTs, let b = lastTs else { return 0 }
            return Int(((b.timeIntervalSince1970 - a.timeIntervalSince1970) * 1000).rounded())
        }()
        return [
            "id": id,
            "project": project,
            "project_label": projectLabel,
            "cwd": cwd ?? NSNull(),
            "git_branch": gitBranch ?? NSNull(),
            "first_ts": firstTs.map(isoString) ?? NSNull(),
            "last_ts": lastTs.map(isoString) ?? NSNull(),
            "duration_ms": durMs,
            "num_user_msgs": numUser,
            "num_assistant_msgs": numAssistant,
            "num_tool_calls": numTools,
            "num_subagents": numSubagents,
            "usage": usage.toDict(),
            "skills": skills,
            "preview": preview,
            "detail_loaded": false,
        ]
    }
}

// 一个会话（main transcript + 已关联的 subagent）。可过滤字段保留为强类型，
// 完整 JSON 通过 toDict() 产出。
struct Session {
    var id: String
    var project: String          // 目录名（-Users-…）
    var projectLabel: String
    var cwd: String?
    var gitBranch: String?
    var firstTs: Date?
    var lastTs: Date?
    var numUser: Int
    var numAssistant: Int
    var numTools: Int
    var numSubagents: Int
    var usage: Usage
    var skills: [String]
    var preview: String
    var turns: [[String: Any]]
    var orphanSubagents: [[String: Any]]

    func toDict() -> [String: Any] {
        let durMs: Int = {
            guard let a = firstTs, let b = lastTs else { return 0 }
            return Int(((b.timeIntervalSince1970 - a.timeIntervalSince1970) * 1000).rounded())
        }()
        return [
            "id": id,
            "project": project,
            "project_label": projectLabel,
            "cwd": cwd ?? NSNull(),
            "git_branch": gitBranch ?? NSNull(),
            "first_ts": firstTs.map(isoString) ?? NSNull(),
            "last_ts": lastTs.map(isoString) ?? NSNull(),
            "duration_ms": durMs,
            "num_user_msgs": numUser,
            "num_assistant_msgs": numAssistant,
            "num_tool_calls": numTools,
            "num_subagents": numSubagents,
            "usage": usage.toDict(),
            "skills": skills,
            "preview": preview,
            "turns": turns,
            "orphan_subagents": orphanSubagents,
        ]
    }
}

// 当前生效的筛选条件（对应原命令行 flag）。
struct Scope {
    enum Since: String, CaseIterable {
        case d7 = "7d", h24 = "24h", d30 = "30d", all = "all"
        var date: Date? {
            switch self {
            case .all: return nil
            case .h24: return Date(timeIntervalSinceNow: -24 * 3600)
            case .d7: return Date(timeIntervalSinceNow: -7 * 86400)
            case .d30: return Date(timeIntervalSinceNow: -30 * 86400)
            }
        }
    }
    static let defaultMaxSessions = 40
    var since: Since = .d7
    var projectLabel: String? = nil   // nil = 全部项目
    var maxSessions: Int = defaultMaxSessions
}

// ISO8601 带毫秒，形如 2026-06-22T01:31:23.003Z —— 与 JS Date.toISOString() 一致。
private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

func isoString(_ d: Date) -> String { isoFormatter.string(from: d) }
func parseTimestamp(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    return isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}
