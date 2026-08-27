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

    /// Every note.
    ///
    /// Deliberately *not* `@Published`. A keystroke changes one note's text,
    /// and republishing the array on every one of them re-rendered the sidebar,
    /// the toolbar and the status bar — sorting the library, re-reading every
    /// note's first line, rebuilding forty rows — for a change none of them
    /// could show yet. Structural changes call `libraryChanged()`; typing calls
    /// `libraryWillSettle()`, and the chrome catches up a few times a second.
    private(set) var notes: [Note] = []

    /// Bumped whenever the library changes in a way the UI can see. Views
    /// observe the store as a whole, so this is what invalidates them — and
    /// what the derived values below are cached against.
    @Published private(set) var libraryVersion: Int = 0

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
        didSet { if findQuery != oldValue { findQueryChanged() } }
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

    /// Past this many bytes, a document is recounted — and a search of it
    /// re-run — once the typing pauses rather than on every keystroke: a full
    /// pass over 8 MB costs an eighth of a second, which the writer would feel.
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

    /// Linked notes carrying words their file hasn't been given yet.
    ///
    /// This used to be a copy of what was last written to each file, and a save
    /// asked whether it still equalled the note — which walks both documents to
    /// the first difference. A caret resting at the end of an 8 MB file made
    /// that an 8 MB comparison on the main actor, every 700 ms, per open file,
    /// and the copies themselves doubled what a large open file cost in memory.
    /// A note is dirty because it was typed into; that is a set membership.
    private var unflushed: Set<UUID> = []
    private var saveTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?

    /// How far the library has moved, and how much of that the disk has been
    /// told about. Every save used to re-encode and rewrite the whole library
    /// whether or not a word had changed — so ⌘S on an untouched library, and
    /// the save at every quit, each rewrote a megabyte of JSON to say nothing.
    private var edits = 0
    private var written = 0
    /// True between handing a snapshot to the writer and hearing back.
    private var writing = false

    /// The sifted, sorted library, and the counts under the editor. Both are
    /// derived from every note's text, and both used to be recomputed several
    /// times per redraw — `visible` twice in one pass of the sidebar's body.
    /// They are answered once per version instead.
    private var cachedVisible: (version: Int, query: String, notes: [Note])?
    private var cachedStats: (version: Int, id: UUID?, stats: Stats)?

    struct PoeMessage: Identifiable {
        let id = UUID()
        var title: String
        var body: String
    }

    // MARK: - Invalidation

    /// The library changed in a way the UI has to show now.
    func libraryChanged() {
        settleTask?.cancel()
        settleTask = nil
        reindex()
        libraryVersion &+= 1
    }

    /// The library changed under the writer's fingers. The sidebar's snippet
    /// and the word count are worth keeping current, but not at the price of
    /// rebuilding them between two keystrokes — this lets them catch up a few
    /// times a second while the typing carries on undisturbed.
    private func libraryWillSettle() {
        guard settleTask == nil else { return }
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.settleTask = nil
            self?.libraryVersion &+= 1
        }
    }

    // MARK: - Location

    nonisolated static let directory: URL = {
        // The self test points this somewhere disposable: a harness that types
        // into notes must never be pointed at the real ones.
        if let scratch = ProcessInfo.processInfo.environment["POE_LIBRARY"], !scratch.isEmpty {
            return URL(fileURLWithPath: scratch, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Poe", isDirectory: true)
    }()

    nonisolated static var fileURL: URL { directory.appendingPathComponent("notes.json") }

    // MARK: - Lifecycle

    private init() {
        load()
        // Adopt anything that changed on disk before deciding what is "current".
        syncLinkedFilesNow()
        if notes.isEmpty {
            notes = [Note(text: Self.welcomeText)]
            scheduleSave()
        }
        libraryChanged()
        selection = sorted.first?.id
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        notes = (try? decoder.decode([Note].self, from: data)) ?? []
        libraryChanged()
    }

    /// Coalesces rapid edits into a single write.
    func scheduleSave() {
        edits &+= 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Write everything out — the library, and every linked note's file.
    ///
    /// Encoding a library and pushing it to disk used to happen on the main
    /// actor, which meant the caret stopped for as long as the write took, a
    /// second after every pause in the typing. The snapshot is taken here; the
    /// disk work happens on `writer`, an actor, so saves also can't overlap
    /// each other. Only a quit waits for it.
    func saveNow() {
        let pending = claimLinkedWrites()
        guard edits != written || !pending.isEmpty else { return }
        writing = true
        let snapshot = notes
        let version = edits
        let writer = Self.writer
        Task { [weak self] in
            let outcome = await writer.save(snapshot, linked: pending)
            self?.writing = false
            // Only a write that landed counts as told. A save that failed —
            // a full disk, a revoked permission — leaves the library looking
            // unsaved, so the next one tries again instead of assuming.
            if outcome.saved { self?.written = version }
            self?.linkedWrites(finished: pending, failed: outcome.failed)
        }
    }

    /// The blocking version, for the one moment it matters: the app is going
    /// away and an unfinished write would go with it. Done right here, on
    /// whichever thread is quitting, rather than handed to anything that might
    /// not be scheduled again.
    func saveAndWait() {
        saveTask?.cancel()
        saveTask = nil
        let pending = claimLinkedWrites()
        // Nothing has changed and nothing is in flight: the file on disk is
        // already this library, and a quit needn't rewrite it to say so.
        guard edits != written || writing || !pending.isEmpty else { return }
        let outcome = Writer.perform(notes, linked: pending)
        if outcome.saved { written = edits }
        // Same book-keeping the async path does — a file that has just been
        // written is no longer a broken link, whichever way the write got there.
        linkedWrites(finished: pending, failed: outcome.failed)
    }

    /// Take the linked notes whose files are behind, and consider them handed
    /// over. A keystroke that lands while the write is in flight marks the note
    /// again, so nothing typed during a save is lost; a write that fails puts
    /// it back.
    private func claimLinkedWrites() -> [LinkedWrite] {
        guard !unflushed.isEmpty else { return [] }
        let claimed = notes.compactMap { note -> LinkedWrite? in
            guard let link = note.file, unflushed.contains(note.id) else { return nil }
            return LinkedWrite(id: note.id, link: link, text: note.text)
        }
        unflushed.subtract(claimed.map(\.id))
        return claimed
    }

    /// Book-keeping for writes that have landed, back on the main actor.
    private func linkedWrites(finished: [LinkedWrite], failed: Set<UUID>) {
        for write in finished {
            if failed.contains(write.id) {
                brokenLinks.insert(write.id)
                unflushed.insert(write.id)
            } else {
                brokenLinks.remove(write.id)
            }
        }
    }

    struct LinkedWrite: Sendable {
        var id: UUID
        var link: FileLink
        var text: String
    }

    /// Which linked files refused the write, and whether the library itself
    /// reached the disk.
    struct Written: Sendable {
        var failed: Set<UUID> = []
        var saved = false
    }

    /// Everything that touches the disk, serialized and off the main thread.
    private actor Writer {
        func save(_ snapshot: [Note], linked: [LinkedWrite]) -> Written {
            Self.perform(snapshot, linked: linked)
        }

        nonisolated static func perform(_ snapshot: [Note], linked: [LinkedWrite]) -> Written {
            var outcome = Written()
            for write in linked {
                do { try TextFile.write(write.text, to: write.link) } catch { outcome.failed.insert(write.id) }
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            // Sorted keys keep the file diffable; pretty-printing only made it
            // bigger and slower to write, and nobody reads it by hand.
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return outcome }
            try? FileManager.default.createDirectory(at: NoteStore.directory, withIntermediateDirectories: true)
            do {
                try data.write(to: NoteStore.fileURL, options: .atomic)
                outcome.saved = true
            } catch {}
            return outcome
        }

        /// Read every linked file, so the main actor can decide what to adopt
        /// without blocking on the disk to find out.
        func reread(_ links: [(id: UUID, link: FileLink)]) -> [UUID: TextFile.Loaded?] {
            var result: [UUID: TextFile.Loaded?] = [:]
            for (id, link) in links {
                guard TextFile.exists(link) else { continue }
                result[id] = try? TextFile.read(link.url)
            }
            return result
        }
    }

    private static let writer = Writer()

    // MARK: - Derived state

    /// Pinned first, then most recently touched.
    var sorted: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
    }

    /// What the sidebar lists. Answered from the cache until the library or the
    /// search changes: the filter reads every note's full text, and the sidebar
    /// asks for this more than once per pass.
    var visible: [Note] {
        if let cached = cachedVisible, cached.version == libraryVersion, cached.query == query {
            return cached.notes
        }
        let notes = sorted.filter { $0.matches(query) }
        cachedVisible = (libraryVersion, query, notes)
        return notes
    }

    /// Words, characters and lines under the editor — one pass over the whole
    /// document, taken once per settled change rather than once per redraw.
    typealias Stats = Note.Counts

    var stats: Stats {
        if let cached = cachedStats, cached.version == libraryVersion, cached.id == selection {
            return cached.stats
        }
        let stats = selectedNote?.counts ?? Stats()
        cachedStats = (libraryVersion, selection, stats)
        return stats
    }

    /// Where each note sits in `notes`.
    ///
    /// Finding the open note used to be a walk of the library, and the window
    /// asks for it constantly — the toolbar, the status bar, the editor's text,
    /// and every keystroke on its way to the store. At two hundred notes that
    /// walk cost most of a millisecond per keystroke on its own.
    private var index: [UUID: Int] = [:]

    private func reindex() {
        index.removeAll(keepingCapacity: true)
        index.reserveCapacity(notes.count)
        for position in notes.indices { index[notes[position].id] = position }
    }

    /// Where `id` sits, by lookup — falling back to a walk if the map has gone
    /// stale, so a mutation that forgets to announce itself is a slow answer
    /// rather than a wrong one.
    func position(of id: UUID) -> Int? {
        if let position = index[id], position < notes.count, notes[position].id == id {
            return position
        }
        guard let found = notes.firstIndex(where: { $0.id == id }) else { return nil }
        reindex()
        return found
    }

    var selectedNote: Note? {
        guard let index = selectedIndex else { return nil }
        return notes[index]
    }

    var selectedIndex: Int? {
        guard let selection else { return nil }
        return position(of: selection)
    }

    var canPreview: Bool {
        selectedNote?.kind.rendersMarkdown ?? false
    }

    /// Two-way binding onto the selected note's text, with save + timestamp bookkeeping.
    var currentText: Binding<String> {
        Binding(
            get: { self.selectedNote?.text ?? "" },
            set: { self.edit(to: $0) }
        )
    }

    /// A keystroke. Everything here is O(1) in the size of the document except
    /// the assignment itself, and nothing on this path re-renders the window:
    /// the text view already shows the change, and the chrome that hasn't seen
    /// it yet catches up when the typing settles.
    private func edit(to newValue: String) {
        guard let index = selectedIndex else { return }
        let previous = notes[index].text
        // Comparing lengths first — O(1) — so an ordinary keystroke, which
        // always changes the length, never compares two whole documents.
        if previous.utf8.count == newValue.utf8.count, previous == newValue { return }

        notes[index].text = newValue
        notes[index].updated = Date()
        if notes[index].file != nil { unflushed.insert(notes[index].id) }
        scheduleSave()

        // The placeholder under an empty document has to go the moment the
        // first character lands, so that one change is published at once.
        if previous.isEmpty != newValue.isEmpty {
            libraryChanged()
        } else {
            libraryWillSettle()
        }

        // Every match past the edit has shifted; keep the tally honest,
        // but don't yank the view off to one of them.
        // Bytes, not UTF-16 units, which a string has to be walked to count.
        // They only ever over-estimate, so the threshold still holds.
        if findVisible { scheduleFindRecount(length: newValue.utf8.count) }
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
            unflushed.remove(notes[index].id)
            brokenLinks.remove(notes[index].id)
            libraryChanged()
            return notes[index].id
        }

        let note = Note(
            text: loaded.text,
            created: loaded.created,
            updated: loaded.modified,
            file: loaded.link
        )
        notes.append(note)
        unflushed.remove(note.id)
        libraryChanged()
        return note.id
    }

    // MARK: - Keeping files in step

    /// Pull in changes made outside Poe.
    ///
    /// The file wins only when it is genuinely newer than the note — otherwise
    /// keystrokes that haven't been flushed yet would lose to the older copy on
    /// disk. Run at launch and whenever the app comes back to the front.
    ///
    /// Reading every linked file is disk work, so it happens off the main
    /// thread; only the decision about what to adopt is made here. Coming back
    /// to Poe with a folder full of open files no longer stalls the window.
    func syncLinkedFiles() {
        let links = linkedFiles()
        guard !links.isEmpty else { return }
        let writer = Self.writer
        Task { [weak self] in
            let loaded = await writer.reread(links)
            self?.adopt(reread: loaded)
        }
    }

    /// The blocking version, used once at launch: what is "current" cannot be
    /// decided before we know what is on disk.
    private func syncLinkedFilesNow() {
        var loaded: [UUID: TextFile.Loaded?] = [:]
        for (id, link) in linkedFiles() {
            guard TextFile.exists(link) else { continue }
            loaded[id] = try? TextFile.read(link.url)
        }
        adopt(reread: loaded)
    }

    private func linkedFiles() -> [(id: UUID, link: FileLink)] {
        notes.compactMap { note in note.file.map { (note.id, $0) } }
    }

    /// Fold the files we just read back into the library. A note whose file was
    /// missing from the results has gone from the disk.
    private func adopt(reread loaded: [UUID: TextFile.Loaded?]) {
        var changed = false
        for index in notes.indices {
            guard notes[index].file != nil else { continue }
            let id = notes[index].id

            guard let entry = loaded[id] else {
                brokenLinks.insert(id)
                continue
            }
            brokenLinks.remove(id)
            guard let file = entry else { continue }

            if file.text == notes[index].text {
                unflushed.remove(id)
            } else if file.modified > notes[index].updated {
                notes[index].text = file.text
                notes[index].file = file.link
                notes[index].updated = file.modified
                unflushed.remove(id)
                changed = true
            } else {
                // The library holds words the file was never given — a crash
                // between the keystroke and the flush. The next save carries
                // them across, which is what comparing the two copies used to
                // work out on its own.
                unflushed.insert(id)
            }
        }
        if changed { libraryChanged() }
    }

    /// Discard local edits and take whatever the file says now.
    func reloadSelectedFromDisk() {
        guard let index = selectedIndex, let link = notes[index].file else { return }
        do {
            let loaded = try TextFile.read(link.url)
            notes[index].text = loaded.text
            notes[index].file = loaded.link
            notes[index].updated = loaded.modified
            unflushed.remove(notes[index].id)
            brokenLinks.remove(notes[index].id)
            libraryChanged()
            scheduleSave()
        } catch {
            message = PoeMessage(title: "Couldn’t reload", body: error.localizedDescription)
        }
    }

    /// Keep the text, drop the tether — the file on disk stops changing.
    func unlinkSelected() {
        guard let index = selectedIndex, notes[index].file != nil else { return }
        unflushed.remove(notes[index].id)
        brokenLinks.remove(notes[index].id)
        notes[index].file = nil
        notes[index].updated = Date()
        libraryChanged()
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
            libraryChanged()
            selection = note.id
            scheduleSave()
        }
        query = ""
        previewing = false
        focusEditor()
    }

    func delete(_ id: UUID) {
        guard let index = position(of: id) else { return }
        let wasSelected = selection == id
        let neighbours = visible
        let row = neighbours.firstIndex { $0.id == id }
        notes.remove(at: index)
        unflushed.remove(id)
        brokenLinks.remove(id)
        libraryChanged()
        if wasSelected {
            let remaining = visible
            if let row, !remaining.isEmpty {
                selection = remaining[min(row, remaining.count - 1)].id
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
        guard let index = position(of: id) else { return }
        notes[index].pinned.toggle()
        libraryChanged()
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
        libraryChanged()
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
            return Self.ranges(of: findQuery, in: text)
                .map { FindMatch(range: $0, block: nil) }
        }

        var found: [FindMatch] = []
        for (index, block) in visibleBlocks(of: text).enumerated() {
            guard found.count < Self.findMatchLimit else { break }
            found += Self.ranges(of: findQuery, in: block)
                .map { FindMatch(range: $0, block: index) }
        }
        return found
    }

    /// A letter typed into the find field.
    ///
    /// The same bargain the recount after an edit makes, for the same reason:
    /// counting is fast but not free, and typing "receive" into a 4 MB document
    /// asked for seven passes over it where one will do. Emptying the field
    /// clears the bar at once — nobody should watch stale highlights fade.
    private func findQueryChanged() {
        findRecount?.cancel()
        guard findVisible, !findQuery.isEmpty,
              let text = selectedNote?.text, text.utf8.count > Self.instantFindLimit
        else { return refreshFind(reveal: true) }

        findRecount = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshFind(reveal: true)
        }
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
    /// the sidebar's search uses, and now by the same two roads.
    ///
    /// The sidebar stopped asking Foundation for this because
    /// `range(of:options:)` manages about 40 MB/s; the find bar was still
    /// paying it over the whole document for every letter typed into the field.
    /// An ASCII query in an ASCII document needs none of that machinery — case
    /// folding is one bit, accent folding is nothing, and a UTF-8 offset *is*
    /// the UTF-16 offset, so the fast scan can hand back ranges the editor and
    /// the preview can use unchanged. Anything else goes back to Foundation,
    /// which is the only thing that knows what "café" folds onto.
    private static func ranges(of query: String, in text: String) -> [NSRange] {
        if let needle = Note.asciiFolded(query), let found = asciiRanges(of: needle, in: text) {
            return found
        }
        return foundationRanges(of: query, in: text as NSString)
    }

    /// Where an ASCII needle sits in plain ASCII text, or nil the moment the
    /// text turns out not to be plain: past a high byte the offsets stop
    /// meaning UTF-16, and what folds onto what stops being ours to say.
    private static func asciiRanges(of needle: [UInt8], in text: String) -> [NSRange]? {
        let scanned: [NSRange]?? = text.utf8.withContiguousStorageIfAvailable { haystack in
            var found: [NSRange] = []
            var index = 0
            let count = haystack.count
            let last = count - needle.count
            while index < count, found.count < findMatchLimit {
                let byte = haystack[index]
                if byte >= 0x80 { return nil }
                if index <= last, Note.fold(byte) == needle[0] {
                    var offset = 1
                    while offset < needle.count, Note.fold(haystack[index + offset]) == needle[offset] {
                        offset += 1
                    }
                    if offset == needle.count {
                        found.append(NSRange(location: index, length: needle.count))
                        index += needle.count
                        continue
                    }
                }
                index += 1
            }
            return found
        }
        return scanned ?? nil
    }

    private static func foundationRanges(of query: String, in text: NSString) -> [NSRange] {
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
            unflushed.remove(notes[index].id)
            brokenLinks.remove(notes[index].id)
            libraryChanged()
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
