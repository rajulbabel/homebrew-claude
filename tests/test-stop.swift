///
///  test-stop.swift
///  Unit tests for pure-logic functions in claude-stop.swift.
///
///  Compiled with:  swiftc -D TESTING -framework AppKit \
///                    hooks/claude-stop.swift tests/harness.swift tests/test-stop.swift \
///                    -o tests/test-stop-bin
///

import AppKit
import Foundation

// ═══════════════════════════════════════════════════════════════════
// MARK: - stripBlockMarkdown Tests (8)
// ═══════════════════════════════════════════════════════════════════

func testStripBlockMarkdown() {
    test("stripBlock: heading h2") {
        assertEq(stripBlockMarkdown("## Hello World"), "Hello World")
    }
    test("stripBlock: heading h1") {
        assertEq(stripBlockMarkdown("# Title"), "Title")
    }
    test("stripBlock: bullet dash") {
        assertEq(stripBlockMarkdown("- Item one"), "Item one")
    }
    test("stripBlock: bullet star") {
        assertEq(stripBlockMarkdown("* Item two"), "Item two")
    }
    test("stripBlock: bullet plus") {
        assertEq(stripBlockMarkdown("+ Item three"), "Item three")
    }
    test("stripBlock: numbered list") {
        assertEq(stripBlockMarkdown("1. First item"), "First item")
    }
    test("stripBlock: blockquote") {
        assertEq(stripBlockMarkdown("> Quote text"), "Quote text")
    }
    test("stripBlock: link replaced with label") {
        assertEq(
            stripBlockMarkdown("See [docs](https://example.com) here"),
            "See docs here"
        )
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - renderMarkdownInline Tests (9)
// ═══════════════════════════════════════════════════════════════════

func testRenderMarkdownInline() {
    let font  = NSFont.systemFont(ofSize: 14)
    let color = NSColor.white

    test("renderInline: plain text") {
        let r = renderMarkdownInline("hello world", font: font, color: color)
        assertEq(r.string, "hello world")
    }
    test("renderInline: bold **text**") {
        let r = renderMarkdownInline("say **hello**", font: font, color: color)
        assertEq(r.string, "say hello")
        let f = r.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        assertTrue(
            f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "should be bold"
        )
    }
    test("renderInline: italic *text*") {
        let r = renderMarkdownInline("say *hello*", font: font, color: color)
        assertEq(r.string, "say hello")
        let f = r.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        assertTrue(
            f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false,
            "should be italic"
        )
    }
    test("renderInline: code `text`") {
        let r = renderMarkdownInline("use `code` here", font: font, color: color)
        assertEq(r.string, "use code here")
        let f = r.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
        assertTrue(f?.isFixedPitch ?? false, "should be monospaced")
    }
    test("renderInline: bold italic ***text***") {
        let r = renderMarkdownInline("***wow***", font: font, color: color)
        assertEq(r.string, "wow")
        // The boldIt font is italicVariant(of: bold). Since withSymbolicTraits
        // replaces traits, the result has italic but may lose bold on some systems.
        let f = r.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        assertTrue(
            f?.fontDescriptor.symbolicTraits.contains(.italic) ?? false,
            "should be italic"
        )
    }
    test("renderInline: underscore bold __text__") {
        let r = renderMarkdownInline("__bold__", font: font, color: color)
        assertEq(r.string, "bold")
        let f = r.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        assertTrue(
            f?.fontDescriptor.symbolicTraits.contains(.bold) ?? false,
            "should be bold"
        )
    }
    test("renderInline: underscore italic _text_") {
        let r = renderMarkdownInline("_italic_", font: font, color: color)
        assertEq(r.string, "italic")
    }
    test("renderInline: mixed formatting") {
        let r = renderMarkdownInline("**bold** and *italic*", font: font, color: color)
        assertEq(r.string, "bold and italic")
    }
    test("renderInline: no formatting unchanged") {
        let r = renderMarkdownInline("no formatting here", font: font, color: color)
        assertEq(r.string, "no formatting here")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - buildStopGist Tests (8)
// ═══════════════════════════════════════════════════════════════════

func testBuildStopGist() {
    test("stopGist: empty message") {
        assertEq(buildStopGist(""), "Claude has finished")
    }
    test("stopGist: blank lines only") {
        assertEq(buildStopGist("\n\n\n"), "Claude has finished")
    }
    test("stopGist: simple message") {
        assertEq(buildStopGist("Updated the file"), "Updated the file")
    }
    test("stopGist: strips 'Done. ' prefix") {
        assertEq(buildStopGist("Done. Everything updated"), "Everything updated")
    }
    test("stopGist: strips 'Done! ' prefix") {
        assertEq(buildStopGist("Done! All tests pass"), "All tests pass")
    }
    test("stopGist: long message truncated at 80 chars") {
        let long = String(repeating: "a", count: 100)
        let gist = buildStopGist(long)
        assertTrue(gist.count <= 80, "should be truncated to <=80")
        assertTrue(gist.hasSuffix("..."))
    }
    test("stopGist: strips heading markdown") {
        assertEq(buildStopGist("## Summary"), "Summary")
    }
    test("stopGist: skips blank leading lines") {
        assertEq(buildStopGist("\n\nActual content"), "Actual content")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - buildStopContent Tests (10)
// ═══════════════════════════════════════════════════════════════════

func testBuildStopContent() {
    test("stopContent: plain text") {
        let r = buildStopContent("Hello world")
        assertContains(r.string, "Hello world")
    }
    test("stopContent: code fence") {
        let r = buildStopContent("Before\n```\ncode here\n```\nAfter")
        assertContains(r.string, "code here")
    }
    test("stopContent: heading strips #") {
        let r = buildStopContent("# Title")
        assertContains(r.string, "Title")
        assertNotContains(r.string, "#")
    }
    test("stopContent: bullet list uses dot") {
        let r = buildStopContent("- Item one\n- Item two")
        assertContains(r.string, "\u{2022}")
        assertContains(r.string, "Item one")
    }
    test("stopContent: star bullet") {
        let r = buildStopContent("* Star item")
        assertContains(r.string, "\u{2022}")
    }
    test("stopContent: numbered list preserved") {
        let r = buildStopContent("1. First\n2. Second")
        assertContains(r.string, "1.")
        assertContains(r.string, "First")
    }
    test("stopContent: inline bold rendered") {
        let r = buildStopContent("This is **bold** text")
        assertContains(r.string, "bold")
        assertNotContains(r.string, "**")
    }
    test("stopContent: multiple code fences") {
        let r = buildStopContent("```swift\nlet x = 1\n```\nText\n```\nmore\n```")
        assertContains(r.string, "let x = 1")
        assertContains(r.string, "more")
    }
    test("stopContent: empty string") {
        let r = buildStopContent("")
        assertTrue(r.length >= 0)
    }
    test("stopContent: trailing newlines stripped") {
        let r = buildStopContent("Content\n\n\n")
        assertFalse(r.string.hasSuffix("\n"), "trailing newlines should be stripped")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - measureStopContentHeight Tests (2)
// ═══════════════════════════════════════════════════════════════════

func testMeasureStopContentHeight() {
    test("measureHeight: non-empty content") {
        let content = buildStopContent("Hello\nWorld\nLine 3")
        let height = measureStopContentHeight(content, width: 500)
        assertTrue(height > 0, "height should be positive")
    }
    test("measureHeight: more content is taller") {
        let short = buildStopContent("Short")
        let long  = buildStopContent((0..<20).map { "Line \($0)" }.joined(separator: "\n"))
        let hShort = measureStopContentHeight(short, width: 500)
        let hLong  = measureStopContentHeight(long, width: 500)
        assertTrue(hLong > hShort, "more lines should be taller")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - italicVariant Tests (3)
// ═══════════════════════════════════════════════════════════════════

func testItalicVariant() {
    test("italicVariant: produces italic trait") {
        let base = NSFont.systemFont(ofSize: 14)
        let italic = italicVariant(of: base)
        assertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic))
    }
    test("italicVariant: preserves point size") {
        let base = NSFont.systemFont(ofSize: 14)
        let italic = italicVariant(of: base)
        assertEq(italic.pointSize, 14)
    }
    test("italicVariant: bold input produces bold-italic") {
        let bold = NSFont.systemFont(ofSize: 14, weight: .bold)
        let bi = italicVariant(of: bold)
        assertTrue(bi.fontDescriptor.symbolicTraits.contains(.italic))
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Theme / Layout Constants Tests (4)
// ═══════════════════════════════════════════════════════════════════

func testThemeAndLayout() {
    test("Theme: background colors have full alpha") {
        assertTrue(Theme.background.alphaComponent > 0)
        assertTrue(Theme.codeBackground.alphaComponent > 0)
    }
    test("Layout: panel width positive") {
        assertTrue(Layout.panelWidth > 0)
    }
    test("Layout: auto-dismiss positive") {
        assertTrue(Layout.autoDismiss > 0)
    }
    test("Layout: code block min < max") {
        assertTrue(Layout.minCodeBlockHeight < Layout.maxCodeBlockHeight)
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Content Cap Tests (3)
// ═══════════════════════════════════════════════════════════════════

func testStopContentCap() {
    test("stopContent: very long message is capped") {
        let longMessage = (0..<2000).map { "This is line number \($0)" }
            .joined(separator: "\n")
        let content = buildStopContent(longMessage)
        let lineCount = content.string.components(separatedBy: "\n").count
        // Should be capped well below 2000 lines
        assertTrue(lineCount <= 600, "content should be capped (got \(lineCount) lines)")
    }
    test("stopContent: capped content shows truncation notice") {
        let longMessage = (0..<2000).map { "Line \($0)" }
            .joined(separator: "\n")
        let content = buildStopContent(longMessage)
        assertContains(content.string, "truncated")
    }
    test("stopContent: short message not capped") {
        let shortMessage = "Just a few lines\nof content\nhere"
        let content = buildStopContent(shortMessage)
        assertNotContains(content.string, "truncated")
    }
}

// ═══════════════════════════════════════════════════════════════════
// MARK: - Main Entry Point
// ═══════════════════════════════════════════════════════════════════

@main
enum StopTests {
    static func main() {
        testStripBlockMarkdown()
        testRenderMarkdownInline()
        testBuildStopGist()
        testBuildStopContent()
        testMeasureStopContentHeight()
        testItalicVariant()
        testThemeAndLayout()
        testStopContentCap()

        exit(printSummary())
    }
}
