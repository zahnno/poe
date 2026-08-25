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

    private var firstLine: String? {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = line.drop(while: { $0 == "#" || $0 == ">" || $0 == "-" || $0 == "*" })
                .trimmingCharacters(in: .whitespaces)
            let candidate = stripped.isEmpty ? line : stripped
            return String(candidate.prefix(80))
        }
        return nil
    }

    /// A one-line teaser. For a note the title line is already spoken for, so it
    /// starts below it; for a file the title is the filename, so line one counts.
    var snippet: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if file == nil, let firstUsed = lines.firstIndex(where: { !$0.isEmpty }) {
            lines.removeSubrange(...firstUsed)
        }
        let rest = lines.filter { !$0.isEmpty }.joined(separator: " ")
        if rest.isEmpty { return file == nil ? "No additional text" : "Empty file" }
        return String(rest.prefix(140))
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
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

    var lineCount: Int {
        text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let file, file.path.range(of: query, options: options) != nil { return true }
        return text.range(of: query, options: options) != nil
    }
}
