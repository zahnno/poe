import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var created: Date
    var updated: Date
    var pinned: Bool
    /// Set when this note came from — and writes back to — a file on disk.
    var file: FileLink?

    init(
        id: UUID = UUID(),
        text: String = "",
        created: Date = Date(),
        updated: Date = Date(),
        pinned: Bool = false,
        file: FileLink? = nil
    ) {
        self.id = id
        self.text = text
        self.created = created
        self.updated = updated
        self.pinned = pinned
        self.file = file
    }

    /// A file keeps its own name; a note is named by its first line.
    var title: String {
        if let file { return file.name }
        return firstLine ?? "Untitled"
    }

    /// How much of any one line the title and the snippet are willing to read.
    ///
    /// Both want the first line or two, and both used to `split` the entire
    /// text to get there — 9ms and 13ms respectively in a 190 KB note, paid per
    /// sidebar row on every redraw. Neither answer can come from further in
    /// than this, so neither looks: a minified file with one enormous line
    /// costs the same as a short one.
    private static let lineLimit = 2_048

    /// Walk the document a line at a time, trimmed and capped, blanks skipped,
    /// stopping the moment the caller has what it came for. Line ends are found
    /// over UTF-8 — a byte scan, rather than grapheme-breaking the whole text.
    private func firstLines(_ take: (String) -> Bool) {
        let bytes = text.utf8
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let end = bytes[index...].firstIndex(of: 0x0A) ?? bytes.endIndex
            let stop = bytes.index(index, offsetBy: Self.lineLimit, limitedBy: end) ?? end
            let line = String(decoding: bytes[index..<stop], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty, !take(line) { return }
            index = end < bytes.endIndex ? bytes.index(after: end) : bytes.endIndex
        }
    }

    private var firstLine: String? {
        var found: String?
        firstLines { line in
            let stripped = line.drop(while: { $0 == "#" || $0 == ">" || $0 == "-" || $0 == "*" })
                .trimmingCharacters(in: .whitespaces)
            found = String((stripped.isEmpty ? line : stripped).prefix(80))
            return false
        }
        return found
    }

    /// A one-line teaser. For a note the title line is already spoken for, so it
    /// starts below it; for a file the title is the filename, so line one counts.
    var snippet: String {
        var rest = ""
        var skipped = file != nil
        firstLines { line in
            guard skipped else { skipped = true; return true }
            if !rest.isEmpty { rest += " " }
            rest += line
            return rest.count < 140
        }
        if rest.isEmpty { return file == nil ? "No additional text" : "Empty file" }
        return String(rest.prefix(140))
    }

    /// Stops at the first character that isn't blank, rather than building a
    /// trimmed copy of the whole document to ask whether it came out empty.
    var isEmpty: Bool {
        for scalar in text.unicodeScalars {
            if scalar.value < 128 {
                switch scalar {
                case " ", "\n", "\t", "\r", "\u{0B}", "\u{0C}": continue
                default: return false
                }
            } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                return false
            }
        }
        return true
    }

    /// Counted, not split: the old version allocated a substring per word.
    var wordCount: Int {
        var count = 0
        var inWord = false
        for byte in text.utf8 {
            if byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    var kind: FileKind {
        // A note with no file behind it is markdown by convention.
        guard let file else { return .markdown }
        return FileKind.of(file.url)
    }

    /// The chip shown beside the title: the extension, or "NOTE".
    var badge: String {
        guard let file else { return "NOTE" }
        let ext = file.url.pathExtension
        return ext.isEmpty ? "TEXT" : ext.uppercased()
    }

    /// Likewise counted rather than `components(separatedBy:)`, which built an
    /// array holding a second copy of the entire document.
    var lineCount: Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for byte in text.utf8 where byte == 0x0A { count += 1 }
        return count
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if let file, file.path.range(of: query, options: Self.searchOptions) != nil { return true }
        return Self.text(text, contains: query)
    }

    /// Forgiving in the same way the find bar is: case and accents ignored.
    static let searchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Does this document hold that query?
    ///
    /// `String.range(of:options:)` manages about 40 MB/s, which the sidebar's
    /// search paid over the whole library on every keystroke — 75ms a letter
    /// across a few megabytes of notes, and worst exactly when the query
    /// matches nothing, which is most of the way through typing one.
    ///
    /// Nearly every search is ASCII looked for in ASCII, and there case folding
    /// is one bit and accent folding is nothing at all. So that case gets a
    /// scan of its own over the UTF-8, and anything else — an accented query, a
    /// note with accents in it that the query might still fold onto — is handed
    /// back to Foundation, which is the only thing that knows the answer.
    static func text(_ text: String, contains query: String) -> Bool {
        guard let needle = asciiFolded(query) else {
            return text.range(of: query, options: searchOptions) != nil
        }
        let outcome = text.utf8.withContiguousStorageIfAvailable { haystack -> (found: Bool, plain: Bool) in
            var plain = true
            var index = 0
            let count = haystack.count
            let last = count - needle.count
            while index < count {
                let byte = haystack[index]
                if byte >= 0x80 { plain = false }
                if index <= last, fold(byte) == needle[0] {
                    var offset = 1
                    while offset < needle.count, fold(haystack[index + offset]) == needle[offset] {
                        offset += 1
                    }
                    if offset == needle.count { return (true, plain) }
                }
                index += 1
            }
            return (false, plain)
        }

        guard let outcome else { return text.range(of: query, options: searchOptions) != nil }
        if outcome.found { return true }
        // Nothing matched byte for byte. If the note is pure ASCII that settles
        // it; if it isn't, "café" may still be the "cafe" being looked for.
        return outcome.plain ? false : text.range(of: query, options: searchOptions) != nil
    }

    private static func fold(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte | 0x20 : byte
    }

    /// The query as lowercase ASCII bytes, or nil if it isn't plain ASCII.
    private static func asciiFolded(_ query: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(query.utf8.count)
        for byte in query.utf8 {
            guard byte < 0x80 else { return nil }
            bytes.append(fold(byte))
        }
        return bytes.isEmpty ? nil : bytes
    }
}
