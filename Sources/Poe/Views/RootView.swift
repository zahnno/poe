import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @EnvironmentObject var store: Workspace
    @ObservedObject private var themeManager = ThemeManager.shared
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            AuroraBackground()

            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                EditorView()
                    .frame(maxWidth: .infinity)
            }
            // The title bar is hidden, but SwiftUI still keeps its height clear
            // above the content — on top of the room the sidebar and toolbar
            // already leave for the traffic lights, which paid for them twice.
            .ignoresSafeArea(.container, edges: .top)
            // A flat veil, not `.ultraThinMaterial`. A material is a live
            // backdrop blur, and this one covered the whole window over a
            // background that never stops moving — so it re-blurred every
            // pixel behind it, every frame, for a softness the aurora's own
            // gradients already provide.
            .background(Color.white.opacity(0.025))

            if dropTargeted { dropOverlay }
        }
        .frame(minWidth: 720, minHeight: 480)
        // The title bar is hidden, but the Window menu, Mission Control and
        // the Dock still name each window by it — so with several open, each
        // says which note it's showing.
        .navigationTitle(store.selectedNote?.title ?? "Poe")
        .background(WindowAccessor(floating: store.floating) { [weak store] in store?.becameKey() })
        .preferredColorScheme(themeManager.currentTheme.isLight ? .light : .dark)
        .tint(Theme.accent)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted.animation(.easeOut(duration: 0.15))) { providers in
            open(providers)
        }
        .alert(
            deleteTitle,
            isPresented: Binding(
                get: { store.pendingDelete != nil },
                set: { if !$0 { store.pendingDelete = nil } }
            )
        ) {
            Button(store.pendingDelete?.file == nil ? "Delete" : "Remove", role: .destructive) {
                store.confirmPendingDelete()
            }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        } message: {
            Text(deleteMessage)
        }
        .alert(
            bulkDeleteTitle,
            isPresented: Binding(
                get: { store.pendingBulkDelete != nil },
                set: { if !$0 { store.pendingBulkDelete = nil } }
            )
        ) {
            Button(bulkDeleteVerb, role: .destructive) {
                store.confirmPendingBulkDelete()
            }
            Button("Cancel", role: .cancel) { store.pendingBulkDelete = nil }
        } message: {
            Text(bulkDeleteMessage)
        }
        .alert(
            store.message?.title ?? "",
            isPresented: Binding(
                get: { store.message != nil },
                set: { if !$0 { store.message = nil } }
            ),
            presenting: store.message
        ) { _ in
            Button("OK", role: .cancel) { store.message = nil }
        } message: { message in
            Text(message.body)
        }
        .onOpenURL { url in
            // SwiftUI claims the open-documents event for a `WindowGroup` app and
            // hands the app delegate an empty list, so this is where files that
            // come from Finder, the Dock, or `open -a Poe` actually arrive. They
            // go to the window in front, whichever window heard about them.
            Workspace.openExternal([url])
        }
        .onAppear {
            // Start in the note itself — the search field can wait for Cmd F.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.focusEditor() }
        }
        .onDisappear { store.saveAndWait() }
    }

    // MARK: - Dropping files

    /// Drag a file — any text file — anywhere onto the window to open it.
    private func open(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in store.open([url]) }
            }
        }
        return accepted
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.accent.opacity(0.65), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.void.opacity(0.55))
            )
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Theme.accent)
                    Text("Drop to open")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                    Text("Markdown, plain text, code — anything text")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .padding(14)
            .transition(.opacity)
            .allowsHitTesting(false)
    }

    // MARK: - Delete confirmation

    private var deleteTitle: String {
        guard let note = store.pendingDelete else { return "" }
        return note.file == nil ? "Delete “\(note.title)”?" : "Remove “\(note.title)” from Poe?"
    }

    private var deleteMessage: String {
        guard let note = store.pendingDelete else { return "" }
        if let file = note.file {
            return "Poe stops editing it. \(file.displayPath) stays exactly where it is."
        }
        return "This note has \(note.wordCount) words. Deleting it cannot be undone."
    }

    // MARK: - Bulk delete confirmation

    /// Removing a linked note and deleting a note are different acts, and a
    /// sweep can hold both — so the wording says which, and how many of each.
    private var bulkDeleteVerb: String {
        guard let targets = store.pendingBulkDelete else { return "Delete" }
        return targets.allSatisfy { $0.file != nil } ? "Remove" : "Delete"
    }

    private var bulkDeleteTitle: String {
        guard let targets = store.pendingBulkDelete else { return "" }
        return targets.allSatisfy { $0.file != nil }
            ? "Remove \(targets.count) files from Poe?"
            : "Delete \(targets.count) notes?"
    }

    private var bulkDeleteMessage: String {
        guard let targets = store.pendingBulkDelete else { return "" }
        let linked = targets.filter { $0.file != nil }.count
        let plain = targets.filter { $0.file == nil }
        var lines: [String] = []

        if linked > 0 {
            lines.append(linked == targets.count
                ? "Poe stops editing them. The files stay exactly where they are."
                : "\(linked) of them are files — Poe stops editing those, and they stay where they are.")
        }
        if !plain.isEmpty {
            let words = plain.reduce(0) { $0 + $1.wordCount }
            lines.append(plain.count == 1
                ? "One note, \(words) words, will be deleted. That cannot be undone."
                : "\(plain.count) notes, \(words) words in all, will be deleted. That cannot be undone.")
        }
        return lines.joined(separator: " ")
    }
}

// MARK: - The window itself

/// Reaches the `NSWindow` SwiftUI put this view in, to dress it the way Poe
/// wants — a titlebar the aurora bleeds through, no system tabs on top of our
/// own — to float it when asked, and to say when it comes to the front.
///
/// Done per window, as each one appears: dressing `NSApp.windows` once at
/// launch missed every window opened after it.
struct WindowAccessor: NSViewRepresentable {
    var floating: Bool
    var onBecomeKey: () -> Void

    func makeNSView(context: Context) -> WindowTracker {
        let view = WindowTracker()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ view: WindowTracker, context: Context) {
        view.onBecomeKey = onBecomeKey
        view.floating = floating
    }
}

final class WindowTracker: NSView {
    var onBecomeKey: () -> Void = {}
    var floating = false {
        didSet { applyLevel() }
    }
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let window else { return }

        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.tabbingMode = .disallowed
        window.backgroundColor = NSColor(Theme.void)
        window.appearance = Theme.current.isLight ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
        applyLevel()

        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            self?.onBecomeKey()
        }
        if window.isKeyWindow { onBecomeKey() }
    }

    private func applyLevel() {
        window?.level = floating ? .floating : .normal
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
