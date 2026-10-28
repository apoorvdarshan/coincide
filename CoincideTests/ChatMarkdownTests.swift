import Foundation
import Testing

@testable import Coincide

private typealias Block = ChatMarkdown.Block
private typealias Inline = ChatMarkdown.Inline

private func parse(_ text: String) -> [Block] { ChatMarkdown.parse(text) }

/// The inlines of a text that parses as one paragraph.
private func inlines(_ text: String) -> [Inline] {
    let blocks = ChatMarkdown.parse(text)
    guard blocks.count == 1, case .paragraph(let inlines) = blocks[0] else {
        Issue.record("Expected one paragraph for \(text.debugDescription), got \(blocks)")
        return []
    }
    return inlines
}

private func paragraph(_ text: String) -> Block { .paragraph([.text(text)]) }

private func list(ordered: Bool = false, start: Int = 0, tight: Bool = true, _ items: [[Block]], tasks: [Bool?]? = nil) -> Block {
    let items = items.enumerated().map { index, blocks in
        ChatMarkdown.ListItem(task: tasks?[index] ?? nil, blocks: blocks)
    }
    return .list(ChatMarkdown.List(isOrdered: ordered, start: start, isTight: tight, items: items))
}

struct ChatMarkdownBlockTests {
    // MARK: Headings

    @Test func atxHeadingsTakeOneToSixHashesAndASpace() {
        #expect(parse("# Title") == [.heading(level: 1, [.text("Title")])])
        #expect(parse("###### Six") == [.heading(level: 6, [.text("Six")])])
        #expect(parse("####### Seven") == [paragraph("####### Seven")])
        #expect(parse("#hashtag") == [paragraph("#hashtag")])
        #expect(parse("   ## Indented") == [.heading(level: 2, [.text("Indented")])])
        // An empty heading, as a reply that is still streaming may end.
        #expect(parse("#") == [.heading(level: 1, [])])
    }

    @Test func aClosingRunOfHashesIsDecorationButAHashtagIsNot() {
        #expect(parse("## Closing ##") == [.heading(level: 2, [.text("Closing")])])
        #expect(parse("# Issue #12") == [.heading(level: 1, [.text("Issue #12")])])
        #expect(parse("# Sharp#") == [.heading(level: 1, [.text("Sharp#")])])
        #expect(parse("# ###") == [.heading(level: 1, [])])
    }

    @Test func setextUnderlinesMakeHeadingsOfTheParagraphAbove() {
        #expect(parse("Title\n=====") == [.heading(level: 1, [.text("Title")])])
        #expect(parse("Title\n---") == [.heading(level: 2, [.text("Title")])])
        #expect(parse("Two\nlines\n===") == [.heading(level: 1, [.text("Two"), .softBreak, .text("lines")])])
        // After a blank line the dashes are a rule.
        #expect(parse("Para\n\n---") == [paragraph("Para"), .rule])
    }

    // MARK: Paragraphs and breaks

    @Test func paragraphsAreSeparatedByBlankLines() {
        #expect(parse("one\n\ntwo") == [paragraph("one"), paragraph("two")])
        #expect(parse("\n\n  \nonly\n\n\n") == [paragraph("only")])
        #expect(parse("") == [])
    }

    @Test func lineEndsInsideAParagraphAreSoftUnlessMarkedHard() {
        #expect(inlines("one\ntwo") == [.text("one"), .softBreak, .text("two")])
        #expect(inlines("one  \ntwo") == [.text("one"), .lineBreak, .text("two")])
        #expect(inlines("one\\\ntwo") == [.text("one"), .lineBreak, .text("two")])
        #expect(inlines("one<br>two<br/>three") == [.text("one"), .lineBreak, .text("two"), .lineBreak, .text("three")])
        // Leading spaces of the next line are not content.
        #expect(inlines("one\n   two") == [.text("one"), .softBreak, .text("two")])
    }

    @Test func windowsLineEndingsReadLikeUnixOnes() {
        #expect(parse("# A\r\n\r\none\r\ntwo\r\n") == parse("# A\n\none\ntwo\n"))
        #expect(parse("```\r\ncode\r\n```") == [.code(language: nil, text: "code")])
    }

    // MARK: Code

    @Test func fencedCodeKeepsItsLanguageAndText() {
        #expect(parse("```swift\nlet x = 1\n\nprint(x)\n```") == [.code(language: "swift", text: "let x = 1\n\nprint(x)")])
        #expect(parse("~~~\n*not emphasis*\n~~~") == [.code(language: nil, text: "*not emphasis*")])
        // Only the first word of the info string names the language.
        #expect(parse("```ts title=\"a.ts\"\nx\n```") == [.code(language: "ts", text: "x")])
    }

    @Test func anUnclosedFenceRunsToTheEndSoAStreamingReplyStaysCode() {
        #expect(parse("Intro\n\n```python\nprint(1)\n") == [paragraph("Intro"), .code(language: "python", text: "print(1)\n")])
        #expect(parse("```") == [.code(language: nil, text: "")])
    }

    @Test func aFenceClosesOnlyWithAtLeastAsManyMarkersOfTheSameKind() {
        #expect(parse("````\n```\nstill code\n~~~~\n````\nafter") == [
            .code(language: nil, text: "```\nstill code\n~~~~"), paragraph("after"),
        ])
        // A closing fence takes no info string.
        #expect(parse("```\na\n``` js\nb\n```") == [.code(language: nil, text: "a\n``` js\nb")])
    }

    @Test func aFenceIndentIsRemovedFromItsLines() {
        #expect(parse("  ```\n    two\n  one\nnone\n  ```") == [.code(language: nil, text: "  two\none\nnone")])
    }

    @Test func backticksInTheInfoStringMeanItIsNoFence() {
        #expect(parse("``` a`b") == [paragraph("``` a`b")])
    }

    @Test func fourSpacesOrATabIndentCode() {
        #expect(parse("    let a = 1\n\n    let b = 2\n\n\nafter") == [.code(language: nil, text: "let a = 1\n\nlet b = 2"), paragraph("after")])
        #expect(parse("\tcode") == [.code(language: nil, text: "code")])
        // Indented lines continue a paragraph instead.
        #expect(parse("para\n    more") == [.paragraph([.text("para"), .softBreak, .text("more")])])
    }

    // MARK: Rules and quotes

    @Test func threeOrMoreMarkersMakeARule() {
        for rule in ["---", "***", "___", "- - -", " * * * *"] {
            #expect(parse(rule) == [.rule], "\(rule)")
        }
        #expect(parse("--") == [paragraph("--")])
        #expect(parse("-- x") == [paragraph("-- x")])
    }

    @Test func quotesHoldBlocksAndContinueLazily() {
        #expect(parse("> one\n> two") == [.quote([.paragraph([.text("one"), .softBreak, .text("two")])])])
        #expect(parse("> one\nlazy") == [.quote([.paragraph([.text("one"), .softBreak, .text("lazy")])])])
        #expect(parse("> one\n\nafter") == [.quote([paragraph("one")]), paragraph("after")])
        #expect(parse("> > nested") == [.quote([.quote([paragraph("nested")])])])
        #expect(parse("> # Head\n> - item") == [.quote([.heading(level: 1, [.text("Head")]), list([[paragraph("item")]])])])
        // A line that starts a block of its own ends the quote.
        #expect(parse("> quoted\n- item") == [.quote([paragraph("quoted")]), list([[paragraph("item")]])])
    }

    // MARK: Lists

    @Test func bulletListsAreTightUnlessItemsAreSeparatedByBlankLines() {
        #expect(parse("- a\n- b") == [list([[paragraph("a")], [paragraph("b")]])])
        #expect(parse("* a\n\n* b") == [list(tight: false, [[paragraph("a")], [paragraph("b")]])])
        #expect(parse("- a\n\n  more\n- b") == [list(tight: false, [[paragraph("a"), paragraph("more")], [paragraph("b")]])])
    }

    @Test func orderedListsKeepTheirStartNumber() {
        #expect(parse("3. three\n4. four") == [list(ordered: true, start: 3, [[paragraph("three")], [paragraph("four")]])])
        #expect(parse("1) one\n2) two") == [list(ordered: true, start: 1, [[paragraph("one")], [paragraph("two")]])])
        // Ten digits are too many for a list number.
        #expect(parse("1234567890. big") == [paragraph("1234567890. big")])
    }

    @Test func aDifferentMarkerStartsANewList() {
        #expect(parse("- a\n+ b") == [list([[paragraph("a")]]), list([[paragraph("b")]])])
        #expect(parse("1. a\n2) b") == [list(ordered: true, start: 1, [[paragraph("a")]]), list(ordered: true, start: 2, [[paragraph("b")]])])
    }

    @Test func nestedListsBelongToTheirItem() {
        let nested = parse("- top\n  - inner\n    1. deep\n- next")
        #expect(nested == [
            list([
                [paragraph("top"), list([[paragraph("inner"), list(ordered: true, start: 1, [[paragraph("deep")]])]])],
                [paragraph("next")],
            ])
        ])
    }

    @Test func listItemsCanHoldCodeAndContinueLazily() {
        #expect(parse("- item\n  ```sh\n  ls\n  ```") == [list([[paragraph("item"), .code(language: "sh", text: "ls")]])])
        #expect(parse("- item\nlazy line") == [list([[.paragraph([.text("item"), .softBreak, .text("lazy line")])]])])
    }

    @Test func taskItemsRecordWhetherTheyAreDone() {
        #expect(
            parse("- [ ] todo\n- [x] done\n- [X] also\n- [?] plain") == [
                list(
                    [[paragraph("todo")], [paragraph("done")], [paragraph("also")], [paragraph("[?] plain")]],
                    tasks: [false, true, true, nil])
            ])
        #expect(parse("- [x]") == [list([[]], tasks: [true])])
        // The box needs a space after it.
        #expect(parse("- [x]done") == [list([[paragraph("[x]done")]])])
    }

    @Test func onlyAListStartingAtOneInterruptsAParagraph() {
        #expect(parse("Intro\n2. two") == [.paragraph([.text("Intro"), .softBreak, .text("2. two")])])
        #expect(parse("Intro\n1. one") == [paragraph("Intro"), list(ordered: true, start: 1, [[paragraph("one")]])])
        #expect(parse("Intro\n- item") == [paragraph("Intro"), list([[paragraph("item")]])])
        // An empty item does not interrupt one; a lone dash underlines it.
        #expect(parse("Intro\n-") == [.heading(level: 2, [.text("Intro")])])
    }

    // MARK: Tables

    @Test func tablesReadAlignmentsHeaderAndRows() {
        let table = parse("| Name | Count | Mid |\n|:-----|------:|:---:|\n| a | 1 | x |\n| b | 2 | y |")
        #expect(
            table == [
                .table(
                    ChatMarkdown.Table(
                        alignments: [.left, .right, .center], header: [[.text("Name")], [.text("Count")], [.text("Mid")]],
                        rows: [[[.text("a")], [.text("1")], [.text("x")]], [[.text("b")], [.text("2")], [.text("y")]]]))
            ])
    }

    @Test func tableRowsArePaddedOrCutToTheHeader() {
        let table = parse("a | b\n--- | ---\n1\n1 | 2 | 3\n`x \\| y` | **z**")
        #expect(
            table == [
                .table(
                    ChatMarkdown.Table(
                        alignments: [.none, .none], header: [[.text("a")], [.text("b")]],
                        rows: [
                            [[.text("1")], []],
                            [[.text("1")], [.text("2")]],
                            [[.code("x | y")], [.strong([.text("z")])]],
                        ]))
            ])
    }

    @Test func aTableNeedsADelimiterRowMatchingItsHeader() {
        #expect(parse("| a | b |\n| --- |") == [.paragraph([.text("| a | b |"), .softBreak, .text("| --- |")])])
        #expect(parse("| a |\n| x |") == [.paragraph([.text("| a |"), .softBreak, .text("| x |")])])
    }

    @Test func aTableInterruptsAParagraphAndEndsAtABlankLine() {
        let blocks = parse("Intro\n| a |\n| - |\n| 1 |\n\nAfter")
        #expect(
            blocks == [
                paragraph("Intro"),
                .table(ChatMarkdown.Table(alignments: [.none], header: [[.text("a")]], rows: [[[.text("1")]]])),
                paragraph("After"),
            ])
    }
}

struct ChatMarkdownInlineTests {
    @Test func emphasisStrongAndBoth() {
        #expect(inlines("*a* _b_") == [.emphasis([.text("a")]), .text(" "), .emphasis([.text("b")])])
        #expect(inlines("**a** __b__") == [.strong([.text("a")]), .text(" "), .strong([.text("b")])])
        #expect(inlines("***both***") == [.emphasis([.strong([.text("both")])])])
        #expect(inlines("**bold *and italic***") == [.strong([.text("bold "), .emphasis([.text("and italic")])])])
    }

    @Test func underscoresInsideWordsAreLiteralButAsterisksAreNot() {
        #expect(inlines("snake_case_name") == [.text("snake_case_name")])
        #expect(inlines("2*3*4") == [.text("2"), .emphasis([.text("3")]), .text("4")])
    }

    @Test func delimitersNeedToFlankText() {
        #expect(inlines("a * b * c") == [.text("a * b * c")])
        #expect(inlines("*unclosed") == [.text("*unclosed")])
        #expect(inlines("**unbalanced*") == [.text("*"), .emphasis([.text("unbalanced")])])
    }

    @Test func strikethroughTakesExactlyTwoTildes() {
        #expect(inlines("~~gone~~") == [.strikethrough([.text("gone")])])
        #expect(inlines("~one~ ~~~three~~~") == [.text("~one~ ~~~three~~~")])
    }

    @Test func codeSpansKeepTheirContentLiteral() {
        #expect(inlines("`*x*`") == [.code("*x*")])
        #expect(inlines("`` a ` b ``") == [.code("a ` b")])
        #expect(inlines("` `") == [.code(" ")])
        #expect(inlines("`a\nb`") == [.code("a b")])
        #expect(inlines("`unclosed") == [.text("`unclosed")])
        #expect(inlines("``mismatch`") == [.text("``mismatch`")])
    }

    @Test func backslashEscapesPunctuationOnly() {
        #expect(inlines("\\*not\\* \\[x\\]") == [.text("*not* [x]")])
        #expect(inlines("C:\\Users") == [.text("C:\\Users")])
    }

    @Test func commonEntitiesDecode() {
        #expect(inlines("&amp; &lt;tag&gt; &quot;q&quot; &#39;s&apos; a&nbsp;b") == [.text("& <tag> \"q\" 's' a\u{00A0}b")])
        #expect(inlines("&unknown; & alone") == [.text("&unknown; & alone")])
    }

    @Test func inlineLinksWithTitlesAngleDestinationsAndParentheses() {
        #expect(inlines("[text](https://x.com)") == [.link(destination: "https://x.com", [.text("text")])])
        #expect(inlines("[t](https://x.com \"Title\")") == [.link(destination: "https://x.com", [.text("t")])])
        #expect(inlines("[t](<a file.md>)") == [.link(destination: "a file.md", [.text("t")])])
        #expect(inlines("[t](a(b)c)") == [.link(destination: "a(b)c", [.text("t")])])
        #expect(inlines("[t](a\\)b)") == [.link(destination: "a)b", [.text("t")])])
        #expect(inlines("[**bold** link](x)") == [.link(destination: "x", [.strong([.text("bold")]), .text(" link")])])
    }

    @Test func bracketsWithoutADestinationStayText() {
        #expect(inlines("[just brackets]") == [.text("[just brackets]")])
        #expect(inlines("[a] (b)") == [.text("[a] (b)")])
        #expect(inlines("[open](unclosed") == [.text("[open](unclosed")])
        #expect(inlines("a]b") == [.text("a]b")])
    }

    @Test func linksCannotContainLinks() {
        #expect(inlines("[a [b](c) d](e)") == [.text("[a "), .link(destination: "c", [.text("b")]), .text(" d](e)")])
    }

    @Test func imagesKeepTheirAltTextAndSource() {
        #expect(inlines("![A *cat*](cat.png)") == [.image(alt: "A cat", source: "cat.png")])
        #expect(inlines("![alt]") == [.text("![alt]")])
    }

    @Test func angleAutolinksNeedASchemeOfTwoOrMoreLetters() {
        #expect(inlines("<https://a.b/c>") == [.link(destination: "https://a.b/c", [.text("https://a.b/c")])])
        #expect(inlines("<mailto:me@x.y>") == [.link(destination: "mailto:me@x.y", [.text("mailto:me@x.y")])])
        #expect(inlines("<c:path>") == [.text("<c:path>")])
        #expect(inlines("<not a link>") == [.text("<not a link>")])
        #expect(inlines("a < b") == [.text("a < b")])
    }

    @Test func bareURLsLinkWithoutTrailingPunctuation() {
        #expect(
            inlines("See https://example.com/a. Then") == [
                .text("See "), .link(destination: "https://example.com/a", [.text("https://example.com/a")]), .text(". Then"),
            ])
        #expect(inlines("www.example.com") == [.link(destination: "http://www.example.com", [.text("www.example.com")])])
        #expect(
            inlines("(https://en.wikipedia.org/wiki/A_(b))") == [
                .text("("),
                .link(destination: "https://en.wikipedia.org/wiki/A_(b)", [.text("https://en.wikipedia.org/wiki/A_(b)")]),
                .text(")"),
            ])
        #expect(inlines("**https://x.io**") == [.strong([.link(destination: "https://x.io", [.text("https://x.io")])])])
    }

    @Test func urlsInsideWordsOrWithoutAHostAreNotLinked() {
        #expect(inlines("xhttps://a.b") == [.text("xhttps://a.b")])
        #expect(inlines("https://") == [.text("https://")])
        #expect(inlines("http://.") == [.text("http://.")])
        #expect(inlines("whatever") == [.text("whatever")])
    }

    @Test func plainTextFlattensInlinesForLabels() {
        let text = inlines("**Bold** and `code`, [a link](x) ![pic](p.png)\nnext  \nline")
        #expect(ChatMarkdown.plainText(text) == "Bold and code, a link pic next\nline")
    }
}

/// Re-parsing a growing text from its last blocks, as a streaming reply does, gives what parsing it whole does.
struct ChatMarkdownIncrementalTests {
    private static let prefix = "# Before\n\n```ts\nconst values = [1, 2];\n```\n\n"

    /// Ported from T3 Code's incremental Markdown tests, minus HTML, references and footnotes, which Coincide
    /// does not render.
    nonisolated static let tails = [
        "a\n===\n\nb\n---\n",
        "- first\n\n  continued\n\n- next\n",
        "> quoted\n>\n> ```js\n> abc\n> ```\n\nend",
        "a | b\n--|--\na | b\n",
        "```\na\n```\n\nnext\n\n~~~\nb\n~~~\n\nmore",
        "\n\n\tcode\n\nmore",
        "text <https://example.com> *bold*",
        "- [ ] task\n- [x] done\n\n1. one\n2. two",
        "Intro\n#123 fixed\n\nNext\n#",
        "Para\n| a |\n| - |\n| 1 |\n\nafter",
        "- a\n  - b\n    - c\n\nend ünïcödé 🎉 text",
        "    indented\n    code\n\npara\n---\n",
    ]

    @Test(arguments: tails)
    func streamingEveryPrefixMatchesAFullParse(tail: String) {
        assertStreamingMatchesFullParse(Self.prefix + tail)
    }

    @Test func streamingCRLFTextMatchesAFullParse() {
        assertStreamingMatchesFullParse((Self.prefix + "next\n\n```\nlast\n```\n\nend").replacingOccurrences(of: "\n", with: "\r\n"))
    }

    @Test func blocksBeforeTheLastLinesAreKeptWhileTheTextGrows() {
        let first = ChatMarkdown.Document(parsing: Array("# One\n\npara\n\n- a\n- b\n".utf8))
        let (grown, kept) = first.reparsed(Array("# One\n\npara\n\n- a\n- b\n- c and more".utf8))
        #expect(kept == 2)
        #expect(grown.blocks == ChatMarkdown.parse("# One\n\npara\n\n- a\n- b\n- c and more"))
        #expect(grown.startLines == [0, 2, 4])
    }

    @Test func anEditedTextIsParsedAgainFromTheStart() {
        let first = ChatMarkdown.Document(parsing: Array("# One\n\npara\n\nmore\n".utf8))
        let edited = "# Uno\n\npara\n\nmore\nstill"
        let (document, kept) = first.reparsed(Array(edited.utf8))
        #expect(kept == 0)
        #expect(document.blocks == ChatMarkdown.parse(edited))
        // A shorter text cannot reuse anything either.
        let (shorter, keptShorter) = first.reparsed(Array("# One".utf8))
        #expect(keptShorter == 0)
        #expect(shorter.blocks == ChatMarkdown.parse("# One"))
    }

    @Test func aGrowingLastLineCanJoinTheBlockBeforeIt() {
        // `Intro` then `#` is a paragraph and an empty heading, until the line reads `#123 fixed`.
        let before = ChatMarkdown.Document(parsing: Array("Start\n\nIntro\n#".utf8))
        #expect(before.blocks == [paragraph("Start"), paragraph("Intro"), .heading(level: 1, [])])
        let (after, _) = before.reparsed(Array("Start\n\nIntro\n#123 fixed".utf8))
        #expect(after.blocks == [paragraph("Start"), .paragraph([.text("Intro"), .softBreak, .text("#123 fixed")])])
    }

    /// Feeds the text one character at a time, re-parsing incrementally, and compares each step with a full parse.
    private func assertStreamingMatchesFullParse(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) {
        var document = ChatMarkdown.Document(parsing: [])
        var text = ""
        for character in source {
            text.append(character)
            let bytes = Array(text.utf8)
            document = document.reparsed(bytes).document
            let full = ChatMarkdown.Document(parsing: bytes)
            guard document.blocks == full.blocks, document.startLines == full.startLines else {
                Issue.record("Streaming diverged at \(text.debugDescription)", sourceLocation: sourceLocation)
                return
            }
            #expect(document.lastLine == full.lastLine, sourceLocation: sourceLocation)
            #expect(document.lastLineOffset == full.lastLineOffset, sourceLocation: sourceLocation)
            #expect(document.startOffsets == full.startOffsets, sourceLocation: sourceLocation)
        }
    }
}
