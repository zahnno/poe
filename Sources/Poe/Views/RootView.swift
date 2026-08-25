import SwiftUI

struct RootView: View {
    @EnvironmentObject var store: NoteStore

    var body: some View {
        ZStack {
            AuroraBackground()

            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                EditorView()
                    .frame(maxWidth: .infinity)
            }
            .background(.ultraThinMaterial.opacity(0.35))
        }
        .frame(minWidth: 720, minHeight: 480)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .alert(
            "Delete “\(store.pendingDelete?.title ?? "")”?",
            isPresented: Binding(
                get: { store.pendingDelete != nil },
                set: { if !$0 { store.pendingDelete = nil } }
            )
        ) {
            Button("Delete", role: .destructive) { store.confirmPendingDelete() }
            Button("Cancel", role: .cancel) { store.pendingDelete = nil }
        } message: {
            Text("This note has \(store.pendingDelete?.wordCount ?? 0) words. Deleting it cannot be undone.")
        }
        .onAppear {
            // Start in the note itself — the search field can wait for Cmd F.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { store.focusEditor() }
        }
        .onDisappear { store.saveNow() }
    }
}
