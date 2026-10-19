import Foundation
import Testing
@testable import Spectro

@Schema("interaction_owners")
private struct InteractionOwner {
    @ID var id: UUID
    @Column("DisplayName") var name: String = ""
    @Column("Score") var score: Int = 0
    @SoftDelete var removedAt: Date?

    init(name: String, score: Int) {
        self.name = name
        self.score = score
    }
}

@Schema("interaction_entries")
private struct InteractionEntry {
    @ID var id: UUID
    @ForeignKey("owner_ref") var ownerId: UUID
    @Column("DisplayName") var name: String = ""
    @Column("Score") var score: Int = 0
    @SoftDelete var removedAt: Date?

    init(ownerId: UUID, name: String, score: Int) {
        self.ownerId = ownerId
        self.name = name
        self.score = score
    }
}

extension DatabaseIntegrationTests {
    @Suite("Query interactions")
    struct QueryInteractionTests {
        private struct Fixture: Sendable {
            let active: InteractionOwner
            let unmatched: InteractionOwner
            let deleted: InteractionOwner
        }

        private func withFixture(
            inTransaction: Bool,
            _ body: @escaping @Sendable (any Repo, Fixture) async throws -> Void
        ) async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS interaction_owners (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    "DisplayName" TEXT NOT NULL, "Score" INTEGER NOT NULL, removed_at TIMESTAMPTZ
                )
                """)
            try await repo.executeRawSQL("""
                CREATE UNIQUE INDEX IF NOT EXISTS interaction_owners_active_name
                ON interaction_owners ("DisplayName") WHERE removed_at IS NULL
                """)
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS interaction_entries (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    owner_ref UUID NOT NULL REFERENCES interaction_owners(id),
                    "DisplayName" TEXT NOT NULL, "Score" INTEGER NOT NULL, removed_at TIMESTAMPTZ
                )
                """)
            try await repo.executeRawSQL("TRUNCATE interaction_entries, interaction_owners")
            let active = try await repo.insert(InteractionOwner(name: "Alpha", score: 10))
            let unmatched = try await repo.insert(InteractionOwner(name: "Beta", score: 20))
            let deleted = try await repo.insert(InteractionOwner(name: "Removed", score: 30))
            try await repo.delete(InteractionOwner.self, id: deleted.id)
            _ = try await repo.insert(InteractionEntry(ownerId: active.id, name: "visible", score: 1))
            let hidden = try await repo.insert(InteractionEntry(ownerId: active.id, name: "hidden", score: 100))
            let onlyHidden = try await repo.insert(InteractionEntry(ownerId: unmatched.id, name: "hidden", score: 200))
            _ = try await repo.insert(InteractionEntry(ownerId: deleted.id, name: "visible", score: 3))
            try await repo.delete(InteractionEntry.self, id: hidden.id)
            try await repo.delete(InteractionEntry.self, id: onlyHidden.id)
            let fixture = Fixture(active: active, unmatched: unmatched, deleted: deleted)
            if inTransaction {
                try await repo.transaction { try await body($0, fixture) }
            } else {
                try await body(repo, fixture)
            }
        }

        @Test("Joined operations resolve overlapping custom columns", arguments: [false, true], ["filter-before", "filter-after", "order-before", "order-after", "select", "model-selection", "aggregates", "grouped", "with-deleted"])
        func overlappingColumns(inTransaction: Bool, operation: String) async throws {
            try await withFixture(inTransaction: inTransaction) { repo, fixture in
                let base = repo.query(InteractionOwner.self)
                let joined = base.leftJoin(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId })
                switch operation {
                case "filter-before":
                    let rows = try await base.where { $0.name == "Alpha" || $0.name == "Removed" }
                        .leftJoin(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId }).all()
                    #expect(rows.map(\.id) == [fixture.active.id])
                case "filter-after":
                    #expect(try await joined.where { $0.name == "Alpha" }.count() == 1)
                case "order-before":
                    let rows = try await base.orderBy({ $0.score }, .desc)
                        .leftJoin(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId }).all()
                    #expect(rows.map(\.id) == [fixture.unmatched.id, fixture.active.id])
                case "order-after":
                    let rows = try await joined.orderBy({ $0.name }, .desc).all()
                    #expect(rows.map(\.id) == [fixture.unmatched.id, fixture.active.id])
                case "select":
                    let names = try await joined.orderBy { $0.name }.select { $0.name }.all()
                    #expect(names == ["Alpha", "Beta"])
                    let pairs = try await joined.orderBy { $0.name }.select { ($0.name, $0.score) }.all()
                    #expect(pairs.map(\._0) == ["Alpha", "Beta"])
                    #expect(pairs.map(\._1) == [10, 20])
                case "model-selection":
                    let rows = try await base.selectFields { $0.id }.selectFields { $0.name }
                        .selectFields { $0.score }.selectFields { $0.removedAt }
                        .leftJoin(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId })
                        .orderBy { $0.name }.all()
                    #expect(rows.map(\.id) == [fixture.active.id, fixture.unmatched.id])
                    #expect(rows.map(\.name) == ["Alpha", "Beta"])
                case "aggregates":
                    #expect(try await joined.sum { $0.score } == 30)
                    #expect(try await joined.avg { $0.score } == 15)
                    #expect(try await joined.min { $0.score } == 10)
                    #expect(try await joined.max { $0.score } == 20)
                case "grouped":
                    let groups = try await joined.groupBy { $0.name }
                        .having { $0.name != "Beta" }.orderBy { $0.name }.groupedSum { $0.score }
                    #expect(groups.count == 1)
                    #expect(groups.first?.group == ["DisplayName": "Alpha"])
                    #expect(groups.first?.value == 10)
                case "with-deleted":
                    let all = joined.withDeleted()
                    #expect(try await all.sum { $0.score } == 70)
                    let names = try await all.orderBy { $0.name }.select { $0.name }.all()
                    #expect(names == ["Alpha", "Alpha", "Beta", "Removed"])
                default:
                    Issue.record("Unknown operation: \(operation)")
                }
            }
        }

        @Test("Typed joins and withDeleted agree on both tables", arguments: [false, true])
        func typedSoftDeleteJoins(inTransaction: Bool) async throws {
            try await withFixture(inTransaction: inTransaction) { repo, fixture in
                let base = repo.query(InteractionOwner.self)
                let query = base.leftJoin(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId })
                let rows = try await query.executeJoin(with: InteractionEntry.self).orderBy { $0.name }.all()
                #expect(rows.count == 2)
                #expect(rows.first?.0.id == fixture.active.id)
                #expect(rows.first?.1?.name == "visible")
                #expect(rows.last?.0.id == fixture.unmatched.id)
                #expect(rows.last?.1 == nil)
                let all = try await query.withDeleted().executeJoin(with: InteractionEntry.self).all()
                #expect(all.count == 4)
                #expect(all.filter { $0.0.removedAt != nil }.count == 1)
                #expect(all.filter { $0.1?.removedAt != nil }.count == 2)
                #expect(try await base.join(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId }).count() == 1)
                #expect(try await base.withDeleted().join(InteractionEntry.self, on: { $0.left.id == $0.right.ownerId }).count() == 4)
            }
        }

        @Test("Custom-column updates respect deletion and restore", arguments: [false, true])
        func updateAndRestore(inTransaction: Bool) async throws {
            try await withFixture(inTransaction: inTransaction) { repo, fixture in
                #expect(try await repo.get(InteractionOwner.self, id: fixture.deleted.id) == nil)
                let deleted = try #require(try await repo.get(InteractionOwner.self, id: fixture.deleted.id, withDeleted: true))
                #expect(deleted.removedAt != nil)
                do {
                    _ = try await repo.update(Changeset.cast(deleted, params: ["name": "Changed"], permitted: ["name"]))
                    Issue.record("Updating a deleted record must fail")
                } catch SpectroError.notFound {
                    // A missing record does not abort the transaction.
                }
                let restored = try await repo.restore(InteractionOwner.self, id: deleted.id)
                #expect(restored.name == "Removed")
                #expect(restored.removedAt == nil)
                let updated = try await repo.update(InteractionOwner.self, id: deleted.id, changes: ["name": "Restored"])
                #expect(updated.name == "Restored")
                let rows = try await repo.query(InteractionOwner.self).where { $0.name == "Restored" }.all()
                #expect(rows.map(\.id) == [deleted.id])
            }
        }

        @Test("Restore conflicts expose server errors and roll back only the savepoint")
        func restoreConflictInSavepoint() async throws {
            try await withFixture(inTransaction: false) { repo, fixture in
                let replacement = try await repo.insert(InteractionOwner(name: "Removed", score: 40))
                try await repo.transaction { transaction in
                    let tx = try #require(transaction as? TransactionRepo)
                    do {
                        try await tx.savepoint { sp -> Void in
                            _ = try await sp.update(InteractionOwner.self, id: fixture.active.id, changes: ["name": "Temporary"])
                            _ = try await sp.restore(InteractionOwner.self, id: fixture.deleted.id)
                        }
                        Issue.record("Restoring a duplicate active name must fail")
                    } catch let error as SpectroError {
                        #expect(error.serverError?.sqlState == "23505")
                        #expect(error.serverError?.constraintName == "interaction_owners_active_name")
                    }
                    let active = try await tx.get(InteractionOwner.self, id: fixture.active.id)
                    #expect(active?.name == "Alpha")
                    #expect(try await tx.get(InteractionOwner.self, id: fixture.deleted.id) == nil)
                    try await tx.delete(InteractionOwner.self, id: replacement.id)
                    let restored = try await tx.savepoint { sp in
                        try await sp.restore(InteractionOwner.self, id: fixture.deleted.id)
                    }
                    #expect(restored.removedAt == nil)
                }
                #expect(try await repo.get(InteractionOwner.self, id: replacement.id) == nil)
                #expect(try await repo.get(InteractionOwner.self, id: fixture.deleted.id)?.name == "Removed")
            }
        }
    }
}
