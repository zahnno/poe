import SwiftUI
import AppKit

/// The writing surface.
///
/// SwiftUI's `TextEditor` can't give us a glowing caret, generous line spacing,
/// real undo, or a text container inset, so this wraps `NSTextView` directly.
struct PoeTextView: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("poe.editor")

    @Binding var text: String
    var focusToken: Int
    /// False while the markdown preview is up: the view stays mounted (so undo
    /// history and scroll position survive) but must not hold the keyboard.
    var active: Bool = true

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
        textView.defaultParagraphStyle = Coordinator.paragraphStyle
        textView.typingAttributes = Coordinator.attributes

        // Prose tools that fight with markdown and code.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        context.coordinator.apply(to: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        // Only rewrite the buffer when the model genuinely diverged (a note switch,
        // not the keystroke we just reported) — otherwise the caret jumps to the end.
        if textView.string != text {
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

        static let paragraphStyle: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 7
            style.paragraphSpacing = 10
            return style
        }()

        static let attributes: [NSAttributedString.Key: Any] = [
            .font: Theme.editorFont,
            .foregroundColor: NSColor(Theme.ink),
            .paragraphStyle: paragraphStyle
        ]

        init(_ parent: PoeTextView) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        /// Re-stamp font, colour and spacing across the buffer after a wholesale
        /// text replacement, which drops attributes on the floor.
        func apply(to textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.setAttributes(Self.attributes, range: full)
            textView.typingAttributes = Self.attributes
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
