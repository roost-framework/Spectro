import Foundation
import Testing
@testable import Spectro

@Schema("join_authors")
private struct JoinAuthor {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
    @Column var note: String?
    @Timestamp var createdAt: Date
}

@Schema("join_articles")
private struct JoinArticle {
    @ID var id: UUID
    @ForeignKey var authorId: UUID
    @Column("display_name") var name: String = ""
    @Column var note: String?
    @Timestamp var createdAt: Date
}

// Deliberately disagrees with the real table's TEXT column.
@Schema("join_articles")
private struct MalformedJoinArticle {
    @ID var id: UUID
    @ForeignKey var authorId: UUID
    @Column("display_name") var name: Int = 0
}

extension DatabaseIntegrationTests {
    @Suite("Join decoding")
    struct JoinDecodingTests {
        private func withTables(_ body: (GenericDatabaseRepo, UUID, UUID) async throws -> Void) async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS join_authors (
                    id UUID PRIMARY KEY, display_name TEXT NOT NULL, note TEXT, created_at TIMESTAMPTZ NOT NULL
                )
                """)
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS join_articles (
                    id UUID PRIMARY KEY, author_id UUID NOT NULL, display_name TEXT NOT NULL, note TEXT,
                    created_at TIMESTAMPTZ NOT NULL
                )
                """)
            try await repo.executeRawSQL("TRUNCATE join_articles, join_authors")
            let authorID = UUID(), articleID = UUID()
            _ = try await repo.executeRawQuery(sql: """
                INSERT INTO join_authors VALUES ($1, 'Author', 'author note', '2020-01-01T00:00:00Z')
                """, parameters: [.init(uuid: authorID)])
            _ = try await repo.executeRawQuery(sql: """
                INSERT INTO join_articles VALUES ($1, $2, 'Article', NULL, '2021-01-01T00:00:00Z')
                """, parameters: [.init(uuid: articleID), .init(uuid: authorID)])
            try await body(repo, authorID, articleID)
        }

        @Test("Joined rows preserve separate IDs, custom columns, dates, and nulls")
        func overlappingColumns() async throws {
            try await withTables { repo, authorID, articleID in
                let pair = try #require(try await repo.query(JoinAuthor.self)
                    .join(JoinArticle.self, on: { $0.left.id == $0.right.authorId })
                    .executeJoin(with: JoinArticle.self).first())
                let article = try #require(pair.1)
                #expect(pair.0.id == authorID)
                #expect(article.id == articleID)
                #expect(article.authorId == authorID)
                #expect(pair.0.name == "Author")
                #expect(article.name == "Article")
                #expect(pair.0.note == "author note")
                #expect(article.note == nil)
                #expect(pair.0.createdAt == Date(timeIntervalSince1970: 1_577_836_800))
                #expect(article.createdAt == Date(timeIntervalSince1970: 1_609_459_200))
            }
        }

        @Test("Filters, ordering, selection, and join conditions use custom column names")
        func customColumnNames() async throws {
            try await withTables { repo, authorID, articleID in
                let authors = try await repo.query(JoinAuthor.self)
                    .where { $0.name == "Author" }.orderBy { $0.name }.all()
                #expect(authors.map(\.id) == [authorID])
                #expect(try await repo.query(JoinAuthor.self).select { $0.name }.all() == ["Author"])
                let pair = try await repo.query(JoinAuthor.self)
                    .join(JoinArticle.self, on: { $0.left.id == $0.right.authorId })
                    .executeJoin(with: JoinArticle.self)
                    .where { $0.joined.name == "Article" }.first()
                #expect(pair?.1?.id == articleID)
            }
        }

        @Test("An unmatched left join returns nil instead of a default model")
        func unmatchedLeftJoin() async throws {
            try await withTables { repo, authorID, _ in
                try await repo.executeRawSQL("DELETE FROM join_articles")
                let pairs = try await repo.query(JoinAuthor.self)
                    .leftJoinAndExecute(JoinArticle.self, on: { $0.left.id == $0.right.authorId })
                #expect(pairs.count == 1)
                #expect(pairs.first?.0.id == authorID)
                #expect(pairs.first?.1 == nil)
            }
        }

        @Test("A normal query with a join only decodes the main table")
        func mainOnly() async throws {
            try await withTables { repo, authorID, _ in
                let author = try #require(try await repo.query(JoinAuthor.self)
                    .join(JoinArticle.self, on: { $0.left.id == $0.right.authorId }).first())
                #expect(author.id == authorID)
                #expect(author.name == "Author")
                #expect(author.createdAt == Date(timeIntervalSince1970: 1_577_836_800))
            }
        }

        @Test("Present malformed joined data throws instead of becoming nil or defaults")
        func malformedJoinedRow() async throws {
            try await withTables { repo, _, _ in
                do {
                    _ = try await repo.query(JoinAuthor.self)
                        .joinAndExecute(MalformedJoinArticle.self, on: { $0.left.id == $0.right.authorId })
                    Issue.record("Expected a joined-column decoding error")
                } catch let error as SpectroError {
                    #expect(error.localizedDescription.contains("display_name"))
                }
            }
        }

        @Test("A matched row with a NULL required key is a decoding error")
        func nullJoinedKey() async throws {
            try await withTables { repo, _, _ in
                try await repo.executeRawSQL("ALTER TABLE join_articles DROP CONSTRAINT join_articles_pkey")
                try await repo.executeRawSQL("ALTER TABLE join_articles ALTER COLUMN id DROP NOT NULL")
                do {
                    try await repo.executeRawSQL("UPDATE join_articles SET id = NULL")
                    do {
                        _ = try await repo.query(JoinAuthor.self)
                            .leftJoinAndExecute(JoinArticle.self, on: { $0.left.id == $0.right.authorId })
                        Issue.record("Expected NULL required key to fail decoding")
                    } catch let error as SpectroError {
                        #expect(error.localizedDescription.contains("join_articles.id"))
                    }
                } catch {
                    try? await repo.executeRawSQL("DROP TABLE join_articles")
                    throw error
                }
                try await repo.executeRawSQL("DROP TABLE join_articles")
            }
        }

        @Test("Normal model queries reject right joins with absent main rows")
        func rightJoinModelContract() async throws {
            try await withTables { repo, _, _ in
                try await repo.executeRawSQL("DELETE FROM join_authors")
                do {
                    _ = try await repo.query(JoinAuthor.self)
                        .rightJoin(JoinArticle.self, on: { $0.left.id == $0.right.authorId }).all()
                    Issue.record("Expected unsupported model right join error")
                } catch let error as SpectroError {
                    #expect(error.localizedDescription.contains("right"))
                }
            }
        }

        @Test("Typed tuples reject right joins because the main model is nonoptional")
        func rightJoinContract() async throws {
            try await withTables { repo, _, _ in
                do {
                    _ = try repo.query(JoinAuthor.self)
                        .rightJoin(JoinArticle.self, on: { $0.left.id == $0.right.authorId })
                        .executeJoin(with: JoinArticle.self)
                    Issue.record("Expected unsupported typed right join error")
                } catch let error as SpectroError {
                    #expect(error.localizedDescription.contains("right"))
                }
            }
        }
    }
}
