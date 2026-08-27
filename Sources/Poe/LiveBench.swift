import AppKit
import Foundation

/// What Poe costs while it is actually being used.
///
/// The keystroke bench measures the synchronous half of a keystroke with the
/// run loop held shut. That is the half a writer feels first, but it leaves out
/// everything Poe defers on purpose — the settle that catches the chrome up, the
/// debounced restyle, the save — along with the window's own animation, none of
/// which can run while the loop is closed.
///
/// This runs the app for real: the loop spins, the timers fire, the background
/// drifts. And it measures CPU time rather than wall time, because wall time on
/// a machine with anything else running on it measures the other thing.
///
/// `POE_SELFTEST=live`, with POE_BENCH_NOTES / POE_BENCH_SIZE / POE_BENCH_STROKES.
@MainActor
enum LiveBench {

    static func run() {
        let store = NoteStore.shared
        let notes = Int(ProcessInfo.processInfo.environment["POE_BENCH_NOTES"] ?? "") ?? 20
        let size = Int(ProcessInfo.processInfo.environment["POE_BENCH_SIZE"] ?? "") ?? 40_000
        let strokes = Int(ProcessInfo.processInfo.environment["POE_BENCH_STROKES"] ?? "") ?? 120
        /// About as fast as anyone types, and slow enough that the work Poe puts
        /// off until the typing pauses gets its chance to happen.
        let interval = 0.08
        let idleSeconds = 6.0

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

        // Sitting there doing nothing, which is what a notepad mostly does.
        // Whether the app was frontmost while idling — the background stops
        // drifting when it isn't, so an idle figure means nothing without it.
        var idleStart = 0.0
        var wasActive = false
        after(3.5) { idleStart = cpu(); wasActive = NSApp.isActive }

        after(3.5 + idleSeconds) {
            let idle = cpu() - idleStart
            guard let textView = findTextView() else {
                print("LIVE: no editor"); NSApp.terminate(nil); return
            }
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))

            let typingStart = cpu()
            var typed = 0
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
                guard typed < strokes else {
                    timer.invalidate()
                    // Let the last settle and the save that follows it land.
                    after(1.5) {
                        let typing = cpu() - typingStart
                        print(String(
                            format: "LIVE notes=%d size=%dKB  active=%@  idle %.1f%% of a core  typing %.3f ms CPU/stroke  (%.2fs total)",
                            notes + 1, size / 1000,
                            wasActive ? "yes" : "NO",
                            idle / idleSeconds * 100,
                            typing * 1000 / Double(strokes),
                            typing
                        ))
                        NSApp.terminate(nil)
                    }
                    return
                }
                typed += 1
                textView.insertText("a", replacementRange: textView.selectedRange())
            }
        }
    }

    /// CPU actually burned by this process, every thread of it. Note that the
    /// compositing the window asks of the system happens in WindowServer, which
    /// is a different process and not counted here.
    private static func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func after(_ seconds: Double, _ block: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: block)
    }

    private static func findTextView() -> NSTextView? {
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let found = search(root) { return found }
        }
        return nil
    }

    private static func search(_ view: NSView) -> NSTextView? {
        if let textView = view as? NSTextView, textView.identifier == PoeTextView.identifier {
            return textView
        }
        for subview in view.subviews {
            if let found = search(subview) { return found }
        }
        return nil
    }
}
