import SwiftUI

/// Add / Edit a quick-message template. Title + multi-line content, Save gated on
/// both being non-empty. The caller supplies an async `onSave` (create or update)
/// and the sheet dismisses on success or surfaces the error inline.
struct QuickMessageEditorSheet: View {
    let editing: QuickMessage?
    let onSave: (_ title: String, _ content: String) async throws -> Void

    @State private var title: String
    @State private var content: String
    @State private var isSaving = false
    @State private var saveError: String?
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case title, content }

    init(editing: QuickMessage? = nil, onSave: @escaping (String, String) async throws -> Void) {
        self.editing = editing
        self.onSave = onSave
        _title = State(initialValue: editing?.title ?? "")
        _content = State(initialValue: editing?.content ?? "")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedContent: String { content.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedTitle.isEmpty && !trimmedContent.isEmpty && !isSaving }

    var body: some View {
        NavigationStack {
            ZStack {
                CodegBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        EditorSection(title: "Title") {
                            FieldRow(label: "Title") {
                                TextField("e.g. Run the tests", text: $title)
                                    .submitLabel(.next)
                                    .focused($focusedField, equals: .title)
                                    .onSubmit { focusedField = .content }
                            }
                        }
                        EditorSection(title: "Message", footer: "Inserted into the chat composer when you pick this template.") {
                            FieldRow(label: "Content") {
                                TextField("Message text", text: $content, axis: .vertical)
                                    .lineLimit(4...12)
                                    .focused($focusedField, equals: .content)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 28)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(editing == nil ? "New Quick Message" : "Edit Quick Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.tint(Theme.textSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .tint(Theme.accent)
                        .disabled(!canSave)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .alert("Couldn’t Save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let snapshotTitle = trimmedTitle
        let snapshotContent = trimmedContent
        Task {
            do {
                try await onSave(snapshotTitle, snapshotContent)
                dismiss()
            } catch {
                saveError = APIError.userMessage(error)
                isSaving = false
            }
        }
    }
}
