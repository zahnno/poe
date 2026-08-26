import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var store: NoteStore
    @FocusState private var searchFocused: Bool
    @Namespace private var highlight

    var body: some View {
        VStack(spacing: 0) {
            // Room for the traffic lights, since the title bar is hidden.
            Color.clear.frame(height: 30)

            wordmark
            searchField
            list
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

            Text("\(store.notes.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.inkFaint)
                .monospacedDigit()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
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

        return Button {
            // Whether you were reading or writing carries across the switch;
            // a document with no markdown in it drops the preview by itself.
            store.selection = note.id
        } label: {
            HStack(alignment: .top, spacing: 9) {
                if note.pinned {
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
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: store.selection)
        .contextMenu {
            Button(note.pinned ? "Unpin" : "Pin") { store.togglePin(note.id) }
            Button("Duplicate as Note") {
                store.selection = note.id
                store.duplicateSelected()
            }
            Button("Copy Text") {
                store.selection = note.id
                store.copySelectedToPasteboard()
            }
            Button("Save As…") {
                store.selection = note.id
                store.saveSelectedAs()
            }
            if note.file != nil {
                Divider()
                Button("Reveal File in Finder") {
                    store.selection = note.id
                    store.revealSelectedInFinder()
                }
                Button("Reload from Disk") {
                    store.selection = note.id
                    store.reloadSelectedFromDisk()
                }
                Button("Stop Editing File") {
                    store.selection = note.id
                    store.unlinkSelected()
                }
            }
            Divider()
            Button(note.file == nil ? "Delete" : "Remove from Poe", role: .destructive) {
                store.requestDelete(note)
            }
        }
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
