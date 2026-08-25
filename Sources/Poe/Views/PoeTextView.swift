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

    var styled: Bool { kind.rendersMarkdown && text.count <= Self.stylingLimit }
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
        textView.string = text
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

        context.coordinator.apply(to: textView)
        context.coordinator.watchScrolling(of: scrollView)
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
            textView.string = text
            context.coordinator.apply(to: textView)
            textView.undoManager?.removeAllActions()
            context.coordinator.restoreCaret(in: textView)
        } else if textView.string != text {
            // Same document, new text: a reload from disk, or a change made
            // outside Poe. Keep the caret where the writer left it.
            let selected = textView.selectedRange()
            textView.string = text
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

    final class Coordinator: NSObject, NSTextViewDelegate {
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

        /// Esc closes the find bar from the editor too, the way it does from the
        /// field itself — the writer shouldn't have to reach back for it.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            return parent.onEscape()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onEdit(textView.string)
            restyleCaretParagraph(in: textView)
            scheduleRestyle(of: textView)
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
            guard let layoutManager = textView.layoutManager else { return }
            let whole = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: whole)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: whole)
            guard findState.active, !findState.matches.isEmpty else { return }

            let onScreen = visibleRange(of: textView)
            for (index, range) in findState.matches.map(\.range).enumerated() {
                guard NSMaxRange(range) <= whole.length else { continue }
                let current = index + 1 == findState.current
                guard current || NSIntersectionRange(range, onScreen).length > 0 else { continue }
                layoutManager.addTemporaryAttributes(
                    current ? Self.currentMatch : Self.otherMatch,
                    forCharacterRange: range
                )
            }
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
    static var current: NSTextView? {
        for window in NSApp.windows where window.isVisible {
            if let root = window.contentView, let found = search(root) { return found }
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
