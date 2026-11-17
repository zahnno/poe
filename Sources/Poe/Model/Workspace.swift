import AppKit
import Combine
import Foundation
import SwiftUI

/// One window's view onto the library.
///
/// The library — every note, the disk, the files behind them — is shared by
/// every window. What a window is *looking at* is its own: which notes it has
/// open as tabs, which tab is in front, whether it's reading or writing, what
/// its sidebar is searching for, and the find bar over the open note. Two
/// windows can read two different notes, or the same note two ways.
///
/// Views observe this object only. It re-announces every change the library
/// makes, so a note edited in one window catches up in the others.
@MainActor
final class Workspace: ObservableObject {

    /// The workspace of the window most recently in front — where menu
    /// commands, Finder opens and Dock drops land when no view says otherwise.
    static weak var active: Workspace?

    /// A note the next window to open should show, set just before asking
    /// SwiftUI for that window ("Open in New Window", "Move Tab to New Window").
    static var pendingNote: UUID?

    /// Files that arrived before any window existed to show them.
    private static var pendingURLs: [URL] = []

    /// Only the first window of a launch picks up where the last one left off;
    /// windows opened afterwards start on a blank page.
    private static var restoredSession = false

    let library: NoteStore
    private var libraryWatch: AnyCancellable?

    // MARK: Tabs

    /// The notes this window has open, in tab order. Never empty once the
    /// window is up; the strip only shows itself when there's more than one.
    @Published private(set) var tabs: [UUID] = [] {
        didSet { if tabs != oldValue { rememberSession() } }
    }

    /// Tabs closed in this window, most recent last, for ⇧⌘T.
    private var closedTabs: [UUID] = []

    /// Whether each tab was being read or written when it was left, so
    /// flicking between tabs puts each one back the way it was.
    private var previewMemory: [UUID: Bool] = [:]

    /// The note in the editor — always one of `tabs`.
    ///
    /// Choosing a note that isn't open yet navigates the tab in front to it,
    /// the way following a link in a browser tab does. Opening it *beside* the
    /// others is `openInNewTab`.
    @Published var selection: UUID? {
        didSet {
            if let selection, !tabs.contains(selection) {
                if let old = oldValue, let position = tabs.firstIndex(of: old) {
                    tabs[position] = selection
                } else {
                    tabs.append(selection)
                }
            }
            // A code or data file has no markdown to preview.
            if previewing, !(selectedNote?.kind.rendersMarkdown ?? true) { previewing = false }
            // A different document: the same word, counted afresh from the top,
            // since the caret we'd otherwise start from belongs to the last one.
            if oldValue != selection {
                refreshFind(reveal: true, from: 0)
                rememberSession()
            }
        }
    }

    @Published var query: String = ""

    @Published var sidebarVisible: Bool = true {
        didSet { if sidebarVisible != oldValue { rememberSession() } }
    }
    @Published var previewing: Bool = false {
        didSet {
            // Reading and writing show different words — the same search has to
            // be counted again against whichever is on screen.
            if previewing != oldValue, findVisible { refreshFind(reveal: true, from: 0) }
        }
    }

    /// This window floats above every other app's windows.
    @Published var floating: Bool = false

    @Published var pendingDelete: Note?
    /// A delete of several notes at once, waiting on its confirmation.
    @Published var pendingBulkDelete: [Note]?
    @Published var message: PoeMessage?

    // MARK: Multi-selection
    //
    // `selection` is the note in the editor; this is the set the sidebar has
    // ticked. Empty means there is no multi-selection at all, and every note
    // command falls back to acting on the open note — which is what keeps the
    // menu bar honest whether or not the sidebar is in the middle of a sweep.

    @Published var marked: Set<UUID> = []
    /// Where a shift-click measures its range from.
    private var markAnchor: UUID?

    @Published var searchFocusToken: Int = 0
    @Published var editorFocusToken: Int = 0

    /// This window's text view, once it exists. Find starts from its caret and
    /// ⌘E reads its selection — and with several windows open, "the editor"
    /// has to mean this window's, not whichever one was built last.
    weak var editor: NSTextView?

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

    /// The sifted, sorted library, and the counts under the editor. Both are
    /// derived from every note's text, and both used to be recomputed several
    /// times per redraw — `visible` twice in one pass of the sidebar's body.
    /// They are answered once per version instead.
    private var cachedVisible: (version: Int, query: String, notes: [Note])?
    private var cachedStats: (version: Int, id: UUID?, stats: Stats)?

    // MARK: - Lifecycle

    init(library: NoteStore = .shared) {
        self.library = library
        library.register(self)

        // Property observers don't run inside an initialiser, so the opening
        // state is set directly rather than through `selection`.
        if let pending = Self.pendingNote {
            Self.pendingNote = nil
            let id = library.contains(pending) ? pending : library.blankNote()
            tabs = [id]
            selection = id
            previewing = library.note(id)?.kind == .markdown
        } else if !Self.restoredSession, let session = Self.loadSession(),
                  case let open = session.tabs.filter(library.contains), !open.isEmpty {
            tabs = open
            selection = session.selection.flatMap { open.contains($0) ? $0 : nil } ?? open.first
            sidebarVisible = session.sidebarVisible
        } else if Self.restoredSession {
            // A new window is a fresh page, the way it is in every editor.
            let id = library.blankNote()
            tabs = [id]
            selection = id
        } else if let first = library.sorted.first?.id {
            tabs = [first]
            selection = first
        }
        Self.restoredSession = true

        // Forward the library's changes, so views that watch only this object
        // still hear about a note edited, pinned or deleted in another window.
        libraryWatch = library.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        if Self.active == nil { Self.active = self }

        if !Self.pendingURLs.isEmpty {
            let urls = Self.pendingURLs
            Self.pendingURLs = []
            DispatchQueue.main.async { [weak self] in self?.open(urls) }
        }
    }

    /// This window came to the front.
    func becameKey() {
        Self.active = self
        rememberSession()
    }

    /// Files from Finder, the Dock, or `open -a Poe notes.md`: they go to the
    /// window in front, or wait for the first one if none is up yet.
    static func openExternal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let target = active ?? NoteStore.shared.liveWorkspaces.first {
            target.open(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    // MARK: - Remembering where you were

    private struct Session: Codable {
        var tabs: [UUID]
        var selection: UUID?
        var sidebarVisible: Bool
    }

    private static let sessionKey = "poe.session"

    private static func loadSession() -> Session? {
        guard !NoteStore.isScratch,
              let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    /// The window in front is what the next launch reopens: its tabs, the one
    /// you were in, and whether the sidebar was showing.
    private func rememberSession() {
        guard !NoteStore.isScratch, Self.active == nil || Self.active === self, !tabs.isEmpty else { return }
        let session = Session(tabs: tabs, selection: selection, sidebarVisible: sidebarVisible)
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionKey)
    }

    // MARK: - The library, as this window sees it

    var notes: [Note] { library.notes }
    var brokenLinks: Set<UUID> { library.brokenLinks }

    func saveNow() { library.saveNow() }
    func saveAndWait() { library.saveAndWait() }
    func syncLinkedFiles() { library.syncLinkedFiles() }

    /// What the sidebar lists. Answered from the cache until the library or the
    /// search changes: the filter reads every note's full text, and the sidebar
    /// asks for this more than once per pass.
    var visible: [Note] {
        if let cached = cachedVisible, cached.version == library.libraryVersion, cached.query == query {
            return cached.notes
        }
        let notes = library.sorted.filter { $0.matches(query) }
        cachedVisible = (library.libraryVersion, query, notes)
        return notes
    }

    /// Words, characters and lines under the editor — one pass over the whole
    /// document, taken once per settled change rather than once per redraw.
    typealias Stats = Note.Counts

    var stats: Stats {
        if let cached = cachedStats, cached.version == library.libraryVersion, cached.id == selection {
            return cached.stats
        }
        let stats = selectedNote?.counts ?? Stats()
        cachedStats = (library.libraryVersion, selection, stats)
        return stats
    }

    var selectedNote: Note? { library.note(selection) }

    /// The open tabs as notes, in order. A tab whose note has gone is skipped.
    var tabNotes: [Note] { tabs.compactMap { library.note($0) } }

    /// The ticked notes, in the order the sidebar lists them — so an export, a
    /// copy or a delete happens in the order the user can see, not in whatever
    /// order a hash set happens to hold.
    var markedNotes: [Note] {
        guard !marked.isEmpty else { return [] }
        return library.sorted.filter { marked.contains($0.id) }
    }

    /// What a note command applies to: the ticked notes when there are any,
    /// otherwise the one that's open.
    var actionTargets: [Note] {
        let ticked = markedNotes
        return ticked.isEmpty ? (selectedNote.map { [$0] } ?? []) : ticked
    }

    /// What a row's own context menu applies to: the whole ticked set when the
    /// row belongs to it, and just that row when it doesn't.
    func contextTargets(for note: Note) -> [Note] {
        marked.contains(note.id) ? markedNotes : [note]
    }

    var canPreview: Bool {
        selectedNote?.kind.rendersMarkdown ?? false
    }

    /// Markdown shortcuts only make sense while writing markdown.
    var canFormat: Bool {
        !previewing && canPreview
    }

    /// Two-way binding onto the selected note's text.
    var currentText: Binding<String> {
        Binding(
            get: { self.selectedNote?.text ?? "" },
            set: { self.edit(to: $0) }
        )
    }

    /// A keystroke, on its way to the library.
    private func edit(to newValue: String) {
        guard let selection, library.edit(selection, to: newValue) else { return }
        // Every match past the edit has shifted; keep the tally honest — here,
        // and in any other window searching the same note — but don't yank the
        // view off to one of them.
        // Bytes, not UTF-16 units, which a string has to be walked to count.
        // They only ever over-estimate, so the threshold still holds.
        for workspace in library.liveWorkspaces where workspace.findVisible && workspace.selection == selection {
            workspace.scheduleFindRecount(length: newValue.utf8.count)
        }
    }

    // MARK: - Tabs

    /// Bring a tab to the front, putting it back the way it was left.
    func selectTab(_ id: UUID) {
        guard tabs.contains(id) else { return }
        if let current = selection { previewMemory[current] = previewing }
        selection = id
        if let remembered = previewMemory[id] { previewing = remembered && canPreview }
        focusEditor()
    }

    /// ⌘1…⌘8 pick a tab by place; ⌘9 always means the last one, the way it
    /// does in every browser.
    func selectTab(at position: Int) {
        guard !tabs.isEmpty else { return }
        let index = position >= 9 ? tabs.count - 1 : position - 1
        guard tabs.indices.contains(index) else { return }
        selectTab(tabs[index])
    }

    /// Step through the tabs, coming round the other end.
    func cycleTab(_ offset: Int) {
        guard tabs.count > 1, let current = selection, let index = tabs.firstIndex(of: current) else { return }
        selectTab(tabs[(index + offset + tabs.count) % tabs.count])
    }

    /// Open a note beside the others — or just switch to it, if it's already open.
    func openInNewTab(_ id: UUID) {
        guard library.contains(id) else { return }
        if tabs.contains(id) {
            selectTab(id)
            return
        }
        let after = selection.flatMap { tabs.firstIndex(of: $0) }.map { $0 + 1 } ?? tabs.count
        tabs.insert(id, at: after)
        selectTab(id)
    }

    /// ⌘T: a blank page in a tab of its own.
    func newTab() {
        query = ""
        marked.removeAll()
        markAnchor = nil
        openInNewTab(library.blankNote())
        previewing = false
        focusEditor()
    }

    /// Close one tab. The last tab never closes on its own — closing it means
    /// closing the window, and that's the window's call.
    func closeTab(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(of: id) else { return }
        closedTabs.removeAll { $0 == id }
        closedTabs.append(id)
        if closedTabs.count > 30 { closedTabs.removeFirst() }
        let wasSelected = selection == id
        tabs.remove(at: index)
        if wasSelected { selectTab(tabs[min(index, tabs.count - 1)]) }
    }

    /// ⌘W. False when there was only one tab, which means the window should go.
    func closeCurrentTab() -> Bool {
        guard tabs.count > 1, let selection else { return false }
        closeTab(selection)
        return true
    }

    func closeOtherTabs(_ id: UUID) {
        guard tabs.contains(id) else { return }
        for other in tabs where other != id {
            closedTabs.removeAll { $0 == other }
            closedTabs.append(other)
        }
        tabs = [id]
        if selection != id { selectTab(id) }
    }

    /// ⇧⌘T — the tab you just closed, back where you can see it.
    func reopenClosedTab() {
        while let id = closedTabs.popLast() {
            guard library.contains(id), !tabs.contains(id) else { continue }
            openInNewTab(id)
            return
        }
    }

    var canReopenTab: Bool {
        closedTabs.contains { library.contains($0) && !tabs.contains($0) }
    }

    /// Drag a tab reorder: move `id` to sit where `target` is.
    func moveTab(_ id: UUID, to target: UUID) {
        guard id != target, let from = tabs.firstIndex(of: id), let to = tabs.firstIndex(of: target) else { return }
        var reordered = tabs
        reordered.remove(at: from)
        reordered.insert(id, at: to)
        tabs = reordered
    }

    /// Take a tab out of this window so another can have it. The window that
    /// receives it is opened by the view, which is the only thing that can
    /// ask SwiftUI for one.
    func detachTab(_ id: UUID) {
        Self.pendingNote = id
        closeTab(id)
    }

    // MARK: - Removal, as told by the library

    /// Before notes go: where in this window's sidebar the topmost of them sat,
    /// so the editor can land on its neighbour.
    func planRemoval(of ids: Set<UUID>) -> Int? {
        visible.firstIndex { ids.contains($0.id) }
    }

    /// After they've gone: close their tabs, forget them, and land somewhere.
    func applyRemoval(of ids: Set<UUID>, row: Int?) {
        marked.subtract(ids)
        if let anchor = markAnchor, ids.contains(anchor) { markAnchor = nil }
        closedTabs.removeAll { ids.contains($0) }
        for id in ids { previewMemory[id] = nil }
        if let pending = pendingDelete, ids.contains(pending.id) { pendingDelete = nil }

        let wasSelected = selection.map { ids.contains($0) } ?? false
        let position = selection.flatMap { tabs.firstIndex(of: $0) }
        tabs.removeAll { ids.contains($0) }
        guard wasSelected || selection == nil else { return }

        if !tabs.isEmpty {
            // Another tab is open: go to the one that slid into this place.
            selectTab(tabs[min(position ?? 0, tabs.count - 1)])
        } else {
            // The only tab went: its sidebar neighbour takes its place.
            let remaining = visible
            if let row, !remaining.isEmpty {
                selection = remaining[min(row, remaining.count - 1)].id
            } else {
                selection = remaining.first?.id ?? library.sorted.first?.id
            }
        }
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

    /// Open files in this window, each in a tab of its own.
    func open(_ urls: [URL]) {
        let (opened, failures) = library.load(urls)

        if !opened.isEmpty {
            query = ""
            for (offset, id) in opened.enumerated() {
                // A blank, untouched page in front is replaced rather than kept
                // beside the file — nobody wants a tab of nothing.
                if offset == 0, let current = selectedNote, current.isEmpty, current.file == nil,
                   !tabs.contains(id) {
                    selection = id
                } else {
                    openInNewTab(id)
                }
            }
            // A markdown file arrives as a document to read; everything else —
            // a note, a config file, code — arrives as something to edit.
            previewing = selectedNote?.kind == .markdown
            focusEditor()
            NSApp.activate(ignoringOtherApps: true)
        }

        if !failures.isEmpty {
            message = PoeMessage(
                title: failures.count == 1 ? "Couldn’t open that file" : "Couldn’t open \(failures.count) files",
                body: failures.joined(separator: "\n\n")
            )
        }
    }

    func reloadSelectedFromDisk() {
        guard let selection else { return }
        do {
            try library.reloadFromDisk(selection)
        } catch {
            message = PoeMessage(title: "Couldn’t reload", body: error.localizedDescription)
        }
    }

    func unlinkSelected() { unlink(actionTargets) }
    func unlink(_ targets: [Note]) { library.unlink(targets) }

    func revealSelectedInFinder() { library.revealInFinder(selection) }

    // MARK: - Commands

    /// ⌘N: a blank page, in the tab in front.
    func newNote() {
        selection = library.blankNote()
        query = ""
        previewing = false
        marked.removeAll()
        markAnchor = nil
        focusEditor()
    }

    func delete(_ id: UUID) {
        library.delete(ids: [id])
    }

    func delete(ids: Set<UUID>) {
        library.delete(ids: ids)
    }

    func deleteSelected() {
        requestDelete(actionTargets)
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

    /// The same question asked of a whole set. One note keeps the singular
    /// wording it always had; a set of nothing but blank, unlinked notes still
    /// goes quietly.
    func requestDelete(_ targets: [Note]) {
        guard !targets.isEmpty else { return }
        if targets.count == 1 {
            requestDelete(targets[0])
        } else if targets.allSatisfy({ $0.isEmpty && $0.file == nil }) {
            delete(ids: Set(targets.map(\.id)))
        } else {
            pendingBulkDelete = targets
        }
    }

    func confirmPendingDelete() {
        guard let note = pendingDelete else { return }
        pendingDelete = nil
        delete(note.id)
    }

    func confirmPendingBulkDelete() {
        guard let targets = pendingBulkDelete else { return }
        pendingBulkDelete = nil
        delete(ids: Set(targets.map(\.id)))
    }

    func togglePin(_ id: UUID) {
        guard let note = library.note(id) else { return }
        library.togglePin([note])
    }

    func togglePinSelected() { togglePin(actionTargets) }
    func togglePin(_ targets: [Note]) { library.togglePin(targets) }

    func duplicateSelected() { duplicate(actionTargets) }

    func duplicate(_ targets: [Note]) {
        let copies = library.duplicate(targets)
        guard !copies.isEmpty else { return }
        // The copies become the sweep, so whatever you do next lands on them
        // rather than on the originals you just copied.
        marked = copies.count > 1 ? Set(copies) : []
        markAnchor = copies.first
        selection = copies.first
    }

    func copySelectedToPasteboard() { copy(actionTargets) }
    func copy(_ targets: [Note]) { library.copy(targets) }

    func saveSelectedAs() {
        guard let selection else { return }
        if let failure = library.saveAs(selection) { message = failure }
    }

    func export(_ targets: [Note]) {
        if let result = library.export(targets) { message = result }
    }

    // MARK: - Multi-selection

    /// A plain click: one note, and the anchor a later shift-click measures from.
    func choose(_ id: UUID) {
        marked.removeAll()
        markAnchor = id
        if tabs.contains(id) { selectTab(id) } else { selection = id }
    }

    /// Command-click: tick or untick one note without disturbing the rest.
    func toggleMark(_ id: UUID) {
        if marked.contains(id) {
            marked.remove(id)
        } else {
            // The first tick brings the open note in with it — otherwise
            // ticking a second note would silently drop the first.
            if marked.isEmpty, let selection, selection != id { marked.insert(selection) }
            marked.insert(id)
            selection = id
        }
        markAnchor = id
    }

    /// Shift-click: everything between the anchor and here. The anchor stays
    /// put, so shift-clicking again re-measures from the same place rather than
    /// growing the range one note at a time.
    func extendMark(to id: UUID) {
        let list = visible
        guard let end = list.firstIndex(where: { $0.id == id }) else { return }
        let anchor = (markAnchor ?? selection).flatMap { start in list.firstIndex { $0.id == start } }
        guard let anchor else { choose(id); return }
        let span = anchor <= end ? anchor...end : end...anchor
        marked = Set(list[span].map(\.id))
        selection = id
    }

    /// Tick everything the sidebar is showing — a search narrows what "all"
    /// means, which is the point of running one first.
    func markAll() {
        sidebarVisible = true
        let list = visible
        guard !list.isEmpty else { return }
        marked = Set(list.map(\.id))
        if markAnchor == nil { markAnchor = selection ?? list.first?.id }
    }

    func clearMarks() {
        marked.removeAll()
        markAnchor = selection
    }

    func toggleMarkAll() {
        let list = visible
        if !marked.isEmpty, marked.count >= list.count { clearMarks() } else { markAll() }
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

    /// Menu commands are built once per window focus, not per selection, so the
    /// guard lives here rather than in the menu.
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

    // MARK: - Markdown shortcuts

    func format(_ action: MarkdownEditing.Action) {
        guard canFormat, let editor else { return }
        editor.window?.makeFirstResponder(editor)
        MarkdownEditing.perform(action, in: editor)
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
            let caret = readingRendered ? 0 : anchor ?? editor?.selectedRange().location ?? 0
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
    fileprivate func scheduleFindRecount(length: Int) {
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
        guard let editor else { return }
        let range = editor.selectedRange()
        guard range.length > 0 else { return }
        let selected = (editor.string as NSString).substring(with: range)
        guard !selected.isEmpty else { return }
        findQuery = selected
        showFind()
    }
}
