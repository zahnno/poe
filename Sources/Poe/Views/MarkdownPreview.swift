import SwiftUI

/// A light-touch markdown renderer.
///
/// Block structure (headings, bullets, quotes, fenced code, rules) is handled
/// line by line here; inline spans are handed to `AttributedString`'s own
/// markdown parser so links, bold, italic and code all come for free.
struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    view(for: block)
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

    // MARK: - Blocks

    private enum Block {
        case heading(String, Int)
        case bullet(String)
        case quote(String)
        case code(String)
        case rule
        case paragraph(String)
        case blank
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var codeLines: [String] = []
        var inCode = false

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
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
                result.append(.blank)
            } else if line.hasPrefix("#") {
                let level = min(line.prefix(while: { $0 == "#" }).count, 3)
                result.append(.heading(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), level))
            } else if line == "---" || line == "***" || line == "___" {
                result.append(.rule)
            } else if line.hasPrefix("> ") {
                result.append(.quote(String(line.dropFirst(2))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
                result.append(.bullet(String(line.dropFirst(2))))
            } else {
                result.append(.paragraph(line))
            }
        }
        if inCode, !codeLines.isEmpty {
            result.append(.code(codeLines.joined(separator: "\n")))
        }
        return result
    }

    @ViewBuilder
    private func view(for block: Block) -> some View {
        switch block {
        case .heading(let value, let level):
            inline(value)
                .font(.system(size: [26.0, 20.0, 16.0][level - 1], weight: .bold, design: .rounded))
                .foregroundStyle(level == 1 ? AnyShapeStyle(Theme.glow) : AnyShapeStyle(Theme.ink))
                .padding(.top, level == 1 ? 2 : 8)

        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle()
                    .fill(Theme.accent.opacity(0.75))
                    .frame(width: 4.5, height: 4.5)
                inline(value)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Theme.ink.opacity(0.92))
            }
            .padding(.leading, 4)

        case .quote(let value):
            HStack(spacing: 12) {
                Capsule()
                    .fill(Theme.glow)
                    .frame(width: 2.5)
                inline(value)
                    .font(.system(size: 14.5).italic())
                    .foregroundStyle(Theme.inkDim)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .code(let value):
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.accent.opacity(0.92))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glass(radius: 12)

        case .rule:
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.vertical, 4)

        case .paragraph(let value):
            inline(value)
                .font(.system(size: 14.5))
                .foregroundStyle(Theme.ink.opacity(0.92))
                .lineSpacing(5)

        case .blank:
            Color.clear.frame(height: 1)
        }
    }

    private func inline(_ value: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: value,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attributed)
        }
        return Text(value)
    }
}
