import AppKit
import SwiftUI

/// The `unichar` for an ASCII character — `UInt16`, unlike `UInt8`, has no
/// `init(ascii:)`, and the scanner below compares raw code units.
private func unit(_ scalar: Unicode.Scalar) -> unichar { unichar(scalar.value) }

/// Live markdown styling for the editor.
///
/// Nothing here rewrites a single character. The buffer stays exactly the text
/// that is on disk, markers and all — headings simply grow, emphasis takes
/// hold, and the syntax that produces it steps back into the background. That
/// matters more than usual now that a note can *be* a file: what you see has to
/// be what gets written.
///
/// Styling is always scoped to a range — the paragraph you are typing in, or
/// the part of the document on screen. Nothing here ever walks a whole file:
/// text you cannot see does not need to look like anything yet, and a 140 KB
/// note would otherwise cost half a second every time the typing paused.
enum MarkdownStyle {

    // MARK: - Ink

    private static let manager = NSFontManager.shared
    private static let body = Theme.editorFont

    private static let bodyBold = manager.convert(body, toHaveTrait: .boldFontMask)
    private static let bodyItalic = manager.convert(body, toHaveTrait: .italicFontMask)
    /// SF Mono ships no italic on every system; slant it by hand when it doesn't.
    private static let needsSlant = !bodyItalic.fontDescriptor.symbolicTraits.contains(.italic)

    private static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: descriptor, size: size) ?? font
    }

    private static let headingFonts: [NSFont] = [
        rounded(25, weight: .bold),
        rounded(20.5, weight: .bold),
        rounded(17.5, weight: .semibold),
        rounded(16, weight: .semibold),
        rounded(15, weight: .semibold),
        rounded(15, weight: .medium)
    ]

    private static let ink = NSColor(Theme.ink)
    private static let inkDim = NSColor(Theme.inkDim)
    private static let accent = NSColor(Theme.accent)
    private static let violet = NSColor(Theme.violet)
    /// Markers recede but never vanish — you can always see what you're editing.
    private static let marker = NSColor(Theme.inkFaint).withAlphaComponent(0.55)
    private static let codeInk = NSColor(Theme.accent).withAlphaComponent(0.92)
    private static let codeBackground = NSColor.white.withAlphaComponent(0.05)

    // Spelled out with types: a heterogeneous dictionary literal that also has to
    // infer a ternary or an integer literal takes the type checker *minutes*.
    private static let underline: Int = NSUnderlineStyle.single.rawValue
    private static let noUnderline: Int = 0
    private static let slant: Double = 0.16

    // MARK: - Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Every pattern here is a literal, so a failure is a programmer error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static let headingLine = regex("^(#{1,6})([ \\t]+)(.*)$")
    private static let quoteLine = regex("^([ \\t]*>[ \\t]?)(.*)$")
    private static let bulletLine = regex("^([ \\t]*[-*+][ \\t]+)(.*)$")
    private static let orderedLine = regex("^([ \\t]*\\d{1,9}[.)][ \\t]+)(.*)$")
    private static let ruleLine = regex("^[ \\t]*([-*_])[ \\t]*(\\1[ \\t]*){2,}$")
    private static let taskBox = regex("^(\\[[ xX]\\])([ \\t]+)")

    private static let codeSpan = regex("`[^`\\n]+`")
    private static let boldSpan = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicSpan = regex("(?<![*_\\w])([*_])(?=[^\\s*_])([^*_\\n]+?)(?<=[^\\s*_])\\1(?![*_\\w])")
    private static let strikeSpan = regex("(~~)(?=\\S)(.+?)(?<=\\S)(~~)")
    private static let linkSpan = regex("(!?\\[)([^\\]\\n]*)(\\]\\()([^)\\s]+)(\\))")
    private static let bareLink = regex("(?<![(<\\w])https?://[^\\s)\\]>]+")

    // MARK: - Entry point

    /// Restyle `requested`, widened to whole lines. Only attributes are touched.
    static func apply(to storage: NSTextStorage, base: [NSAttributedString.Key: Any], in requested: NSRange) {
        let text = storage.string as NSString
        guard text.length > 0 else { return }

        let clamped = NSRange(
            location: min(requested.location, text.length),
            length: min(requested.length, text.length - min(requested.location, text.length))
        )
        var range = text.lineRange(for: NSRange(location: clamped.location, length: 0))
        if clamped.length > 0 {
            range = NSUnionRange(range, text.lineRange(for: NSRange(location: NSMaxRange(clamped) - 1, length: 1)))
        }

        // A fence opened above the restyled window still applies inside it.
        var fenced = isFenced(before: range.location, in: text)

        storage.beginEditing()
        storage.setAttributes(base, range: range)

        var location = range.location
        while location < NSMaxRange(range) {
            let line = text.lineRange(for: NSRange(location: location, length: 0))
            style(line: line, in: storage, text: text, base: base, fenced: &fenced)
            guard NSMaxRange(line) > location else { break }
            location = NSMaxRange(line)
        }

        storage.endEditing()
    }

    /// How many fences stood above a point, and which buffer that was counted in.
    ///
    /// `upTo` is always the start of a line, which is the only place the caller
    /// ever asks about, and so the only place an incremental count can resume
    /// from safely.
    private static var counted: (buffer: ObjectIdentifier?, upTo: Int, fences: Int) = (nil, 0, 0)

    /// Cross-checks the running count against a full rescan on every query.
    ///
    /// Set by the self test and nothing else — it makes the whole point of the
    /// running count moot, and exists so a test can prove the two agree over an
    /// edit at every position a writer could put one.
    static let verifying = ProcessInfo.processInfo.environment["POE_FENCE_VERIFY"] != nil
    static private(set) var mismatches = 0

    /// An edit landed at `location`. A count taken from below it still stands;
    /// one taken from above it was counted over text that has since changed.
    ///
    /// Called for every character edit in the buffer, so the invariant holds
    /// however the text got there — typed, pasted, undone, or replaced wholesale.
    static func invalidate(from location: Int) {
        if location < counted.upTo { counted = (nil, 0, 0) }
    }

    /// Count the fences above a point: an odd number means we start inside code.
    ///
    /// This runs on every keystroke, and used to read everything above the caret
    /// each time — the one part of a restyle whose cost grew with the length of
    /// the document rather than with the size of the edit. It doesn't need to.
    /// Typing never alters the text above the caret's own paragraph, so the
    /// count above it cannot have changed either: it is taken once, extended a
    /// line at a time as the caret moves down the document, and thrown away the
    /// moment an edit lands at or above where it was taken from.
    private static func isFenced(before location: Int, in text: NSString) -> Bool {
        guard location > 0 else { return false }

        var start = 0
        var fences = 0
        if counted.buffer == ObjectIdentifier(text), counted.upTo <= location, counted.upTo <= text.length {
            start = counted.upTo
            fences = counted.fences
        }
        if start < location {
            fences += fenceLines(in: text, from: start, to: location)
        }
        counted = (ObjectIdentifier(text), location, fences)
        if verifying, fences != fenceLines(in: text, from: 0, to: location) { mismatches += 1 }
        return fences % 2 == 1
    }

    /// The fence lines in `[start, end)`, which both have to be line starts.
    ///
    /// Copies those code units out once and walks them as raw `UInt16` — eight
    /// times quicker than handing the same text to the regex engine, and thirty
    /// times quicker than reading it back through `NSString` a character at a time.
    private static func fenceLines(in text: NSString, from start: Int, to end: Int) -> Int {
        let length = end - start
        guard length > 0 else { return 0 }
        if scratch.count < length {
            scratch = [unichar](repeating: 0, count: max(length, 8_192))
        }
        scratch.withUnsafeMutableBufferPointer { buffer in
            text.getCharacters(buffer.baseAddress!, range: NSRange(location: start, length: length))
        }

        let space = unit(" "), tab = unit("\t"), newline = unit("\n")
        let backtick = unit("`"), tilde = unit("~")
        var fences = 0
        scratch.withUnsafeBufferPointer { buffer in
            var index = 0
            while index < length {
                // Past the line's indent, if that is where a fence begins.
                var scan = index
                while scan < length, buffer[scan] == space || buffer[scan] == tab { scan += 1 }
                if scan + 2 < length {
                    let character = buffer[scan]
                    if character == backtick || character == tilde,
                       buffer[scan + 1] == character, buffer[scan + 2] == character {
                        fences += 1
                    }
                }
                while index < length, buffer[index] != newline { index += 1 }
                index += 1
            }
        }
        return fences
    }

    /// Reused between keystrokes so the scan above doesn't allocate.
    private static var scratch: [unichar] = []

    /// `NSFontManager` conversions are not free, and the emphasis pass asked
    /// for the same two fonts on every span of every line it touched.
    private static var traitCache: [NSFont: (bold: NSFont, italic: NSFont)] = [:]

    private static func traits(of font: NSFont) -> (bold: NSFont, italic: NSFont) {
        if let cached = traitCache[font] { return cached }
        let converted = (
            bold: manager.convert(font, toHaveTrait: .boldFontMask),
            italic: manager.convert(font, toHaveTrait: .italicFontMask)
        )
        traitCache[font] = converted
        return converted
    }

    // MARK: - Lines

    private static func style(
        line: NSRange,
        in storage: NSTextStorage,
        text: NSString,
        base: [NSAttributedString.Key: Any],
        fenced: inout Bool
    ) {
        // The line without its newline: offsets in it map straight onto the buffer.
        var content = line
        while content.length > 0 {
            let last = text.character(at: NSMaxRange(content) - 1)
            guard last == 0x0A || last == 0x0D else { break }
            content.length -= 1
        }
        guard content.length > 0 else { return }

        // Look at the line's characters before building any Strings: most lines
        // are plain prose and need nothing at all.
        let scan = Scan(of: text, in: content)
        if scan.isBlank { return }

        let string = text.substring(with: content)
        let whole = NSRange(location: 0, length: (string as NSString).length)
        let trimmed = scan.opensFence ? string.trimmingCharacters(in: .whitespaces) : ""

        func absolute(_ local: NSRange) -> NSRange {
            NSRange(location: content.location + local.location, length: local.length)
        }

        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            fenced.toggle()
            let fence: [NSAttributedString.Key: Any] = [.foregroundColor: marker, .backgroundColor: codeBackground]
            storage.addAttributes(fence, range: line)
            return
        }
        if fenced {
            let code: [NSAttributedString.Key: Any] = [.foregroundColor: codeInk, .backgroundColor: codeBackground]
            storage.addAttributes(code, range: line)
            return
        }

        if scan.lead == unit("#"), let match = headingLine.firstMatch(in: string, range: whole) {
            let level = match.range(at: 1).length
            let font = headingFonts[min(level, headingFonts.count) - 1]
            let colour: NSColor = level == 1 ? accent : ink
            let spacing: CGFloat = level == 1 ? 6 : 12
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: colour,
                .paragraphStyle: paragraph(from: base, spacingBefore: spacing)
            ]
            storage.addAttributes(attributes, range: content)
            storage.addAttribute(.foregroundColor, value: marker, range: absolute(match.range(at: 1)))
            inline(in: storage, text: text, content: absolute(match.range(at: 3)), base: base, font: font)
            return
        }

        if scan.mayRule, ruleLine.firstMatch(in: string, range: whole) != nil {
            storage.addAttribute(.foregroundColor, value: marker, range: content)
            return
        }

        if scan.lead == unit(">"), let match = quoteLine.firstMatch(in: string, range: whole) {
            let rest = absolute(match.range(at: 2))
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: inkDim,
                .font: bodyItalic,
                .paragraphStyle: paragraph(from: base, headIndent: 18)
            ]
            storage.addAttributes(attributes, range: content)
            if needsSlant { storage.addAttribute(.obliqueness, value: 0.16, range: content) }
            storage.addAttribute(.foregroundColor, value: marker, range: absolute(match.range(at: 1)))
            inline(in: storage, text: text, content: rest, base: base, font: bodyItalic)
            return
        }

        if scan.mayList, let match = bulletLine.firstMatch(in: string, range: whole)
            ?? orderedLine.firstMatch(in: string, range: whole) {
            let markerAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: accent,
                .font: bodyBold,
                .paragraphStyle: paragraph(from: base, headIndent: 22)
            ]
            storage.addAttributes(markerAttributes, range: absolute(match.range(at: 1)))
            storage.addAttribute(.paragraphStyle, value: paragraph(from: base, headIndent: 22), range: content)

            var rest = absolute(match.range(at: 2))
            // "- [x] done" — tick the box in violet, the way the preview would.
            let restString = text.substring(with: rest)
            if let box = taskBox.firstMatch(in: restString, range: NSRange(location: 0, length: (restString as NSString).length)) {
                let boxRange = NSRange(location: rest.location + box.range(at: 1).location, length: box.range(at: 1).length)
                let done = text.substring(with: boxRange).lowercased().contains("x")
                let tick: NSColor = done ? violet : marker
                let boxAttributes: [NSAttributedString.Key: Any] = [.foregroundColor: tick, .font: bodyBold]
                storage.addAttributes(boxAttributes, range: boxRange)
                if done { storage.addAttribute(.foregroundColor, value: inkDim, range: rest) }
                let consumed = box.range(at: 1).length + box.range(at: 2).length
                rest = NSRange(location: rest.location + consumed, length: max(0, rest.length - consumed))
                if done {
                    let finished: [NSAttributedString.Key: Any] = [.foregroundColor: inkDim, .strikethroughStyle: underline]
                    storage.addAttributes(finished, range: rest)
                }
            }
            inline(in: storage, text: text, content: rest, base: base, font: body)
            return
        }

        inline(in: storage, text: text, content: content, base: base, font: body)
    }

    /// A copy of the editor's paragraph style with one thing changed.
    private static func paragraph(
        from base: [NSAttributedString.Key: Any],
        spacingBefore: CGFloat = 0,
        headIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let style = (base[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        style.paragraphSpacingBefore = spacingBefore
        style.headIndent = headIndent
        return style
    }

    // MARK: - Spans

    private static func inline(
        in storage: NSTextStorage,
        text: NSString,
        content: NSRange,
        base: [NSAttributedString.Key: Any],
        font: NSFont
    ) {
        guard content.length > 0 else { return }
        let scan = Scan(of: text, in: content)
        guard scan.mayEmphasise || scan.mayCode || scan.mayLink || scan.mayStrike || scan.mayAutolink else { return }
        let string = text.substring(with: content)
        let whole = NSRange(location: 0, length: (string as NSString).length)
        func absolute(_ local: NSRange) -> NSRange {
            NSRange(location: content.location + local.location, length: local.length)
        }

        // Code wins: nothing inside backticks is emphasis.
        var code: [NSRange] = []
        for match in (scan.mayCode ? codeSpan.matches(in: string, range: whole) : []) {
            code.append(match.range)
            let span = absolute(match.range)
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: codeInk, .backgroundColor: codeBackground, .font: body
            ]
            storage.addAttributes(attributes, range: span)
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: span.location, length: 1))
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(span) - 1, length: 1))
        }
        func isCode(_ range: NSRange) -> Bool {
            code.contains { NSIntersectionRange($0, range).length > 0 }
        }

        for match in (scan.mayLink ? linkSpan.matches(in: string, range: whole) : []) where !isCode(match.range) {
            let label: [NSAttributedString.Key: Any] = [.foregroundColor: accent, .underlineStyle: underline]
            let plumbing: [NSAttributedString.Key: Any] = [.foregroundColor: marker, .underlineStyle: noUnderline]
            storage.addAttributes(label, range: absolute(match.range(at: 2)))
            for group in [1, 3, 4, 5] {
                storage.addAttributes(plumbing, range: absolute(match.range(at: group)))
            }
        }

        for match in (scan.mayAutolink ? bareLink.matches(in: string, range: whole) : []) where !isCode(match.range) {
            let link: [NSAttributedString.Key: Any] = [.foregroundColor: accent, .underlineStyle: underline]
            storage.addAttributes(link, range: absolute(match.range))
        }

        for match in (scan.mayEmphasise ? boldSpan.matches(in: string, range: whole) : []) where !isCode(match.range) {
            let span = absolute(match.range)
            storage.addAttribute(.font, value: traits(of: font).bold, range: span)
            dimEdges(of: span, width: 2, in: storage)
        }

        for match in (scan.mayEmphasise ? italicSpan.matches(in: string, range: whole) : []) where !isCode(match.range) {
            let span = absolute(match.range)
            let italic = traits(of: font).italic
            storage.addAttribute(.font, value: italic, range: span)
            if !italic.fontDescriptor.symbolicTraits.contains(.italic) {
                storage.addAttribute(.obliqueness, value: slant, range: span)
            }
            dimEdges(of: span, width: 1, in: storage)
        }

        for match in (scan.mayStrike ? strikeSpan.matches(in: string, range: whole) : []) where !isCode(match.range) {
            let span = absolute(match.range)
            let struck: [NSAttributedString.Key: Any] = [.strikethroughStyle: underline, .foregroundColor: inkDim]
            storage.addAttributes(struck, range: span)
            dimEdges(of: span, width: 2, in: storage)
        }
    }

    /// One pass over a line's characters, answering every "is it worth running a
    /// regex here?" question at once. Markdown is punctuation, and most lines
    /// have none of it.
    private struct Scan {
        var lead: UInt16 = 0          // first character that isn't a space or tab
        var isBlank = true
        var opensFence = false        // starts with ``` or ~~~
        var mayRule = false           // only -, * or _ and spaces
        var mayList = false           // starts with a bullet or a digit
        var mayEmphasise = false      // * or _
        var mayCode = false           // `
        var mayLink = false           // [
        var mayStrike = false         // ~
        var mayAutolink = false       // ://

        init(of text: NSString, in range: NSRange) {
            let space = unit(" "), tab = unit("\t")
            let star = unit("*"), underscore = unit("_")
            let dash = unit("-"), plus = unit("+")
            let tick = unit("`"), tilde = unit("~")
            let bracket = unit("["), colon = unit(":")
            let slash = unit("/")
            var ruleCandidate = true
            var ruleCharacter: UInt16 = 0

            for offset in 0..<range.length {
                let character = text.character(at: range.location + offset)
                if isBlank, character != space, character != tab {
                    isBlank = false
                    lead = character
                    mayList = character == dash || character == star || character == plus
                        || (character >= unit("0") && character <= unit("9"))
                    if character == tick || character == tilde {
                        // ```swift or ~~~ — confirmed by the caller, cheaply.
                        opensFence = offset + 2 < range.length
                            && text.character(at: range.location + offset + 1) == character
                            && text.character(at: range.location + offset + 2) == character
                    }
                }
                switch character {
                case star, underscore: mayEmphasise = true
                case tick: mayCode = true
                case bracket: mayLink = true
                case tilde: mayStrike = true
                case colon:
                    if offset + 2 < range.length,
                       text.character(at: range.location + offset + 1) == slash,
                       text.character(at: range.location + offset + 2) == slash {
                        mayAutolink = true
                    }
                default: break
                }
                if ruleCandidate, character != space, character != tab {
                    if character == dash || character == star || character == underscore {
                        if ruleCharacter == 0 { ruleCharacter = character }
                        if ruleCharacter != character { ruleCandidate = false }
                    } else {
                        ruleCandidate = false
                    }
                }
            }
            mayRule = ruleCandidate && ruleCharacter != 0
        }
    }

    /// Fade the `**`, `*` or `~~` that wraps a span, leaving the words alone.
    private static func dimEdges(of span: NSRange, width: Int, in storage: NSTextStorage) {
        guard span.length > width * 2 else { return }
        storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: span.location, length: width))
        storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: NSMaxRange(span) - width, length: width))
    }
}
