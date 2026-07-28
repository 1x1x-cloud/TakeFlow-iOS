import Foundation

@MainActor
final class ScriptEditorViewModel: ObservableObject {
    enum SaveState: Equatable {
        case idle
        case pending
        case saving
        case saved
        case failed
    }

    @Published private(set) var isLoading = true
    @Published private(set) var title = ""
    @Published private(set) var content = ""
    @Published private(set) var speechRateCharactersPerMinute =
        ScriptMetrics.defaultSpeechRate
    @Published private(set) var lastReadPosition = 0
    @Published private(set) var saveState: SaveState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingRecoveryDraft: ScriptRecoveryDraft?

    private let scriptID: UUID
    private let service: any ScriptLibraryServicing
    private let debounceDuration: Duration
    private let sessionID: UUID
    private let now: @Sendable () -> Date
    private var script: Script?
    private var saveTask: Task<Void, Never>?
    private var recoveryWriteTask:
        Task<Result<Void, AppError>, Never>?
    private var latestRecoveryVersion: ScriptRecoveryDraftWriteVersion?
    private var revision: UInt64 = 0
    private var hasLoaded = false

    init(
        scriptID: UUID,
        service: any ScriptLibraryServicing,
        debounceDuration: Duration = .milliseconds(600),
        sessionID: UUID = UUID(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.scriptID = scriptID
        self.service = service
        self.debounceDuration = debounceDuration
        self.sessionID = sessionID
        self.now = now
    }

    var characterCount: Int {
        ScriptMetrics.characterCount(in: content)
    }

    var estimatedDuration: TimeInterval {
        ScriptMetrics.estimatedDuration(
            for: content,
            charactersPerMinute: speechRateCharactersPerMinute
        )
    }

    var visibleTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ScriptEditorStrings.unnamedScript : trimmed
    }

    var saveStateText: String {
        switch saveState {
        case .idle:
            return ""
        case .pending:
            return ScriptEditorStrings.pendingSave
        case .saving:
            return ScriptEditorStrings.saving
        case .saved:
            return ScriptEditorStrings.saved
        case .failed:
            return ScriptEditorStrings.saveFailed
        }
    }

    func load() async {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        isLoading = true

        do {
            let loaded = try await service.script(id: scriptID)
            script = loaded
            title = loaded.title
            content = loaded.content
            speechRateCharactersPerMinute =
                loaded.speechRateCharactersPerMinute
            lastReadPosition = loaded.lastReadPosition
            saveState = .saved
            do {
                pendingRecoveryDraft = try await service.recoveryDraft(
                    newerThan: loaded
                )
            } catch {
                show(error)
            }
        } catch {
            show(error)
        }

        isLoading = false
    }

    func setTitle(_ value: String) {
        guard title != value else {
            return
        }
        title = value
        scheduleAutosave()
    }

    func setContent(_ value: String) {
        guard content != value else {
            return
        }
        content = value
        lastReadPosition = ScriptMetrics.clampedReadPosition(
            lastReadPosition,
            content: value
        )
        scheduleAutosave()
    }

    func setSpeechRate(_ value: Double) {
        let clamped = ScriptMetrics.clampedSpeechRate(value)
        guard speechRateCharactersPerMinute != clamped else {
            return
        }
        speechRateCharactersPerMinute = clamped
        scheduleAutosave()
    }

    func setLastReadPosition(_ value: Int) {
        let clamped = ScriptMetrics.clampedReadPosition(value, content: content)
        guard lastReadPosition != clamped else {
            return
        }
        lastReadPosition = clamped
        scheduleAutosave()
    }

    func flushPendingSave() async {
        guard script != nil, saveState == .pending || saveState == .failed else {
            return
        }
        saveTask?.cancel()
        saveTask = nil
        await persist(revision: revision)
    }

    func recoverPendingDraft() {
        guard let recoveryDraft = pendingRecoveryDraft else {
            return
        }
        pendingRecoveryDraft = nil
        title = recoveryDraft.title
        content = recoveryDraft.content
        speechRateCharactersPerMinute = ScriptMetrics.clampedSpeechRate(
            recoveryDraft.speechRateCharactersPerMinute
        )
        lastReadPosition = ScriptMetrics.clampedReadPosition(
            recoveryDraft.lastReadPosition,
            content: recoveryDraft.content
        )
        scheduleAutosave()
    }

    func keepSavedVersion() async {
        guard let recoveryDraft = pendingRecoveryDraft else {
            return
        }
        pendingRecoveryDraft = nil
        do {
            try await service.clearRecoveryDraft(
                for: scriptID,
                committedThrough: recoveryDraft.writeVersion
            )
        } catch {
            show(error)
        }
    }

    func dismissError() {
        errorMessage = nil
    }

    private func scheduleAutosave() {
        guard script != nil else {
            return
        }

        revision += 1
        let scheduledRevision = revision
        saveState = .pending
        scheduleRecoveryDraftWrite(revision: scheduledRevision)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }
            await persist(revision: scheduledRevision)
        }
    }

    private func scheduleRecoveryDraftWrite(revision: UInt64) {
        guard let script else {
            return
        }

        let draftTimestamp = max(
            now(),
            script.updatedAt.addingTimeInterval(0.001)
        )
        let recoveryDraft = ScriptRecoveryDraft(
            scriptID: scriptID,
            title: title,
            content: content,
            lastReadPosition: lastReadPosition,
            speechRateCharactersPerMinute:
                speechRateCharactersPerMinute,
            draftUpdatedAt: draftTimestamp,
            baseScriptUpdatedAt: script.updatedAt,
            sessionID: sessionID,
            revision: revision
        )
        latestRecoveryVersion = recoveryDraft.writeVersion

        let service = service
        let task = Task<Result<Void, AppError>, Never> {
            do {
                try await service.writeRecoveryDraft(recoveryDraft)
                return .success(())
            } catch let appError as AppError {
                return .failure(appError)
            } catch {
                return .failure(.recoveryDraftUnavailable)
            }
        }
        recoveryWriteTask = task

        Task { [weak self] in
            let result = await task.value
            guard
                let self,
                self.latestRecoveryVersion == recoveryDraft.writeVersion
            else {
                return
            }
            if case .failure(let error) = result {
                self.show(error)
            }
        }
    }

    private func persist(revision savedRevision: UInt64) async {
        let recoveryResult = await recoveryWriteTask?.value
        if let recoveryResult, case .failure(let error) = recoveryResult {
            show(error)
        }

        guard savedRevision == revision, var draft = script else {
            return
        }

        draft.title = title
        draft.content = content
        draft.speechRateCharactersPerMinute =
            speechRateCharactersPerMinute
        draft.lastReadPosition = lastReadPosition
        saveState = .saving

        do {
            let saved = try await service.update(draft)
            guard savedRevision == revision else {
                return
            }
            script = saved
            saveState = .saved
            if let latestRecoveryVersion {
                do {
                    try await service.clearRecoveryDraft(
                        for: scriptID,
                        committedThrough: latestRecoveryVersion
                    )
                    if savedRevision == revision {
                        self.latestRecoveryVersion = nil
                        recoveryWriteTask = nil
                    }
                } catch {
                    show(error)
                }
            }
        } catch {
            guard savedRevision == revision else {
                return
            }
            saveState = .failed
            show(error)
        }
    }

    private func show(_ error: Error) {
        let appError = error as? AppError ?? .persistenceUnavailable
        errorMessage = appError.errorDescription
    }
}
