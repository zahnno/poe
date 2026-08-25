import AppKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.hairline)
            content
            Divider().overlay(Theme.hairline)
            statusBar
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
                    store.sidebarVisible.toggle()
                }
            } label: {
                Image(systemName: store.sidebarVisible ? "sidebar.left" : "sidebar.leading")
            }
            .buttonStyle(IconButtonStyle())
            .help("Toggle sidebar (⌘0)")

            VStack(alignment: .leading, spacing: 1) {
                Text(store.selectedNote?.title ?? "Poe")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                if let note = store.selectedNote {
                    Text("Edited \(note.updated.poeRelative) ago".replacingOccurrences(of: "now ago", with: "just now"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkFaint)
                }
            }
            .id(store.selection)
            .transition(.opacity)

            Spacer(minLength: 12)

            if let note = store.selectedNote {
                Button { store.togglePin(note.id) } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(active: note.pinned))
                .help(note.pinned ? "Unpin (⌘D)" : "Pin (⌘D)")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { store.previewing.toggle() }
            } label: {
                Image(systemName: store.previewing ? "pencil" : "eye")
            }
            .buttonStyle(IconButtonStyle(active: store.previewing))
            .help(store.previewing ? "Back to editing (⌘P)" : "Preview markdown (⌘P)")

            Menu {
                Button("Duplicate") { store.duplicateSelected() }
                Button("Copy Text") { store.copySelectedToPasteboard() }
                Button("Export as Markdown…") { store.exportSelected() }
                Divider()
                Button("Reveal Library in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NoteStore.directory.path)
                }
                Divider()
                Button("Delete Note", role: .destructive) { store.deleteSelected() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
            .buttonStyle(IconButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.top, store.sidebarVisible ? 8 : 30)
        .padding(.bottom, 8)
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: store.sidebarVisible)
    }

    // MARK: - Body

    /// The editor is never torn down — the preview and empty state layer over it.
    /// Swapping them as `if/else` branches would make SwiftUI rebuild the
    /// `NSTextView` on every toggle, losing undo history and the caret with it.
    private var content: some View {
        ZStack(alignment: .topLeading) {
            PoeTextView(
                text: store.currentText,
                focusToken: store.editorFocusToken,
                active: !store.previewing && store.selectedNote != nil
            )
            .opacity(store.previewing ? 0 : 1)

            if !store.previewing, store.currentText.wrappedValue.isEmpty {
                Text("Start writing…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.inkFaint.opacity(0.6))
                    .padding(.leading, 35)
                    .padding(.top, 30)
                    .allowsHitTesting(false)
            }

            if store.previewing {
                MarkdownPreview(text: store.currentText.wrappedValue)
                    .transition(.opacity)
            }

            if store.selectedNote == nil {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.void.opacity(0.6))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            LanternMark(height: 46)
            Text("Nothing selected")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.inkDim)
            Button("New note") { store.newNote() }
                .buttonStyle(PressableButtonStyle())
                .foregroundStyle(Theme.accent)
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let note = store.selectedNote, !note.isEmpty {
                stat("\(note.wordCount)", "words")
                dot
                stat("\(note.text.count)", "chars")
                if note.wordCount > 40 {
                    dot
                    stat("\(Int(ceil(Double(note.wordCount) / 220.0)))", "min read")
                }
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: Theme.accent, radius: 4)
                Text("Saved automatically")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.inkDim)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(Theme.inkFaint)
        }
    }

    private var dot: some View {
        Circle()
            .fill(Theme.inkFaint.opacity(0.4))
            .frame(width: 2.5, height: 2.5)
    }
}

/// Small square glyph buttons in the toolbar: dim by default, accent when active.
struct IconButtonStyle: ButtonStyle {
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(active ? Theme.accent : Theme.inkDim)
            .frame(width: 26, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.14) : Color.white.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(active ? Theme.accent.opacity(0.35) : Theme.panelStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.14), value: active)
    }
}
