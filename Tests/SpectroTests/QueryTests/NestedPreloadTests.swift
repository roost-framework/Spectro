import Foundation
import Testing
@testable import Spectro

@Schema("nest_authors")
struct NestAuthor {
    @ID var id: UUID
    @Column var name: String
    @HasMany var books: [NestBook]
    @ManyToMany(junctionTable: "nest_author_genres") var genres: [NestGenre]
}

@Schema("nest_editors")
struct NestEditor {
    @ID var id: UUID
    @Column var name: String
}

@Schema("nest_books")
struct NestBook {
    @ID var id: UUID
    @Column var title: String
    @Column var year: Int
    @ForeignKey var nestAuthorId: UUID
    @Column var nestEditorId: UUID?
    @BelongsTo var nestAuthor: NestAuthor?
    @BelongsTo var nestEditor: NestEditor?
    @HasMany var chapters: [NestChapter]
}

@Schema("nest_chapters")
struct NestChapter {
    @ID var id: UUID
    @Column var number: Int
    @ForeignKey var nestBookId: UUID
}

@Schema("nest_genres")
struct NestGenre {
    @ID var id: UUID
    @Column var name: String
}

@Schema("nest_author_genres")
struct NestAuthorGenre {
    @ID var id: UUID
    @ForeignKey var nestAuthorId: UUID
    @ForeignKey var nestGenreId: UUID
}

extension DatabaseIntegrationTests {
@Suite("Nested and customized preloads", .serialized)
struct NestedPreloadTests {
    private func withLibrary(_ body: (GenericDatabaseRepo, NestEditor) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        for table in ["nest_author_genres", "nest_genres", "nest_chapters", "nest_books", "nest_editors", "nest_authors"] {
            try await repo.executeRawSQL("DROP TABLE IF EXISTS \(table.quoted)")
        }
        try await repo.executeRawSQL(#"CREATE TABLE "nest_authors" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "nest_editors" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL("""
            CREATE TABLE "nest_books" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "title" TEXT NOT NULL, "year" INTEGER NOT NULL,
                "nest_author_id" UUID NOT NULL, "nest_editor_id" UUID
            )
            """)
        try await repo.executeRawSQL(#"CREATE TABLE "nest_chapters" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "number" INTEGER NOT NULL, "nest_book_id" UUID NOT NULL)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "nest_genres" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "nest_author_genres" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "nest_author_id" UUID NOT NULL, "nest_genre_id" UUID NOT NULL)"#)

        let editor = try await repo.insert(NestEditor(name: "Eve"))
        let ana = try await repo.insert(NestAuthor(name: "Ana"))
        let bo = try await repo.insert(NestAuthor(name: "Bo"))
        let old = try await repo.insert(NestBook(title: "Old", year: 1990, nestAuthorId: ana.id, nestEditorId: editor.id))
        let new = try await repo.insert(NestBook(title: "New", year: 2020, nestAuthorId: ana.id))
        _ = try await repo.insert(NestBook(title: "Mid", year: 2005, nestAuthorId: bo.id))
        for number in [2, 1] { _ = try await repo.insert(NestChapter(number: number, nestBookId: old.id)) }
        _ = try await repo.insert(NestChapter(number: 1, nestBookId: new.id))
        let essay = try await repo.insert(NestGenre(name: "essay"))
        let poetry = try await repo.insert(NestGenre(name: "poetry"))
        let crime = try await repo.insert(NestGenre(name: "crime"))
        for (author, genre) in [(ana, essay), (ana, poetry), (ana, crime), (bo, crime)] {
            _ = try await repo.insert(NestAuthorGenre(nestAuthorId: author.id, nestGenreId: genre.id))
        }
        try await body(repo, editor)
    }

    @Test("Preloads nest through customized queries")
    func nested() async throws {
        try await withLibrary { repo, _ in
            let authors = try await repo.query(NestAuthor.self)
                .orderBy { $0.name }
                .preload(\.$books) { books in
                    books.orderBy { $0.year }.preload(\.$chapters) { $0.orderBy { $0.number } }
                }
                .all()

            #expect(authors.map(\.name) == ["Ana", "Bo"])
            #expect(authors[0].books.map(\.title) == ["Old", "New"])
            #expect(authors[0].books[0].chapters.map(\.number) == [1, 2])
            #expect(authors[0].books[1].chapters.map(\.number) == [1])
            #expect(authors[1].books.map(\.title) == ["Mid"])
            #expect(authors[1].books[0].$chapters.isLoaded)
            #expect(authors[1].books[0].chapters.isEmpty)
        }
    }

    @Test("Customized preloads filter related records and order many-to-many results")
    func filteredAndOrdered() async throws {
        try await withLibrary { repo, _ in
            let authors = try await repo.query(NestAuthor.self)
                .orderBy { $0.name }
                .preload(\.$books) { $0.where { $0.year > 2000 } }
                .preload(\.$genres) { $0.orderBy({ $0.name }, .desc) }
                .all()
            #expect(authors[0].books.map(\.title) == ["New"])
            #expect(authors[1].books.map(\.title) == ["Mid"])
            #expect(authors[0].genres.map(\.name) == ["poetry", "essay", "crime"])
            #expect(authors[1].genres.map(\.name) == ["crime"])
        }
    }

    @Test("Belongs-to preloads through a nullable foreign key column, and nest upward")
    func nullableBelongsTo() async throws {
        try await withLibrary { repo, editor in
            let books = try await repo.query(NestBook.self)
                .orderBy { $0.year }
                .preload(\.$nestEditor)
                .preload(\.$nestAuthor) { $0.preload(\.$genres) }
                .all()
            #expect(books.map { $0.nestEditor?.name } == ["Eve", nil, nil])
            #expect(books[0].nestEditor?.id == editor.id)
            #expect(books.map { $0.nestAuthor?.name } == ["Ana", "Bo", "Ana"])
            #expect(books[1].nestAuthor?.genres.map(\.name) == ["crime"])
        }
    }

    @Test("Repo.preload loads relationships of records already fetched, also in transactions")
    func repoPreload() async throws {
        try await withLibrary { repo, _ in
            let authors = try await repo.query(NestAuthor.self).orderBy { $0.name }.all()
            #expect(!authors[0].$books.isLoaded)

            let loaded = try await repo.preload(authors, \.$books) { $0.orderBy { $0.year } }
            #expect(loaded.map { $0.books.map(\.title) } == [["Old", "New"], ["Mid"]])

            let one = try await repo.preload(authors[1], \.$genres)
            #expect(one.genres.map(\.name) == ["crime"])

            let titles = try await repo.transaction { tx in
                let book = try #require(try await tx.query(NestBook.self).where { $0.title == "Old" }.first())
                let withEditor = try await tx.preload(book, \.$nestEditor)
                return withEditor.nestEditor?.name
            }
            #expect(titles == "Eve")

            // A foreign key given as a database column groups like its property.
            let byColumn = try await repo.query(NestAuthor.self).orderBy { $0.name }
                .preload(\.$books, foreignKey: "nest_author_id").all()
            #expect(byColumn.map(\.books.count) == [2, 1])
            #expect(try await repo.preload([NestAuthor](), \.$books).isEmpty)
        }
    }
}
}
