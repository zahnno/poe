import AppKit
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: NoteStore
    @ObservedObject private var themeManager = ThemeManager.shared
    @FocusState private var searchFocused: Bool
    @Namespace private var highlight
    /// The row under the pointer — the only thing that shows an untouched note's
    /// tick box, so the list stays quiet until you reach for it.
    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Room for the traffic lights, since the title bar is hidden.
            Color.clear.frame(height: 30)

            wordmark
            searchField
            list
            if !store.marked.isEmpty { selectionBar }
            newNoteButton
        }
        .frame(width: 268)
        .background(alignment: .trailing) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
        }
        .onChange(of: store.searchFocusToken) { _ in
            searchFocused = true
        }
        .onChange(of: store.editorFocusToken) { _ in
            // The caret moved to the note; stop drawing a focus ring here.
            searchFocused = false
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.85), value: store.marked.isEmpty)
    }

    // MARK: - Header

    private var wordmark: some View {
        HStack(spacing: 9) {
            LanternMark(height: 26)

            Text("poe")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.glow)
                .kerning(1.5)

            Spacer()

            Menu {
                Section("Active: \(themeManager.currentTheme.name)") {
                    Button("Next Theme") { themeManager.nextTheme() }
                        .keyboardShortcut("]", modifiers: [.command, .option])
                    Button("Previous Theme") { themeManager.previousTheme() }
                        .keyboardShortcut("[", modifiers: [.command, .option])
                    Button("Random Theme") { themeManager.randomTheme() }
                }

                Divider()

                Toggle("Show Gradients", isOn: Binding(
                    get: { themeManager.gradientsEnabled },
                    set: { themeManager.gradientsEnabled = $0 }
                ))

                Divider()

                ForEach(ThemeCategory.allCases) { category in
                    Menu(category.rawValue) {
                        ForEach(Theme.themes(in: category)) { theme in
                            Button {
                                themeManager.setTheme(theme.id)
                            } label: {
                                if theme.id == themeManager.currentTheme.id {
                                    Text("✓ \(theme.name)")
                                } else {
                                    Text(theme.name)
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.inkFaint)
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Themes (⌥⌘[ / ⌥⌘])")

            Button { store.toggleMarkAll() } label: {
                Text(store.marked.isEmpty ? "\(store.notes.count)" : "\(store.marked.count)/\(store.notes.count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(store.marked.isEmpty ? Theme.inkFaint : Theme.accent)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(store.marked.isEmpty
                                       ? Color.white.opacity(0.06)
                                       : Theme.accent.opacity(0.16))
                    )
            }
            .buttonStyle(.plain)
            .help("Select every note in the list (⇧⌘A)")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(searchFocused ? Theme.accent : Theme.inkFaint)

            TextField("Search", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(Theme.ink)
                .focused($searchFocused)
                .onSubmit { store.focusEditor() }

            if !store.query.isEmpty {
                Button {
                    store.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.inkFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(searchFocused ? Theme.accent.opacity(0.55) : Theme.panelStroke, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.18), value: searchFocused)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var list: some View {
        // Asked for once, not once per mention: this sorts the library and
        // reads every note to sift it.
        let visible = store.visible
        return ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(visible) { note in
                    row(note)
                }

                if visible.isEmpty {
                    Text("Nothing matches “\(store.query)”")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Theme.inkFaint)
                        .multilineTextAlignment(.center)
                        .padding(.top, 40)
                        .padding(.horizontal, 20)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
    }

    private func row(_ note: Note) -> some View {
        let selected = note.id == store.selection
        let ticked = store.marked.contains(note.id)
        // The box is only drawn once you're either sweeping already or pointing
        // at the row — an idle list shows notes, not checkboxes.
        let showTick = ticked || !store.marked.isEmpty || hovered == note.id

        return Button {
            // A click means one of three things, and the modifier keys are what
            // say which: plain opens the note, ⌘ ticks it, ⇧ takes the run from
            // wherever the last click landed. Reading the flags here rather than
            // through gesture modifiers keeps one hit target on the row.
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                store.extendMark(to: note.id)
            } else if flags.contains(.command) {
                store.toggleMark(note.id)
            } else {
                // Whether you were reading or writing carries across the switch;
                // a document with no markdown in it drops the preview by itself.
                store.choose(note.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                marker(note, ticked: ticked, showTick: showTick)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(note.title)
                            .font(.system(size: 13, weight: selected ? .semibold : .medium, design: .rounded))
                            .foregroundStyle(selected ? Theme.ink : Theme.ink.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        if note.file != nil {
                            KindBadge(text: note.badge, linked: true)
                        }
                    }

                    Text(note.snippet)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.inkFaint)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(note.updated.poeRelative)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.inkFaint.opacity(0.8))
                    .monospacedDigit()
                    .padding(.top, 1)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
                        )
                        .matchedGeometryEffect(id: "row", in: highlight)
                } else if ticked {
                    // A ticked row that isn't the one being edited: tinted, but
                    // without the rail or the ring that mean "you are here".
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Theme.accent.opacity(0.11))
                }
            }
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Theme.glow)
                        .frame(width: 2.5, height: 20)
                        .shadow(color: Theme.accent.opacity(0.8), radius: 5)
                        .padding(.leading, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hovered = note.id }
            else if hovered == note.id { hovered = nil }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.selection)
        .animation(.easeOut(duration: 0.14), value: ticked)
        .contextMenu { menu(for: note) }
    }

    /// The row's leading column: its tick box while you're choosing, and
    /// otherwise whatever the note has to say for itself.
    private func marker(_ note: Note, ticked: Bool, showTick: Bool) -> some View {
        Group {
            if showTick {
                Image(systemName: ticked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(ticked ? Theme.accent : Theme.inkFaint.opacity(0.65))
                    .padding(.top, 1)
            } else if note.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.accent)
                    .padding(.top, 3)
            } else if store.brokenLinks.contains(note.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.rose)
                    .padding(.top, 3)
                    .help("The file behind this note is missing")
            }
        }
        // A fixed column while there is anything to put in it, and none at all
        // when there isn't — so titles don't sit indented over empty space.
        .frame(width: showTick ? 13 : (note.pinned || store.brokenLinks.contains(note.id) ? 11 : 0))
    }

    // MARK: - Row menu

    @ViewBuilder
    private func menu(for note: Note) -> some View {
        // Right-clicking inside the sweep acts on the whole sweep; right-clicking
        // outside it acts on the one row, and leaves the sweep alone.
        let targets = store.contextTargets(for: note)
        let many = targets.count > 1
        let linked = targets.filter { $0.file != nil }

        if many {
            Section("\(targets.count) notes selected") {
                Button(targets.allSatisfy(\.pinned) ? "Unpin All" : "Pin All") { store.togglePin(targets) }
                Button("Duplicate All") { store.duplicate(targets) }
                Button("Copy Text") { store.copy(targets) }
                Button("Export to Folder…") { store.export(targets) }
            }
            if !linked.isEmpty {
                Divider()
                Button(linked.count == targets.count ? "Stop Editing Files" : "Stop Editing \(linked.count) Files") {
                    store.unlink(linked)
                }
            }
            Divider()
            Button("Deselect") { store.clearMarks() }
            Divider()
            Button(linked.count == targets.count ? "Remove \(targets.count) from Poe" : "Delete \(targets.count) Notes",
                   role: .destructive) {
                store.requestDelete(targets)
            }
        } else {
            Button(note.pinned ? "Unpin" : "Pin") { store.togglePin([note]) }
            Button("Duplicate as Note") { store.duplicate([note]) }
            Button("Copy Text") { store.copy([note]) }
            Button("Save As…") {
                store.choose(note.id)
                store.saveSelectedAs()
            }
            Button("Export to Folder…") { store.export([note]) }
            if note.file != nil {
                Divider()
                Button("Reveal File in Finder") {
                    store.choose(note.id)
                    store.revealSelectedInFinder()
                }
                Button("Reload from Disk") {
                    store.choose(note.id)
                    store.reloadSelectedFromDisk()
                }
                Button("Stop Editing File") { store.unlink([note]) }
            }
            Divider()
            Button("Select This Note") { store.toggleMark(note.id) }
            Divider()
            Button(note.file == nil ? "Delete" : "Remove from Poe", role: .destructive) {
                store.requestDelete(note)
            }
        }
    }

    // MARK: - Bulk actions

    /// The bar that appears under the list once anything is ticked. Everything
    /// it offers is also in the row menu; this is the version you can reach
    /// without aiming at a particular row.
    private var selectionBar: some View {
        let targets = store.markedNotes
        let allPinned = !targets.isEmpty && targets.allSatisfy(\.pinned)

        return VStack(spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)

                Text(targets.count == 1 ? "1 note selected" : "\(targets.count) notes selected")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .monospacedDigit()

                Spacer(minLength: 4)

                if targets.count < store.visible.count {
                    Button("All") { store.markAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.accent)
                }

                Button("Done") { store.clearMarks() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.inkDim)
            }

            HStack(spacing: 5) {
                bulkAction(allPinned ? "pin.slash" : "pin", allPinned ? "Unpin these" : "Pin these") {
                    store.togglePin(targets)
                }
                bulkAction("plus.square.on.square", "Duplicate these") { store.duplicate(targets) }
                bulkAction("doc.on.doc", "Copy their text") { store.copy(targets) }
                bulkAction("square.and.arrow.down", "Export to a folder…") { store.export(targets) }
                bulkAction("trash", "Delete these", destructive: true) { store.requestDelete(targets) }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func bulkAction(_ symbol: String, _ help: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(destructive ? Theme.rose : Theme.inkDim)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(PressableButtonStyle())
        .help(help)
    }

    // MARK: - Footer

    private var newNoteButton: some View {
        HStack(spacing: 8) {
            Button { store.newNote() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                    Text("New note")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("⌘N")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.void.opacity(0.55))
                }
                .foregroundStyle(Theme.void)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.glow)
                )
                .shadow(color: Theme.accent.opacity(0.28), radius: 12, y: 4)
            }
            .buttonStyle(PressableButtonStyle())

            Button { store.openFromPanel() } label: {
                Image(systemName: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.inkDim)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.panelStroke, lineWidth: 1)
                    )
            }
            .buttonStyle(PressableButtonStyle())
            .help("Open a file (⌘O)")
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

/// A button that dips slightly when pressed — the only motion feedback in the app.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
