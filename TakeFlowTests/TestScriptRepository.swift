import Foundation
@testable import TakeFlow

enum TestRepositoryError: Error {
    case forcedFailure
}

actor TestScriptRepository: ScriptRepository {
    private struct Entry {
        var script: Script
        var deletedAt: Date?
    }

    private var storage: [UUID: Entry] = [:]
    private var shouldFail = false
    private(set) var saveCallCount = 0
    private(set) var permanentDeleteCallCount = 0

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func resetCounters() {
        saveCallCount = 0
        permanentDeleteCallCount = 0
    }

    func scripts() throws -> [Script] {
        try checkFailure()
        return storage.values
            .filter { $0.deletedAt == nil }
            .map(\.script)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func script(id: UUID) throws -> Script? {
        try checkFailure()
        guard let entry = storage[id], entry.deletedAt == nil else {
            return nil
        }
        return entry.script
    }

    func save(_ script: Script) throws {
        try checkFailure()
        saveCallCount += 1
        storage[script.id] = Entry(script: script, deletedAt: nil)
    }

    func delete(id: UUID, at deletionDate: Date) throws {
        try checkFailure()
        guard storage[id] != nil else {
            throw AppError.scriptNotFound
        }
        storage[id]?.deletedAt = deletionDate
    }

    func restore(id: UUID) throws {
        try checkFailure()
        guard storage[id] != nil else {
            throw AppError.scriptNotFound
        }
        storage[id]?.deletedAt = nil
    }

    func permanentlyDelete(id: UUID) throws {
        try checkFailure()
        permanentDeleteCallCount += 1
        storage[id] = nil
    }

    func purgeDeleted(before date: Date) throws {
        try checkFailure()
        storage = storage.filter { _, entry in
            guard let deletedAt = entry.deletedAt else {
                return true
            }
            return deletedAt > date
        }
    }

    func containsActiveScript(id: UUID) -> Bool {
        guard let entry = storage[id] else {
            return false
        }
        return entry.deletedAt == nil
    }

    private func checkFailure() throws {
        if shouldFail {
            throw TestRepositoryError.forcedFailure
        }
    }
}
