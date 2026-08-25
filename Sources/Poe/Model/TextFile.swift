import AppKit
import Foundation
import UniformTypeIdentifiers

/// A note's tether to a file on disk.
///
/// Everything needed to write the text back exactly as it arrived: where it
/// lives, how it was encoded, and whether it used Windows line endings.
struct FileLink: Codable, Equatable {
    var path: String
    var encoding: UInt = String.Encoding.utf8.rawValue
    var crlf: Bool = false

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var stringEncoding: String.Encoding { String.Encoding(rawValue: encoding) }

    /// `~/Notes/todo.md` — short enough for a status bar.
    var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// What kind of text we are looking at, which decides whether the markdown
/// preview means anything and how the file is badged.
enum FileKind {
    case markdown
    case text
    case code
    case data

    /// Only prose renders as markdown; a Swift file is not a document.
    var rendersMarkdown: Bool { self == .markdown || self == .text }

    var label: String {
        switch self {
        case .markdown: return "Markdown"
        case .text:     return "Plain text"
        case .code:     return "Source"
        case .data:     return "Data"
        }
    }

    private static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mkdn", "mdx", "rmd", "qmd"
    ]

    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "me", "nfo", "rst", "adoc", "org", "tex", "srt", "vtt"
    ]

    private static let dataExtensions: Set<String> = [
        "json", "yaml", "yml", "toml", "csv", "tsv", "xml", "plist",
        "ini", "cfg", "conf", "env", "properties", "lock"
    ]

    /// Extension-less files that are unmistakably code.
    private static let bareCodeNames: Set<String> = [
        "makefile", "dockerfile", "rakefile", "gemfile", "podfile", "brewfile",
        "procfile", "justfile", "cmakelists.txt"
    ]

    static func of(_ url: URL) -> FileKind {
        let name = url.lastPathComponent.lowercased()
        if bareCodeNames.contains(name) { return .code }

        let ext = url.pathExtension.lowercased()
        if ext.isEmpty {
            // `.gitignore`, `.zshrc` — dotfiles are configuration, not prose.
            return name.hasPrefix(".") ? .code : .text
        }
        if markdownExtensions.contains(ext) { return .markdown }
        if textExtensions.contains(ext) { return .text }
        if dataExtensions.contains(ext) { return .data }

        // Anything the system recognises as code, however obscure.
        if let type = UTType(filenameExtension: ext),
           type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .shellScript) {
            return .code
        }
        // An unknown extension on a file that decoded as text is still text.
        return .text
    }
}

enum TextFileError: LocalizedError {
    case isDirectory(String)
    case tooLarge(String, Int)
    case notText(String)
    case unreadable(String, String)

    var errorDescription: String? {
        switch self {
        case .isDirectory(let name):
            return "“\(name)” is a folder. Poe opens files, one at a time."
        case .tooLarge(let name, let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "“\(name)” is \(size). Poe opens text files up to \(TextFile.readableLimit)."
        case .notText(let name):
            return "“\(name)” isn’t text — Poe can’t open binary files."
        case .unreadable(let name, let reason):
            return "Couldn’t read “\(name)”: \(reason)"
        }
    }
}

/// Reading and writing plain text files, carefully.
///
/// The point of care is round-tripping: a file opened in Poe and saved back
/// should differ only where the writer actually typed. That means preserving
/// the original encoding and line endings rather than quietly rewriting the
/// whole file as UTF-8 with Unix newlines.
enum TextFile {
    /// Poe holds the whole document in memory and in the library JSON, so a
    /// generous-but-finite ceiling keeps a stray log file from wedging the app.
    static let sizeLimit = 8 * 1024 * 1024
    static var readableLimit: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeLimit), countStyle: .file)
    }

    struct Loaded {
        var text: String
        var link: FileLink
        var modified: Date
        var created: Date
    }

    static func read(_ url: URL) throws -> Loaded {
        let name = url.lastPathComponent
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .isDirectoryKey, .contentModificationDateKey, .creationDateKey
        ]
        let values = try? url.resourceValues(forKeys: keys)

        if values?.isDirectory == true { throw TextFileError.isDirectory(name) }
        if let size = values?.fileSize, size > sizeLimit { throw TextFileError.tooLarge(name, size) }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw TextFileError.unreadable(name, error.localizedDescription)
        }
        if data.count > sizeLimit { throw TextFileError.tooLarge(name, data.count) }
        // A NUL byte in the first pages means this is not something anyone wants
        // to edit in a notepad, whatever its extension claims.
        if data.prefix(8_192).contains(0) { throw TextFileError.notText(name) }

        var encoding = String.Encoding.utf8
        var text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let guessed = try? String(contentsOf: url, usedEncoding: &encoding) {
            text = guessed
        } else if let latin = String(data: data, encoding: .isoLatin1) {
            encoding = .isoLatin1
            text = latin
        } else {
            throw TextFileError.notText(name)
        }

        // Strip a byte-order mark; it is a file detail, not a character.
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let crlf = text.contains("\r\n")
        if crlf { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        text = text.replacingOccurrences(of: "\r", with: "\n")

        let standardized = url.resolvingSymlinksInPath().standardizedFileURL
        return Loaded(
            text: text,
            link: FileLink(path: standardized.path, encoding: encoding.rawValue, crlf: crlf),
            modified: values?.contentModificationDate ?? Date(),
            created: values?.creationDate ?? Date()
        )
    }

    static func write(_ text: String, to link: FileLink) throws {
        var out = text
        if link.crlf { out = out.replacingOccurrences(of: "\n", with: "\r\n") }

        // If the writer typed something the original encoding can't hold, UTF-8
        // is a better outcome than refusing to save their words.
        guard let data = out.data(using: link.stringEncoding, allowLossyConversion: false)
                ?? out.data(using: .utf8) else {
            throw TextFileError.unreadable(link.name, "text could not be encoded")
        }
        try data.write(to: link.url, options: .atomic)
    }

    static func modificationDate(of link: FileLink) -> Date? {
        try? link.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func exists(_ link: FileLink) -> Bool {
        FileManager.default.fileExists(atPath: link.path)
    }
}
