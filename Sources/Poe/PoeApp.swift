import SwiftUI
import AppKit

@main
struct PoeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One library, as many windows onto it as you like — each with its
        // own tabs, its own open note, and its own way of looking at it.
        WindowGroup("Poe", id: PoeWindow.id) {
            PoeWindow()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands { PoeCommands() }
    }
}

/// One window: its workspace is born with it and dies with it.
struct PoeWindow: View {
    static let id = "main"

    @StateObject private var workspace = Workspace()

    var body: some View {
        RootView()
            .environmentObject(workspace)
            // The menu bar reads this to know which window a command is for.
            .focusedSceneObject(workspace)
    }
}

/// The menu bar.
///
/// Commands live outside every window, so each one asks which window is in
/// front — `focused` — and falls back to the one most recently in front, for
/// the moments a panel or an alert holds the key window instead.
struct PoeCommands: Commands {
    @FocusedObject private var focused: Workspace?
    @Environment(\.openWindow) private var openWindow

    private var store: Workspace? { focused ?? Workspace.active }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { store?.newNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Tab") { store?.newTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window") { newWindow(showing: nil) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open File…") { store?.openFromPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                // The last tab closes the window, the way it does in a browser.
                if store?.closeCurrentTab() != true { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Save Now") { store?.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { store?.saveSelectedAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Reload from Disk") { store?.reloadSelectedFromDisk() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Export to Folder…") { store.map { $0.export($0.actionTargets) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }

        CommandMenu("Note") {
            // Each of these acts on the sidebar's selection when there is one,
            // and on the open note when there isn't — so the menu bar and the
            // list never disagree about what "the note" means.
            Button("Select All Notes") { store?.markAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Deselect Notes") { store?.clearMarks() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Divider()
            Button("Pin / Unpin") { store?.togglePinSelected() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Duplicate") { store?.duplicateSelected() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Open in New Window") { newWindow(showing: store?.selection) }
            Button("Reveal File in Finder") { store?.revealSelectedInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Stop Editing File") { store?.unlinkSelected() }
            Divider()
            Button("Next Note") { store?.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Note") { store?.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Copy Text") { store?.copySelectedToPasteboard() }
            Divider()
            Button("Delete Note") { store?.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandMenu("Format") {
            // Markdown only, and only while writing — each one no-ops otherwise,
            // since menu items here can't see what's in the editor.
            Button("Bold") { store?.format(.bold) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { store?.format(.italic) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Inline Code") { store?.format(.code) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Link") { store?.format(.link) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Checklist Item") { store?.format(.checklist) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }

        CommandGroup(after: .toolbar) {
            // These commands are rebuilt when the window in front changes, not
            // when its note does, so they can't dim themselves as the note
            // changes — each one no-ops instead when there's nothing to do.
            Button("Toggle Markdown Preview") {
                withAnimation(.easeInOut(duration: 0.22)) { store?.togglePreview() }
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("Toggle Sidebar") {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    store?.sidebarVisible.toggle()
                }
            }
            .keyboardShortcut("0", modifiers: .command)

            Divider()
        }

        CommandGroup(before: .windowArrangement) {
            Button("Show Next Tab") { store?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Show Previous Tab") { store?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Reopen Closed Tab") { store?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Move Tab to New Window") {
                guard let store, let id = store.selection else { return }
                if store.tabs.count > 1 { store.detachTab(id) } else { Workspace.pendingNote = id }
                openWindow(id: PoeWindow.id)
            }
            Menu("Go to Tab") {
                ForEach(1..<10) { position in
                    Button(position == 9 ? "Last Tab" : "Tab \(position)") { store?.selectTab(at: position) }
                        .keyboardShortcut(KeyEquivalent(Character("\(position)")), modifiers: .command)
                }
            }
            Divider()
            Toggle("Float on Top", isOn: Binding(
                get: { store?.floating ?? false },
                set: { store?.floating = $0 }
            ))
            .keyboardShortcut("f", modifiers: [.command, .option])
            Divider()
        }

        CommandMenu("Theme") {
            Button("Next Theme") { ThemeManager.shared.nextTheme() }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Theme") { ThemeManager.shared.previousTheme() }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Random Theme") { ThemeManager.shared.randomTheme() }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Divider()

            Toggle("Show Gradients", isOn: Binding(
                get: { ThemeManager.shared.gradientsEnabled },
                set: { ThemeManager.shared.gradientsEnabled = $0 }
            ))
            .keyboardShortcut("g", modifiers: [.command, .option])

            Divider()

            ForEach(ThemeCategory.allCases) { category in
                Menu(category.rawValue) {
                    ForEach(Theme.themes(in: category)) { theme in
                        Button(theme.name) {
                            ThemeManager.shared.setTheme(theme.id)
                        }
                    }
                }
            }
        }

        // ⌘F belongs to the document you're reading, the way it does in every
        // other editor; the library's own search keeps the sidebar and moves to
        // ⇧⌘F. Replacing the group takes AppKit's own Find submenu — and its
        // claim on ⌘F — out of the Edit menu with it.
        CommandGroup(replacing: .textEditing) {
            Button("Find in Note…") { store?.toggleFind() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { store?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { store?.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("Use Selection for Find") { store?.useSelectionForFind() }
                .keyboardShortcut("e", modifiers: .command)
            Divider()
            Button("Search All Notes") { store?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandGroup(replacing: .help) {
            Button("Poe Notes Folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NoteStore.directory.path)
            }
        }
    }

    /// A new window — blank, or showing one particular note.
    private func newWindow(showing note: UUID?) {
        Workspace.pendingNote = note
        openWindow(id: PoeWindow.id)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Poe draws its own tabs inside the window; the system's window tabs
        // on top of those would be two tab bars for one idea.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.runIfRequested()
    }

    /// Finder double-click, "Open With", a drop on the Dock icon, `open -a Poe file.md`.
    ///
    /// SwiftUI claims the same event for its own scenes and often hands this
    /// method an empty list — `RootView`'s `onOpenURL` is the other half of the
    /// story. Either can fire, sometimes both, and opening the same path twice
    /// is already a no-op, so both are wired up.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        Workspace.openExternal(urls)
    }

    /// Someone may have edited an open file in another app while we were away.
    func applicationDidBecomeActive(_ notification: Notification) {
        NoteStore.shared.syncLinkedFiles()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.saveAndWait()
    }
}
