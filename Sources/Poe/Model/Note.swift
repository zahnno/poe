import Foundation

struct Note: Identifiable, Codable, Equatable {
    var id: UUID
    var text: String
    var created: Date
    var updated: Date
    var pinned: Bool

    init(id: UUID = UUID(), text: String = "", created: Date = Date(), updated: Date = Date(), pinned: Bool = false) {
        self.id = id
        self.text = text
        self.created = created
        self.updated = updated
        self.pinned = pinned
    }

    /// First non-empty line, stripped of markdown heading markers.
    var title: String {
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let stripped = line.drop(while: { $0 == "#" || $0 == ">" || $0 == "-" || $0 == "*" })
                .trimmingCharacters(in: .whitespaces)
            let candidate = stripped.isEmpty ? line : stripped
            return String(candidate.prefix(80))
        }
        return "Untitled"
    }

    /// A one-line teaser drawn from everything after the title line.
    var snippet: String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if let firstUsed = lines.firstIndex(where: { !$0.isEmpty }) {
            lines.removeSubrange(...firstUsed)
        }
        let rest = lines.filter { !$0.isEmpty }.joined(separator: " ")
        return rest.isEmpty ? "No additional text" : String(rest.prefix(140))
    }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var wordCount: Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }).count
    }

    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
