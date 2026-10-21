import Foundation
import Testing
@testable import Spectro

@Schema("bulk_tags")
struct BulkTag {
    @ID var id: UUID
    @Column var name: String
    @Column var uses: Int
    @SoftDelete var deletedAt: Date?
}

extension DatabaseIntegrationTests {
@Suite("Conflicting inserts, reloads, and batches", .serialized)
struct BulkReadWriteTests {
    private func withTags(_ names: [String], _ body: (GenericDatabaseRepo, [BulkTag]) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "bulk_tags""#)
        try await repo.executeRawSQL("""
            CREATE TABLE "bulk_tags" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "name" TEXT NOT NULL UNIQUE,
                "uses" INTEGER NOT NULL,
                "deleted_at" TIMESTAMPTZ
            )
            """)
        let tags = try await repo.insertAll(names.map { BulkTag(name: $0, uses: 1) })
        try await body(repo, tags)
    }

    @Test("Inserts skip conflicting records or update their rows")
    func conflicts() async throws {
        try await withTags(["a", "b"]) { repo, _ in
            let skipped = try await repo.insertAll([BulkTag(name: "a", uses: 5), BulkTag(name: "c", uses: 5)], onConflict: .nothing())
            #expect(skipped.map(\.name) == ["c"])
            let skippedOnName = try await repo.insertAll([BulkTag(name: "b", uses: 5), BulkTag(name: "d", uses: 5)], onConflict: .nothing(on: .columns(["name"])))
            #expect(skippedOnName.map(\.name) == ["d"])

            let replaced = try await repo.insertAll([BulkTag(name: "a", uses: 7), BulkTag(name: "e", uses: 7)], onConflict: .replace(on: .columns(["name"])))
            #expect(replaced.map(\.uses) == [7, 7])
            let uses = try await repo.insertAll([BulkTag(name: "b", uses: 9)], onConflict: .replace(on: .constraint("bulk_tags_name_key"), columns: ["uses"]))
            #expect(uses.map(\.uses) == [9])
            let names = try await repo.query(BulkTag.self).orderBy { $0.name }.all().map { "\($0.name)\($0.uses)" }
            #expect(names == ["a7", "b9", "c5", "d5", "e7"])

            await #expect(throws: SpectroError.self) {
                try await repo.insertAll([BulkTag(name: "a", uses: 1)], onConflict: .replace(on: .columns(["name"]), columns: []))
            }

            let duplicate = try await repo.insert(BulkTag(name: "a", uses: 0), onConflict: .nothing())
            let fresh = try await repo.insert(BulkTag(name: "f", uses: 0), onConflict: .nothing())
            #expect(duplicate == nil)
            #expect(fresh?.name == "f")

            let inTransaction = try await repo.transaction { tx in
                try await tx.insertAll([BulkTag(name: "f", uses: 3), BulkTag(name: "g", uses: 3)], onConflict: .nothing()).count
            }
            #expect(inTransaction == 1)
        }
    }

    @Test("Reloads read records as stored now, in order, with nil for deleted ones")
    func reloads() async throws {
        try await withTags(["a", "b", "c"]) { repo, tags in
            try await repo.query(BulkTag.self).updateAll { [$0.uses.increment(by: 10)] }
            try await repo.delete(BulkTag.self, id: tags[1].id)

            let reloaded = try await repo.reload(tags.reversed())
            #expect(reloaded.map { $0?.uses } == [11, nil, 11])
            #expect(reloaded.map { $0?.name } == ["c", nil, "a"])
            #expect(try await repo.reload(tags[0])?.uses == 11)
            #expect(try await repo.reload(tags[1]) == nil)
            #expect(try await repo.reload([BulkTag]()).isEmpty)
        }
    }

    @Test("Batches visit every row once, in primary key order")
    func batches() async throws {
        try await withTags(["a", "b", "c", "d", "e", "f", "g"]) { repo, tags in
            var sizes: [Int] = []
            var seen: [UUID] = []
            for try await batch in repo.query(BulkTag.self).batches(of: 3) {
                sizes.append(batch.count)
                seen += batch.map(\.id)
            }
            #expect(sizes == [3, 3, 1])
            #expect(seen == tags.map(\.id).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() })

            var filtered = 0
            for try await batch in repo.query(BulkTag.self).where({ $0.name != "a" }).batches(of: 2) {
                filtered += batch.count
            }
            #expect(filtered == 6)

            var partial: [String] = []
            for try await batch in repo.query(BulkTag.self).selectFields({ $0.name }).batches(of: 6) {
                partial += batch.map(\.name)
            }
            #expect(partial.count == 7)

            let snapshot = try await repo.transaction(isolation: .repeatableRead) { tx in
                var count = 0
                for try await batch in tx.query(BulkTag.self).batches(of: 4) {
                    count += batch.count
                }
                return count
            }
            #expect(snapshot == 7)

            await #expect(throws: SpectroError.self) {
                for try await _ in repo.query(BulkTag.self).orderBy({ $0.name }).batches(of: 2) {}
            }
        }
    }
}
}
