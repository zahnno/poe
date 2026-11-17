import AppKit

/// The small conveniences that make writing markdown feel like writing:
/// ⌘B and ⌘I wrap the selection, ⌘K makes a link, ⇧⌘L makes or ticks a
/// checklist item, and Return carries a list on by itself.
///
/// Every change goes through the text view's own `shouldChangeText` /
/// `didChangeText` pair, so each one is a single step on the undo stack and
/// reaches the store exactly the way typing does.
enum MarkdownEditing {

    enum Action {
        case bold, italic, code, link, checklist
    }

    static func perform(_ action: Action, in textView: NSTextView) {
        switch action {
        case .bold: toggleWrap(textView, marker: "**", name: "Bold")
        case .italic: toggleWrap(textView, marker: "*", name: "Italic")
        case .code: toggleWrap(textView, marker: "`", name: "Code")
        case .link: insertLink(textView)
        case .checklist: toggleChecklist(textView)
        }
    }

    // MARK: - Wrapping

    /// Wrap the selection in a marker — or, when it's already wrapped, unwrap
    /// it. With nothing selected the caret lands between a fresh pair.
    private static func toggleWrap(_ textView: NSTextView, marker: String, name: String) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let width = (marker as NSString).length

        func slice(_ location: Int, _ length: Int) -> String? {
            guard location >= 0, length >= 0, location + length <= text.length else { return nil }
            return text.substring(with: NSRange(location: location, length: length))
        }

        // Is the selection already wrapped? For stars that's a matter of
        // counting them: `***word***` is bold *and* italic, so the run either
        // side says which of the two is there — an odd run has the italic, a
        // run of two or more has the bold.
        let present: Bool
        if marker.allSatisfy({ $0 == "*" }) {
            let star = unichar(UInt8(ascii: "*"))
            var left = 0
            while selection.location - left - 1 >= 0, text.character(at: selection.location - left - 1) == star { left += 1 }
            var right = 0
            while NSMaxRange(selection) + right < text.length, text.character(at: NSMaxRange(selection) + right) == star { right += 1 }
            let shared = min(left, right)
            present = width == 1 ? shared % 2 == 1 : shared >= 2
        } else {
            present = slice(selection.location - width, width) == marker && slice(NSMaxRange(selection), width) == marker
        }

        // The markers sit just outside the selection: take them away.
        let before = selection.location - width
        if present {
            let outer = NSRange(location: before, length: selection.length + 2 * width)
            replace(textView, outer, with: text.substring(with: selection),
                    select: NSRange(location: before, length: selection.length), action: name)
            return
        }

        let selected = text.substring(with: selection)
        // The selection carries its own markers: take those away instead.
        let doubled = marker == "*" && selected.hasPrefix("**") && !selected.hasPrefix("***")
        if selection.length >= 2 * width, selected.hasPrefix(marker), selected.hasSuffix(marker), !doubled {
            let inner = (selected as NSString).substring(with: NSRange(location: width, length: selection.length - 2 * width))
            replace(textView, selection, with: inner,
                    select: NSRange(location: selection.location, length: (inner as NSString).length), action: name)
            return
        }

        replace(textView, selection, with: marker + selected + marker,
                select: NSRange(location: selection.location + width, length: selection.length), action: name)
    }

    // MARK: - Links

    /// `[selection](url)`, with "url" selected ready to be typed over — or the
    /// address on the clipboard already in place, if there is one. A selected
    /// address becomes the link, with the caret in the empty label.
    private static func insertLink(_ textView: NSTextView) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let selected = text.substring(with: selection)

        if isAddress(selected) {
            replace(textView, selection, with: "[](\(selected))",
                    select: NSRange(location: selection.location + 1, length: 0), action: "Link")
            return
        }

        let clipboard = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let label = selected as NSString
        if let clipboard, isAddress(clipboard), !clipboard.contains(" ") {
            let link = "[\(selected)](\(clipboard))"
            let caret = selected.isEmpty
                ? NSRange(location: selection.location + 1, length: 0)
                : NSRange(location: selection.location + (link as NSString).length, length: 0)
            replace(textView, selection, with: link, select: caret, action: "Link")
        } else {
            let link = "[\(selected)](url)"
            let placeholder = selected.isEmpty
                ? NSRange(location: selection.location + 1, length: 0)
                : NSRange(location: selection.location + label.length + 3, length: 3)
            replace(textView, selection, with: link, select: placeholder, action: "Link")
        }
    }

    private static func isAddress(_ string: String) -> Bool {
        string.hasPrefix("http://") || string.hasPrefix("https://") || string.hasPrefix("mailto:")
    }

    // MARK: - Checklists

    /// `- [ ] `, the start of a list item, and its tick box if it has one.
    /// Groups: indent, marker, gap, box.
    static let listItem = try! NSRegularExpression(pattern: "^([ \\t]*)([-*+]|\\d{1,9}[.)])([ \\t]+)(\\[[ xX]\\][ \\t]+)?")

    /// Every line the selection touches becomes a checklist item; a line that
    /// already is one gets ticked, or unticked.
    private static func toggleChecklist(_ textView: NSTextView) {
        let text = textView.string as NSString
        let selection = textView.selectedRange()
        let lines = text.lineRange(for: selection)
        let block = text.substring(with: lines)
        let newline = block.hasSuffix("\n")

        var parts = block.components(separatedBy: "\n")
        if newline { parts.removeLast() }
        let several = parts.count > 1
        let changed = parts.map { line -> String in
            // Blank lines inside a sweep stay blank.
            if several, line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            return toggledChecklist(line)
        }

        let replacement = changed.joined(separator: "\n") + (newline ? "\n" : "")
        let length = (replacement as NSString).length - (newline ? 1 : 0)
        let select: NSRange
        if several || selection.length > 0 {
            select = NSRange(location: lines.location, length: length)
        } else {
            // Keep the caret on the same word it was on.
            let delta = (replacement as NSString).length - lines.length
            let caret = min(max(selection.location + delta, lines.location), lines.location + length)
            select = NSRange(location: caret, length: 0)
        }
        replace(textView, lines, with: replacement, select: select, action: "Checklist")
    }

    static func toggledChecklist(_ line: String) -> String {
        let text = line as NSString
        if let match = listItem.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
            let box = match.range(at: 4)
            if box.location != NSNotFound {
                let tick = NSRange(location: box.location + 1, length: 1)
                let ticked = text.substring(with: tick) != " "
                return text.replacingCharacters(in: tick, with: ticked ? " " : "x")
            }
            return text.replacingCharacters(in: NSRange(location: NSMaxRange(match.range), length: 0), with: "[ ] ")
        }
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        return indent + "- [ ] " + line.dropFirst(indent.count)
    }

    // MARK: - Lists carry on

    /// Return at the end of a list item starts the next one — the same bullet,
    /// the next number, a fresh empty box. Return on an item with nothing in it
    /// ends the list instead. Returns false when Return should just be Return.
    static func continueList(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMarkedText() else { return false }
        let text = textView.string as NSString
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        var end = NSMaxRange(line)
        if end > line.location, text.character(at: end - 1) == 0x0A { end -= 1 }
        let content = NSRange(location: line.location, length: end - line.location)
        let lineText = text.substring(with: content)
        let lineString = lineText as NSString

        guard let match = listItem.firstMatch(in: lineText, range: NSRange(location: 0, length: lineString.length)),
              selection.location >= line.location + match.range.length
        else { return false }

        if match.range.length == content.length {
            // An item with nothing in it: the list is over.
            replace(textView, content, with: "", select: NSRange(location: content.location, length: 0), action: "Typing")
            return true
        }

        let indent = lineString.substring(with: match.range(at: 1))
        var marker = lineString.substring(with: match.range(at: 2))
        if let last = marker.last, last == "." || last == ")", let number = Int(marker.dropLast()) {
            marker = "\(number + 1)\(last)"
        }
        let gap = lineString.substring(with: match.range(at: 3))
        let box = match.range(at: 4).location == NSNotFound ? "" : "[ ] "
        textView.insertText("\n" + indent + marker + gap + box, replacementRange: selection)
        return true
    }

    // MARK: - Plumbing

    private static func replace(_ textView: NSTextView, _ range: NSRange, with string: String,
                                select: NSRange, action: String) {
        guard textView.isEditable else { return }
        // A shortcut is its own step: ⌘Z after ⌘B takes away the bold, not the
        // bold and the sentence typed before it.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.undoManager?.setActionName(action)
        textView.setSelectedRange(select)
        textView.scrollRangeToVisible(select)
    }
}
