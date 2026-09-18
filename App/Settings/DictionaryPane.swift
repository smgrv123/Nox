import Personalization
import SwiftUI

/// `id` already satisfies `Identifiable` — retroactive conformance so the edit
/// sheet can use `.sheet(item:)`. `DictionaryEntry` itself stays untouched.
extension DictionaryEntry: Identifiable {}

/// Dictionary Settings (P5b Phase 5): list, add, edit, delete, and reset. Mutations
/// go through `AppCoordinator` → `DictionaryStore`. Reset is pane-local — never
/// `HistoryWipe`.
struct DictionaryPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingAdd = false
    @State private var confirmReset = false
    @State private var draftCorrect = ""
    @State private var draftMishearing = ""
    @State private var editingEntry: DictionaryEntry?
    @State private var draftEditCorrect = ""
    @State private var draftEditMishearings = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictionary")
                .font(.headline)
            Text("Teach Aide names and jargon Whisper mishears. Corrections also feed dictation cleanup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List(coordinator.dictionaryEntries, id: \.id) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.correctTerm)
                        if !entry.mishearings.isEmpty {
                            Text(entry.mishearings.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        beginEditing(entry)
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Edit \(entry.correctTerm)")
                    Button(role: .destructive) {
                        coordinator.removeDictionaryEntry(id: entry.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete \(entry.correctTerm)")
                }
            }

            HStack {
                Button("Add…") { showingAdd = true }
                Spacer()
                Button("Reset dictionary…", role: .destructive) { confirmReset = true }
            }
        }
        .padding()
        .onAppear { coordinator.reloadDictionaryEntries() }
        .sheet(isPresented: $showingAdd) {
            addSheet
        }
        .sheet(item: $editingEntry) { entry in
            editSheet(for: entry)
        }
        .confirmationDialog("Reset dictionary?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Dictionary", role: .destructive) {
                coordinator.resetDictionary()
            }
        } message: {
            Text("This permanently deletes every saved correction. It does not wipe dictation history.")
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add correction")
                .font(.headline)
            TextField("Correct term", text: $draftCorrect)
            TextField("Mishearing (optional)", text: $draftMishearing)
            HStack {
                Spacer()
                Button("Cancel") { showingAdd = false }
                Button("Add") {
                    coordinator.addDictionaryTerm(
                        correctTerm: draftCorrect, mishearing: draftMishearing)
                    draftCorrect = ""
                    draftMishearing = ""
                    showingAdd = false
                }
                .disabled(draftCorrect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }

    private func beginEditing(_ entry: DictionaryEntry) {
        draftEditCorrect = entry.correctTerm
        draftEditMishearings = entry.mishearings.joined(separator: ", ")
        editingEntry = entry
    }

    private func editSheet(for entry: DictionaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit correction")
                .font(.headline)
            TextField("Correct term", text: $draftEditCorrect)
            TextField("Mishearings (comma-separated)", text: $draftEditMishearings)
            HStack {
                Spacer()
                Button("Cancel") { editingEntry = nil }
                Button("Save") {
                    var updated = entry
                    updated.correctTerm = draftEditCorrect.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.mishearings =
                        draftEditMishearings
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    coordinator.updateDictionaryEntry(updated)
                    editingEntry = nil
                }
                .disabled(draftEditCorrect.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
