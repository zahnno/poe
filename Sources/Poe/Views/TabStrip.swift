import SwiftUI

/// The notes this window has open, side by side.
///
/// Only drawn once there's a second tab — a window with one note open looks
/// exactly the way Poe always has. Click to switch, × to close, right-click
/// for the rest; ⌘1…⌘9 and ⇧⌘[ / ⇧⌘] get there without the mouse.
struct TabStrip: View {
    @EnvironmentObject var store: Workspace
    @Environment(\.openWindow) private var openWindow
    @State private var hovered: UUID?

    var body: some View {
        // Asked for once per pass: each one is a lookup in the library.
        let notes = store.tabNotes
        return HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(notes.enumerated()), id: \.element.id) { position, note in
                            tab(note, position: position)
                                .id(note.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                }
                .onChange(of: store.selection) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }

            Button { store.newTab() } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(IconButtonStyle())
            .help("New tab (⌘T)")
            .padding(.trailing, 12)
        }
        .background(Color.white.opacity(0.02))
    }

    private func tab(_ note: Note, position: Int) -> some View {
        let active = note.id == store.selection
        let hovering = hovered == note.id
        let broken = store.brokenLinks.contains(note.id)

        return HStack(spacing: 5) {
            Button { store.selectTab(note.id) } label: {
                HStack(spacing: 6) {
                    if note.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.accent)
                    } else if broken {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Theme.rose)
                    } else if note.file != nil {
                        Image(systemName: "doc.text")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(active ? Theme.accent : Theme.inkFaint)
                    }

                    Text(note.title)
                        .font(.system(size: 11.5, weight: active ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(active ? Theme.ink : Theme.inkDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { store.closeTab(note.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Color.white.opacity(hovering ? 0.08 : 0)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            // Reserve the space either way, so tabs don't shuffle under the pointer.
            .opacity(active || hovering ? 1 : 0)
            .help("Close tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .frame(minWidth: 84, maxWidth: 200)
        .fixedSize(horizontal: true, vertical: false)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Color.white.opacity(0.08) : Color.white.opacity(hovering ? 0.04 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Theme.accent.opacity(0.32) : Theme.panelStroke.opacity(hovering ? 1 : 0),
                              lineWidth: 1)
        )
        .overlay(alignment: .bottom) {
            if active {
                Capsule()
                    .fill(Theme.glow)
                    .frame(height: 2)
                    .padding(.horizontal, 12)
                    .shadow(color: Theme.accent.opacity(0.7), radius: 4)
                    .offset(y: 1)
            }
        }
        .onHover { inside in
            if inside { hovered = note.id } else if hovered == note.id { hovered = nil }
        }
        .help(help(for: note, position: position))
        .animation(.easeOut(duration: 0.14), value: active)
        .contextMenu {
            Button("Close Tab") { store.closeTab(note.id) }
            Button("Close Other Tabs") { store.closeOtherTabs(note.id) }
            Divider()
            Button("Move to New Window") {
                store.detachTab(note.id)
                openWindow(id: PoeWindow.id)
            }
            Divider()
            Button(note.pinned ? "Unpin" : "Pin") { store.togglePin(note.id) }
            if note.file != nil {
                Button("Reveal File in Finder") { store.library.revealInFinder(note.id) }
            }
        }
    }

    private func help(for note: Note, position: Int) -> String {
        let name = note.file?.path ?? note.title
        return position < 8 ? "\(name)  (⌘\(position + 1))" : name
    }
}
