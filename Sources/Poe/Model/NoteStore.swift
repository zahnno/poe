import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Where one search match is.
///
/// A match in the editor is a range in the buffer. A match in the markdown
/// preview is a range inside one of the blocks the reader can see, since that
/// text — headings without their hashes, bold without its asterisks — is not
/// the text the file holds.
struct FindMatch: Equatable {
    var range: NSRange
    /// The rendered block the range belongs to; nil when it's the raw text.
    var block: Int?
}

/// Owns every note, persists them to disk, and drives the UI.
///
/// Notes live in a single JSON document under Application Support. Writes are
/// debounced so a fast typist never touches the disk more than once per second,
/// and are atomic so a crash mid-save can never truncate the library.
///
/// A note may additionally be *linked* to a file the user opened. Linked notes
/// still live in the library — so they are searchable and survive a relaunch —
/// but every save also writes the text straight back to the original file.
@MainActor
final class NoteStore: ObservableObject {

    /// The single library. Menu commands live outside any view's lifetime, so the
    /// store cannot hang off `@StateObject` — SwiftUI would hand the commands their
    /// own uninitialised copy and every shortcut would silently do nothing.
    static let shared = NoteStore()

    @Published var notes: [Note] = []
    @Published var query: String = ""

    @Published var selection: UUID? {
        didSet {
            // A code or data file has no markdown to preview.
            if previewing, !(selectedNote?.kind.rendersMarkdown ?? true) { previewing = false }
            // A different document: the same word, counted afresh from the top,
            // since the caret we'd otherwise start from belongs to the last one.
            if oldValue != selection { refreshFind(reveal: true, from: 0) }
        }
    }

    @Published var sidebarVisible: Bool = true
    @Published var previewing: Bool = false {
        didSet {
            // Reading and writing show different words — the same search has to
            // be counted again against whichever is on screen.
            if previewing != oldValue, findVisible { refreshFind(reveal: true, from: 0) }
        }
    }
    @Published var pendingDelete: Note?
    @Published var searchFocusToken: Int = 0
    @Published var editorFocusToken: Int = 0

    // MARK: Find in the open document
    //
    // The sidebar's `query` sifts the whole library; this is the other search —
    // a find bar over the one document that is open, the way ⌘F behaves in every
    // other editor. The text view owns the matching, so what lives here is only
    // what the bar draws and the commands that drive it.

    @Published var findVisible: Bool = false
    @Published var findQuery: String = "" {
        didSet { if findQuery != oldValue { refreshFind(reveal: true) } }
    }
    /// Every match in the open document, in UTF-16 — the units both the editor
    /// and `AttributedString` count in — so nothing has to search twice.
    @Published private(set) var findMatches: [FindMatch] = []
    /// Which match is current, counting from one; zero when there are none.
    @Published private(set) var findIndex: Int = 0
    /// True when a document had more matches than we were willing to collect —
    /// the bar says so rather than quietly reporting a smaller number.
    @Published private(set) var findCapped: Bool = false
    @Published var findFocusToken: Int = 0
    /// Bumped only when the current match moves on purpose — a new search, or
    /// ⌘G. Typing in the document recounts without dragging the view anywhere.
    @Published private(set) var findRevealToken: Int = 0

    var findCount: Int { findMatches.count }

    /// Past this many characters, a document is recounted once the typing
    /// pauses rather than on every keystroke: a full pass over 8 MB costs an
    /// eighth of a second, which the writer would feel.
    private static let instantFindLimit = 200_000
    /// And past this many matches we stop collecting. Nothing useful happens
    /// beyond it, and the list itself starts to cost more than the search.
    private static let findMatchLimit = 20_000
    private var findRecount: Task<Void, Never>?
    /// The rendered text of the document being searched, kept between
    /// keystrokes: the markdown behind a long note is parsed once, not once per
    /// letter typed into the find field.
    private var rendered: (text: String, blocks: [String])?

    /// Linked notes whose file has moved, been deleted, or refused a write.
    @Published var brokenLinks: Set<UUID> = []
    @Published var message: PoeMessage?

    /// What we last wrote to each linked file, so a save that changes nothing
    /// doesn't touch the file's modification date.
    private var lastWritten: [UUID: String] = [:]
    private var saveTask: Task<Void, Never>?

    struct PoeMessage: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    // MARK: - Location

    static let directory: URL = {
        // The self test points this somewhere disposable: a harness that types
        // into notes must never be pointed at the real ones.
        if let scratch = ProcessInfo.processInfo.environment["POE_LIBRARY"], !scratch.isEmpty {
            return URL(fileURLWithPath: scratch, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Poe", isDirectory: true)
    }()

    private static var fileURL: URL { directory.appendingPathComponent("notes.json") }

    // MARK: - Lifecycle

    private init() {
        load()
        // Adopt anything that changed on disk before deciding what is "current".
        syncLinkedFiles()
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
        writeLinkedFiles()

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

    var canPreview: Bool {
        selectedNote?.kind.rendersMarkdown ?? false
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
                // Every match past the edit has shifted; keep the tally honest,
                // but don't yank the view off to one of them.
                if self.findVisible { self.scheduleFindRecount(length: newValue.utf16.count) }
            }
        )
    }

    // MARK: - Opening files

    /// Ask for files and open them. Nothing is filtered out up front: an
    /// extension-less config file is as openable as a `.md`, and anything that
    /// turns out to be binary is refused with a reason once we look inside.
    func openFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Open a text file — Markdown, plain text, code, or data."
        panel.prompt = "Open"
        if panel.runModal() == .OK { open(panel.urls) }
    }

    /// Open files from anywhere: the panel, Finder, a drop on the window, or
    /// `open -a Poe notes.md` in a terminal.
    func open(_ urls: [URL]) {
        var lastOpened: UUID?
        var failures: [String] = []

        for url in urls {
            do {
                let loaded = try TextFile.read(url)
                lastOpened = adopt(loaded)
            } catch {
                failures.append(error.localizedDescription)
            }
        }

        if let lastOpened {
            query = ""
            selection = lastOpened
            // A markdown file arrives as a document to read; everything else —
            // a note, a config file, code — arrives as something to edit.
            previewing = selectedNote?.kind == .markdown
            focusEditor()
            scheduleSave()
            NSApp.activate(ignoringOtherApps: true)
        }

        if !failures.isEmpty {
            message = PoeMessage(
                title: failures.count == 1 ? "Couldn’t open that file" : "Couldn’t open \(failures.count) files",
                body: failures.joined(separator: "\n\n")
            )
        }
    }

    /// Fold a freshly read file into the library, reusing the note that already
    /// tracks that path so opening the same file twice doesn't clone it.
    private func adopt(_ loaded: TextFile.Loaded) -> UUID {
        if let index = notes.firstIndex(where: { $0.file?.path == loaded.link.path }) {
            // The file on disk is the truth at the moment it is opened.
            if notes[index].text != loaded.text {
                notes[index].text = loaded.text
                notes[index].updated = loaded.modified
            }
            notes[index].file = loaded.link
            lastWritten[notes[index].id] = loaded.text
            brokenLinks.remove(notes[index].id)
            return notes[index].id
        }

        let note = Note(
            text: loaded.text,
            created: loaded.created,
            updated: loaded.modified,
            file: loaded.link
        )
        notes.append(note)
        lastWritten[note.id] = loaded.text
        return note.id
    }

    // MARK: - Keeping files in step

    /// Push every linked note back to its file. Called on each save.
    private func writeLinkedFiles() {
        for note in notes {
            guard let link = note.file, lastWritten[note.id] != note.text else { continue }
            do {
                try TextFile.write(note.text, to: link)
                lastWritten[note.id] = note.text
                brokenLinks.remove(note.id)
            } catch {
                brokenLinks.insert(note.id)
            }
        }
    }

    /// Pull in changes made outside Poe.
    ///
    /// The file wins only when it is genuinely newer than the note — otherwise
    /// keystrokes that haven't been flushed yet would lose to the older copy on
    /// disk. Run at launch and whenever the app comes back to the front.
    func syncLinkedFiles() {
        for index in notes.indices {
            guard let link = notes[index].file else { continue }
            let id = notes[index].id

            guard TextFile.exists(link) else {
                brokenLinks.insert(id)
                continue
            }
            brokenLinks.remove(id)

            guard let loaded = try? TextFile.read(link.url) else { continue }
            if loaded.text == notes[index].text {
                lastWritten[id] = loaded.text
            } else if loaded.modified > notes[index].updated {
                notes[index].text = loaded.text
                notes[index].file = loaded.link
                notes[index].updated = loaded.modified
                lastWritten[id] = loaded.text
            }
        }
    }

    /// Discard local edits and take whatever the file says now.
    func reloadSelectedFromDisk() {
        guard let index = selectedIndex, let link = notes[index].file else { return }
        do {
            let loaded = try TextFile.read(link.url)
            notes[index].text = loaded.text
            notes[index].file = loaded.link
            notes[index].updated = loaded.modified
            lastWritten[notes[index].id] = loaded.text
            brokenLinks.remove(notes[index].id)
            scheduleSave()
        } catch {
            message = PoeMessage(title: "Couldn’t reload", body: error.localizedDescription)
        }
    }

    /// Keep the text, drop the tether — the file on disk stops changing.
    func unlinkSelected() {
        guard let index = selectedIndex, notes[index].file != nil else { return }
        lastWritten[notes[index].id] = nil
        brokenLinks.remove(notes[index].id)
        notes[index].file = nil
        notes[index].updated = Date()
        scheduleSave()
    }

    func revealSelectedInFinder() {
        guard let link = selectedNote?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([link.url])
    }

    // MARK: - Commands

    func newNote() {
        // Reuse a blank note rather than littering the library with empties.
        if let blank = sorted.first(where: { $0.isEmpty && !$0.pinned && $0.file == nil }) {
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
        lastWritten[id] = nil
        brokenLinks.remove(id)
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

    /// Empty notes go quietly; anything with words in it — or a file behind it —
    /// asks first.
    func requestDelete(_ note: Note) {
        if note.isEmpty, note.file == nil {
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

    /// A duplicate is a note, never a second writer on the same file.
    func duplicateSelected() {
        guard let note = selectedNote else { return }
        let copy = Note(text: note.text)
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

    /// Menu commands are built outside any view, so they can't see whether the
    /// current document has markdown in it — the guard lives here instead.
    func togglePreview() {
        guard canPreview || previewing else { return }
        previewing.toggle()
    }

    func focusSearch() {
        sidebarVisible = true
        searchFocusToken &+= 1
    }

    func focusEditor() {
        editorFocusToken &+= 1
    }

    // MARK: - Find in the open document

    /// ⌘F. Searches whatever is on screen: the text you're writing, or — with
    /// the preview up — the words as they're rendered, markers and all left out
    /// of it. Reading never has to become editing to find something.
    func showFind() {
        guard selectedNote != nil else { return }
        withAnimation(.easeOut(duration: 0.18)) { findVisible = true }
        findFocusToken &+= 1
        refreshFind(reveal: true)
    }

    func hideFind() {
        guard findVisible else { return }
        withAnimation(.easeOut(duration: 0.18)) { findVisible = false }
        findRecount?.cancel()
        findMatches = []
        findIndex = 0
        findCapped = false
        rendered = nil
        focusEditor()
    }

    func toggleFind() {
        // ⌘F on an open bar puts the cursor back in it and selects what's there,
        // rather than closing the thing you just asked for.
        if findVisible { findFocusToken &+= 1 } else { showFind() }
    }

    func findNext() { step(find: 1) }
    func findPrevious() { step(find: -1) }

    private func step(find direction: Int) {
        guard selectedNote != nil else { return }
        guard findVisible, !findQuery.isEmpty else { return showFind() }
        guard !findMatches.isEmpty else { return }
        // Off either end and you come round the other side.
        findIndex = (findIndex - 1 + direction + findMatches.count) % findMatches.count + 1
        findRevealToken &+= 1
    }

    /// Count the matches in the open document.
    ///
    /// A fresh search starts from the caret — the line the writer is already
    /// looking at — and wraps round to the top if there's nothing below it. A
    /// recount after an edit keeps whichever match you were on.
    private func refreshFind(reveal: Bool, from anchor: Int? = nil) {
        findRecount?.cancel()

        guard findVisible, !findQuery.isEmpty, let text = selectedNote?.text else {
            findMatches = []
            findIndex = 0
            findCapped = false
            return
        }

        findMatches = matches(in: text)
        findCapped = findMatches.count >= Self.findMatchLimit
        guard !findMatches.isEmpty else {
            findIndex = 0
            return
        }

        if reveal {
            // From the caret when there's a caret to start from; a reader has
            // none, so a search of the preview starts at the top.
            let caret = readingRendered ? 0 : anchor ?? EditorTextView.current?.selectedRange().location ?? 0
            findIndex = (findMatches.firstIndex { $0.range.location >= caret } ?? 0) + 1
            findRevealToken &+= 1
        } else {
            findIndex = min(max(findIndex, 1), findMatches.count)
        }
    }

    /// True when what's on screen is the rendered markdown rather than the text.
    private var readingRendered: Bool {
        previewing && (selectedNote?.kind.rendersMarkdown ?? false)
    }

    /// Search whichever text the reader is actually looking at.
    private func matches(in text: String) -> [FindMatch] {
        guard readingRendered else {
            return Self.ranges(of: findQuery, in: text as NSString)
                .map { FindMatch(range: $0, block: nil) }
        }

        var found: [FindMatch] = []
        for (index, block) in visibleBlocks(of: text).enumerated() {
            guard found.count < Self.findMatchLimit else { break }
            found += Self.ranges(of: findQuery, in: block as NSString)
                .map { FindMatch(range: $0, block: index) }
        }
        return found
    }

    /// Recount after an edit. A note is counted there and then; a document big
    /// enough for the pass to be felt waits for the keys to stop.
    private func scheduleFindRecount(length: Int) {
        guard length > Self.instantFindLimit else { return refreshFind(reveal: false) }
        findRecount?.cancel()
        findRecount = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshFind(reveal: false)
        }
    }

    private func visibleBlocks(of text: String) -> [String] {
        if let rendered, rendered.text == text { return rendered.blocks }
        let blocks = MarkdownPreview.visibleBlocks(of: text)
        rendered = (text, blocks)
        return blocks
    }

    /// Every occurrence, ignoring case and accents — the same forgiving match
    /// the sidebar's search uses.
    private static func ranges(of query: String, in text: NSString) -> [NSRange] {
        var found: [NSRange] = []
        var start = 0
        let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        while start < text.length, found.count < findMatchLimit {
            let searched = NSRange(location: start, length: text.length - start)
            let range = text.range(of: query, options: options, range: searched)
            guard range.location != NSNotFound, range.length > 0 else { break }
            found.append(range)
            start = NSMaxRange(range)
        }
        return found
    }

    /// ⌘E — take what's selected in the editor as the thing to find.
    func useSelectionForFind() {
        guard let selected = EditorTextView.selectedText, !selected.isEmpty else { return }
        findQuery = selected
        showFind()
    }

    /// Write the note out to a file of the user's choosing — and keep writing
    /// there from then on, the way Save As has always behaved.
    func saveSelectedAs() {
        guard let index = selectedIndex else { return }
        let note = notes[index]

        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.file?.name ?? sanitize(note.title) + ".md"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true
        panel.isExtensionHidden = false
        // Offer the type it already has, or Markdown for a note. An extension the
        // system doesn't recognise gets no filter at all rather than a wrong one.
        if let file = note.file {
            if let type = UTType(filenameExtension: file.url.pathExtension) {
                panel.allowedContentTypes = [type]
            }
        } else {
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var link = note.file ?? FileLink(path: url.path)
        link.path = url.standardizedFileURL.path
        do {
            try TextFile.write(note.text, to: link)
            notes[index].file = link
            lastWritten[notes[index].id] = notes[index].text
            brokenLinks.remove(notes[index].id)
            scheduleSave()
        } catch {
            message = PoeMessage(title: "Couldn’t save", body: error.localizedDescription)
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
    - Cmd O — open a file (.md, .txt, code, anything text)
    - Cmd F — find inside this note
    - Shift Cmd F — search every note
    - Cmd P — preview markdown
    - Cmd D — pin the current note
    - Cmd 0 — hide the sidebar for focus mode
    - Cmd Backspace — remove the current note

    Markdown works: **bold**, *italic*, `code`, and [links](https://example.com).

    Open a file and Poe edits it in place — every keystroke goes straight back to
    the file on disk, in its own encoding and line endings. Drag one onto the
    window to try it.

    Delete this note whenever you're ready to begin.
    """
}
