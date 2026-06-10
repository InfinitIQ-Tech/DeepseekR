//
//  ExpertManagementView.swift
//  DeepseekR
//
//  Created on 6/09/26.
//

import SwiftUI

/// CRUD interface for the expert pool the Reasoner Core routes to.
struct ExpertManagementView: View {
    @ObservedObject var store: ExpertStore
    @Environment(\.dismiss) private var dismiss

    @State private var editingExpert: Expert?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Expert Pool")
                    .font(.title2)
                    .bold()
                Spacer()
                Button("Restore Defaults") {
                    store.restoreDefaults()
                }
                Button {
                    editingExpert = Expert(name: "", specialty: "", systemPrompt: "")
                } label: {
                    Label("Add Expert", systemImage: "plus")
                }
            }
            .padding()

            Divider()

            if store.experts.isEmpty {
                Spacer()
                Text("No experts configured. The Reasoner will assemble experts dynamically for each question.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List {
                    ForEach(store.experts) { expert in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(expert.name)
                                    .font(.headline)
                                Spacer()
                                Button("Edit") {
                                    editingExpert = expert
                                }
                                Button(role: .destructive) {
                                    store.remove(expert)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                            Text(expert.specialty)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, minHeight: 380)
        .sheet(item: $editingExpert) { expert in
            ExpertEditorView(expert: expert) { edited in
                store.upsert(edited)
            }
        }
    }
}

/// Form for creating or editing a single expert.
struct ExpertEditorView: View {
    @State var expert: Expert
    let onSave: (Expert) -> Void
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        !expert.name.trimmingCharacters(in: .whitespaces).isEmpty
            && !expert.specialty.trimmingCharacters(in: .whitespaces).isEmpty
            && !expert.systemPrompt.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configure Expert")
                .font(.title3)
                .bold()

            TextField("Name (e.g. Swift Engineer)", text: $expert.name)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            TextField("Specialty — one line the Reasoner uses for routing", text: $expert.specialty)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            Text("System prompt")
                .font(.subheadline)
                .foregroundColor(.secondary)
            TextEditor(text: $expert.systemPrompt)
                .font(.body)
                .frame(minHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4))
                )

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(expert)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding()
        .frame(minWidth: 440, minHeight: 320)
    }
}

#Preview {
    ExpertManagementView(store: ExpertStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent("preview-experts.json")))
}
