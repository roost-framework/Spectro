import Foundation
import Testing
@testable import Spectro

@Schema("fragment_docs")
struct FragmentDoc {
    @ID var id: UUID
    @Column var title: String
    @Column var rank: Int
    @Column var labels: [String: String]
    @Column var ownerId: UUID?
}

@Schema("fragment_owners")
struct FragmentOwner {
    @ID var id: UUID
    @Column var name: String
}

@Suite("SQL fragments")
struct SQLFragmentUnitTests {
    @Test("Fields are qualified, values are bound, and literal question marks survive numbering")
    func rendering() throws {
        let title = QueryField<String>(name: "title", tableName: "fragment_docs")
        let condition = QueryCondition.fragment("lower(\(title)) = \("a?") AND \(title) ? 'x' AND \(identifier: "my col") > \(3)")
        #expect(condition.sql == "lower(\"fragment_docs\".\"title\") = ? AND \"fragment_docs\".\"title\" \u{E000} 'x' AND \"my col\" > ?")
        #expect(condition.parameters.count == 2)
        #expect(condition.parameters[0].string == "a?")
        #expect(condition.parameters[1].int == 3)
        #expect(renumberPlaceholders(in: condition.sql) == "lower(\"fragment_docs\".\"title\") = $1 AND \"fragment_docs\".\"title\" ? 'x' AND \"my col\" > $2")

        let inner: SQLFragment = "coalesce(\(title), \("none"))"
        let outer = QueryCondition.fragment("\(inner) <> \("x")")
        #expect(outer.parameters.compactMap(\.string) == ["none", "x"])
    }
}

extension DatabaseIntegrationTests {
@Suite("SQL fragments against PostgreSQL", .serialized)
struct SQLFragmentIntegrationTests {
    private func withDocs(_ body: (GenericDatabaseRepo, FragmentOwner) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "fragment_docs""#)
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "fragment_owners""#)
        try await repo.executeRawSQL(#"CREATE TABLE "fragment_owners" ("id" UUID PRIMARY KEY, "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL("""
            CREATE TABLE "fragment_docs" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "title" TEXT NOT NULL,
                "rank" INTEGER NOT NULL,
                "labels" JSONB NOT NULL,
                "owner_id" UUID REFERENCES "fragment_owners"("id")
            )
            """)
        let owner = try await repo.insert(FragmentOwner(name: "Ana"), includePrimaryKey: true)
        _ = try await repo.insert(FragmentDoc(title: "Alpha", rank: 1, labels: ["beta": "yes"], ownerId: owner.id))
        _ = try await repo.insert(FragmentDoc(title: "beta", rank: 2, labels: [:], ownerId: nil))
        _ = try await repo.insert(FragmentDoc(title: "GAMMA", rank: 3, labels: ["beta": "no", "tier": "gold"], ownerId: owner.id))
        try await body(repo, owner)
    }

    @Test("Fragments filter with functions, JSONB operators, and other clauses")
    func filters() async throws {
        try await withDocs { repo, _ in
            let q = repo.query(FragmentDoc.self).orderBy { $0.rank }
            let lowered = try await q.where { .fragment("lower(\($0.title)) = \("gamma")") }.all()
            #expect(lowered.map(\.rank) == [3])

            // The jsonb ? operator is a literal question mark, not a placeholder.
            let tagged = try await q
                .where { $0.rank > 0 }
                .where { .fragment("\($0.labels) ? \("beta")") && $0.rank < 3 }
                .all()
            #expect(tagged.map(\.rank) == [1])

            let gold = try await q.where { .fragment("\($0.labels) ->> 'tier' = \("gold")") }.count()
            #expect(gold == 1)
        }
    }

    @Test("Fragments refer to joined tables and run in having clauses")
    func joinsAndHaving() async throws {
        try await withDocs { repo, owner in
            let docs = try await repo.query(FragmentDoc.self)
                .join(FragmentOwner.self) { $0.left.ownerId == $0.right.id }
                .where { .fragment("upper(\($0.table(FragmentOwner.self).name)) = \("ANA")") }
                .where { $0.table(FragmentOwner.self).name == "Ana" }
                .orderBy { $0.rank }
                .all()
            #expect(docs.map(\.rank) == [1, 3])

            let groups = try await repo.query(FragmentDoc.self)
                .groupBy { $0.ownerId }
                .having { _ in .fragment("count(*) > \(1)") }
                .groupedCount()
            #expect(groups.count == 1)
            #expect(groups.first?.group["owner_id"] == owner.id.uuidString)
        }
    }

    @Test("Fragment statements bind parameters in clause order")
    func statementOrder() async throws {
        try await withDocs { repo, _ in
            let statement = try repo.query(FragmentDoc.self)
                .where { .fragment("\($0.rank) >= \(2)") }
                .where { $0.title != "x" }
                .statement()
            #expect(statement.sql.contains(#""fragment_docs"."rank" >= $1"#))
            #expect(statement.sql.contains("$2"))
            #expect(statement.parameters.count == 2)
        }
    }

    @Test("Raw fragment statements number their parameters, also in transactions")
    func rawStatements() async throws {
        try await withDocs { repo, _ in
            let rank = QueryBuilder<FragmentDoc>().rank
            let statement: SQLFragment = "SELECT \(identifier: "title"), \(rank) * \(10) AS score FROM \(identifier: "fragment_docs") WHERE \(rank) > \(1) AND \(identifier: "labels") ? 'tier'"
            let rows = try await repo.executeRawQuery(statement)
            #expect(rows.count == 1)
            #expect(rows.first?.makeRandomAccess()[data: "title"].string == "GAMMA")
            #expect(rows.first?.makeRandomAccess()[data: "score"].int == 30)

            let count = try await repo.transaction { tx in
                try await tx.executeRawQuery("SELECT 1 FROM \(identifier: "fragment_docs") WHERE \(identifier: "rank") >= \(2)").count
            }
            #expect(count == 2)
        }
    }

    @Test("Expression sorts bind after filters, keep call order with field sorts, and drop out of counts")
    func expressionOrdering() async throws {
        try await withDocs { repo, _ in
            let query = repo.query(FragmentDoc.self)
                .where { .fragment("\($0.rank) >= \(1)") }
                .orderBy(sql: { "CASE WHEN \($0.rank) = \(2) THEN 0 ELSE 1 END" })
                .orderBy({ $0.rank }, .desc)
                .orderBy(sql: { "\($0.id)" })
            let statement = try query.statement()
            #expect(statement.sql.hasSuffix(#"ORDER BY CASE WHEN "fragment_docs"."rank" = $2 THEN 0 ELSE 1 END ASC, "fragment_docs"."rank" DESC, "fragment_docs"."id" ASC"#))
            #expect(statement.parameters.compactMap(\.int) == [1, 2])

            #expect(try await query.all().map(\.rank) == [2, 3, 1])
            #expect(try await query.limit(1).offset(1).all().map(\.rank) == [3])
            #expect(try await query.count() == 3)
            #expect(try await query.page(size: 2, page: 2).items.map(\.rank) == [1])
            #expect(try await query.sum { $0.rank } == 6)
            #expect(try await query.select { $0.title }.all() == ["beta", "GAMMA", "Alpha"])
            let titles = try await repo.query(FragmentDoc.self)
                .select { $0.title }
                .orderBy(sql: { "length(\($0.title)) + \(0)" }, .desc)
                .orderBy { $0.title }
                .all()
            #expect(titles == ["Alpha", "GAMMA", "beta"])

            let grouped = try await repo.query(FragmentDoc.self)
                .groupBy { $0.ownerId }
                .having { _ in .fragment("count(*) >= \(1)") }
                .orderBy(sql: { _ in "count(*) * \(-1)" })
                .groupedCount()
            #expect(grouped.map(\.value) == [2, 1])

            // A direct bulk write drops the ordering; a limited one keeps it to pick rows.
            #expect(try await query.updateAll { [$0.rank.increment(by: 10)] } == 3)
            #expect(try await query.limit(1).updateAll { [$0.title.set("first")] } == 1)
            let first = try await repo.query(FragmentDoc.self).where { $0.title == "first" }.first()
            #expect(first?.rank == 13)
        }
    }
}
}
