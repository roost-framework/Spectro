import Foundation
import Testing
@testable import Spectro

@Schema("bulk_owners")
struct BulkOwner {
    @ID var id: UUID
    @Column var name: String
}

@Schema("bulk_items")
struct BulkItem {
    @ID var id: UUID
    @Column var name: String
    @Column var views: Int
    @Column var price: Decimal
    @Column var tags: [String]
    @ForeignKey var ownerId: UUID
}

@Schema("bulk_soft_items")
struct SoftBulkItem {
    @ID var id: UUID
    @Column var name: String
    @SoftDelete var deletedAt: Date?
}

@Suite("Row locks and bulk write SQL")
struct QueryWriteUnitTests {
    @Test("Locks render after the limit and only lock the queried table")
    func lockSQL() async throws {
        let repo = try await TestDatabase.sharedRepo()
        let sql = try repo.query(BulkItem.self)
            .leftJoin(BulkOwner.self) { $0.left.ownerId == $0.right.id }
            .limit(1)
            .lock(.update, .skipLocked)
            .statement().sql
        #expect(sql.hasSuffix(#" LIMIT 1 FOR UPDATE OF "bulk_items" SKIP LOCKED"#))
        #expect(try repo.query(BulkItem.self).lock(.keyShare, .noWait).statement().sql.hasSuffix(#"FOR KEY SHARE OF "bulk_items" NOWAIT"#))
        #expect(try repo.query(BulkItem.self).lock().select { $0.name }.statement().sql.hasSuffix(#"FOR UPDATE OF "bulk_items""#))
    }

    @Test("Assignments bind values and qualify fields")
    func assignments() {
        let views = QueryField<Int>(name: "views", tableName: "bulk_items")
        let tags = QueryField<[String]>(name: "tags", tableName: "bulk_items")
        let name = QueryField<String>(name: "name", tableName: "bulk_items")
        #expect(views.increment(by: 2).sql == #""bulk_items"."views" + ?"#)
        #expect(tags.push("a").sql == #"array_append("bulk_items"."tags", ?)"#)
        #expect(tags.pull("a").sql == #"array_remove("bulk_items"."tags", ?)"#)
        #expect(name.set("x").sql == "?")
        #expect(name.set("\(name)").parameters.first?.string == "\(name)")
        #expect(name.set(sql: "upper(\(name))").sql == #"upper("bulk_items"."name")"#)
    }
}

extension DatabaseIntegrationTests {
@Suite("Bulk writes and row locks", .serialized)
struct QueryWriteIntegrationTests {
    private func withItems(_ body: (GenericDatabaseRepo, BulkOwner, BulkOwner) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "bulk_items""#)
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "bulk_owners""#)
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "bulk_soft_items""#)
        try await repo.executeRawSQL(#"CREATE TABLE "bulk_owners" ("id" UUID PRIMARY KEY, "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL("""
            CREATE TABLE "bulk_items" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL,
                "views" INTEGER NOT NULL,
                "price" NUMERIC(10, 2) NOT NULL,
                "tags" TEXT[] NOT NULL,
                "owner_id" UUID NOT NULL REFERENCES "bulk_owners"("id")
            )
            """)
        try await repo.executeRawSQL("""
            CREATE TABLE "bulk_soft_items" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL,
                "deleted_at" TIMESTAMPTZ
            )
            """)
        let ana = try await repo.insert(BulkOwner(name: "Ana"), includePrimaryKey: true)
        let bo = try await repo.insert(BulkOwner(name: "Bo"), includePrimaryKey: true)
        for (index, owner) in [ana, ana, bo].enumerated() {
            _ = try await repo.insert(BulkItem(name: "item\(index)", views: index, price: 10, tags: ["new"], ownerId: owner.id))
        }
        try await body(repo, ana, bo)
    }

    @Test("updateAll applies every kind of assignment to the matching rows")
    func updateAll() async throws {
        try await withItems { repo, ana, _ in
            let updated = try await repo.query(BulkItem.self)
                .where { $0.ownerId == ana.id }
                .updateAll { [
                    $0.views.increment(by: 10),
                    $0.price.increment(by: Decimal(string: "0.5")!),
                    $0.tags.push("hot"),
                    $0.name.set(sql: "upper(\($0.name)) || \("!")"),
                ] }
            #expect(updated == 2)

            let items = try await repo.query(BulkItem.self).orderBy { $0.name }.all()
            #expect(items.map(\.name) == ["ITEM0!", "ITEM1!", "item2"])
            #expect(items.map(\.views) == [10, 11, 2])
            #expect(items.map(\.price) == [Decimal(string: "10.5")!, Decimal(string: "10.5")!, 10])
            #expect(items.map(\.tags) == [["new", "hot"], ["new", "hot"], ["new"]])

            let pulled = try await repo.query(BulkItem.self).updateAll { [$0.tags.pull("new")] }
            #expect(pulled == 3)
            #expect(try await repo.query(BulkItem.self).where { $0.tags.contains("new") }.count() == 0)
        }
    }

    @Test("Joins, ordering, and limits choose the rows to update and delete")
    func joinedAndLimited() async throws {
        try await withItems { repo, _, _ in
            let renamed = try await repo.query(BulkItem.self)
                .join(BulkOwner.self) { $0.left.ownerId == $0.right.id }
                .where { $0.table(BulkOwner.self).name == "Ana" }
                .orderBy({ $0.views }, .desc)
                .limit(1)
                .updateAll { [$0.name.set("top")] }
            #expect(renamed == 1)
            let top = try await repo.query(BulkItem.self).where { $0.name == "top" }.first()
            #expect(top?.views == 1)

            let deleted = try await repo.query(BulkItem.self)
                .join(BulkOwner.self) { $0.left.ownerId == $0.right.id }
                .where { $0.table(BulkOwner.self).name == "Bo" }
                .deleteAll()
            #expect(deleted == 1)
            #expect(try await repo.query(BulkItem.self).count() == 2)
            #expect(try await repo.query(BulkItem.self).deleteAll() == 2)
            #expect(try await repo.query(BulkItem.self).deleteAll() == 0)
        }
    }

    @Test("Soft-deleted rows are marked by deleteAll and skipped by updateAll")
    func softDeletes() async throws {
        try await withItems { repo, _, _ in
            for name in ["a", "b", "c"] { _ = try await repo.insert(SoftBulkItem(name: name)) }
            let q = repo.query(SoftBulkItem.self)
            let marked = try await q.where { $0.name != "c" }.deleteAll()
            #expect(marked == 2)
            #expect(try await q.count() == 1)
            #expect(try await q.withDeleted().count() == 3)
            #expect(try await q.withDeleted().deleteAll() == 1)
            #expect(try await q.updateAll { [$0.name.set("z")] } == 0)
            #expect(try await q.withDeleted().updateAll { [$0.name.set("z")] } == 3)
        }
    }

    @Test("An empty updateAll is rejected before execution")
    func emptyUpdate() async throws {
        try await withItems { repo, _, _ in
            await #expect(throws: SpectroError.self) { try await repo.query(BulkItem.self).updateAll { _ in [] } }
        }
    }

    @Test("Bulk writes run inside transactions and roll back with them")
    func transactional() async throws {
        try await withItems { repo, _, _ in
            do {
                _ = try await repo.transaction { tx -> Int in
                    let count = try await tx.query(BulkItem.self).updateAll { [$0.views.set(99)] }
                    #expect(count == 3)
                    throw CancellationError()
                }
                Issue.record("The transaction committed")
            } catch {}
            let committed = try await repo.query(BulkItem.self).where { $0.views == 99 }.count()
            #expect(committed == 0)
        }
    }

    @Test("A locked row is skipped by SKIP LOCKED and fails NOWAIT in another transaction")
    func lockContention() async throws {
        try await withItems { _, _, _ in
            let config = DatabaseConfiguration(
                hostname: TestDatabase.hostname, port: TestDatabase.port, username: TestDatabase.username,
                password: TestDatabase.password, database: TestDatabase.database,
                maxConnectionsPerEventLoop: 2, numberOfThreads: 1
            )
            let spectro = try Spectro(configuration: config)
            do {
                try await spectro.transaction { holder in
                    let locked = try #require(try await holder.query(BulkItem.self).orderBy { $0.views }.limit(1).lock().first())
                    #expect(locked.views == 0)

                    try await spectro.transaction { other in
                        let free = try await other.query(BulkItem.self).orderBy { $0.views }.lock(.update, .skipLocked).all()
                        #expect(free.map(\.views) == [1, 2])
                    }

                    do {
                        try await spectro.transaction { other in
                            _ = try await other.query(BulkItem.self).where { $0.id == locked.id }.lock(.update, .noWait).all()
                        }
                        Issue.record("NOWAIT acquired a locked row")
                    } catch let error as SpectroError {
                        #expect(error.serverError?.sqlState == "55P03")
                    }
                }
            } catch {
                await spectro.shutdown()
                throw error
            }
            await spectro.shutdown()
        }
    }
}
}
