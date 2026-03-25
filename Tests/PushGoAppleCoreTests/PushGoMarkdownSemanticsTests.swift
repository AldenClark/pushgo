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
}
