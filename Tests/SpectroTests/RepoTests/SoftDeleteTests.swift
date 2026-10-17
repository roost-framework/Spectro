import Foundation
import Testing
@testable import Spectro

@Schema("macro_soft_users")
private struct MacroSoftUser {
    @ID var id: UUID
    @Column var name: String
    @SoftDelete var removedAtUTC: Date?
}

@Schema("macro_soft_override", encodable: false)
private struct MacroSoftOverride {
    static var softDeleteColumn: String? { "removed_at" }
    @ID var id: UUID
    @SoftDelete var removedAt: Date?
}

@Schema("soft_notes")
private struct SoftNote {
    @ID var id: UUID
    @ForeignKey var userId: UUID
    @Column var body: String
    @SoftDelete var deletedAt: Date?
}

extension DatabaseIntegrationTests {
@Suite("Soft Delete")
struct SoftDeleteTests {

    @Test("Schema macro preserves soft-delete metadata, dates, and JSON")
    func macroSoftDeleteMapping() throws {
        let removedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let user = MacroSoftUser.build(from: ["name": "Removed", "removedAtUTC": removedAt])
        #expect(MacroSoftUser.softDeleteColumn == "removed_at_utc")
        #expect(MacroSoftUser().removedAtUTC == nil)
        #expect(MacroSoftUser(name: "Active").removedAtUTC == nil)
        #expect(user.removedAtUTC == removedAt)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(user)) as? [String: Any])
        #expect(json["removed_at_utc"] != nil)
        #expect(MacroSoftOverride.softDeleteColumn == "removed_at")
        #expect(MacroSoftOverride.build(from: ["removedAt": removedAt]).removedAt == removedAt)
    }

    @Test("Macro soft deletes filter query and transaction reads and decode withDeleted")
    func macroSoftDeleteQueries() async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS macro_soft_users (
                id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                name TEXT NOT NULL,
                removed_at_utc TIMESTAMPTZ
            )
            """)
        try await repo.executeRawSQL("TRUNCATE macro_soft_users")
        let active = try await repo.insert(MacroSoftUser(name: "Active"))
        let removed = try await repo.insert(MacroSoftUser(name: "Removed"))
        try await repo.delete(MacroSoftUser.self, id: removed.id)

        let visible = try await repo.query(MacroSoftUser.self).all()
        #expect(visible.map(\.id) == [active.id])
        #expect(try await repo.query(MacroSoftUser.self).count() == 1)
        let all = try await repo.query(MacroSoftUser.self).withDeleted().all()
        #expect(all.count == 2)
        #expect(all.first(where: { $0.id == removed.id })?.removedAtUTC != nil)
        let deleted = try await repo.query(MacroSoftUser.self).withDeleted()
            .where { $0.removedAtUTC.isNotNull() }.all()
        #expect(deleted.map(\.id) == [removed.id])

        try await repo.transaction { transaction in
            let visible = try await transaction.query(MacroSoftUser.self).all()
            #expect(visible.map(\.id) == [active.id])
            let all = try await transaction.query(MacroSoftUser.self).withDeleted().all()
            #expect(all.first(where: { $0.id == removed.id })?.removedAtUTC != nil)
        }
    }

    private func withCleanTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS "soft_users" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL DEFAULT '',
                "email" TEXT NOT NULL DEFAULT '',
                "deleted_at" TIMESTAMPTZ
            )
        """)
        try await repo.executeRawSQL(#"TRUNCATE "soft_users""#)
        try await body(repo)
    }

    private func withHardDeleteTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL("""
            CREATE TABLE IF NOT EXISTS "test_users" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL DEFAULT '',
                "email" TEXT NOT NULL DEFAULT '',
                "age" INT NOT NULL DEFAULT 0,
                "is_active" BOOLEAN NOT NULL DEFAULT true,
                "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
        """)
        try await repo.executeRawSQL(#"TRUNCATE "test_users""#)
        try await body(repo)
    }

    @Test("delete() sets deleted_at instead of hard-deleting the row")
    func softDeleteSetsDeletedAt() async throws {
        try await withCleanTable { repo in
            let user = try await repo.insert(SoftUser(name: "Alice", email: "alice@test.com"))
            try await repo.delete(SoftUser.self, id: user.id)

            // Row still exists in the database
            let rows = try await repo.executeRawQuery(
                sql: #"SELECT deleted_at FROM "soft_users" WHERE id = $1"#,
                parameters: [user.id.toPostgresData()]
            )
            #expect(rows.count == 1)
            let ra = rows[0].makeRandomAccess()
            #expect(ra[data: "deleted_at"].date != nil)
        }
    }

    @Test("all() excludes soft-deleted records")
    func allExcludesSoftDeleted() async throws {
        try await withCleanTable { repo in
            let _ = try await repo.insert(SoftUser(name: "Bob", email: "bob@test.com"))
            let toDelete = try await repo.insert(SoftUser(name: "Carol", email: "carol@test.com"))
            try await repo.delete(SoftUser.self, id: toDelete.id)

            let all = try await repo.all(SoftUser.self)
            #expect(all.count == 1)
            #expect(all.first?.name == "Bob")
        }
    }

    @Test("get() returns nil for soft-deleted record")
    func getExcludesSoftDeleted() async throws {
        try await withCleanTable { repo in
            let user = try await repo.insert(SoftUser(name: "Dan", email: "dan@test.com"))
            try await repo.delete(SoftUser.self, id: user.id)

            let fetched = try await repo.get(SoftUser.self, id: user.id)
            #expect(fetched == nil)
        }
    }

    @Test("Query excludes soft-deleted records automatically")
    func queryExcludesSoftDeleted() async throws {
        try await withCleanTable { repo in
            let _ = try await repo.insert(SoftUser(name: "Eve", email: "eve@test.com"))
            let toDelete = try await repo.insert(SoftUser(name: "Frank", email: "frank@test.com"))
            try await repo.delete(SoftUser.self, id: toDelete.id)

            let results = try await repo.query(SoftUser.self).all()
            #expect(results.count == 1)
            #expect(results.first?.name == "Eve")
        }
    }

    @Test("Grouped counts and selected fields exclude soft-deleted records")
    func aggregatesAndSelectExcludeSoftDeleted() async throws {
        try await withCleanTable { repo in
            let _ = try await repo.insert(SoftUser(name: "Ivy", email: "ivy@test.com"))
            let toDelete = try await repo.insert(SoftUser(name: "Jack", email: "jack@test.com"))
            try await repo.delete(SoftUser.self, id: toDelete.id)

            let names = try await repo.query(SoftUser.self).select { $0.name }.all()
            let groups = try await repo.query(SoftUser.self).groupBy { $0.name }.groupedCount()
            let allNames = try await repo.query(SoftUser.self).withDeleted().select { $0.name }.all()
            #expect(names == ["Ivy"])
            #expect(groups.map { $0.group["name"] } == ["Ivy"])
            #expect(Set(allNames) == ["Ivy", "Jack"])
        }
    }

    @Test("Joins exclude soft-deleted rows of the joined table unless withDeleted")
    func joinsExcludeSoftDeletedJoinedRows() async throws {
        try await withCleanTable { repo in
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS "soft_notes" (
                    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    "user_id" UUID NOT NULL,
                    "body" TEXT NOT NULL DEFAULT '',
                    "deleted_at" TIMESTAMPTZ
                )
            """)
            try await repo.executeRawSQL(#"TRUNCATE "soft_notes""#)
            let ann = try await repo.insert(SoftUser(name: "Ann", email: "ann@test.com"))
            let bob = try await repo.insert(SoftUser(name: "Bob", email: "bob@test.com"))
            _ = try await repo.insert(SoftNote(userId: ann.id, body: "kept"))
            for (user, body) in [(ann, "removed"), (bob, "removed")] {
                let note = try await repo.insert(SoftNote(userId: user.id, body: body))
                try await repo.delete(SoftNote.self, id: note.id)
            }

            func pairs(_ rows: [(SoftUser, SoftNote?)]) -> [String] {
                rows.map { "\($0.0.name):\($0.1?.body ?? "-")" }.sorted()
            }
            let query = repo.query(SoftUser.self)
            let inner = try await query.joinAndExecute(SoftNote.self, on: { $0.left.id == $0.right.userId })
            let left = try await query.leftJoinAndExecute(SoftNote.self, on: { $0.left.id == $0.right.userId })
            let right = try await query.rightJoin(SoftNote.self, on: { $0.left.id == $0.right.userId }).count()
            let all = try await query.join(SoftNote.self, on: { $0.left.id == $0.right.userId })
                .withDeleted().executeJoin(with: SoftNote.self).all()
            #expect(pairs(inner) == ["Ann:kept"])
            #expect(pairs(left) == ["Ann:kept", "Bob:-"])
            #expect(right == 1)
            #expect(pairs(all) == ["Ann:kept", "Ann:removed", "Bob:removed"])
        }
    }

    @Test("withDeleted() returns all records including soft-deleted")
    func withDeletedIncludesAll() async throws {
        try await withCleanTable { repo in
            let _ = try await repo.insert(SoftUser(name: "Grace", email: "grace@test.com"))
            let toDelete = try await repo.insert(SoftUser(name: "Hank", email: "hank@test.com"))
            try await repo.delete(SoftUser.self, id: toDelete.id)

            let all = try await repo.query(SoftUser.self).withDeleted().all()
            #expect(all.count == 2)
        }
    }

    @Test("Hard-delete schema is unaffected by soft-delete logic")
    func hardDeleteSchemaUnaffected() async throws {
        try await withHardDeleteTable { repo in
            let user = try await repo.insert(TestUser(name: "Iris", email: "iris@test.com", age: 30))
            try await repo.delete(TestUser.self, id: user.id)

            let all = try await repo.all(TestUser.self)
            #expect(all.isEmpty)
        }
    }

    @Test("delete() is idempotent: second soft-delete is a no-op")
    func softDeleteIdempotent() async throws {
        try await withCleanTable { repo in
            let user = try await repo.insert(SoftUser(name: "Jay", email: "jay@test.com"))
            try await repo.delete(SoftUser.self, id: user.id)
            // Second delete should not throw
            try await repo.delete(SoftUser.self, id: user.id)

            let fetched = try await repo.get(SoftUser.self, id: user.id)
            #expect(fetched == nil)
        }
    }
}
}
