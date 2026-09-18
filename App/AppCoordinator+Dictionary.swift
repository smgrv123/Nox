import Foundation
import Personalization

/// Dictionary Settings mutations (P5b Phase 5). The store is the process-wide
/// `dictionaryStore` created in `setUpStorage`; the pane never constructs its own.
extension AppCoordinator {

    func reloadDictionaryEntries() {
        Task { [weak self] in
            await self?.publishDictionaryEntries()
        }
    }

    func addDictionaryTerm(correctTerm: String, mishearing: String) {
        Task { [weak self] in
            guard let self, let store = self.dictionaryStore else { return }
            try? await store.addExplicit(correctTerm: correctTerm, mishearing: mishearing)
            await self.publishDictionaryEntries()
        }
    }

    func removeDictionaryEntry(id: String) {
        Task { [weak self] in
            guard let self, let store = self.dictionaryStore else { return }
            try? await store.remove(id: id)
            await self.publishDictionaryEntries()
        }
    }

    func updateDictionaryEntry(_ entry: DictionaryEntry) {
        Task { [weak self] in
            guard let self, let store = self.dictionaryStore else { return }
            try? await store.upsert(entry)
            await self.publishDictionaryEntries()
        }
    }

    func resetDictionary() {
        Task { [weak self] in
            guard let self, let store = self.dictionaryStore else { return }
            try? await store.replaceAll([])
            await self.publishDictionaryEntries()
        }
    }

    private func publishDictionaryEntries() async {
        let entries = await dictionaryStore?.allEntries() ?? []
        await MainActor.run { dictionaryEntries = entries }
    }
}
