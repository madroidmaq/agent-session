import XCTest
@testable import AgentSession

final class WorktreeProjectTests: XCTestCase {
    func testCanonicalizeLeavesNormalProjectUnchanged() {
        let raw = "-Users-madroid-dev-agent-session"

        let identity = canonicalizeProjectDir(raw)

        XCTAssertEqual(identity.project, raw)
        XCTAssertEqual(identity.rawProject, raw)
        XCTAssertNil(identity.worktreeName)
        XCTAssertFalse(identity.isWorktree)
    }

    func testCanonicalizeWorktreeProject() {
        let raw = "-Users-madroid-dev-hm-applet-companion--claude-worktrees-zippy-wondering-pine"

        let identity = canonicalizeProjectDir(raw)

        XCTAssertEqual(identity.project, "-Users-madroid-dev-hm-applet-companion")
        XCTAssertEqual(identity.rawProject, raw)
        XCTAssertEqual(identity.worktreeName, "zippy-wondering-pine")
        XCTAssertTrue(identity.isWorktree)
    }

    func testCanonicalizeIgnoresInvalidWorktreeMarkers() {
        let emptyBase = "--claude-worktrees-zippy"
        let emptyName = "-Users-madroid-dev-hm-applet-companion--claude-worktrees-"

        let emptyBaseIdentity = canonicalizeProjectDir(emptyBase)
        XCTAssertEqual(emptyBaseIdentity.project, emptyBase)
        XCTAssertNil(emptyBaseIdentity.worktreeName)
        XCTAssertFalse(emptyBaseIdentity.isWorktree)

        let emptyNameIdentity = canonicalizeProjectDir(emptyName)
        XCTAssertEqual(emptyNameIdentity.project, emptyName)
        XCTAssertNil(emptyNameIdentity.worktreeName)
        XCTAssertFalse(emptyNameIdentity.isWorktree)
    }

    func testClassifyMainTranscriptUsesCanonicalProject() {
        let root = "/tmp/projects"
        let raw = "-Users-madroid-dev-hm-applet-companion--claude-worktrees-zippy-wondering-pine"
        let path = "\(root)/\(raw)/session-123.jsonl"

        let info = TranscriptParser(root: root).classify(path)

        XCTAssertEqual(info.kind, .main)
        XCTAssertEqual(info.sessionId, "session-123")
        XCTAssertEqual(info.project, "-Users-madroid-dev-hm-applet-companion")
        XCTAssertEqual(info.rawProject, raw)
        XCTAssertEqual(info.worktreeName, "zippy-wondering-pine")
        XCTAssertTrue(info.isWorktree)
    }

    func testClassifySubagentTranscriptKeepsWorktreeIdentity() {
        let root = "/tmp/projects"
        let raw = "-Users-madroid-dev-hm-applet-companion--claude-worktrees-zippy-wondering-pine"
        let path = "\(root)/\(raw)/session-123/subagents/agent-reviewer-abcdef.jsonl"

        let info = TranscriptParser(root: root).classify(path)

        XCTAssertEqual(info.kind, .subagent)
        XCTAssertEqual(info.sessionId, "session-123")
        XCTAssertEqual(info.agentId, "reviewer-abcdef")
        XCTAssertEqual(info.project, "-Users-madroid-dev-hm-applet-companion")
        XCTAssertEqual(info.rawProject, raw)
        XCTAssertEqual(info.worktreeName, "zippy-wondering-pine")
        XCTAssertTrue(info.isWorktree)
    }
}
