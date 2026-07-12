import Foundation
import SQLite3

// SQLite + FTS5(trigram) 持久全文索引：一行 = 一个 main transcript 的「可搜索文本」
// （从 ParsedFile turns 提取，剔除 JSONL 结构噪声）。trigram tokenizer 提供大小写
// 不敏感的子串匹配语义（含 CJK），与原线性 grep 行为一致；<3 字符查询退化为 LIKE 扫描。
//
// 增量：files 表记录 (path, mtime, size)，未变文件跳过重建。同步在自有串行队列上
// 按小批次执行，搜索请求可在批次间插队，首次全量建库时不会长时间阻塞搜索。
final class SearchIndex {
    struct Entry {
        let path: String
        let mtime: Date
        let size: Int
        let extractText: () -> String
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "AgentSession.SearchIndex", qos: .utility)
    private let stateLock = NSLock()
    private var currentEntries: [Entry]?
    private var entriesGeneration = 0
    private let chunkSize = 20
    // 同步生命周期：scheduleSync 进入忙碌时 enter()，drainChunk 跑到真正空闲时 leave()。
    // waitForPendingSync 用 group.wait() 信号等待，避免忙等烧 CPU。
    private let syncGroup = DispatchGroup()
    // trigram tokenizer 在当前 SQLite 上是否可用（老版本不带 trigram → 建表失败 → 表不存在）。
    private var ftsAvailable = false
    // 是否已完成至少一次同步。首次建库期间搜索回退线性扫描，避免空索引导致 0 命中。
    // 仅在 queue 上下文（drainChunk 写 / search 读）访问，串行无需加锁。
    private var ready = false

    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init?(dbPath: String) {
        let dir = (dbPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard sqlite3_open(dbPath, &db) == SQLITE_OK, db != nil else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        // schema 变更时递增 user_version 并整体重建
        if scalarInt("PRAGMA user_version") != 1 {
            exec("DROP TABLE IF EXISTS files")
            exec("DROP TABLE IF EXISTS fts")
            exec("""
                CREATE TABLE files(
                    id INTEGER PRIMARY KEY,
                    path TEXT UNIQUE NOT NULL,
                    mtime REAL NOT NULL,
                    size INTEGER NOT NULL
                )
                """)
            exec("CREATE VIRTUAL TABLE fts USING fts5(content, tokenize='trigram')")
            exec("PRAGMA user_version=1")
        }
        // 探测 fts 表是否真的可查：trigram tokenizer 在老 SQLite 上 CREATE 会失败，
        // 此处 prepare 失败（表不存在）即标记不可用，search 将返回 nil 让上层回退线性扫描。
        var probe: OpaquePointer?
        ftsAvailable = sqlite3_prepare_v2(db, "SELECT 1 FROM fts LIMIT 0", -1, &probe, nil) == SQLITE_OK
        if probe != nil { sqlite3_finalize(probe) }
        // 重开已有数据的库 → 视为可信，无需等首次同步即可搜索；空库保持未 ready。
        if ftsAvailable, scalarInt("SELECT COUNT(*) FROM files") > 0 { ready = true }
    }

    deinit { sqlite3_close(db) }

    // MARK: - 同步（增量，分批）

    // 覆盖式提交本次扫描看到的全部 main 文件；重复调用会合并（只保留最新一批）。
    func scheduleSync(_ entries: [Entry]) {
        stateLock.lock()
        entriesGeneration += 1
        let wasIdle = currentEntries == nil
        currentEntries = entries
        stateLock.unlock()
        if wasIdle {
            syncGroup.enter()
            queue.async { self.drainChunk() }
        }
    }

    // 等待当前所有待同步批次完成（测试 / 基准用）。
    func waitForPendingSync() {
        syncGroup.wait()
    }

    // 每次处理至多 chunkSize 个待更新文件后把自己重新入队，让排队的搜索请求插队执行。
    // 每轮重读 files 表定位剩余脏文件 —— 表只有 O(会话数) 行，代价可忽略且天然幂等。
    private func drainChunk() {
        stateLock.lock()
        guard let entries = currentEntries else { stateLock.unlock(); return }
        let generation = entriesGeneration
        stateLock.unlock()

        var dbFiles: [String: (id: Int64, mtime: Double, size: Int64)] = [:]
        query("SELECT id, path, mtime, size FROM files") { stmt in
            dbFiles[string(stmt, 1)] = (sqlite3_column_int64(stmt, 0),
                                        sqlite3_column_double(stmt, 2),
                                        sqlite3_column_int64(stmt, 3))
        }

        exec("BEGIN")
        // 已消失的文件（会话被删除）
        let want = Set(entries.map(\.path))
        for (path, f) in dbFiles where !want.contains(path) {
            exec("DELETE FROM fts WHERE rowid=\(f.id)")
            exec("DELETE FROM files WHERE id=\(f.id)")
        }
        var processed = 0
        var hasMore = false
        for e in entries {
            let epoch = e.mtime.timeIntervalSince1970
            if let f = dbFiles[e.path], f.mtime == epoch, f.size == Int64(e.size) { continue }
            if processed >= chunkSize { hasMore = true; break }
            upsert(path: e.path, mtime: epoch, size: e.size,
                   existingId: dbFiles[e.path]?.id, content: e.extractText())
            processed += 1
        }
        exec("COMMIT")

        if hasMore {
            queue.async { self.drainChunk() }
            return
        }
        stateLock.lock()
        if entriesGeneration == generation { currentEntries = nil }
        let again = currentEntries != nil
        stateLock.unlock()
        if again {
            queue.async { self.drainChunk() }
        } else {
            ready = true
            syncGroup.leave()
        }
    }

    private func upsert(path: String, mtime: Double, size: Int, existingId: Int64?, content: String) {
        let id: Int64
        if let existingId {
            run("UPDATE files SET mtime=?, size=? WHERE id=?") { stmt in
                sqlite3_bind_double(stmt, 1, mtime)
                sqlite3_bind_int64(stmt, 2, Int64(size))
                sqlite3_bind_int64(stmt, 3, existingId)
            }
            exec("DELETE FROM fts WHERE rowid=\(existingId)")
            id = existingId
        } else {
            run("INSERT INTO files(path, mtime, size) VALUES(?,?,?)") { stmt in
                sqlite3_bind_text(stmt, 1, path, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 2, mtime)
                sqlite3_bind_int64(stmt, 3, Int64(size))
            }
            id = sqlite3_last_insert_rowid(db)
        }
        run("INSERT INTO fts(rowid, content) VALUES(?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, id)
            sqlite3_bind_text(stmt, 2, content, -1, Self.SQLITE_TRANSIENT)
        }
    }

    // MARK: - 搜索

    // 返回 path -> 命中片段；nil 表示索引不可用（trigram 不支持 / 首次同步未完成），
    // 调用方应回退线性扫描。≥3 字符走 trigram MATCH（大小写不敏感子串），
    // 更短的查询 LIKE 全扫描存储文本（仍远快于读原始文件）。
    func search(_ rawQuery: String) -> [String: String]? {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [:] }
        return queue.sync {
            guard ftsAvailable, ready else { return nil }
            var hits: [String: String] = [:]
            func record(_ stmt: OpaquePointer?) {
                let path = string(stmt, 0)
                let content = string(stmt, 1)
                hits[path] = Self.snippet(content, query: q)
            }
            if q.count >= 3 {
                let match = "\"" + q.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                query("SELECT f.path, fts.content FROM fts JOIN files f ON f.id = fts.rowid WHERE fts MATCH ?",
                      bind: { sqlite3_bind_text($0, 1, match, -1, Self.SQLITE_TRANSIENT) },
                      row: record)
            } else {
                var escaped = q
                for c in ["\\", "%", "_"] { escaped = escaped.replacingOccurrences(of: c, with: "\\" + c) }
                query("SELECT f.path, fts.content FROM fts JOIN files f ON f.id = fts.rowid WHERE fts.content LIKE ? ESCAPE '\\'",
                      bind: { sqlite3_bind_text($0, 1, "%" + escaped + "%", -1, Self.SQLITE_TRANSIENT) },
                      row: record)
            }
            return hits
        }
    }

    // 命中位置 ±80 字符压平成一行（与原线性搜索的片段风格一致）。
    static func snippet(_ content: String, query: String) -> String {
        guard let range = content.range(of: query, options: [.caseInsensitive]) else {
            return String(content.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        }
        let pad = 80
        let start = content.index(range.lowerBound, offsetBy: -pad, limitedBy: content.startIndex) ?? content.startIndex
        let end = content.index(range.upperBound, offsetBy: pad, limitedBy: content.endIndex) ?? content.endIndex
        var s = String(content[start..<end])
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SQLite 小工具（都在 queue 上调用）

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func scalarInt(_ sql: String) -> Int64 {
        var result: Int64 = 0
        query(sql) { result = sqlite3_column_int64($0, 0) }
        return result
    }

    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        sqlite3_step(stmt)
    }

    private func query(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil,
                       row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    private func string(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }
}

// 从解析结果提取可搜索纯文本：用户/助手/思考文本、slash 命令与参数、
// 工具名 + 摘要 + 输入、tool_result 内容。与 template.html 展示的内容对齐。
func searchableText(_ parsed: ParsedFile) -> String {
    var parts: [String] = []
    func clipText(_ v: Any?) -> String? {
        if let d = v as? [String: Any], let s = d["text"] as? String, !s.isEmpty { return s }
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }
    for t in parsed.turns {
        if let cmd = t["cmd"] as? String { parts.append("/" + cmd) }
        if let s = clipText(t["text"]) { parts.append(s) }
        if let s = clipText(t["args"]) { parts.append(s) }
        if let name = t["name"] as? String { parts.append(name) }
        if let s = t["summary"] as? String, !s.isEmpty { parts.append(s) }
        if let input = t["input"], !(input is NSNull) {
            let j = compactJSON(input)
            if !j.isEmpty, j != "{}" { parts.append(j) }
        }
        if let s = clipText(t["content"]) { parts.append(s) }
        if let s = clipText(t["skill_body"]) { parts.append(s) }
    }
    return parts.joined(separator: "\n")
}
