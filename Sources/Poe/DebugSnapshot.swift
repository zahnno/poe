import AppKit

/// Dev-only harness. POE_SNAPSHOT=<base> renders the live window to PNGs;
/// POE_SELFTEST=1 additionally drives the app through its main flows.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        guard let base = ProcessInfo.processInfo.environment["POE_SNAPSHOT"] else { return }
        guard ProcessInfo.processInfo.environment["POE_SELFTEST"] != nil else {
            after(3.0) { capture(to: base + ".png"); NSApp.terminate(nil) }
            return
        }

        after(2.0) {
            guard let textView = findTextView() else { print("SELFTEST: no editor"); return }
            textView.window?.makeFirstResponder(textView)
            textView.insertText(sample, replacementRange: NSRange(location: 0, length: 0))
        }
        after(4.0) { state("typed"); capture(to: base + "-editor.png") }
        after(5.0) { trigger("Toggle Markdown Preview") }
        after(7.0) { state("preview"); capture(to: base + "-preview.png") }
        after(8.0) { trigger("Toggle Markdown Preview") }
        after(9.0) { trigger("New Note") }
        after(11.0) { state("new note") }
        after(11.5) { findTextView()?.insertText("Second thought\n\nStill here.", replacementRange: NSRange(location: 0, length: 0)) }
        after(13.0) { state("typed again"); capture(to: base + "-second.png") }
        after(14.0) { trigger("Toggle Sidebar") }
        after(16.0) { state("focus"); capture(to: base + "-focus.png") }
        after(17.0) { NSApp.terminate(nil) }
    }

    private static let sample = """
    Aurora Log

    Notes that **save themselves** while you write, with `markdown` where you want it.

    - Cmd P flips to preview
    - Cmd 0 hides the sidebar
    - Cmd F searches everything

    > The best interface is the one that gets out of the way.

    ```
    let thought = Note()
    thought.save()
    ```

    Everything above renders below.
    """

    private static func state(_ label: String) {
        let store = NoteStore.shared
        let notes = store.notes.map { "\($0.text.count)ch\($0.id == store.selection ? "*" : "")" }.joined(separator: " ")
        print("SELFTEST [\(label)] preview=\(store.previewing) sidebar=\(store.sidebarVisible) notes=[\(notes)] editor=\(findTextView()?.string.count ?? -1)ch")
    }

    private static func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private static func capture(to path: String) {
        guard let window = mainWindow,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func findTextView() -> NSTextView? {
        for window in NSApp.windows {
            if let view = window.contentView, let found = search(view) { return found }
        }
        return nil
    }

    private static func search(_ view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.identifier == PoeTextView.identifier { return textView }
        for child in view.subviews {
            if let found = search(child) { return found }
        }
        return nil
    }

    private static func trigger(_ title: String) {
        guard let main = NSApp.mainMenu else { return }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            for (index, item) in submenu.items.enumerated() where item.title == title {
                submenu.performActionForItem(at: index)
                print("SELFTEST: fired \(title)")
                return
            }
        }
        print("SELFTEST: '\(title)' not found")
    }
}
