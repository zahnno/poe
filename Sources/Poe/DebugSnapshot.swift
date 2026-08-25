import AppKit
import Foundation

/// Dev-only harness. POE_SNAPSHOT=<base> renders the live window to PNGs;
/// POE_SELFTEST=1 additionally drives the app through its main flows.
@MainActor
enum DebugSnapshot {
    static func runIfRequested() {
        guard let base = ProcessInfo.processInfo.environment["POE_SNAPSHOT"] else { return }
        guard let scenario = ProcessInfo.processInfo.environment["POE_SELFTEST"] else {
            after(3.0) { capture(to: base + ".png"); NSApp.terminate(nil) }
            return
        }

        // POE_SELFTEST=file exercises only the open-a-file path, with no typing
        // beforehand, so a failure there can't be blamed on the earlier steps.
        if scenario == "file" {
            fileFlow(base: base)
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
        after(17.0) { trigger("Toggle Sidebar") }

        // POE_OPEN=<path> additionally opens a file, edits it, and saves it back.
        guard ProcessInfo.processInfo.environment["POE_OPEN"] != nil else {
            after(18.0) { NSApp.terminate(nil) }
            return
        }
        fileFlow(base: base, start: 18.0)
    }

    /// The file story end to end: open, edit, save back, reopen, adopt an
    /// outside change, refuse a binary, and notice when the file disappears.
    private static func fileFlow(base: String, start: Double = 2.0) {
        guard let path = ProcessInfo.processInfo.environment["POE_OPEN"] else {
            print("SELFTEST: POE_OPEN not set")
            after(start) { NSApp.terminate(nil) }
            return
        }
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let binary = folder.appendingPathComponent("binary.dat")
        let before = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let store = NoteStore.shared

        after(start) { store.open([url]) }

        after(start + 1.5) {
            state("opened")
            let loaded = findTextView()?.string ?? ""
            check("file loads intact", loaded == before.replacingOccurrences(of: "\r\n", with: "\n"))
            guard let textView = findTextView() else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText("\n\nAppended by the self test.\n", replacementRange: textView.selectedRange())
        }

        after(start + 3.0) {
            store.saveNow()
            let disk = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
            check("edit reaches disk", disk.contains("Appended by the self test."))
            check("original text survives", disk.hasPrefix(before.replacingOccurrences(of: "\r\n", with: "\n")))
            capture(to: base + "-file.png")
        }

        after(start + 4.0) {
            // Opening the same file twice is one note, not two.
            let count = store.notes.count
            store.open([url])
            check("reopening doesn't duplicate", store.notes.count == count)
        }

        after(start + 5.0) {
            // Someone edits the file in another app while Poe is in the background.
            try? "Changed outside Poe.\n".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
            store.syncLinkedFiles()
        }

        after(start + 6.0) {
            check("outside change is adopted", store.selectedNote?.text == "Changed outside Poe.\n")
            // SwiftUI defers redraws while the window is occluded, so give the
            // editor a moment to catch up rather than sampling it once.
            eventually("editor shows the new text") { findTextView()?.string == "Changed outside Poe.\n" }
        }

        after(start + 6.5) {
            var bytes = Data("PNG".utf8)
            bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x00])
            try? bytes.write(to: binary)
            let count = store.notes.count
            store.open([binary])
            check("binary file is refused", store.notes.count == count && store.message != nil)
            store.message = nil
        }

        after(start + 7.5) {
            // The file goes missing under us.
            try? FileManager.default.removeItem(at: url)
            store.syncLinkedFiles()
            let id = store.selection ?? UUID()
            check("missing file is flagged", store.brokenLinks.contains(id))
            capture(to: base + "-missing.png")
        }

        after(start + 8.0) {
            // Keep writing and Poe puts the file back rather than losing words.
            store.currentText.wrappedValue = "Written after the file went missing.\n"
            store.saveNow()
            let restored = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check("saving restores the file", restored == "Written after the file went missing.\n")
            check("flag clears once the write lands", !store.brokenLinks.contains(store.selection ?? UUID()))
        }

        after(start + 9.0) {
            try? FileManager.default.removeItem(at: binary)
            print("SELFTEST: \(failures) failed check(s)")
            NSApp.terminate(nil)
        }
    }

    private static var failures = 0

    /// Poll a condition until it holds, or give up and fail.
    private static func eventually(_ label: String, within seconds: Double = 3.0, _ condition: @escaping () -> Bool) {
        func poll(_ remaining: Double) {
            if condition() { check(label, true) }
            else if remaining <= 0 { check(label, false) }
            else { after(0.2) { poll(remaining - 0.2) } }
        }
        poll(seconds)
    }

    private static func check(_ label: String, _ passed: Bool) {
        if !passed { failures += 1 }
        print("SELFTEST: \(passed ? "ok  " : "FAIL") \(label)")
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
        let file = store.selectedNote?.file.map { " file=\($0.name)" } ?? ""
        print("SELFTEST [\(label)] preview=\(store.previewing) sidebar=\(store.sidebarVisible) notes=[\(notes)]\(file) editor=\(findTextView()?.string.count ?? -1)ch")
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
