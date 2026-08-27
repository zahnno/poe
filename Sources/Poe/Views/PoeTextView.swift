import SwiftUI
import AppKit

/// The writing surface.
///
/// SwiftUI's `TextEditor` can't give us a glowing caret, generous line spacing,
/// real undo, or a text container inset, so this wraps `NSTextView` directly.
struct PoeTextView: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("poe.editor")

    /// The text is passed by value, not as a `@Binding`, and deliberately so:
    /// SwiftUI diffs a representable on its stored properties, and a binding's
    /// *contents* are invisible to that comparison. With a binding, text that
    /// changed anywhere but in this view — a reload from disk, a file edited in
    /// another app — never reached the buffer until some unrelated redraw
    /// happened to come along.
    var text: String
    /// Called with the new text whenever the writer types.
    var onEdit: (String) -> Void
    /// Which note or file the buffer currently holds. One text view serves every
    /// document, so this is what tells it a *different* document arrived.
    var documentID: UUID?
    var focusToken: Int
    /// False while the markdown preview is up: the view stays mounted (so undo
    /// history and scroll position survive) but must not hold the keyboard.
    var active: Bool = true
    /// What the buffer holds, which settles three things at once: markdown is
    /// styled as you type and spell-checked, code is neither and sits on
    /// tighter lines.
    var kind: FileKind = .markdown
    /// What the find bar found. The store does the searching — it holds the
    /// text — and the editor only lights the matches and scrolls to one.
    var find: FindState = FindState()
    /// Esc with the find bar up. Returns true if there was a bar to close.
    var onEscape: () -> Bool = { false }

    /// Everything the editor needs to draw a search, as one comparable value.
    struct FindState: Equatable {
        var active: Bool = false
        var matches: [FindMatch] = []
        /// The current match, counting from one; zero when there are none.
        var current: Int = 0
        /// Ticks over when the current match moves on purpose, and only then —
        /// a recount after a keystroke must not scroll the writer away.
        var revealToken: Int = 0

        var currentRange: NSRange? {
            guard current > 0, current <= matches.count else { return nil }
            return matches[current - 1].range
        }
    }

    /// Styling a document TextKit has to keep re-laying out gets expensive
    /// somewhere north of this; beyond it the text stays plain and legible, and
    /// ⌘P still renders the whole thing.
    static let stylingLimit = 60_000

    /// Measured in UTF-8 bytes, which a Swift string already knows, rather
    /// than in characters, which it has to walk the whole document to count —
    /// this is asked on every keystroke and every redraw. Bytes only ever
    /// over-estimate, so the limit still holds.
    var styled: Bool { kind.rendersMarkdown && text.utf8.count <= Self.stylingLimit }
    var dense: Bool { !kind.rendersMarkdown }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.verticalScroller?.alphaValue = 0.35

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.identifier = PoeTextView.identifier
        textView.delegate = context.coordinator
        context.coordinator.replace(textView, with: text)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 30, height: 30)
        textView.insertionPointColor = NSColor(Theme.accent)
        textView.textColor = NSColor(Theme.ink)
        textView.font = Theme.editorFont

        // Prose tools that fight with markdown and code. Autocorrection is off
        // for a second reason: it rewrites text *asynchronously*, and a
        // correction queued against one document used to land in the next one —
        // which, now that documents can be files, means edits to someone's disk.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = styled
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Every character edit, however it got there, so the markdown styler's
        // running fence count can tell what it still knows from what it doesn't.
        textView.textStorage?.delegate = context.coordinator

        context.coordinator.apply(to: textView)
        context.coordinator.watchScrolling(of: scrollView)
        EditorTextView.register(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        textView.isContinuousSpellCheckingEnabled = styled

        if context.coordinator.documentID != documentID {
            // A different document. The text view is shared, so everything it was
            // holding for the last one — half-typed input, an undo stack that
            // would splice the old words into this file — has to go with it.
            context.coordinator.rememberCaret(in: textView)
            context.coordinator.documentID = documentID
            textView.inputContext?.discardMarkedText()
            context.coordinator.replace(textView, with: text)
            context.coordinator.apply(to: textView)
            textView.undoManager?.removeAllActions()
            context.coordinator.restoreCaret(in: textView)
        } else if !context.coordinator.holds(text) {
            // Same document, new text: a reload from disk, or a change made
            // outside Poe. Keep the caret where the writer left it.
            let selected = textView.selectedRange()
            context.coordinator.replace(textView, with: text)
            context.coordinator.apply(to: textView)
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
        }

        textView.isEditable = active
        if !active, textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }

        if active, context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        context.coordinator.updateFind(in: textView, to: find)
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: PoeTextView
        var focusToken: Int
        var documentID: UUID?
        /// A full restyle is cheap but not free; typing only ever restyles the
        /// line under the caret, and this catches up once the keys stop.
        private var pendingRestyle: DispatchWorkItem?
        private weak var scrollView: NSScrollView?
        /// What the last pass covered, so scrolling within it costs nothing.
        private var styledRange: NSRange?
        /// Where the caret was in each document, so coming back feels like
        /// returning rather than starting over.
        private var carets: [UUID: Int] = [:]
        /// What was last drawn, so an update that changes nothing costs nothing.
        private var findState = FindState()
        /// Exactly which ranges carry a highlight, so clearing one doesn't mean
        /// sweeping temporary attributes off the whole document — which asks
        /// TextKit to reconsider every line in it.
        private var lit: [Highlight] = []
        /// The text the buffer is known to hold.
        ///
        /// SwiftUI hands this view the document on every update, and the old
        /// code asked `textView.string != text` — building a `String` from the
        /// storage and comparing two whole documents, on every redraw. Holding
        /// on to the string that went in means the usual answer costs a pointer
        /// comparison: Swift compares identical string buffers by identity.
        private var knownText = ""
        /// True when the edit about to be published has already been spliced
        /// into `knownText`. A change that arrived some other way — or one the
        /// splice couldn't place — reads the whole buffer back instead.
        private var patched = false
        /// Set while we are putting a whole new document in: the storage
        /// delegate must not try to splice a replacement it didn't cause.
        private var replacing = false

        struct Highlight: Equatable {
            var range: NSRange
            var current: Bool
        }

        /// Is this the text the buffer already holds?
        func holds(_ text: String) -> Bool {
            knownText.utf8.count == text.utf8.count && knownText == text
        }

        /// Put a whole new document in the buffer, remembering what it was.
        func replace(_ textView: NSTextView, with text: String) {
            replacing = true
            textView.string = text
            replacing = false
            knownText = text
            patched = false
            lit = []
        }

        static func paragraphStyle(dense: Bool) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = dense ? 2.5 : 7
            style.paragraphSpacing = dense ? 0 : 10
            return style
        }

        static func attributes(dense: Bool) -> [NSAttributedString.Key: Any] {
            [
                .font: Theme.editorFont,
                .foregroundColor: NSColor(Theme.ink),
                .paragraphStyle: paragraphStyle(dense: dense)
            ]
        }

        init(_ parent: PoeTextView) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        func rememberCaret(in textView: NSTextView) {
            guard let documentID else { return }
            carets[documentID] = textView.selectedRange().location
        }

        func restoreCaret(in textView: NSTextView) {
            let limit = (textView.string as NSString).length
            let location = min(documentID.flatMap { carets[$0] } ?? 0, limit)
            let range = NSRange(location: location, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
        }

        /// Re-stamp font, colour and spacing across the buffer after a wholesale
        /// text replacement, which drops attributes on the floor, then style the
        /// markdown on top.
        func apply(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let attributes = Self.attributes(dense: parent.dense)
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            lit = []
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = Self.paragraphStyle(dense: parent.dense)
            styledRange = nil
            restyleVisible(textView, force: true)
            highlightFind(in: textView)
        }

        /// Style what's on screen, plus a margin either side so scrolling never
        /// reveals raw text. Cost stays flat however long the document is.
        func restyleVisible(_ textView: NSTextView, force: Bool) {
            guard parent.styled, let storage = textView.textStorage, storage.length > 0 else { return }
            let target = visibleRange(of: textView)
            if !force, let styled = styledRange, NSIntersectionRange(styled, target) == target { return }
            MarkdownStyle.apply(to: storage, base: Self.attributes(dense: parent.dense), in: target)
            styledRange = target
            highlightFind(in: textView)
        }

        /// Just the paragraph under the caret — what a keystroke can change on
        /// its own, and fast enough to do on every one of them.
        private func restyleCaretParagraph(in textView: NSTextView) {
            guard parent.styled, let storage = textView.textStorage, storage.length > 0 else { return }
            let text = storage.string as NSString
            let caret = min(textView.selectedRange().location, text.length)
            let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
            MarkdownStyle.apply(to: storage, base: Self.attributes(dense: parent.dense), in: paragraph)
            // Everything after the edit has shifted; the old range no longer maps.
            styledRange = nil
            highlightFind(in: textView)
        }

        /// Multi-line markdown — a fence opening three lines up — only settles
        /// once the typing pauses.
        private func scheduleRestyle(of textView: NSTextView) {
            pendingRestyle?.cancel()
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.restyleVisible(textView, force: true)
            }
            pendingRestyle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        /// Style follows the scroll: whatever comes into view gets styled as it
        /// arrives, and scrolling inside what's already styled does nothing.
        func watchScrolling(of scrollView: NSScrollView) {
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(didScroll),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func didScroll() {
            guard let textView = scrollView?.documentView as? NSTextView else { return }
            restyleVisible(textView, force: false)
            // Not part of the restyle: code and very long documents never reach
            // it, and their matches still have to light up as they scroll in.
            // With no search up there is nothing to relight, and this fires on
            // every frame of every scroll.
            guard findState.active || !lit.isEmpty else { return }
            highlightFind(in: textView)
        }

        private func visibleRange(of textView: NSTextView) -> NSRange {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer,
                  let storage = textView.textStorage else {
                return NSRange(location: 0, length: 0)
            }
            let visible = textView.visibleRect
            let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
            let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // A screenful of slack either side, so scrolling never shows raw text.
            let padding = 2_500
            let start = max(0, characters.location - padding)
            let end = min(storage.length, NSMaxRange(characters) + padding)
            return NSRange(location: start, length: end - start)
        }

        /// Text changed in the buffer — typed, pasted, undone, or replaced whole.
        /// Attribute-only edits are the styler's own work and change nothing it
        /// has counted.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyle.invalidate(from: editedRange.location)
            guard !replacing else { return }
            patched = splice(editedRange, delta: delta, of: textStorage)
        }

        /// Carry the edit that just landed into `knownText`, instead of reading
        /// the whole document back out of the buffer.
        ///
        /// The storage hands over the range the edit now occupies and how much
        /// longer it made the document, which between them say exactly what was
        /// replaced: `editedRange.length - delta` characters in the same place.
        /// So a keystroke splices in a keystroke. It used to bridge, copy and
        /// validate the entire document per character — half a millisecond on a
        /// 40 KB note, and the largest single cost of typing into a big file.
        ///
        /// False if the edit can't be placed — a buffer we've lost track of, or
        /// a range that doesn't land on a character boundary — and the caller
        /// falls back to reading it whole.
        private func splice(_ edited: NSRange, delta: Int, of storage: NSTextStorage) -> Bool {
            let replaced = edited.length - delta
            guard edited.location >= 0, edited.length >= 0, replaced >= 0,
                  NSMaxRange(edited) <= storage.length,
                  // What we hold has to *be* what the buffer held a moment ago,
                  // or the range below would splice into the wrong document.
                  storage.length - delta == knownText.utf16.count,
                  let range = Range(NSRange(location: edited.location, length: replaced), in: knownText)
            else { return false }

            // Small inserts — every keystroke — arrive as Swift's own compact
            // string form and need no conversion; a paste is bulk-converted
            // once, here, rather than a character at a time downstream.
            let inserted = edited.length == 0
                ? ""
                : Self.native((storage.string as NSString).substring(with: edited))
            knownText.replaceSubrange(range, with: inserted)
            return true
        }

        /// Esc closes the find bar from the editor too, the way it does from the
        /// field itself — the writer shouldn't have to reach back for it.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            return parent.onEscape()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // The storage delegate has already carried the edit across; only a
            // change it couldn't place sends us back to the whole document. The
            // very same string then goes to the store and stays here, so the
            // update that comes back knows itself on sight.
            if !patched { knownText = Self.native(textView) }
            patched = false
            parent.onEdit(knownText)
            restyleCaretParagraph(in: textView)
            scheduleRestyle(of: textView)
        }

        /// The buffer's text, as a string Swift can actually read.
        ///
        /// `NSTextView.string` hands back a *lazily bridged* `NSString`. It
        /// arrives instantly — and then every byte anyone asks of it is fetched
        /// one character at a time through Objective-C. On a 40 KB note that
        /// makes `utf8.count` cost 0.2 ms, the byte scanners in `Note` run 13×
        /// slower than they read, and `withContiguousStorageIfAvailable` — which
        /// the library search leans on for its fast path — quietly returns nil,
        /// so that path never runs at all.
        ///
        /// Converting it here, once, in bulk, costs about half a millisecond and
        /// buys all of that back for as long as the note is in memory: this is
        /// the string the store keeps, so nothing downstream ever pays again.
        static func native(_ textView: NSTextView) -> String {
            native(textView.string)
        }

        static func native(_ text: String) -> String {
            if text.isContiguousUTF8 { return text }
            // Through `Data` rather than `makeContiguousUTF8()`, which walks the
            // text character by character and costs ten times as much, and
            // rather than `utf8String`, which stops at the first NUL.
            if let data = (text as NSString).data(using: String.Encoding.utf8.rawValue),
               let converted = String(data: data, encoding: .utf8) {
                return converted
            }
            var fallback = text
            fallback.makeContiguousUTF8()
            return fallback
        }

        // MARK: - Find

        /// Draw the search the store handed us: light every match on screen,
        /// and scroll to the current one when it has actually moved.
        func updateFind(in textView: NSTextView, to state: FindState) {
            let previous = findState
            guard state != previous else { return }
            findState = state

            if state.active, state.revealToken != previous.revealToken {
                reveal(in: textView)
            }
            highlightFind(in: textView)
        }

        /// Scroll a match into view and leave the caret on it, so dismissing the
        /// bar puts you exactly where you were looking.
        private func reveal(in textView: NSTextView) {
            guard let range = findState.currentRange,
                  NSMaxRange(range) <= (textView.string as NSString).length else { return }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            restyleVisible(textView, force: false)
        }

        /// Matches are lit with temporary attributes: the buffer itself is never
        /// touched, so nothing here can reach the file on disk or the undo stack.
        /// Only what's on screen is lit — a match in a 2 MB file costs nothing
        /// until you scroll to it.
        private func highlightFind(in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let storage = textView.textStorage else { return }
            let wanted = highlights(in: textView, length: storage.length)
            // Scrolling a long document fires this on every frame; most of them
            // want exactly what is already drawn.
            guard wanted != lit else { return }

            for highlight in lit {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlight.range)
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlight.range)
            }
            for highlight in wanted {
                layoutManager.addTemporaryAttributes(
                    highlight.current ? Self.currentMatch : Self.otherMatch,
                    forCharacterRange: highlight.range
                )
            }
            lit = wanted
        }

        /// Which matches should be lit: the ones on screen, plus the current
        /// one wherever it is. A document can hold twenty thousand matches, so
        /// the on-screen run is found by bisection rather than by walking them.
        private func highlights(in textView: NSTextView, length: Int) -> [Highlight] {
            guard findState.active, !findState.matches.isEmpty else { return [] }
            let matches = findState.matches
            let onScreen = visibleRange(of: textView)

            var found: [Highlight] = []
            if let current = findState.currentRange, NSMaxRange(current) <= length {
                found.append(Highlight(range: current, current: true))
            }

            // First match that could still reach into the visible range.
            var low = 0, high = matches.count
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(matches[middle].range) <= onScreen.location { low = middle + 1 } else { high = middle }
            }

            var index = low
            while index < matches.count, matches[index].range.location < NSMaxRange(onScreen) {
                let range = matches[index].range
                let ordinal = index + 1
                index += 1
                // The current one is already in, wherever it happens to be.
                guard NSMaxRange(range) <= length, ordinal != findState.current else { continue }
                found.append(Highlight(range: range, current: false))
            }
            return found
        }

        private static let currentMatch: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.85),
            .foregroundColor: NSColor(Theme.void)
        ]

        private static let otherMatch: [NSAttributedString.Key: Any] = [
            .backgroundColor: NSColor(Theme.accent).withAlphaComponent(0.20),
            .foregroundColor: NSColor(Theme.ink)
        ]

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}




/// The editor's text view, wherever it currently is in the window.
///
/// ⌘E is a menu command, and menu commands live outside every view — so the one
/// thing it needs, the writer's selection, has to be fetched from the responder
/// tree by hand.
enum EditorTextView {
    /// The editor registers itself when it is built, so finding it later is a
    /// lookup rather than a walk of every view in every window — which is what
    /// ⌘F did, on each recount, to ask where the caret was.
    private static weak var registered: NSTextView?

    static func register(_ textView: NSTextView) { registered = textView }

    static var current: NSTextView? {
        if let registered, registered.window != nil { return registered }
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let found = search(root) {
                registered = found
                return found
            }
        }
        return nil
    }

    static var selectedText: String? {
        guard let textView = current else { return nil }
        let range = textView.selectedRange()
        guard range.length > 0 else { return nil }
        return (textView.string as NSString).substring(with: range)
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
