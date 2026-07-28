import Foundation
import SwiftData

@ModelActor
actor SwiftDataScriptRepository: ScriptRepository {
    func scripts() throws -> [Script] {
        let descriptor = FetchDescriptor<ScriptRecord>(
            predicate: #Predicate { $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )

        return try modelContext.fetch(descriptor).map(\.value)
    }

    func script(id: UUID) throws -> Script? {
        try record(id: id, includesDeleted: false)?.value
    }

    func save(_ script: Script) throws {
        if let existing = try record(id: script.id, includesDeleted: true) {
            existing.update(from: script)
        } else {
            modelContext.insert(ScriptRecord(script: script))
        }

        try modelContext.save()
    }

    func delete(id: UUID, at deletionDate: Date) throws {
        guard let record = try record(id: id, includesDeleted: false) else {
            throw AppError.scriptNotFound
        }

        record.deletedAt = deletionDate
        try modelContext.save()
    }

    func restore(id: UUID) throws {
        guard let record = try record(id: id, includesDeleted: true) else {
            throw AppError.scriptNotFound
        }

        record.deletedAt = nil
        try modelContext.save()
    }

    func permanentlyDelete(id: UUID) throws {
        guard let record = try record(id: id, includesDeleted: true) else {
            return
        }

        modelContext.delete(record)
        try modelContext.save()
    }

    func purgeDeleted(before date: Date) throws {
        let descriptor = FetchDescriptor<ScriptRecord>(
            predicate: #Predicate { $0.deletedAt != nil }
        )
        let records = try modelContext.fetch(descriptor)

        for record in records {
            if let deletedAt = record.deletedAt, deletedAt <= date {
                modelContext.delete(record)
            }
        }

        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    private func record(id: UUID, includesDeleted: Bool) throws -> ScriptRecord? {
        let requestedID = id
        var descriptor = FetchDescriptor<ScriptRecord>(
            predicate: #Predicate { $0.id == requestedID }
        )
        descriptor.fetchLimit = 1

        guard let record = try modelContext.fetch(descriptor).first else {
            return nil
        }

        if !includesDeleted, record.deletedAt != nil {
            return nil
        }
        return record
    }
}

actor UnavailableScriptRepository: ScriptRepository {
    func scripts() throws -> [Script] {
        throw AppError.persistenceUnavailable
    }

    func script(id: UUID) throws -> Script? {
        throw AppError.persistenceUnavailable
    }

    func save(_ script: Script) throws {
        throw AppError.persistenceUnavailable
    }

    func delete(id: UUID, at deletionDate: Date) throws {
        throw AppError.persistenceUnavailable
    }

    func restore(id: UUID) throws {
        throw AppError.persistenceUnavailable
    }

    func permanentlyDelete(id: UUID) throws {
        throw AppError.persistenceUnavailable
    }

    func purgeDeleted(before date: Date) throws {
        throw AppError.persistenceUnavailable
    }
}
