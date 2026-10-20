import Foundation
import NIOCore
import PostgresNIO
import Testing
@testable import Spectro

enum ArticleStatus: String, Codable, DatabaseValue {
    case draft, published, archived
}

/// Stored in a PostgreSQL enum column.
enum ArticleMood: String, Codable, DatabaseValue {
    case calm, urgent
}

struct ArticleMeta: Codable, Equatable, JSONBValue {
    var views: Int
    var editor: String?
}

/// A hand-written conformance with no PostgreSQL array type.
struct Cents: DatabaseValue, Equatable {
    var amount: Int
    func toPostgresData() -> PostgresData { PostgresData(int: amount) }
    static func fromPostgresData(_ data: PostgresData) -> Cents? { data.int.map(Cents.init) }
}

@Schema("typed_articles")
struct TypedArticle {
    @Column var urgency: ArticleMood?
    @ID var id: UUID
    @Column var price: Decimal
    @Column var discount: Decimal?
    @Column var status: ArticleStatus = .draft
    @Column var mood: ArticleMood = .calm
    @Column var tags: [String]
    @Column var reviewerIds: [UUID]
    @Column var scores: [Int]?
    @Column var meta: ArticleMeta = ArticleMeta(views: 0, editor: nil)
    @Column var labels: [String: String]
    @Column var payload: Data
}

/// Records whose array has no PostgreSQL array type cannot be encoded.
@Schema("unencodable_records", encodable: false)
struct UnencodableRecord {
    @ID var id: UUID
    @Column var amounts: [Cents]
}

enum RegistryOwnerA {
    struct Item: Schema, SchemaBuilder {
        static let tableName = "a_items"
        @ID var id: UUID
        init() { id = UUID() }
    }
}

enum RegistryOwnerB {
    struct Item: Schema, SchemaBuilder {
        static let tableName = "b_items"
        @ID var id: UUID
        init() { id = UUID() }
    }
}

@Suite("DatabaseValue metadata and encoding")
struct DatabaseValueUnitTests {
    @Test("Custom column types are registered with their stored type and nullability")
    func metadata() {
        let fields = Dictionary(uniqueKeysWithValues: SchemaRegistry.extractMetadata(from: TypedArticle.self).fields.map { ($0.name, $0) })
        #expect(fields.count == 12)
        #expect(fields["price"]?.fieldType == .custom)
        #expect(fields["price"]?.valueType == Decimal.self)
        #expect(fields["price"]?.isNullable == false)
        #expect(fields["discount"]?.valueType == Decimal.self)
        #expect(fields["discount"]?.isNullable == true)
        #expect(fields["scores"]?.valueType == [Int].self)
        #expect(fields["scores"]?.isNullable == true)
        #expect(fields["reviewerIds"]?.databaseName == "reviewer_ids")
        #expect(fields["status"]?.valueType == ArticleStatus.self)
        #expect(fields["payload"]?.valueType == Data.self)
        #expect(fields["id"]?.fieldType == .uuid)
    }

    @Test("Values encode with their PostgreSQL types")
    func encoding() throws {
        #expect(Decimal(string: "19.99")!.toPostgresData().type == .numeric)
        #expect(try ["a", "b"].toPostgresData().type == .textArray)
        #expect(try [ArticleStatus.draft].toPostgresData().type == .textArray)
        // A String raw value is sent untyped, so PostgreSQL enum columns accept it.
        #expect(try ArticleStatus.draft.toPostgresData().type == .null)
        #expect(try ArticleMeta(views: 1).toPostgresData().type == .jsonb)
        #expect(try (nil as Decimal?).toPostgresData().value == nil)
        #expect(Cents(amount: 5).toPostgresData().int == 5)
        #expect(Cents.fromPostgresData(PostgresData(int: 7)) == Cents(amount: 7))
        #expect(throws: SpectroError.self) { try [Cents(amount: 1)].toPostgresData() }
        let json = PostgresData(type: .json, formatCode: .binary, value: ByteBuffer(string: #"{"views":2}"#))
        #expect(ArticleMeta.fromPostgresData(json) == ArticleMeta(views: 2, editor: nil))
    }

    @Test("Schemas with the same name keep separate metadata")
    func registryIdentity() async {
        #expect(await SchemaRegistry.shared.register(RegistryOwnerA.Item.self).tableName == "a_items")
        #expect(await SchemaRegistry.shared.register(RegistryOwnerB.Item.self).tableName == "b_items")
    }

    @Test("Writes fail on values that cannot be encoded and on empty column lists")
    func writeErrors() async throws {
        let repo = try await TestDatabase.sharedRepo()
        let record = UnencodableRecord(amounts: [Cents(amount: 1)])
        await #expect(throws: SpectroError.self) { try await repo.insert(record) }
        await #expect(throws: SpectroError.self) { try await repo.insertAll([record]) }
        await #expect(throws: SpectroError.self) { try await repo.upsert(RegistryOwnerA.Item(), conflictTarget: .columns(["id"])) }
        await #expect(throws: SpectroError.self) { try await repo.insertAll([RegistryOwnerA.Item()]) }
    }

    @Test("Changeset casting converts external input to custom types")
    func casting() {
        let cs = Changeset<TypedArticle>.cast(nil, params: [
            "price": "12.50",
            "discount": 1.5,
            "status": "published",
            "tags": ["swift", "postgres"],
            "meta": ["views": 3, "editor": "ana"] as [String: any Sendable],
            "labels": ["tier": "gold"],
        ], permitted: ["price", "discount", "status", "tags", "meta", "labels"])

        #expect(cs.isValid)
        #expect(cs.changes["price"] as? Decimal == Decimal(string: "12.50"))
        #expect(cs.changes["discount"] as? Decimal == Decimal(string: "1.5"))
        #expect(cs.changes["status"] as? ArticleStatus == .published)
        #expect(cs.changes["tags"] as? [String] == ["swift", "postgres"])
        #expect(cs.changes["meta"] as? ArticleMeta == ArticleMeta(views: 3, editor: "ana"))
        #expect(cs.changes["labels"] as? [String: String] == ["tier": "gold"])

        let invalid = Changeset<TypedArticle>.cast(nil, params: [
            "price": "twelve", "status": "bogus", "tags": [1, 2], "meta": ["views": "many"] as [String: any Sendable], "discount": true,
        ], permitted: ["price", "status", "tags", "meta", "discount"])
        #expect(Set(invalid.errors.keys) == ["price", "status", "tags", "meta", "discount"])
    }

    @Test("Array filters bind the element and the array")
    func arrayConditions() {
        let tags = QueryField<[String]>(name: "tags", tableName: "typed_articles")
        #expect(tags.contains("swift").sql == #"? = ANY("typed_articles"."tags")"#)
        #expect(tags.containsAll(["a"]).sql == #""typed_articles"."tags" @> ?"#)
        #expect(tags.overlaps(["a"]).parameters.first?.type == .textArray)
        let scores = QueryField<[Int]?>(name: "scores", tableName: "typed_articles")
        #expect(scores.contains(3).parameters.first?.int == 3)
    }
}

extension DatabaseIntegrationTests {
@Suite("DatabaseValue column types", .serialized)
struct DatabaseValueIntegrationTests {
    private func withTable(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "typed_articles""#)
        try await repo.executeRawSQL(#"DROP TYPE IF EXISTS "article_mood""#)
        try await repo.executeRawSQL(#"CREATE TYPE "article_mood" AS ENUM ('calm', 'urgent')"#)
        try await repo.executeRawSQL("""
            CREATE TABLE "typed_articles" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                "price" NUMERIC(12, 2) NOT NULL,
                "discount" NUMERIC(5, 2),
                "status" TEXT NOT NULL,
                "mood" "article_mood" NOT NULL,
                "urgency" "article_mood",
                "tags" TEXT[] NOT NULL,
                "reviewer_ids" UUID[] NOT NULL,
                "scores" INTEGER[],
                "meta" JSONB NOT NULL,
                "labels" JSONB NOT NULL,
                "payload" BYTEA NOT NULL
            )
            """)
        try await body(repo)
    }

    private func article(price: String, status: ArticleStatus = .draft, mood: ArticleMood = .calm,
                         tags: [String] = [], reviewers: [UUID] = []) -> TypedArticle {
        TypedArticle(
            price: Decimal(string: price)!, status: status, mood: mood, tags: tags, reviewerIds: reviewers,
            meta: ArticleMeta(views: 7, editor: "ana"), labels: ["tier": "gold"], payload: Data([0, 1, 255])
        )
    }

    @Test("Every custom type round-trips through insert and get")
    func roundTrip() async throws {
        try await withTable { repo in
            let reviewer = UUID()
            var draft = article(price: "19.99", status: .published, mood: .urgent, tags: ["swift", "orm"], reviewers: [reviewer])
            draft.discount = Decimal(string: "2.50")
            draft.scores = [3, 5]
            let inserted = try await repo.insert(draft)

            let fetched = try #require(try await repo.get(TypedArticle.self, id: inserted.id))
            #expect(fetched.price == Decimal(string: "19.99"))
            #expect(fetched.discount == Decimal(string: "2.5"))
            #expect(fetched.status == .published)
            #expect(fetched.mood == .urgent)
            #expect(fetched.tags == ["swift", "orm"])
            #expect(fetched.reviewerIds == [reviewer])
            #expect(fetched.scores == [3, 5])
            #expect(fetched.meta == ArticleMeta(views: 7, editor: "ana"))
            #expect(fetched.labels == ["tier": "gold"])
            #expect(fetched.payload == Data([0, 1, 255]))
        }
    }

    @Test("NULL and empty values round-trip")
    func nullsAndEmpties() async throws {
        try await withTable { repo in
            var draft = article(price: "0")
            draft.labels = [:]
            draft.payload = Data()
            let inserted = try await repo.insert(draft)
            let fetched = try #require(try await repo.get(TypedArticle.self, id: inserted.id))
            #expect(fetched.discount == nil)
            #expect(fetched.scores == nil)
            #expect(fetched.tags == [])
            #expect(fetched.labels == [:])
            #expect(fetched.payload == Data())

            let updated = try await repo.update(TypedArticle.self, id: inserted.id, changes: [
                "discount": Decimal(string: "1.25")!, "scores": [1], "status": ArticleStatus.archived,
            ])
            #expect(updated.discount == Decimal(string: "1.25"))
            #expect(updated.scores == [1])
            #expect(updated.status == .archived)

            // NULL and values both fit a nullable PostgreSQL enum column.
            #expect(try await repo.query(TypedArticle.self).updateAll { [$0.urgency.set(.urgent)] } == 1)
            #expect(try await repo.get(TypedArticle.self, id: inserted.id)?.urgency == .urgent)
            #expect(try await repo.query(TypedArticle.self).updateAll { [$0.urgency.set(nil)] } == 1)
            #expect(try await repo.get(TypedArticle.self, id: inserted.id)?.urgency == nil)
        }
    }

    @Test("Filters compare decimals, enums, and arrays")
    func filters() async throws {
        try await withTable { repo in
            let reviewer = UUID()
            _ = try await repo.insert(article(price: "5.00", status: .draft, tags: ["swift"]))
            _ = try await repo.insert(article(price: "15.00", status: .published, mood: .urgent, tags: ["swift", "postgres"], reviewers: [reviewer]))
            _ = try await repo.insert(article(price: "25.00", status: .archived, tags: ["elixir"]))

            func prices(_ query: Query<TypedArticle>) async throws -> [Decimal] {
                try await query.orderBy { $0.price }.all().map(\.price)
            }
            let q = repo.query(TypedArticle.self)
            #expect(try await prices(q.where { $0.price > Decimal(10) }) == [15, 25])
            #expect(try await prices(q.where { $0.status == .published }) == [15])
            #expect(try await prices(q.where { $0.status.in([.draft, .archived]) }) == [5, 25])
            #expect(try await prices(q.where { $0.mood == .urgent }) == [15])
            #expect(try await prices(q.where { $0.tags.contains("swift") }) == [5, 15])
            #expect(try await prices(q.where { $0.tags.containsAll(["swift", "postgres"]) }) == [15])
            #expect(try await prices(q.where { $0.tags.overlaps(["elixir", "postgres"]) }) == [15, 25])
            #expect(try await prices(q.where { $0.reviewerIds.contains(reviewer) }) == [15])
            #expect(try await q.where { $0.price.between(Decimal(1), and: Decimal(20)) }.count() == 2)
        }
    }

    @Test("Selected custom columns decode, including NULL")
    func selection() async throws {
        try await withTable { repo in
            var withDiscount = article(price: "10.00")
            withDiscount.discount = 1
            _ = try await repo.insert(withDiscount)
            _ = try await repo.insert(article(price: "20.00"))

            let q = repo.query(TypedArticle.self).orderBy { $0.price }
            #expect(try await q.select { $0.price }.all() == [10, 20])
            #expect(try await q.select { $0.discount }.all() == [1, nil])
            let pairs = try await q.select { ($0.status, $0.tags) }.all()
            #expect(pairs.map(\._0) == [.draft, .draft])
            // Models decode from a subset of their columns; the others keep their defaults.
            let partial = try await q.selectFields { $0.price }.all()
            #expect(partial.map(\.price) == [10, 20])
            #expect(partial.allSatisfy { $0.tags.isEmpty })

            // Outside selectFields, a missing column is a decoding error.
            let row = try #require(try await repo.executeRawQuery(sql: #"SELECT "id", "price" FROM "typed_articles""#).first)
            await #expect(throws: SpectroError.self) { try await TypedArticle.from(row: row) }
        }
    }

    @Test("Changesets insert cast custom values")
    func changesetInsert() async throws {
        try await withTable { repo in
            let cs = Changeset<TypedArticle>.cast(nil, params: [
                "price": "12.5", "status": "published", "mood": "urgent", "tags": ["a"], "reviewerIds": [String](),
                "meta": ["views": 1] as [String: any Sendable], "labels": ["k": "v"], "payload": Data([9]),
            ], permitted: ["price", "status", "mood", "tags", "reviewerIds", "meta", "labels", "payload"])
            let inserted = try await repo.insert(cs)
            #expect(inserted.price == Decimal(string: "12.50"))
            #expect(inserted.status == .published)
            #expect(inserted.mood == .urgent)
            #expect(inserted.meta == ArticleMeta(views: 1, editor: nil))
        }
    }
}
}
