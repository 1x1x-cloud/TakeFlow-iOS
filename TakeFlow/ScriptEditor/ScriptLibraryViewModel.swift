import Foundation

@MainActor
final class ScriptLibraryViewModel: ObservableObject {
    @Published private(set) var scripts: [Script] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleteConfirmationPresented = false
    @Published private(set) var pendingDeletion: ScriptDeletion?
    @Published private(set) var errorMessage: String?
    @Published var searchText = "" {
        didSet {
            scheduleSearch()
        }
    }

    private let service: any ScriptLibraryServicing
    private var requestedDeletionID: UUID?
    private var searchTask: Task<Void, Never>?
    private var finalizeDeletionTask: Task<Void, Never>?

    init(service: any ScriptLibraryServicing) {
        self.service = service
    }

    var hasSearchQuery: Bool {
        !searchText.isEmpty
    }

    func load() async {
        isLoading = true
        await reload()
        isLoading = false
    }

    func createBlankScript() async -> UUID? {
        do {
            let script = try await service.createBlankScript()
            await reload()
            return script.id
        } catch {
            show(error)
            return nil
        }
    }

    func duplicate(_ script: Script) async {
        do {
            _ = try await service.duplicate(id: script.id)
            await reload()
        } catch {
            show(error)
        }
    }

    func requestDelete(_ script: Script) {
        requestedDeletionID = script.id
        isDeleteConfirmationPresented = true
    }

    func cancelDelete() {
        requestedDeletionID = nil
        isDeleteConfirmationPresented = false
    }

    func dismissDeleteConfirmation() {
        isDeleteConfirmationPresented = false
    }

    func confirmDelete() async {
        guard let scriptID = requestedDeletionID else {
            return
        }
        requestedDeletionID = nil
        isDeleteConfirmationPresented = false

        do {
            let deletion = try await service.delete(id: scriptID)
            pendingDeletion = deletion
            await reload()
            scheduleFinalDeletion(deletion)
        } catch {
            show(error)
        }
    }

    func undoDelete() async {
        guard let deletion = pendingDeletion else {
            return
        }
        finalizeDeletionTask?.cancel()
        finalizeDeletionTask = nil

        do {
            try await service.undo(deletion)
            pendingDeletion = nil
            await reload()
        } catch {
            pendingDeletion = nil
            show(error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.reload()
        }
    }

    private func reload() async {
        do {
            scripts = try await service.scripts(matching: searchText)
        } catch {
            show(error)
        }
    }

    private func scheduleFinalDeletion(_ deletion: ScriptDeletion) {
        finalizeDeletionTask?.cancel()
        let delay = max(0, deletion.expiresAt.timeIntervalSinceNow)

        finalizeDeletionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard !Task.isCancelled, let self else {
                return
            }

            do {
                try await service.finalize(deletion)
                if pendingDeletion?.script.id == deletion.script.id {
                    pendingDeletion = nil
                }
            } catch {
                show(error)
            }
        }
    }

    private func show(_ error: Error) {
        let appError = error as? AppError ?? .persistenceUnavailable
        errorMessage = appError.errorDescription
    }
}
