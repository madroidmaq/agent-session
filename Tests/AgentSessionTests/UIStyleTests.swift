import XCTest
@testable import AgentSession

final class UIStyleTests: XCTestCase {
    func testMissingOrInvalidValueFallsBackToAuto() {
        XCTAssertEqual(UIStyle.resolve(nil), .auto)
        XCTAssertEqual(UIStyle.resolve(""), .auto)
        XCTAssertEqual(UIStyle.resolve("unknown"), .auto)
    }

    func testSupportedStylesResolveFromStableRawValues() {
        XCTAssertEqual(UIStyle.resolve("auto"), .auto)
        XCTAssertEqual(UIStyle.resolve("claude"), .claude)
        XCTAssertEqual(UIStyle.resolve("codex"), .codex)
        XCTAssertEqual(UIStyle.resolve("grok"), .grok)
    }

    func testCSSClassesMatchRootThemeSelectors() {
        XCTAssertEqual(UIStyle.auto.cssClass, "ui-auto")
        XCTAssertEqual(UIStyle.claude.cssClass, "ui-claude")
        XCTAssertEqual(UIStyle.codex.cssClass, "ui-codex")
        XCTAssertEqual(UIStyle.grok.cssClass, "ui-grok")
    }

    func testTranscriptTemplateKeepsSourceSpecificMessageGrammar() throws {
        let html = try templateHTML()

        XCTAssertTrue(html.contains("renderConversationSplit(turns, tabKey, subKeyOf, source)"))
        XCTAssertTrue(html.contains("conversation source-${source}"))
        XCTAssertTrue(html.contains(".source-claude .msg-user"))
        XCTAssertTrue(html.contains(".source-codex .msg-user"))
        XCTAssertTrue(html.contains(".source-grok .msg-user"))
        XCTAssertTrue(html.contains("sourceToolName(source, name)"))
    }

    func testSessionHeaderDoesNotRepeatTheFirstPromptAsATitle() throws {
        let html = try templateHTML()

        XCTAssertTrue(html.contains("sessionHeaderHTML(s, agent)"))
        XCTAssertFalse(html.contains("<h1>${esc(s.preview)}</h1>"))
    }

    private func templateHTML() throws -> String {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let templateURL = repositoryRoot
            .appendingPathComponent("Sources/AgentSession/Resources/template.html")
        return try String(contentsOf: templateURL, encoding: .utf8)
    }
}
