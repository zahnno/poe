import AppKit
import Foundation
import QuartzCore

/// Dev-only harness. POE_SNAPSHOT=<base> renders the live window to PNGs;
/// POE_SELFTEST=1 additionally drives the app through its main flows, and
/// POE_SELFTEST=bench times a keystroke from the key down to the window
/// settling (POE_BENCH_NOTES / POE_BENCH_SIZE / POE_BENCH_STROKES).
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

        // POE_SELFTEST=find exercises ⌘F: find inside the open note.
        if scenario == "find" {
            findFlow(base: base)
            return
        }

        // POE_SELFTEST=bench types into a full library and times each keystroke,
        // window update included.
        // POE_SELFTEST=live runs the app for real and measures CPU, not wall time.
        // POE_SELFTEST=drift captures the window twice, ten seconds apart, so a
        // test can tell a background that is drifting from one that has stopped.
        if scenario == "drift" {
            var first: [CGPoint] = []
            after(4.0) {
                guard let view = findDriftView() else { print("SELFTEST: no drift view"); return }
                check("the background is drifting", view.isDrifting)
                first = view.driftPhase
                // A layout pass must not put the drift back to its beginning.
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                check("laying out again left the drift running", view.isDrifting)
                print("SELFTEST: drift at 4s  \(first.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " "))")
            }
            after(14.0) {
                guard let view = findDriftView() else { print("SELFTEST: no drift view"); return }
                let second = view.driftPhase
                print("SELFTEST: drift at 14s \(second.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " "))")
                let moved = zip(first, second).contains { abs($0.x - $1.x) > 1 || abs($0.y - $1.y) > 1 }
                check("the orbs moved over ten seconds", moved)
                print("SELFTEST: \(failures) failed check(s)")
                NSApp.terminate(nil)
            }
            return
        }

        // POE_SELFTEST=scroll drags a long note past the window, with a search
        // up, and asks whether the scroll actually went anywhere.
        if scenario == "scroll" {
            scrollFlow()
            return
        }

        if scenario == "live" {
            LiveBench.run()
            return
        }

        if scenario == "bench" {
            benchFlow()
            return
        }

        // POE_SELFTEST=fence edits a fenced document everywhere a writer could,
        // with POE_FENCE_VERIFY on, to prove the styler's running fence count
        // says what a full rescan would have said.
        if scenario == "fence" {
            fenceFlow()
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
            // Markdown arrives rendered; anything else arrives ready to edit.
            let markdown = store.selectedNote?.kind == .markdown
            check("markdown opens rendered, other text opens editable", store.previewing == markdown)
            if markdown { capture(to: base + "-preview.png") }
            store.previewing = false
        }

        after(start + 2.8) {
            capture(to: base + "-styled.png")
            guard let textView = findTextView() else { print("SELFTEST: no editor"); return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText("\n\n## Appended by the self test\n\nWith **bold** and `code`.\n", replacementRange: textView.selectedRange())
        }

        after(start + 5.1) {
            store.saveAndWait()
            let disk = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
                .replacingOccurrences(of: "\r\n", with: "\n")
            check("edit reaches disk", disk.contains("## Appended by the self test"))
            check("original text survives", disk.hasPrefix(before.replacingOccurrences(of: "\r\n", with: "\n")))
            // Styling is attributes only: the buffer still matches the file byte for byte.
            check("styling leaves the text alone", findTextView()?.string == disk)
            capture(to: base + "-file.png")
        }

        after(start + 5.8) { trigger("Toggle Markdown Preview") }

        after(start + 5.8) {
            check("the preview command still works", store.previewing)
            store.previewing = false
        }

        after(start + 6.3) {
            // Opening the same file twice is one note, not two.
            let count = store.notes.count
            store.open([url])
            check("reopening doesn't duplicate", store.notes.count == count)
            store.previewing = false
        }

        after(start + 7.3) {
            // Someone edits the file in another app while Poe is in the background.
            try? "Changed outside Poe.\n".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
            store.syncLinkedFiles()
        }

        after(start + 8.3) {
            check("outside change is adopted", store.selectedNote?.text == "Changed outside Poe.\n")
            // SwiftUI defers redraws while the window is occluded, so give the
            // editor a moment to catch up rather than sampling it once.
            eventually("editor shows the new text") { findTextView()?.string == "Changed outside Poe.\n" }
        }

        after(start + 8.8) {
            var bytes = Data("PNG".utf8)
            bytes.append(contentsOf: [0x00, 0x01, 0x02, 0x00])
            try? bytes.write(to: binary)
            let count = store.notes.count
            store.open([binary])
            check("binary file is refused", store.notes.count == count && store.message != nil)
            store.message = nil
        }

        after(start + 9.8) {
            // The file goes missing under us.
            try? FileManager.default.removeItem(at: url)
            store.syncLinkedFiles()
        }

        // Reading the disk and writing to it both happen off the main thread
        // now, so these checks look after the call rather than inside it — and
        // leave room for a `capture` on the main thread to finish first.
        after(start + 11.2) {
            let id = store.selection ?? UUID()
            check("missing file is flagged", store.brokenLinks.contains(id))
            capture(to: base + "-missing.png")
        }

        after(start + 12.4) {
            // Keep writing and Poe puts the file back rather than losing words.
            store.currentText.wrappedValue = "Written after the file went missing.\n"
            store.saveAndWait()
        }

        after(start + 13.0) {
            let restored = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            check("saving restores the file", restored == "Written after the file went missing.\n")
            check("flag clears once the write lands", !store.brokenLinks.contains(store.selection ?? UUID()))
        }

        after(start + 14.6) {
            try? FileManager.default.removeItem(at: binary)
            print("SELFTEST: \(failures) failed check(s)")
            NSApp.terminate(nil)
        }
    }

    /// ⌘F end to end: count the matches, step through them, wrap round, keep
    /// counting as the writer types — and leave every character alone.
    ///
    /// The word below appears exactly six times, counting the shouted one.
    private static func findFlow(base: String, start: Double = 2.0) {
        let store = NoteStore.shared
        let text = """
        Lantern notes

        A lantern in the dark, a lantern on the desk, and a lantern in the window.

        The word lantern turns up six times here — the last one being this LANTERN.

        Written **bright** star, with the emphasis in the way.
        """

        after(start - 0.5) {
            // The point of the whole exercise: ⌘F reaches the document, and the
            // library's search is still there, one key over.
            check("⌘F is Find in Note… (\(shortcutOwner("f", [.command]) ?? "nothing"))",
                  shortcutOwner("f", [.command]) == "Find in Note…")
            check("⇧⌘F is Search All Notes (\(shortcutOwner("f", [.command, .shift]) ?? "nothing"))",
                  shortcutOwner("f", [.command, .shift]) == "Search All Notes")
            check("⌘G is Find Next", shortcutOwner("g", [.command]) == "Find Next")
            check("⇧⌘G is Find Previous", shortcutOwner("g", [.command, .shift]) == "Find Previous")
            check("⌘E is Use Selection for Find", shortcutOwner("e", [.command]) == "Use Selection for Find")
        }

        // A note of its own, so the counts below are only ever about this text.
        after(start) { trigger("New Note") }

        after(start + 0.8) {
            guard let textView = findTextView() else { return check("editor exists", false) }
            textView.window?.makeFirstResponder(textView)
            textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        }

        // ⌘F while reading: the markdown stays rendered and the words on screen
        // are what gets searched — markers and all left out of it.
        after(start + 1.6) { store.previewing = true }

        after(start + 2.0) { trigger("Find in Note…") }

        after(start + 2.6) {
            check("⌘F opens the find bar", store.findVisible)
            check("reading stays reading", store.previewing)
            store.findQuery = "lantern"
        }

        after(start + 3.6) {
            check("the preview is searched where it stands (\(store.findCount))", store.findCount == 6)
            check("every match knows its block", store.findMatches.allSatisfy { $0.block != nil })
            check("the first match is current (\(store.findIndex))", store.findIndex == 1)
            check("nothing is lit in the editor behind it", !lit(at: 0))
            capture(to: base + "-find-preview.png")
            store.previewing = false
        }

        after(start + 4.4) {
            check("the same words are found in the text (\(store.findCount))", store.findCount == 6)
            check("and now they point at the buffer", store.findMatches.allSatisfy { $0.block == nil })
            check("finding a word doesn't sift the library", store.query.isEmpty)
            check("the match is lit", lit(at: store.findMatches.first?.range.location ?? -1))
            check("the words around it aren't", !lit(at: 10))
            capture(to: base + "-find.png")
            trigger("Find Next")
        }

        after(start + 5.2) {
            check("⌘G steps forward (\(store.findIndex))", store.findIndex == 2)
            trigger("Find Previous")
        }

        after(start + 6.0) {
            check("⇧⌘G steps back (\(store.findIndex))", store.findIndex == 1)
            trigger("Find Previous")
        }

        after(start + 6.8) {
            check("stepping back off the front wraps to the end (\(store.findIndex))", store.findIndex == 6)
            check("searching leaves the text alone", findTextView()?.string == text)
            guard let textView = findTextView() else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            textView.insertText("\n\nOne more lantern.", replacementRange: textView.selectedRange())
        }

        after(start + 7.8) {
            eventually("typing keeps the count honest") { store.findCount == 7 }
        }

        // The point of searching what's rendered: the reader looks for the words
        // as they read, not as they're written.
        after(start + 8.6) {
            store.previewing = true
            store.findQuery = "bright star"
        }

        after(start + 9.4) {
            check("a phrase the markers interrupt is found in the preview (\(store.findCount))", store.findCount == 1)
            store.previewing = false
        }

        after(start + 10.2) {
            check("and isn't in the text, where the asterisks are", store.findCount == 0)
            trigger("Search All Notes")
        }

        after(start + 11.0) {
            check("⇧⌘F still searches every note", store.sidebarVisible)
            check("the library search is a separate field", store.query.isEmpty && !store.findQuery.isEmpty)

            // ⌘E: take the word under the selection as the thing to find.
            guard let textView = findTextView() else { return }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange((textView.string as NSString).range(of: "desk"))
            trigger("Use Selection for Find")
        }

        after(start + 11.8) {
            check("⌘E searches for what's selected", store.findQuery == "desk")
            check("and counts it", store.findCount == 1 && store.findIndex == 1)
            guard let textView = findTextView() else { return }
            textView.window?.makeFirstResponder(textView)
            textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        }

        after(start + 12.6) {
            check("esc closes the bar from the editor", !store.findVisible)
            check("closing forgets the matches", store.findCount == 0)
            capture(to: base + "-find-closed.png")
            print("SELFTEST: \(failures) failed check(s)")
            NSApp.terminate(nil)
        }
    }

    /// Scrolling a long note, before and after a search.
    ///
    /// Steps the clip view down the way a drag does and watches two things a
    /// scroll must not do: land anywhere but where it was pushed, and restyle
    /// on every frame. Styling relays out the lines under the reader, so a
    /// scroll that pays for one per frame is a scroll that shudders in place —
    /// which is what a search used to leave behind, its jump having stranded
    /// the styled window somewhere the reader no longer was.
    private static func scrollFlow() {
        let store = NoteStore.shared
        var body = "Long Note\n\n"
        var paragraph = 0
        while body.utf8.count < 40_000 {
            body += "## Section \(paragraph)\nProse about lantern and **things** and `code`, running on a while.\nA second line with lantern in it too, so the search has plenty to find.\n\n"
            paragraph += 1
        }

        after(1.5) {
            store.newNote()
            store.currentText.wrappedValue = body
        }

        /// Is the markdown on screen actually styled? The point of restyling
        /// less often is that scrolling still never shows a heading as raw text.
        func headingStyled(_ textView: NSTextView) -> Bool {
            guard let storage = textView.textStorage,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return false }
            let glyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
            let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            let text = storage.string as NSString
            let heading = text.range(of: "## Section", options: [], range: visible)
            guard heading.location != NSNotFound else { return false }
            // The words after the marker, which a styled heading grows.
            let title = heading.location + 3
            let font = storage.attribute(.font, at: title, effectiveRange: nil) as? NSFont
            return (font?.pointSize ?? 0) > Theme.editorFont.pointSize
        }

        /// One drag, a frame per turn of the run loop — nested run loops don't
        /// drain the main queue, and catching up with a scroll is the one thing
        /// that happens there.
        func drag(_ label: String, steps: Int = 40, by delta: CGFloat = 200, then done: @escaping () -> Void) {
            guard let textView = findTextView(), let scrollView = textView.enclosingScrollView else {
                check("scroll view exists", false)
                return done()
            }
            let clip = scrollView.contentView
            let start = clip.bounds.origin.y
            let styled = MarkdownStyle.passes
            var drift: [Int] = []

            func frame(_ remaining: Int) {
                guard remaining > 0 else {
                    let travelled = clip.bounds.origin.y - start
                    let asked = delta * CGFloat(steps)
                    let restyles = MarkdownStyle.passes - styled
                    print("SELFTEST: [\(label)] \(steps) frames, \(restyles) restyle(s), drift \(drift)")
                    check("[\(label)] the scroll went where it was pushed", travelled > asked * 0.8)
                    check("[\(label)] nothing pulled it back", drift.allSatisfy { $0 == 0 })
                    check("[\(label)] the headings on screen are styled", headingStyled(textView))
                    check("[\(label)] the frames didn't each pay for a restyle", restyles * 3 < steps)
                    return done()
                }
                let wanted = clip.bounds.origin.y + delta
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: wanted))
                scrollView.reflectScrolledClipView(clip)
                after(0.016) {
                    // Where it ended up against where it was put: anything but
                    // zero is something pulling the view somewhere else.
                    drift.append(Int(clip.bounds.origin.y - wanted))
                    frame(remaining - 1)
                }
            }
            frame(steps)
        }

        after(3.0) {
            drag("plain") {
                trigger("Find in Note…")
                store.findQuery = "lantern"
                after(1.0) {
                    check("the search found matches (\(store.findCount))", store.findCount > 10)
                    drag("with the search up") {
                        // Stepping through matches is what used to strand the
                        // styled window: ⌘G can put the reader anywhere.
                        for _ in 0..<20 { store.findNext() }
                        after(0.5) {
                            drag("after stepping through matches") {
                                store.hideFind()
                                after(0.5) {
                                    check("the bar is closed", !store.findVisible)
                                    drag("after the search") {
                                        print("SELFTEST: \(failures) failed check(s)")
                                        NSApp.terminate(nil)
                                    }
                                }
                            }
                        }
                    }
                }
            }
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

    /// Does the incremental fence count agree with counting from scratch?
    ///
    /// The count above the caret is kept between keystrokes and only thrown away
    /// when an edit lands above where it was taken. That is a claim about every
    /// way text can reach the buffer, so this makes every one of them: typing at
    /// the top, the middle and the end, deleting, replacing a selection, pasting
    /// a fence in, undoing it, and swapping the document out from under it.
    private static func fenceFlow() {
        let store = NoteStore.shared

        let document = """
        Title

        Prose before any code at all.

        ```
        let a = 1
        ```

        Between the blocks.

        ~~~
        tilde fenced
        ~~~

        After both.

        ```swift
        unterminated fence opens here
        """

        after(1.5) {
            store.newNote()
            store.currentText.wrappedValue = document
        }

        after(3.0) {
            guard let textView = findTextView() else {
                print("SELFTEST: no editor"); NSApp.terminate(nil); return
            }
            textView.window?.makeFirstResponder(textView)
            check("verification is on", MarkdownStyle.verifying)

            let length = { (textView.string as NSString).length }

            // An edit at every offset in the document, top to bottom and back.
            for offset in stride(from: 0, to: length(), by: 7) {
                textView.setSelectedRange(NSRange(location: min(offset, length()), length: 0))
                textView.insertText("x", replacementRange: textView.selectedRange())
            }
            for offset in stride(from: length() - 1, through: 0, by: -11) {
                textView.setSelectedRange(NSRange(location: max(offset, 0), length: 1))
                textView.insertText("", replacementRange: textView.selectedRange())
            }

            // Fences arriving and leaving whole, above text already counted.
            for _ in 0..<12 {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.insertText("```\nsudden fence\n```\n", replacementRange: textView.selectedRange())
                textView.setSelectedRange(NSRange(location: 30, length: 0))
                textView.insertText("tail", replacementRange: textView.selectedRange())
                textView.undoManager?.undo()
                textView.undoManager?.undo()
            }

            // A selection replaced across a fence, then the whole document swapped.
            textView.setSelectedRange(NSRange(location: 0, length: min(60, length())))
            textView.insertText("replaced\n```\n", replacementRange: textView.selectedRange())
            store.newNote()
            store.currentText.wrappedValue = document + "\n```\nand more\n```\n"

            check("fence count never disagreed with a full rescan", MarkdownStyle.mismatches == 0)
            if MarkdownStyle.mismatches > 0 {
                print("SELFTEST: \(MarkdownStyle.mismatches) mismatch(es)")
            }
            print("SELFTEST: \(failures) failed check(s)")
            NSApp.terminate(nil)
        }
    }

    /// What one keystroke costs, end to end.
    ///
    /// Builds a library of the size someone actually keeps, opens a long note
    /// in it, then types a character at a time — forcing the window to settle
    /// after each one, so the measurement includes everything the keystroke set
    /// in motion, not just the insert.
    private static func benchFlow() {
        let store = NoteStore.shared
        let notes = Int(ProcessInfo.processInfo.environment["POE_BENCH_NOTES"] ?? "") ?? 20
        let size = Int(ProcessInfo.processInfo.environment["POE_BENCH_SIZE"] ?? "") ?? 40_000
        let strokes = Int(ProcessInfo.processInfo.environment["POE_BENCH_STROKES"] ?? "") ?? 150

        var body = "Bench Note\n\n"
        var paragraph = 0
        while body.utf8.count < size {
            body += "## Section \(paragraph)\nProse about **things** and `code`, running on a while.\n\n"
            paragraph += 1
        }

        after(1.5) {
            for index in 0..<notes {
                store.newNote()
                store.currentText.wrappedValue = "Note \(index)\n\n" + body
            }
            store.newNote()
            store.currentText.wrappedValue = body
        }

        after(3.5) {
            guard let textView = findTextView(), let view = textView.window?.contentView else {
                print("BENCH: no editor"); NSApp.terminate(nil); return
            }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

            @MainActor func settle() {
                PoePerf.measure("  settle.layout") { view.layoutSubtreeIfNeeded() }
                PoePerf.measure("  settle.flush") { CATransaction.flush() }
                PoePerf.measure("  settle.display") { view.displayIfNeeded() }
            }

            // Warm the caches the first keystroke would otherwise pay for.
            for _ in 0..<10 {
                textView.insertText("w", replacementRange: textView.selectedRange())
                settle()
            }

            PoePerf.enabled = ProcessInfo.processInfo.environment["POE_BENCH_PERF"] != nil
            PoePerf.reset()
            var samples: [Double] = []
            for _ in 0..<strokes {
                let started = CFAbsoluteTimeGetCurrent()
                textView.insertText("a", replacementRange: textView.selectedRange())
                let inserted = CFAbsoluteTimeGetCurrent()
                settle()
                let done = CFAbsoluteTimeGetCurrent()
                PoePerf.record("insertText (total)", inserted - started)
                PoePerf.record("settle (SwiftUI+draw)", done - inserted)
                samples.append((done - started) * 1000)
            }
            samples.sort()
            let mean = samples.reduce(0, +) / Double(samples.count)
            print(String(
                format: "BENCH notes=%d size=%dKB  mean %.3f ms  median %.3f ms  p95 %.3f ms  max %.3f ms",
                notes + 1, size / 1000, mean,
                samples[samples.count / 2], samples[Int(Double(samples.count) * 0.95)], samples[samples.count - 1]
            ))
            PoePerf.report(over: strokes)
            NSApp.terminate(nil)
        }
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
        guard let window = mainWindow, let view = window.contentView else { return }
        // An occluded window stops redrawing, so a capture can otherwise write a
        // frame from several seconds ago. Bring it forward and flush first.
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        view.layoutSubtreeIfNeeded()
        CATransaction.flush()
        view.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.contentView != nil }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func findDriftView() -> DriftView? {
        func search(_ view: NSView) -> DriftView? {
            if let found = view as? DriftView { return found }
            for subview in view.subviews {
                if let found = search(subview) { return found }
            }
            return nil
        }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let found = search(root) { return found }
        }
        return nil
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

    /// Matches are drawn as temporary attributes on the layout manager — this
    /// is the only place the difference between that and editing the text shows.
    private static func lit(at index: Int) -> Bool {
        guard index >= 0, let layoutManager = findTextView()?.layoutManager else { return false }
        return layoutManager.temporaryAttribute(.backgroundColor, atCharacterIndex: index, effectiveRange: nil) != nil
    }

    /// Which menu item a key stroke would actually reach — the first match in
    /// menu order, which is how AppKit itself resolves one.
    private static func shortcutOwner(_ key: String, _ flags: NSEvent.ModifierFlags) -> String? {
        func search(_ menu: NSMenu) -> String? {
            menu.update()
            for item in menu.items {
                if item.keyEquivalent.lowercased() == key, modifiers(of: item) == flags { return item.title }
                if let submenu = item.submenu, let found = search(submenu) { return found }
            }
            return nil
        }
        guard let main = NSApp.mainMenu else { return nil }
        return search(main)
    }

    /// An uppercase key equivalent carries the shift the mask doesn't mention.
    private static func modifiers(of item: NSMenuItem) -> NSEvent.ModifierFlags {
        var flags = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        let key = item.keyEquivalent
        if key != key.lowercased() { flags.insert(.shift) }
        return flags
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

/// Where a keystroke's time actually goes.
///
/// Off unless the bench asks for it, and then only a pair of `CFAbsoluteTime`
/// reads per span — cheap enough not to change what it is measuring.
enum PoePerf {
    static var enabled = false
    private static var totals: [String: (seconds: Double, count: Int)] = [:]

    @inline(__always)
    static func measure<T>(_ label: String, _ body: () -> T) -> T {
        guard enabled else { return body() }
        let started = CFAbsoluteTimeGetCurrent()
        defer { record(label, CFAbsoluteTimeGetCurrent() - started) }
        return body()
    }

    static func record(_ label: String, _ seconds: Double) {
        guard enabled else { return }
        var entry = totals[label] ?? (0, 0)
        entry.seconds += seconds
        entry.count += 1
        totals[label] = entry
    }

    static func reset() { totals = [:] }

    static func report(over strokes: Int) {
        guard enabled else { return }
        for (label, entry) in totals.sorted(by: { $0.value.seconds > $1.value.seconds }) {
            print(String(
                format: "PERF  %-26s %8.3f ms/stroke  (%d calls, %.3f ms each)",
                (label as NSString).utf8String!, entry.seconds * 1000 / Double(strokes),
                entry.count, entry.seconds * 1000 / Double(entry.count)
            ))
        }
    }
}
