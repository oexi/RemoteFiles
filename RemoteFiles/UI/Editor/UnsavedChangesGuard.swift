import SwiftUI

/// Replaces the navigation back button while an editor has unsaved changes so
/// leaving asks to save or discard instead of silently dropping the edits.
struct UnsavedChangesGuard: ViewModifier {
    let isDirty: Bool
    let save: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isDirty)
            .toolbar {
                if isDirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            confirming = true
                        } label: {
                            Label("Back", systemImage: "chevron.backward")
                        }
                    }
                }
            }
            .confirmationDialog("Unsaved Changes", isPresented: $confirming, titleVisibility: .visible) {
                Button("Save") {
                    Task {
                        if await save() { dismiss() }
                    }
                }
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { }
            } message: {
                Text("This file has changes that have not been saved.")
            }
    }
}

extension View {
    func unsavedChangesGuard(isDirty: Bool, save: @escaping () async -> Bool) -> some View {
        modifier(UnsavedChangesGuard(isDirty: isDirty, save: save))
    }
}
