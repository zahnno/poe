import SwiftUI
import AppKit

@main
struct PoeApp: App {
    private var store: NoteStore { .shared }
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Poe") {
            RootView()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1040, height: 700)
        .commands { commands }
    }

    @CommandsBuilder
    private var commands: some Commands {
        // Replace "New Window" — one library, one window.
        CommandGroup(replacing: .newItem) {
            Button("New Note") { store.newNote() }
                .keyboardShortcut("n", modifiers: .command)
            Button("Open File…") { store.openFromPanel() }
                .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save Now") { store.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { store.saveSelectedAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Reload from Disk") { store.reloadSelectedFromDisk() }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandMenu("Note") {
            Button("Pin / Unpin") { store.togglePinSelected() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Duplicate") { store.duplicateSelected() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Divider()
            Button("Reveal File in Finder") { store.revealSelectedInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Stop Editing File") { store.unlinkSelected() }
            Divider()
            Button("Next Note") { store.step(1) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Previous Note") { store.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Divider()
            Button("Delete Note") { store.deleteSelected() }
                .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(after: .toolbar) {
            // These commands are built once, outside any view, so they can't
            // dim themselves as the selection changes — each one no-ops instead
            // when the current document has nothing for it to do.
            Button("Toggle Markdown Preview") {
                withAnimation(.easeInOut(duration: 0.22)) { store.togglePreview() }
            }
            .keyboardShortcut("p", modifiers: .command)

            Button("Toggle Sidebar") {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    store.sidebarVisible.toggle()
                }
            }
            .keyboardShortcut("0", modifiers: .command)

            Button("Search Notes") { store.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)

            Divider()
        }

        CommandGroup(replacing: .help) {
            Button("Poe Notes Folder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NoteStore.directory.path)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DebugSnapshot.runIfRequested()

        // Let the aurora bleed to the very edges of the window.
        DispatchQueue.main.async {
            for window in NSApp.windows {
                window.titlebarAppearsTransparent = true
                window.isMovableByWindowBackground = true
                window.backgroundColor = NSColor(Theme.void)
                window.appearance = NSAppearance(named: .darkAqua)
            }
        }
    }

    /// Finder double-click, "Open With", a drop on the Dock icon, `open -a Poe file.md`.
    /// Files from Finder, the Dock, or `open -a Poe notes.md`.
    ///
    /// SwiftUI claims the same event for its own scenes and often hands this
    /// method an empty list — `RootView`'s `onOpenURL` is the other half of the
    /// story. Either can fire, sometimes both, and opening the same path twice
    /// is already a no-op, so both are wired up.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        NoteStore.shared.open(urls)
    }

    /// Someone may have edited an open file in another app while we were away.
    func applicationDidBecomeActive(_ notification: Notification) {
        NoteStore.shared.syncLinkedFiles()
    }

    func applicationWillTerminate(_ notification: Notification) {
        NoteStore.shared.saveNow()
    }
}


