import AppKit
import SwiftUI

struct EditorView: View {
    @EnvironmentObject var store: NoteStore

    private var note: Note? { store.selectedNote }
    private var linkBroken: Bool {
        guard let note else { return false }
        return store.brokenLinks.contains(note.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if store.findVisible {
                FindBar()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
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
                HStack(spacing: 7) {
                    Text(note?.title ?? "Poe")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)

                    if let note {
                        KindBadge(text: note.badge, linked: note.file != nil)
                    }
                }

                if let note {
                    Text(subtitle(for: note))
                        .font(.system(size: 10.5))
                        .foregroundStyle(linkBroken ? Theme.rose : Theme.inkFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(note.file?.path ?? "")
                }
            }
            .id(store.selection)
            .transition(.opacity)

            Spacer(minLength: 12)

            if let note {
                Button { store.togglePin(note.id) } label: {
                    Image(systemName: note.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(IconButtonStyle(active: note.pinned))
                .help(note.pinned ? "Unpin (⌘D)" : "Pin (⌘D)")
            }

            if note != nil {
                Button { store.toggleFind() } label: {
                    Image(systemName: "text.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle(active: store.findVisible))
                .help("Find in this note (⌘F)")
            }

            Button {
                withAnimation(.easeInOut(duration: 0.22)) { store.togglePreview() }
            } label: {
                Image(systemName: store.previewing ? "pencil" : "eye")
            }
            .buttonStyle(IconButtonStyle(active: store.previewing))
            .disabled(!store.canPreview)
            .opacity(store.canPreview ? 1 : 0.4)
            .help(previewHelp)

            Menu {
                Button("Open File…") { store.openFromPanel() }
                Divider()
                Button("Duplicate as Note") { store.duplicateSelected() }
                Button("Copy Text") { store.copySelectedToPasteboard() }
                Button("Save As…") { store.saveSelectedAs() }
                if note?.file != nil {
                    Divider()
                    Button("Reveal File in Finder") { store.revealSelectedInFinder() }
                    Button("Reload from Disk") { store.reloadSelectedFromDisk() }
                    Button("Stop Editing File") { store.unlinkSelected() }
                }
                Divider()
                Button("Reveal Library in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NoteStore.directory.path)
                }
                Divider()
                Button(note?.file == nil ? "Delete Note" : "Remove from Poe", role: .destructive) {
                    store.deleteSelected()
                }
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

    private func subtitle(for note: Note) -> String {
        if let file = note.file {
            if linkBroken { return "Missing — \(file.displayPath)" }
            return file.displayPath
        }
        return "Edited \(note.updated.poeRelative) ago".replacingOccurrences(of: "now ago", with: "just now")
    }

    private var previewHelp: String {
        guard store.canPreview else { return "Preview is for Markdown and plain text" }
        return store.previewing ? "Back to editing (⌘P)" : "Preview markdown (⌘P)"
    }

    // MARK: - Body

    /// The editor is never torn down — the preview and empty state layer over it.
    /// Swapping them as `if/else` branches would make SwiftUI rebuild the
    /// `NSTextView` on every toggle, losing undo history and the caret with it.
    private var content: some View {
        ZStack(alignment: .topLeading) {
            PoeTextView(
                text: store.currentText.wrappedValue,
                onEdit: { store.currentText.wrappedValue = $0 },
                documentID: store.selection,
                focusToken: store.editorFocusToken,
                active: !store.previewing && note != nil,
                kind: note?.kind ?? .markdown,
                find: PoeTextView.FindState(
                    active: store.findVisible && !store.previewing,
                    matches: store.findMatches,
                    current: store.findIndex,
                    revealToken: store.findRevealToken
                ),
                onEscape: { [store] in
                    guard store.findVisible else { return false }
                    store.hideFind()
                    return true
                }
            )
            .opacity(store.previewing ? 0 : 1)

            if !store.previewing, store.currentText.wrappedValue.isEmpty {
                Text(note?.file == nil ? "Start writing…" : "This file is empty — start writing…")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundStyle(Theme.inkFaint.opacity(0.6))
                    .padding(.leading, 35)
                    .padding(.top, 30)
                    .allowsHitTesting(false)
            }

            if store.previewing {
                MarkdownPreview(
                    text: store.currentText.wrappedValue,
                    find: MarkdownPreview.Find(
                        matches: store.findVisible ? store.findMatches : [],
                        current: store.findIndex,
                        revealToken: store.findRevealToken
                    )
                )
                .transition(.opacity)
            }

            if note == nil {
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
            HStack(spacing: 10) {
                Button("New note") { store.newNote() }
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(Theme.accent)
                Text("or")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.inkFaint)
                Button("Open a file…") { store.openFromPanel() }
                    .buttonStyle(PressableButtonStyle())
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let note, !note.isEmpty {
                if note.kind.rendersMarkdown {
                    stat("\(note.wordCount)", "words")
                } else {
                    stat("\(note.lineCount)", "lines")
                }
                dot
                stat("\(note.text.count)", "chars")
                if note.kind.rendersMarkdown, note.wordCount > 40 {
                    dot
                    stat("\(Int(ceil(Double(note.wordCount) / 220.0)))", "min read")
                }
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(linkBroken ? Theme.rose : Theme.accent)
                    .frame(width: 5, height: 5)
                    .shadow(color: linkBroken ? Theme.rose : Theme.accent, radius: 4)
                Text(saveLabel)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(linkBroken ? Theme.rose : Theme.inkFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var saveLabel: String {
        guard let file = note?.file else { return "Saved automatically" }
        if linkBroken { return "Can’t write to \(file.name)" }
        return "Saving to \(file.name)"
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

/// The little type chip — "MD", "SWIFT", "NOTE" — that says what you're editing.
struct KindBadge: View {
    var text: String
    var linked: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .kerning(0.6)
            .foregroundStyle(linked ? Theme.accent : Theme.inkFaint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(linked ? Theme.accent.opacity(0.14) : Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(linked ? Theme.accent.opacity(0.3) : Theme.panelStroke, lineWidth: 0.75)
            )
            .lineLimit(1)
            .fixedSize()
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
