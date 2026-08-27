import SwiftUI

/// A light-touch markdown renderer.
///
/// Block structure (headings, bullets, quotes, fenced code, rules) is worked
/// out here, a line at a time, though consecutive prose lines gather into one
/// paragraph; inline spans are handed to `AttributedString`'s own markdown
/// parser so links, bold, italic and code all come for free.
struct MarkdownPreview: View {
    let text: String
    /// What ⌘F found, in the words the reader can see rather than the ones the
    /// file is written in — the store searched `visibleBlocks(of:)` for these.
    var find: Find = Find()
    /// Parsed once per document, not once per redraw, and laid out lazily: a
    /// long file used to re-split every line and build every view on every
    /// single render, which is most of a second in a 100 KB note.
    private let blocks: [Block]
    /// Matches by the block they landed in, each with its number in the whole
    /// document, so a block knows which of its own words is the current one.
    private let marks: [Int: [(ordinal: Int, range: NSRange)]]

    struct Find: Equatable {
        var matches: [FindMatch] = []
        /// The current match, counting from one; zero when there are none.
        var current: Int = 0
        /// Ticks over when the current match moves, which is when to scroll.
        var revealToken: Int = 0
    }

    init(text: String, find: Find = Find()) {
        self.text = text
        self.find = find
        self.blocks = Self.blocks(of: text)
        self.marks = Dictionary(
            grouping: find.matches.enumerated().compactMap { ordinal, match in
                match.block.map { (block: $0, ordinal: ordinal + 1, range: match.range) }
            },
            by: { $0.block }
        ).mapValues { $0.map { (ordinal: $0.ordinal, range: $0.range) } }
    }

    var body: some View {
        ScrollView {
            ScrollViewReader { scroller in
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(blocks.indices, id: \.self) { index in
                        view(for: blocks[index], at: index)
                            .id(index)
                    }
                }
                .onChange(of: find.revealToken) { _ in
                    guard let block = blockOfCurrentMatch else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        scroller.scrollTo(block, anchor: .center)
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
            .textSelection(.enabled)
        }
        .scrollIndicators(.never)
    }

    private var blockOfCurrentMatch: Int? {
        guard find.current > 0, find.current <= find.matches.count else { return nil }
        return find.matches[find.current - 1].block
    }

    // MARK: - Blocks

    fileprivate enum Block {
        case heading(String, Int)
        case bullet(String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
        case blank
    }

    /// The last document parsed, kept whole.
    ///
    /// `init` runs on every pass of the parent's body — every keystroke, every
    /// selection change — and used to re-split and re-classify the entire
    /// document each time, which the comment above claimed it didn't. It does
    /// now: same text, same blocks, no work.
    private static var parsed: (text: String, blocks: [Block])?

    fileprivate static func blocks(of text: String) -> [Block] {
        if let parsed, parsed.text.utf8.count == text.utf8.count, parsed.text == text {
            return parsed.blocks
        }
        let blocks = parse(text)
        parsed = (text, blocks)
        return blocks
    }

    /// Inline markdown, parsed once per distinct block rather than once per
    /// block per redraw — `AttributedString(markdown:)` is a real parser, and
    /// scrolling the preview was running it over every visible block on every
    /// frame.
    private static var inlineCache: [String: AttributedString] = [:]

    private static func parse(_ text: String) -> [Block] {
        var result: [Block] = []
        var codeLines: [String] = []
        var inCode = false
        /// The prose lines gathered so far, which become one block rather than
        /// one each. A `Text` is the whole of a selection in SwiftUI — you can
        /// drag within one and never across two — so a paragraph split over a
        /// view per line is a paragraph the reader can't select and copy. It's
        /// also what markdown means: a hard-wrapped paragraph reflows.
        var prose: [String] = []
        /// Whether the line just gathered asked for a break of its own: two
        /// trailing spaces, markdown's hard break, which the trim below would
        /// otherwise eat.
        var breaks: [Bool] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            var joined = prose[0]
            for index in 1..<prose.count {
                joined += breaks[index - 1] ? "\n" : " "
                joined += prose[index]
            }
            result.append(.paragraph(joined))
            prose = []
            breaks = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushProse()
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                }
                inCode.toggle()
                continue
            }
            if inCode {
                codeLines.append(raw)
                continue
            }

            if line.isEmpty {
                flushProse()
                result.append(.blank)
            } else if line.hasPrefix("#") {
                flushProse()
                let level = min(line.prefix(while: { $0 == "#" }).count, 3)
                result.append(.heading(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), level))
            } else if line == "---" || line == "***" || line == "___" {
                flushProse()
                result.append(.rule)
            } else if line.hasPrefix("> ") {
                flushProse()
                result.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                flushProse()
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                prose.append(line)
                breaks.append(raw.hasSuffix("  "))
            }
        }
        flushProse()
        if inCode, !codeLines.isEmpty {
            result.append(.code(codeLines.joined(separator: "\n")))
        }
        return result
    }

    /// The words the reader can see, block by block — the markers gone, in the
    /// order they're drawn. This is what ⌘F searches while the preview is up,
    /// so a `**bold**` word is found by typing the word, not the asterisks.
    ///
    /// Index for index the same blocks the view lays out, so a match knows
    /// which one it belongs to.
    static func visibleBlocks(of text: String) -> [String] {
        blocks(of: text).map(visible)
    }

    private static func visible(_ block: Block) -> String {
        switch block {
        case .heading(let value, _), .bullet(let value), .quote(let value), .paragraph(let value):
            return String(attributed(value).characters)
        case .code(let value):
            return value
        case .rule, .blank:
            return ""
        }
    }

    private static func attributed(_ value: String) -> AttributedString {
        if let cached = inlineCache[value] { return cached }
        let parsed = (try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(value)
        // A plain ceiling rather than a real LRU: this only has to survive one
        // screenful being redrawn, and a document's worth of lines is more than
        // enough for that.
        if inlineCache.count > 2_000 { inlineCache.removeAll(keepingCapacity: true) }
        inlineCache[value] = parsed
        return parsed
    }

    @ViewBuilder
    private func view(for block: Block, at index: Int) -> some View {
        switch block {
        case .heading(let value, let level):
            inline(value, at: index)
                .font(.system(size: [26.0, 20.0, 16.0][level - 1], weight: .bold, design: .rounded))
                .foregroundStyle(level == 1 ? AnyShapeStyle(Theme.glow) : AnyShapeStyle(Theme.ink))
                .padding(.top, level == 1 ? 2 : 8)

        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Theme.accent.opacity(0.75))
                    .frame(width: 4.5, height: 4.5)
                inline(value, at: index)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.ink.opacity(0.92))
            }
            .padding(.leading, 4)

        case .quote(let value):
            HStack(spacing: 12) {
                Capsule()
                    .fill(Theme.glow)
                    .frame(width: 2.5)
                inline(value, at: index)
                    .font(.system(size: 14.5).italic())
                    .foregroundStyle(Theme.inkDim)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let value):
            text(value, at: index)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.92))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Flat, not `.glass` — a material is a live backdrop blur, and
                // a document can hold a hundred code blocks.
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.codePanel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.panelStroke, lineWidth: 1)
                )

        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)

        case .paragraph(let value):
            inline(value, at: index)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .lineSpacing(5)

        case .blank:
            Color.clear.frame(height: 1)
        }
    }

    private func inline(_ value: String, at index: Int) -> Text {
        Text(lit(Self.attributed(value), at: index))
    }

    /// Code keeps its markers — there are none to hide — but still lights up.
    private func text(_ value: String, at index: Int) -> Text {
        Text(lit(AttributedString(value), at: index))
    }

    /// Paint the matches this block holds. The ranges came from searching the
    /// very characters below, so they land on the word and nothing else.
    private func lit(_ attributed: AttributedString, at index: Int) -> AttributedString {
        guard let found = marks[index] else { return attributed }
        var result = attributed
        for (ordinal, range) in found {
            guard let converted = Range(range, in: result) else { continue }
            let current = ordinal == find.current
            result[converted].backgroundColor = current ? Theme.accent.opacity(0.85) : Theme.accent.opacity(0.22)
            result[converted].foregroundColor = current ? Theme.void : Theme.ink
        }
        return result
    }
}
