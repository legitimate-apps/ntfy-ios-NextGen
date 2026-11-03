import XCTest
import UIKit
@testable import ntfy

final class FencedCodeTests: XCTestCase {
    func testLanguageFenceKeepsLiteralIndentationNewlinesAndUnicode() {
        let source = "Intro **bold**\n```python\n  print(\"🙂 *literal* https://example.com\")\n    next()\n```\nAfter `inline`"
        XCTAssertEqual(markdownSegments(source), [
            MarkdownSegment(text: "Intro **bold**\n", isCode: false),
            MarkdownSegment(text: "  print(\"🙂 *literal* https://example.com\")\n    next()\n", isCode: true),
            MarkdownSegment(text: "After `inline`", isCode: false)])
        let result = renderMessageBody(source, contentType: "text/markdown")
        XCTAssertEqual(String(result.characters), "Intro bold\n  print(\"🙂 *literal* https://example.com\")\n    next()\nAfter inline")
        let code = result.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        XCTAssertNil(code?.link)
    }
    func testLongerFenceIgnoresShorterAndWrongClosers() {
        XCTAssertEqual(markdownSegments("````sh\na\n```\n~~~\nb\n````\nend"), [
            MarkdownSegment(text: "a\n```\n~~~\nb\n", isCode: true), MarkdownSegment(text: "end", isCode: false)])
    }
    func testUnclosedFenceAndCRLF() {
        XCTAssertEqual(markdownSegments("```\r\n  a\r\n\r\nb"), [MarkdownSegment(text: "  a\r\n\r\nb", isCode: true)])
    }
    func testMultipleEmptyAndIndentedTildeBlocks() {
        XCTAssertEqual(markdownSegments("```\n```\ntext\n  ~~~json\n{}\n  ~~~~  \n"), [
            MarkdownSegment(text: "text\n", isCode: false), MarkdownSegment(text: "{}\n", isCode: true)])
    }
    func testInlineBackticksAndInvalidFenceRemainInline() {
        let source = "before `inline` after\n    ```\n```bad`info\n"
        XCTAssertEqual(markdownSegments(source), [MarkdownSegment(text: source, isCode: false)])
    }
    func testCodeAndInlineUseMonospaceLabelColorAndAdaptiveBackground() throws {
        let result = makeMessageNSAttributedString(renderMessageBody("```\n  value\n```\n`inline`", contentType: "text/markdown"), style: .body)
        XCTAssertEqual(result.string, "  value\ninline")
        for index in [2, 8] {
            let font = try XCTUnwrap(result.attribute(.font, at: index, effectiveRange: nil) as? UIFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
            XCTAssertEqual(result.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor, .label)
        }
        let background = try XCTUnwrap(result.attribute(.backgroundColor, at: 2, effectiveRange: nil) as? UIColor)
        XCTAssertNotEqual(background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)), background.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark)))
        XCTAssertNil(result.attribute(.link, at: 2, effectiveRange: nil))
    }
    func testPlainTextStaysOriginalAndLongCodeWrapsWithoutHyphens() throws {
        let source = "```sh\n  " + String(repeating: "token", count: 40) + "\n```"
        XCTAssertEqual(String(renderMessageBody(source, contentType: nil).characters), source)
        let rendered = makeMessageNSAttributedString(renderMessageBody(source, contentType: "text/markdown"), style: .body)
        let wrapped = applyMessageWrapping(to: rendered)
        let style = try XCTUnwrap(wrapped.attribute(.paragraphStyle, at: 2, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(style.headIndent, 8)
        XCTAssertEqual(wrapped.string, "  " + String(repeating: "token", count: 40) + "\n")
    }
}
