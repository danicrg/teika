import SwiftData
import SwiftUI

struct NoteDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ObsidianExporter.self) private var obsidian: ObsidianExporter?
    @FocusState private var isEditing: Bool
    @State private var didCopy = false
    @State private var isDeleting = false
    @State private var showsSaveError = false

    let note: Note

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.04, blue: 0.05)
                .ignoresSafeArea()
            if canEditNote {
                TextEditor(text: noteText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .focused($isEditing)
                    .accessibilityLabel("Note text")
                    .padding()
                    // Readable measure on iPad and in landscape.
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard canEditNote else { return }
                    UIPasteboard.general.string = note.text
                    didCopy = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopy = false }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .disabled(!canEditNote)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    guard canEditNote else { return }
                    isDeleting = true
                    isEditing = false
                    // Dismiss first: deleting while this view is still on screen leaves
                    // `body` re-evaluating against a destroyed model object.
                    dismiss()
                    context.delete(note)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!canEditNote)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if canEditNote, let obsidian, obsidian.isEnabled {
                VaultStatusBar(note: note, obsidian: obsidian)
            }
        }
        .onDisappear {
            saveChanges()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                saveChanges()
            }
        }
        .alert("Couldn’t save changes", isPresented: $showsSaveError) {
            Button("Retry") { saveChanges() }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your edits are still here, but couldn’t be saved. Try again.")
        }
    }

    private var canEditNote: Bool {
        !isDeleting && !note.isDeleted && note.modelContext != nil
    }

    /// Guard both sides of the binding: the editor can finish a pending input event
    /// while deletion is dismissing this view.
    private var noteText: Binding<String> {
        Binding(
            get: { canEditNote ? note.text : "" },
            set: { text in
                guard canEditNote, note.text != text else { return }
                note.text = text
                saveChanges()
            }
        )
    }

    private func saveChanges() {
        guard canEditNote, context.hasChanges else { return }
        do {
            try context.save()
            showsSaveError = false
        } catch {
            // Keep the model's unsaved text intact so a retry can persist it.
            showsSaveError = true
        }
    }
}

/// Where this note stands in the vault, and the button that saves it there. Nothing is
/// written until that button is tapped.
private struct VaultStatusBar: View {
    let note: Note
    let obsidian: ObsidianExporter

    var body: some View {
        HStack(spacing: 8) {
            switch note.vaultState {
            case .saved? where !note.hasUnsavedVaultChanges:
                Image(systemName: "checkmark.circle")
                Text(note.vaultPath.map { ($0 as NSString).lastPathComponent } ?? "Saved")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            case .saved?:
                Text("Changed since saved")
                Spacer(minLength: 0)
                saveButton("Save") { await obsidian.save(note) }
            case .editedElsewhere?:
                Image(systemName: "exclamationmark.circle")
                Text("Changed in Obsidian")
                Spacer(minLength: 0)
                saveButton("Save as new") { await obsidian.saveAsNewNote(note) }
            case .missing?:
                Image(systemName: "exclamationmark.circle")
                Text("Moved or deleted in Obsidian")
                Spacer(minLength: 0)
                saveButton("Save as new") { await obsidian.saveAsNewNote(note) }
            case nil:
                Text(note.isDraft == true ? "Draft" : "Not in Obsidian")
                Spacer(minLength: 0)
                saveButton("Save to Obsidian") {
                    let saved = await obsidian.save(note)
                    if saved {
                        note.isDraft = nil
                        try? note.modelContext?.save()
                    }
                    return saved
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveButton(_ title: String, action: @escaping () async -> Bool) -> some View {
        Button(title) { Task { _ = await action() } }
            .buttonStyle(.borderedProminent)
            .disabled(obsidian.isSaving || note.text.trimmed.isEmpty)
    }
}

#Preview {
    let store = try! NoteStore(inMemory: true)
    let note = try! store.add(text: "Hello from Parakeet.")
    NavigationStack {
        NoteDetailView(note: note)
    }
    .modelContainer(store.container)
}
