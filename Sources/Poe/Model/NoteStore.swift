import Foundation
import SwiftUI
import AppKit

/// Owns every note, persists them to disk, and drives the UI.
///
/// Notes live in a single JSON document under Application Support. Writes are
/// debounced so a fast typist never touches the disk more than once per second,
/// and are atomic so a crash mid-save can never truncate the library.
@MainActor
final class NoteStore: ObservableObject {

    /// The single library. Menu commands live outside any view's lifetime, so the
    /// store cannot hang off `@StateObject` — SwiftUI would hand the commands their
    /// own uninitialised copy and every shortcut would silently do nothing.
    static let shared = NoteStore()

    @Published var notes: [Note] = []
    @Published var selection: UUID?
    @Published var query: String = ""

    @Published var sidebarVisible: Bool = true
    @Published var previewing: Bool = false
    @Published var pendingDelete: Note?
    @Published var searchFocusToken: Int = 0
    @Published var editorFocusToken: Int = 0

    private var saveTask: Task<Void, Never>?

    // MARK: - Location

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Poe", isDirectory: true)
    }()

    private static var fileURL: URL { directory.appendingPathComponent("notes.json") }

    // MARK: - Lifecycle

    private init() {
        load()
        if notes.isEmpty {
            notes = [Note(text: Self.welcomeText)]
            scheduleSave()
        }
        selection = sorted.first?.id
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([Note].self, from: data)) ?? []
    }

    /// Coalesces rapid edits into a single write.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let snapshot = notes
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: - Derived state

    /// Pinned first, then most recently touched.
    var sorted: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }

    var visible: [Note] {
        sorted.filter { $0.matches(query) }
    }

    var selectedNote: Note? {
        guard let selection else { return nil }
        return notes.first { $0.id == selection }
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return notes.firstIndex { $0.id == selection }
    }

    /// Two-way binding onto the selected note's text, with save + timestamp bookkeeping.
    var currentText: Binding<String> {
        Binding(
            get: { self.selectedNote?.text ?? "" },
            set: { newValue in
                guard let index = self.selectedIndex, self.notes[index].text != newValue else { return }
                self.notes[index].text = newValue
                self.notes[index].updated = Date()
                self.scheduleSave()
            }
        )
    }

    // MARK: - Commands

    func newNote() {
        // Reuse a blank note rather than littering the library with empties.
        if let blank = sorted.first(where: { $0.isEmpty && !$0.pinned }) {
            selection = blank.id
        } else {
            let note = Note()
            notes.append(note)
            selection = note.id
            scheduleSave()
        }
        query = ""
        previewing = false
        focusEditor()
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selection == id
        let neighbours = visible
        let position = neighbours.firstIndex { $0.id == id }
        notes.remove(at: index)
        if wasSelected {
            let remaining = visible
            if let position, !remaining.isEmpty {
                selection = remaining[min(position, remaining.count - 1)].id
            } else {
                selection = remaining.first?.id
            }
        }
        if notes.isEmpty { newNote() }
        scheduleSave()
    }

    func deleteSelected() {
        guard let note = selectedNote else { return }
        requestDelete(note)
    }

    /// Empty notes go quietly; anything with words in it asks first.
    func requestDelete(_ note: Note) {
        if note.isEmpty {
            delete(note.id)
        } else {
            pendingDelete = note
        }
    }

    func confirmPendingDelete() {
        guard let note = pendingDelete else { return }
        pendingDelete = nil
        delete(note.id)
    }

    func togglePin(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[index].pinned.toggle()
        scheduleSave()
    }

    func togglePinSelected() {
        guard let selection else { return }
        togglePin(selection)
    }

    func duplicateSelected() {
        guard let note = selectedNote else { return }
        var copy = Note(text: note.text)
        copy.created = Date()
        copy.updated = Date()
        notes.append(copy)
        selection = copy.id
        scheduleSave()
    }

    func step(_ offset: Int) {
        let list = visible
        guard !list.isEmpty else { return }
        guard let current = selection, let index = list.firstIndex(where: { $0.id == current }) else {
            selection = list.first?.id
            return
        }
        let next = (index + offset + list.count) % list.count
        selection = list[next].id
    }

    func focusSearch() {
        sidebarVisible = true
        searchFocusToken &+= 1
    }

    func focusEditor() {
        editorFocusToken &+= 1
    }

    func exportSelected() {
        guard let note = selectedNote else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = sanitize(note.title) + ".md"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? note.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func copySelectedToPasteboard() {
        guard let note = selectedNote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "note" : cleaned
    }

    // MARK: - First launch

    private static let welcomeText = """
    Welcome to Poe

    A quiet place to think. Start typing — everything saves itself.

    ## Shortcuts
    - Cmd N — new note
    - Cmd F — search every note
    - Cmd P — preview markdown
    - Cmd D — pin the current note
    - Cmd 0 — hide the sidebar for focus mode
    - Cmd Backspace — delete the current note

    Markdown works: **bold**, *italic*, `code`, and [links](https://example.com).

    Delete this note whenever you're ready to begin.
    """
}
