import Foundation
import Testing
import PostgresKit
@testable import Spectro

@Schema("column_authors")
private struct ColumnAuthor {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
    @Column var emailAddress: String = ""
    @ForeignKey var teamId: UUID
    @ForeignKey("org_ref") var organizationId: UUID
    @Timestamp var createdAt: Date
    @SoftDelete var removedAtUTC: Date?
    @HasMany var posts: [ColumnPost]
}

@Schema("column_posts")
private struct ColumnPost {
    @ID var id: UUID
    @ForeignKey var columnAuthorId: UUID
}

@Suite("Schema column names")
struct SchemaColumnTests {
    private actor Recorder: QueryExecutor {
        var statements: [String] = []

        func executeQuery<T: Sendable>(
            sql: String, parameters: [PostgresData],
            resultMapper: @Sendable @escaping (PostgresRow) throws -> T
        ) async throws -> [T] {
            statements.append(sql)
            return []
        }
    }

    @Test("Schema macro key paths resolve to database columns, including overrides")
    func macroColumns() {
        #expect(ColumnAuthor.column(for: \.id) == "id")
        #expect(ColumnAuthor.column(for: \.emailAddress) == "email_address")
        #expect(ColumnAuthor.column(for: \.name) == "display_name")
        #expect(ColumnAuthor.column(for: \.teamId) == "team_id")
        #expect(ColumnAuthor.column(for: \.organizationId) == "org_ref")
        #expect(ColumnAuthor.column(for: \.createdAt) == "created_at")
        #expect(ColumnAuthor.column(for: \.removedAtUTC) == "removed_at_utc")
        #expect(ColumnAuthor.column(for: \.removedAtUTC) == ColumnAuthor.softDeleteColumn)
    }

    @Test("Manual schemas resolve property names to columns")
    func manualColumns() {
        #expect(SoftUser.column(for: \.deletedAt) == "deleted_at")
        #expect(SoftUser.column(for: \.deletedAt) == SoftUser.softDeleteColumn)
        #expect(TestUser.column(for: \.isActive) == "is_active")
        #expect(TestUser.column(for: \.createdAt) == "created_at")
    }

    @Test("A relationship key path returns its snake_cased property name")
    func relationshipKeyPath() {
        #expect(ColumnAuthor.column(for: \.$posts) == "posts")
    }

    @Test("Columns match the SQL Query emits for the same key paths")
    func matchesQuerySQL() async throws {
        let recorder = Recorder()
        _ = try await Query(schema: ColumnAuthor.self, executor: recorder)
            .where { $0.emailAddress == "ada@test.com" && $0.teamId == UUID() }
            .all()
        let sql = try #require(await recorder.statements.first)
        #expect(sql.contains("\"\(ColumnAuthor.column(for: \.emailAddress))\" = $1"))
        #expect(sql.contains("\"\(ColumnAuthor.column(for: \.teamId))\" = $2"))
    }
}
