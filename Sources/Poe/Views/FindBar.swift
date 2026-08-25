import AppKit
import SwiftUI

/// Find inside the note you're reading — ⌘F.
///
/// The sidebar's field sifts the library; this one searches the one document
/// that's open, and says how many times the word turns up in it. It only ever
/// reads: nothing typed here can change a note, or the file behind it.
struct FindBar: View {
    @EnvironmentObject var store: NoteStore
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(focused ? Theme.accent : Theme.inkFaint)

            TextField("Find in this note", text: $store.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .onSubmit { store.findNext() }
                .onExitCommand { store.hideFind() }

            Text(tally)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(none ? Theme.rose : Theme.inkFaint)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()

            HStack(spacing: 4) {
                Button { store.findPrevious() } label: { Image(systemName: "chevron.up") }
                    .help("Previous match (⇧⌘G)")
                Button { store.findNext() } label: { Image(systemName: "chevron.down") }
                    .help("Next match (⌘G)")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(store.findCount == 0)
            .opacity(store.findCount == 0 ? 0.4 : 1)

            Button("Done") { store.hideFind() }
                .buttonStyle(PressableButtonStyle())
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .help("Close the find bar (esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.white.opacity(0.03))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
        .onChange(of: store.findFocusToken) { _ in
            focused = true
            selectAll()
        }
        .onChange(of: store.editorFocusToken) { _ in
            focused = false
        }
        .onAppear {
            focused = true
        }
    }

    private var none: Bool { store.findCount == 0 && !store.findQuery.isEmpty }

    private var tally: String {
        if store.findQuery.isEmpty { return "" }
        if store.findCount == 0 { return "No matches" }
        // Say when we stopped counting rather than pass a cap off as a total.
        return "\(store.findIndex) of \(store.findCount)\(store.findCapped ? "+" : "")"
    }

    /// ⌘F with the bar already open should offer the last search up for
    /// replacing, the way every other find bar on the Mac does.
    private func selectAll() {
        // The focus lands a turn later; the field editor isn't there until it has.
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSText)?.selectAll(nil)
        }
    }
}
