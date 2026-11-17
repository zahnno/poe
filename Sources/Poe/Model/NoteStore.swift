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

/// Something worth telling the writer, shown as an alert in their window.
struct PoeMessage: Identifiable {
    let id = UUID()
    var title: String
    var body: String
}

/// The library: every note, persisted to disk, shared by every window.
///
/// Notes live in a single JSON document under Application Support. Writes are
/// debounced so a fast typist never touches the disk more than once per second,
/// and are atomic so a crash mid-save can never truncate the library.
///
/// A note may additionally be *linked* to a file the user opened. Linked notes
/// still live in the library — so they are searchable and survive a relaunch —
/// but every save also writes the text straight back to the original file.
///
/// What a window is *looking at* — its tabs, the open note, the preview, the
/// find bar, the sidebar's search — belongs to that window's `Workspace`, so
/// two windows can read two different notes out of the one library.
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
    /// what the derived values in each workspace are cached against.
    @Published private(set) var libraryVersion: Int = 0

    /// Linked notes whose file has moved, been deleted, or refused a write.
    @Published private(set) var brokenLinks: Set<UUID> = []

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

    // MARK: - Windows

    /// Every window's workspace, held weakly: a closed window's state goes with
    /// it. The library tells them when notes they may be showing disappear.
    private var workspaces: [WeakWorkspace] = []

    private struct WeakWorkspace {
        weak var value: Workspace?
    }

    func register(_ workspace: Workspace) {
        workspaces.removeAll { $0.value == nil }
        workspaces.append(WeakWorkspace(value: workspace))
    }

    var liveWorkspaces: [Workspace] {
        workspaces.compactMap(\.value)
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

    /// True when the library is a scratch one the self test pointed us at —
    /// nothing about it should leak into the real app's remembered state.
    nonisolated static var isScratch: Bool {
        !(ProcessInfo.processInfo.environment["POE_LIBRARY"] ?? "").isEmpty
    }

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

    // MARK: - Lookup

    /// Pinned first, then most recently touched.
    var sorted: [Note] {
        notes.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.updated > b.updated
        }
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

    func note(_ id: UUID?) -> Note? {
        guard let id, let position = position(of: id) else { return nil }
        return notes[position]
    }

    func contains(_ id: UUID) -> Bool {
        position(of: id) != nil
    }

    // MARK: - Editing

    /// A keystroke. Everything here is O(1) in the size of the document except
    /// the assignment itself, and nothing on this path re-renders a window:
    /// the text view already shows the change, and the chrome that hasn't seen
    /// it yet catches up when the typing settles.
    ///
    /// Returns false when the text didn't actually change.
    @discardableResult
    func edit(_ id: UUID, to newValue: String) -> Bool {
        guard let index = position(of: id) else { return false }
        let previous = notes[index].text
        // Comparing lengths first — O(1) — so an ordinary keystroke, which
        // always changes the length, never compares two whole documents.
        if previous.utf8.count == newValue.utf8.count, previous == newValue { return false }

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
        return true
    }

    /// A blank note to write in. Reuses one that's already blank rather than
    /// littering the library with empties.
    func blankNote() -> UUID {
        if let blank = sorted.first(where: { $0.isEmpty && !$0.pinned && $0.file == nil }) {
            return blank.id
        }
        let note = Note()
        notes.append(note)
        libraryChanged()
        scheduleSave()
        return note.id
    }

    // MARK: - Opening files

    /// Read files into the library — from the panel, Finder, a drop on a
    /// window, or `open -a Poe notes.md` in a terminal. Returns the notes that
    /// now hold them, in order, and why any couldn't be opened.
    func load(_ urls: [URL]) -> (opened: [UUID], failures: [String]) {
        var opened: [UUID] = []
        var failures: [String] = []
        for url in urls {
            do {
                let loaded = try TextFile.read(url)
                let id = adopt(loaded)
                if !opened.contains(id) { opened.append(id) }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !opened.isEmpty { scheduleSave() }
        return (opened, failures)
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
    func reloadFromDisk(_ id: UUID) throws {
        guard let index = position(of: id), let link = notes[index].file else { return }
        let loaded = try TextFile.read(link.url)
        notes[index].text = loaded.text
        notes[index].file = loaded.link
        notes[index].updated = loaded.modified
        unflushed.remove(notes[index].id)
        brokenLinks.remove(notes[index].id)
        libraryChanged()
        scheduleSave()
    }

    /// Keep the text, drop the tether — the file on disk stops changing.
    func unlink(_ targets: [Note]) {
        var changed = false
        for note in targets {
            guard let index = position(of: note.id), notes[index].file != nil else { continue }
            unflushed.remove(notes[index].id)
            brokenLinks.remove(notes[index].id)
            notes[index].file = nil
            notes[index].updated = Date()
            changed = true
        }
        guard changed else { return }
        libraryChanged()
        scheduleSave()
    }

    func revealInFinder(_ id: UUID?) {
        guard let link = note(id)?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([link.url])
    }

    // MARK: - Library commands

    /// Remove a whole set in one pass. Deleting them one at a time re-sorted the
    /// library and re-picked a neighbour after each one, so a sweep of twenty
    /// notes moved the editor twenty times on its way to the note it settles on.
    ///
    /// Every window gets a say: each one works out where its sidebar was before
    /// the notes go, then closes the tabs that held them and lands somewhere
    /// sensible afterwards.
    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty, notes.contains(where: { ids.contains($0.id) }) else { return }
        let plans = liveWorkspaces.map { ($0, $0.planRemoval(of: ids)) }

        notes.removeAll { ids.contains($0.id) }
        unflushed.subtract(ids)
        brokenLinks.subtract(ids)
        // An empty library has nowhere for a window to land.
        if notes.isEmpty { notes.append(Note()) }
        libraryChanged()

        for (workspace, row) in plans { workspace.applyRemoval(of: ids, row: row) }
        scheduleSave()
    }

    /// Pin the whole set — or unpin it, once every note in it is already
    /// pinned. A mixed set pins, the way a checkbox over many rows behaves.
    func togglePin(_ targets: [Note]) {
        guard !targets.isEmpty else { return }
        let pin = !targets.allSatisfy(\.pinned)
        for note in targets {
            guard let index = position(of: note.id) else { continue }
            notes[index].pinned = pin
        }
        libraryChanged()
        scheduleSave()
    }

    /// A duplicate is a note, never a second writer on the same file.
    func duplicate(_ targets: [Note]) -> [UUID] {
        guard !targets.isEmpty else { return [] }
        let copies = targets.map { Note(text: $0.text) }
        notes.append(contentsOf: copies)
        libraryChanged()
        scheduleSave()
        return copies.map(\.id)
    }

    func copy(_ targets: [Note]) {
        guard !targets.isEmpty else { return }
        // One note copies as itself. Several are stitched together under their
        // own titles, so what lands in the paste can still be read apart.
        let text = targets.count == 1
            ? targets[0].text
            : targets.map { "# \($0.title)\n\n\($0.text)" }.joined(separator: "\n\n---\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Write the note out to a file of the user's choosing — and keep writing
    /// there from then on, the way Save As has always behaved. Returns a
    /// message only when something went wrong.
    func saveAs(_ id: UUID) -> PoeMessage? {
        guard let index = position(of: id) else { return nil }
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

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The panel ran the loop; the note may have moved in the meantime.
        guard let index = position(of: id) else { return nil }

        var link = note.file ?? FileLink(path: url.path)
        link.path = url.standardizedFileURL.path
        do {
            try TextFile.write(notes[index].text, to: link)
            notes[index].file = link
            unflushed.remove(notes[index].id)
            brokenLinks.remove(notes[index].id)
            libraryChanged()
            scheduleSave()
            return nil
        } catch {
            return PoeMessage(title: "Couldn’t save", body: error.localizedDescription)
        }
    }

    /// Write a copy of each note into a folder of the user's choosing.
    ///
    /// Deliberately not Save As: exporting a sweep of twenty notes should not
    /// leave twenty files that Poe now writes to on every keystroke. The notes
    /// stay notes, and nothing already in the folder is overwritten.
    func export(_ targets: [Note]) -> PoeMessage? {
        guard !targets.isEmpty else { return nil }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = targets.count == 1
            ? "Choose a folder to export this note into"
            : "Choose a folder to export \(targets.count) notes into"
        guard panel.runModal() == .OK, let folder = panel.url else { return nil }

        var taken: Set<String> = []
        var exported = 0
        var failed: [String] = []

        for note in targets {
            let stem = note.file.map { ($0.name as NSString).deletingPathExtension } ?? sanitize(note.title)
            let extensionName = note.file?.url.pathExtension
            let suffix = (extensionName?.isEmpty == false ? extensionName! : "md")

            var name = "\(stem).\(suffix)"
            var attempt = 2
            while taken.contains(name.lowercased())
                    || FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) {
                name = "\(stem) \(attempt).\(suffix)"
                attempt += 1
            }
            taken.insert(name.lowercased())

            do {
                var link = note.file ?? FileLink(path: folder.appendingPathComponent(name).path)
                link.path = folder.appendingPathComponent(name).path
                try TextFile.write(note.text, to: link)
                exported += 1
            } catch {
                failed.append(name)
            }
        }

        if failed.isEmpty {
            return PoeMessage(
                title: exported == 1 ? "Exported 1 note" : "Exported \(exported) notes",
                body: "Written to \(folder.path)."
            )
        }
        return PoeMessage(
            title: "Couldn’t export everything",
            body: "\(exported) written to \(folder.path). These couldn’t be: \(failed.joined(separator: ", "))."
        )
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
    - Cmd T — new note in a new tab
    - Shift Cmd N — new window
    - Cmd W — close tab · Shift Cmd T — reopen it
    - Cmd 1…9, Shift Cmd [ and ] — switch tabs
    - Cmd O — open a file (.md, .txt, code, anything text)
    - Cmd F — find inside this note
    - Shift Cmd F — search every note
    - Cmd P — preview markdown
    - Cmd B / Cmd I / Cmd K — bold, italic, link
    - Shift Cmd L — turn a line into a checklist item, or tick it
    - Cmd D — pin the current note
    - Cmd 0 — hide the sidebar for focus mode
    - Cmd Backspace — remove the current note

    Markdown works: **bold**, *italic*, `code`, and [links](https://example.com).
    Lists carry on by themselves when you press Return.

    - [ ] Option-click a note in the sidebar to open it in a new tab
    - [ ] Right-click one to open it in its own window

    Open a file and Poe edits it in place — every keystroke goes straight back to
    the file on disk, in its own encoding and line endings. Drag one onto the
    window to try it.

    Delete this note whenever you're ready to begin.
    """
}
