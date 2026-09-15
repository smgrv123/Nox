import Personalization
import SwiftUI

/// Dictionary Settings (P5b Phase 5): list, add, delete, and reset. Mutations go
/// through `AppCoordinator` → `DictionaryStore`. Reset is pane-local — never
/// `HistoryWipe`.
struct DictionaryPane: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var showingAdd = false
    @State private var confirmReset = false
    @State private var draftCorrect = ""
    @State private var draftMishearing = ""

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
}
