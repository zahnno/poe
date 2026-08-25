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
    /// Prose gets red squiggles; a JSON file does not.
    var spellChecks: Bool = true
    /// Code wants its lines close together; prose wants room to breathe.
    var dense: Bool = false

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
        textView.isContinuousSpellCheckingEnabled = spellChecks
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        context.coordinator.apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        textView.isContinuousSpellCheckingEnabled = spellChecks

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
        /// text replacement, which drops attributes on the floor.
        func apply(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let attributes = Self.attributes(dense: parent.dense)
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            textView.typingAttributes = attributes
            textView.defaultParagraphStyle = Self.paragraphStyle(dense: parent.dense)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onEdit(textView.string)
        }
    }
}
