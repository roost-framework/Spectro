import Foundation
import Testing
@testable import Spectro

@Schema("locked_docs")
struct LockedDoc {
    @ID var id: UUID
    @Column var title: String
    @Column var lockVersion: Int = 1
    @Column var revision: Int = 0
}

extension DatabaseIntegrationTests {
@Suite("Optimistic locking", .serialized)
struct OptimisticLockTests {
    private func withDoc(_ body: (GenericDatabaseRepo, LockedDoc) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "locked_docs""#)
        try await repo.executeRawSQL(#"CREATE TABLE "locked_docs" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "title" TEXT NOT NULL, "lock_version" INTEGER NOT NULL DEFAULT 1, "revision" INTEGER NOT NULL DEFAULT 0)"#)
        try await body(repo, try await repo.insert(LockedDoc(title: "Draft", lockVersion: 1, revision: 0)))
    }

    @Test("A locked update increments the version, and a stale one throws")
    func staleUpdate() async throws {
        try await withDoc { repo, doc in
            let first = Changeset.cast(doc, params: ["title": "First"], permitted: ["title"]).optimisticLock()
            let second = Changeset.cast(doc, params: ["title": "Second"], permitted: ["title"]).optimisticLock()

            let updated = try await repo.update(first)
            #expect(updated.title == "First")
            #expect(updated.lockVersion == 2)

            do {
                _ = try await repo.update(second)
                Issue.record("A stale update succeeded")
            } catch let error as SpectroError {
                guard case .staleRecord = error else { throw error }
            }
            #expect(try await repo.reload(doc)?.title == "First")

            // Without other changes, the update still increments the version.
            let touched = try await repo.update(Changeset.cast(updated, params: [:], permitted: []).optimisticLock())
            #expect(touched.lockVersion == 3)

            let custom = try await repo.update(Changeset.cast(touched, params: ["title": "Custom"], permitted: ["title"]).optimisticLock("revision"))
            #expect(custom.revision == 1)
            #expect(custom.lockVersion == 3)

            await #expect(throws: SpectroError.self) {
                _ = try await repo.update(Changeset.cast(custom, params: ["title": "x"], permitted: ["title"]).optimisticLock("title"))
            }

            // A version cast from a stale form wins over the loaded one, as in Ecto.
            let fresh = try #require(try await repo.reload(doc))
            let staleForm = Changeset.cast(fresh, params: ["title": "Form", "lockVersion": 1], permitted: ["title", "lockVersion"]).optimisticLock()
            await #expect(throws: SpectroError.self) { _ = try await repo.update(staleForm) }

            // A write in its own transaction, for a preparation, throws the same error.
            let prepared = Changeset.cast(doc, params: ["title": "Prepared"], permitted: ["title"])
                .optimisticLock()
                .prepareChanges { changeset, _ in changeset }
            do {
                _ = try await repo.update(prepared)
                Issue.record("A stale prepared update succeeded")
            } catch SpectroError.staleRecord {}

            try await repo.delete(LockedDoc.self, id: doc.id)
            do {
                _ = try await repo.update(Changeset.cast(custom, params: ["title": "Gone"], permitted: ["title"]).optimisticLock())
                Issue.record("An update of a deleted record succeeded")
            } catch let error as SpectroError {
                guard case .staleRecord = error else { throw error }
            }
        }
    }
}
}
