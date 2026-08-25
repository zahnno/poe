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
        }

        /// Style what's on screen, plus a margin either side so scrolling never
        /// reveals raw text. Cost stays flat however long the document is.
        func restyleVisible(_ textView: NSTextView, force: Bool) {
            guard parent.styled, let storage = textView.textStorage, storage.length > 0 else { return }
            let target = visibleRange(of: textView)
            if !force, let styled = styledRange, NSIntersectionRange(styled, target) == target { return }
            MarkdownStyle.apply(to: storage, base: Self.attributes(dense: parent.dense), in: target)
            styledRange = target
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

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onEdit(textView.string)
            restyleCaretParagraph(in: textView)
            scheduleRestyle(of: textView)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}


