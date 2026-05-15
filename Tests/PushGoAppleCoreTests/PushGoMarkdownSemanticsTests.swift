import XCTest
@testable import PushGoAppleCore

final class PushGoMarkdownSemanticsTests: XCTestCase {
    func testParser_keepsLinkInsideTableCell() {
        let markdown = """
        | Name | Link |
        | --- | --- |
        | Docs | [Guide](https://example.com/path_(v2)) |
        """

        let document = PushGoMarkdownParser().parse(markdown)
        guard case let .table(table) = document.blocks.first else {
            return XCTFail("expected a table block")
        }
        guard table.rows.count == 1, table.rows[0].count == 2 else {
            return XCTFail("expected one parsed data row with two cells")
        }

        XCTAssertEqual(table.rows[0][0], [.text("Docs")])
        XCTAssertEqual(
            table.rows[0][1],
            [.link(text: [.text("Guide")], url: "https://example.com/path_(v2)")]
        )
    }

    func testListPreview_preservesOrderedListNumbersAndLinkSemantics() {
        let markdown = """
        3. [Read guide](https://example.com/guide)
        4. Next step
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(
            preview,
            """
            3. Read guide (https://example.com/guide)
            4. Next step
            """
        )
    }

    func testListPreview_skipsTableContent() {
        let markdown = """
        | Service | Link |
        | --- | --- |
        | PushGo | [Open](https://example.com/pushgo) |
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(preview, "")
    }

    func testListPreview_skipsMarkdownImages() {
        let markdown = """
        ![Diagram](https://example.com/arch_(v2).png)
        1. Keep this line
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(preview, "1. Keep this line")
    }

    func testListPreview_skipsCodeBlocksAndHTMLButKeepsBlockquotesAndTasks() {
        let markdown = """
        ```json
        {"env":"prod"}
        ```
        <div>hidden</div>
        > Keep quote
        - [x] Keep task
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(
            preview,
            """
            Keep quote
            - [x] Keep task
            """
        )
    }

    func testListPreview_skipsPureLinkCollections() {
        let markdown = """
        [Docs](https://example.com/docs) | [Status](https://example.com/status)

        Keep this paragraph after [link](https://example.com/keep) now
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(preview, "Keep this paragraph after link (https://example.com/keep) now")
    }

    func testListPreview_skipsLinkedImagesAndSinglePureLinks() {
        let markdown = """
        [![tupian](https://i.v2ex.co/H0LZ8hZ1.png "tupian")](https://i.v2ex.co/H0LZ8hZ1.png "tupian")

        [Standalone](https://example.com/only)

        Keep this paragraph after [link](https://example.com/keep) now
        """

        let preview = MessagePreviewExtractor.listPreview(from: markdown)
        XCTAssertEqual(preview, "Keep this paragraph after link (https://example.com/keep) now")
    }

    func testDisplayMode_keepsStructuredRenderingForModerateMultilineMarkdown() {
        let markdown = """
        # Runtime quality
        - item 1
        - item 2
        - item 3
        """

        XCTAssertEqual(pushGoMarkdownDisplayMode(for: markdown), .structuredText)
    }

    func testDisplayMode_keepsInlineRenderingForShortSingleLineMarkdown() {
        let markdown = "Visit [PushGo](https://example.com/pushgo)"
        XCTAssertEqual(pushGoMarkdownDisplayMode(for: markdown), .inlineText)
    }

    func testDisplayMode_keepsStructuredRenderingForGatewaySizedMarkdown() {
        let markdownSafetyCapBytes = 27 * 1024
        let markdown = String(repeating: "## Runtime quality headline\n- payload line\n", count: 642)
        XCTAssertLessThan(markdown.lengthOfBytes(using: .utf8), markdownSafetyCapBytes)
        XCTAssertEqual(pushGoMarkdownDisplayMode(for: markdown), .structuredText)
    }

    func testPlainTextDisplaySegments_preserveGatewaySizedContentExactly() {
        let markdownSafetyCapBytes = 27 * 1024
        let markdown = String(repeating: "emoji 😀 中日英 mixed line with url https://example.com/path\n", count: 418)
        XCTAssertLessThan(markdown.lengthOfBytes(using: .utf8), markdownSafetyCapBytes)
        let segments = pushGoPlainTextDisplaySegments(for: markdown, maxChunkBytes: 4 * 1024, maxChunkLines: 64)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.joined(), markdown)
    }

    func testPlainTextDisplaySegments_keepSmallContentAsSingleSegment() {
        let markdown = "plain text line 1\nplain text line 2"
        XCTAssertEqual(
            pushGoPlainTextDisplaySegments(for: markdown, maxChunkBytes: 4 * 1024, maxChunkLines: 64),
            [markdown]
        )
    }

    func testBoundedPreviewSource_capsGatewaySizedMarkdownToHeadRegion() {
        let markdownSafetyCapBytes = 27 * 1024
        let head = String(repeating: "- keep preview line\n", count: 40)
        let tail = String(repeating: "tail payload with code block marker ``` and table | a | b |\n", count: 447)
        XCTAssertLessThan((head + tail).lengthOfBytes(using: .utf8), markdownSafetyCapBytes)
        let source = MessagePreviewExtractor.boundedPreviewSource(
            head + tail,
            maxLines: 6,
            maxCharacters: 1200
        )

        XCTAssertTrue(source.hasPrefix(head))
        XCTAssertLessThan(source.count, (head + tail).count)
        XCTAssertLessThanOrEqual(source.count, 16_384)
    }
}
