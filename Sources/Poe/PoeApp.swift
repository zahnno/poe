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
        }

        CommandGroup(replacing: .saveItem) {
            Button("Export as Markdown…") { store.exportSelected() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save Now") { store.saveNow() }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu("Note") {
            Button("Pin / Unpin") { store.togglePinSelected() }
                .keyboardShortcut("d", modifiers: .command)
            Button("Duplicate") { store.duplicateSelected() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
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
            Button("Toggle Markdown Preview") {
                withAnimation(.easeInOut(duration: 0.22)) { store.previewing.toggle() }
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
}
