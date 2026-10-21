import Foundation
import Testing
@testable import Spectro

@Schema("comp_authors")
struct CompAuthor {
    @ID var id: UUID
    @Column var name: String
}

@Schema("comp_posts")
struct CompPost {
    @ID var id: UUID
    @Column var title: String
    @Column var views: Int
    @Column var likes: Int
    @ForeignKey var compAuthorId: UUID
    @Column var editorId: UUID?
}

@Schema("comp_comments")
struct CompComment {
    @ID var id: UUID
    @ForeignKey var compPostId: UUID
    @Column var body: String
}

@Schema("comp_categories")
struct CompCategory {
    @ID var id: UUID
    @Column var name: String
    @Column var parentId: UUID?
    @SoftDelete var deletedAt: Date?
}

extension DatabaseIntegrationTests {
@Suite("Query composition", .serialized)
struct QueryCompositionTests {
    private struct Library {
        let repo: GenericDatabaseRepo
        let ana: CompAuthor
        let bo: CompAuthor
        var posts: Query<CompPost> { repo.query(CompPost.self) }
    }

    private func withLibrary(_ body: (Library) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        for table in ["comp_comments", "comp_posts", "comp_authors"] {
            try await repo.executeRawSQL("DROP TABLE IF EXISTS \(table.quoted)")
        }
        try await repo.executeRawSQL(#"CREATE TABLE "comp_authors" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL("""
            CREATE TABLE "comp_posts" (
                "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "title" TEXT NOT NULL,
                "views" INTEGER NOT NULL, "likes" INTEGER NOT NULL,
                "comp_author_id" UUID NOT NULL, "editor_id" UUID
            )
            """)
        try await repo.executeRawSQL(#"CREATE TABLE "comp_comments" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "comp_post_id" UUID NOT NULL, "body" TEXT NOT NULL)"#)

        let ana = try await repo.insert(CompAuthor(name: "Ana"))
        let bo = try await repo.insert(CompAuthor(name: "Bo"))
        _ = try await repo.insert(CompAuthor(name: "Cy"))
        let apple = try await repo.insert(CompPost(title: "Apple", views: 10, likes: 20, compAuthorId: ana.id, editorId: bo.id))
        _ = try await repo.insert(CompPost(title: "Banana", views: 300, likes: 5, compAuthorId: ana.id))
        let cherry = try await repo.insert(CompPost(title: "Cherry", views: 150, likes: 150, compAuthorId: bo.id, editorId: ana.id))
        _ = try await repo.insert(CompPost(title: "Date", views: 50, likes: 60, compAuthorId: bo.id))
        for (post, body) in [(apple, "great"), (apple, "great too"), (cherry, "ok")] {
            _ = try await repo.insert(CompComment(compPostId: post.id, body: body))
        }
        try await body(Library(repo: repo, ana: ana, bo: bo))
    }

    @Test("Distinct removes join duplicates, and distinct on keeps each group's first row")
    func distinct() async throws {
        try await withLibrary { lib in
            let commented = lib.posts.join(CompComment.self) { $0.left.id == $0.right.compPostId }
            #expect(try await commented.count() == 3)
            #expect(try await commented.distinct().count() == 2)
            #expect(try await commented.distinct().orderBy { $0.title }.all().map(\.title) == ["Apple", "Cherry"])

            let top = lib.posts.distinct { $0.compAuthorId }.orderBy({ $0.views }, .desc)
            let statement = try top.statement()
            #expect(statement.sql.contains(#"SELECT DISTINCT ON ("comp_posts"."comp_author_id") * FROM"#))
            #expect(statement.sql.hasSuffix(#"ORDER BY "comp_posts"."comp_author_id" ASC, "comp_posts"."views" DESC"#))
            #expect(Set(try await top.all().map(\.title)) == ["Banana", "Cherry"])
            #expect(try await top.count() == 2)
            #expect(try await top.sum { $0.views } == 450)
            #expect(try await top.limit(1).exists())

            // An ordering that starts with the distinct column keeps its direction.
            let descending = lib.posts.distinct { $0.compAuthorId }
                .orderBy({ $0.compAuthorId }, .desc)
                .orderBy({ $0.views }, .desc)
            #expect(try descending.statement().sql.hasSuffix(#"ORDER BY "comp_posts"."comp_author_id" DESC, "comp_posts"."views" DESC"#))
            #expect(try await descending.all().count == 2)

            let authors = lib.posts.select { $0.compAuthorId }.distinct()
            #expect(try await authors.count() == 2)
            #expect(Set(try await authors.all()) == [lib.ana.id, lib.bo.id])
        }
    }

    @Test("Set operations combine queries that keep their own clauses, under the result's clauses")
    func setOperations() async throws {
        try await withLibrary { lib in
            let popular = lib.posts.where { $0.views > 100 }
            let anas = lib.posts.where { $0.compAuthorId == lib.ana.id }

            #expect(try await popular.union(anas).orderBy { $0.title }.all().map(\.title) == ["Apple", "Banana", "Cherry"])
            #expect(try await popular.unionAll(anas).count() == 4)
            #expect(try await popular.intersect(anas).all().map(\.title) == ["Banana"])
            #expect(try await popular.intersectAll(anas).count() == 1)
            #expect(try await popular.except(anas).all().map(\.title) == ["Cherry"])
            #expect(try await popular.exceptAll(anas).count() == 1)
            #expect(try await popular.union(anas).union(lib.posts.where { $0.title == "Date" }).count() == 4)

            let liked = popular.union(anas)
                .where { $0.likes > 10 }
                .orderBy(sql: { "\($0.views) * \(-1)" })
            #expect(try await liked.all().map(\.title) == ["Cherry", "Apple"])
            #expect(try await liked.limit(1).all().map(\.title) == ["Cherry"])
            #expect(try await liked.count() == 2)
            #expect(try await liked.sum { $0.views } == 160)
            let statement = try liked.statement()
            #expect(statement.parameters.map(\.int) == [100, nil, 10, -1])
            #expect(statement.sql.contains(#"("comp_posts"."likes" > $3) ORDER BY "comp_posts"."views" * $4 ASC"#))

            let extremes = lib.posts.orderBy({ $0.views }, .desc).limit(1)
                .union(lib.posts.orderBy { $0.views }.limit(1))
                .orderBy { $0.views }
            #expect(try await extremes.all().map(\.title) == ["Apple", "Banana"])

            let bos = try await popular.union(anas)
                .join(CompAuthor.self) { $0.left.compAuthorId == $0.right.id }
                .where { $0.table(CompAuthor.self).name == "Bo" }
                .all()
            #expect(bos.map(\.title) == ["Cherry"])

            #expect(try await popular.union(anas).updateAll { [$0.likes.increment(by: 1)] } == 3)
            #expect(try await lib.posts.where { $0.title == "Date" }.first()?.likes == 60)

            let invalid = lib.posts.join(CompAuthor.self, as: "not valid") { $0.left.compAuthorId == $0.right.id }
            await #expect(throws: SpectroError.self) { try await invalid.union(anas).all() }
        }
    }

    @Test("Exists and subqueries filter on other tables' rows, correlated or not")
    func subqueries() async throws {
        try await withLibrary { lib in
            let comments = lib.repo.query(CompComment.self)
            let commented = try await lib.posts
                .where { post in .exists(comments.where { $0.compPostId == post.id }) }
                .orderBy { $0.title }
                .all()
            #expect(commented.map(\.title) == ["Apple", "Cherry"])

            let silent = try await lib.posts
                .where { post in !.exists(comments.where { $0.compPostId == post.id }) }
                .orderBy { $0.title }
                .all()
            #expect(silent.map(\.title) == ["Banana", "Date"])

            let okayed = try await lib.posts
                .where { $0.views > 100 }
                .where { post in .exists(comments.where { $0.compPostId == post.id && $0.body == "ok" }) }
                .where { $0.likes > 1 }
                .all()
            #expect(okayed.map(\.title) == ["Cherry"])

            #expect(try await lib.posts.where { $0.views > 100 }.exists())
            #expect(try await !lib.posts.where { $0.views > 1000 }.exists())
            #expect(try await lib.posts.join(CompComment.self) { $0.left.id == $0.right.compPostId }.distinct().orderBy { $0.title }.exists())
            #expect(try await lib.posts.orderBy { $0.title }.offset(3).exists())
            #expect(try await !lib.posts.orderBy { $0.title }.offset(4).exists())

            let authors = lib.repo.query(CompAuthor.self).orderBy { $0.name }
            let popularAuthors = lib.posts.where { $0.views > 200 }.select { $0.compAuthorId }
            #expect(try await authors.where { $0.id.in(popularAuthors) }.all().map(\.name) == ["Ana"])
            #expect(try await authors.where { $0.id.notIn(popularAuthors) }.all().map(\.name) == ["Bo", "Cy"])

            // Nullable columns on either side.
            let editors = lib.posts.select { $0.editorId }
            #expect(try await authors.where { $0.id.in(editors) }.all().map(\.name) == ["Ana", "Bo"])
            #expect(try await authors.where { $0.id.notIn(editors) }.all().isEmpty)
            #expect(try await authors.where { $0.id.notIn(editors.where { $0.editorId.isNotNull() }) }.all().map(\.name) == ["Cy"])
            let bo = lib.repo.query(CompAuthor.self).where { $0.name == "Bo" }.select { $0.id }
            #expect(try await lib.posts.where { $0.editorId.in(bo) }.all().map(\.title) == ["Apple"])
            #expect(try await lib.posts.where { $0.editorId.notIn(bo) }.all().map(\.title) == ["Cherry"])
        }
    }

    @Test("Columns compare with columns")
    func columnComparisons() async throws {
        try await withLibrary { lib in
            func titles(_ condition: (QueryBuilder<CompPost>) -> QueryCondition) async throws -> [String] {
                try await lib.posts.where(condition).orderBy { $0.title }.all().map(\.title)
            }
            let greater = try await titles { $0.likes > $0.views }
            let greaterOrEqual = try await titles { $0.likes >= $0.views }
            let less = try await titles { $0.likes < $0.views }
            let lessOrEqual = try await titles { $0.likes <= $0.views }
            let equal = try await titles { $0.likes == $0.views }
            let different = try await titles { $0.likes != $0.views }
            let edited = try await titles { $0.editorId == $0.compAuthorId }
            let editedReversed = try await titles { $0.compAuthorId == $0.editorId }
            #expect(greater == ["Apple", "Date"])
            #expect(greaterOrEqual == ["Apple", "Cherry", "Date"])
            #expect(less == ["Banana"])
            #expect(lessOrEqual == ["Banana", "Cherry"])
            #expect(equal == ["Cherry"])
            #expect(different.count == 3)
            #expect(edited.isEmpty && editedReversed.isEmpty)
        }
    }

    @Test("Bulk writes go through distinct rows")
    func distinctWrites() async throws {
        try await withLibrary { lib in
            let top = lib.posts.distinct { $0.compAuthorId }.orderBy({ $0.views }, .desc)
            let updated = try await top.updateAll { [$0.title.set(sql: "\($0.title) || \("!")")] }
            let titles = try await lib.posts.where { $0.title.endsWith("!") }.orderBy { $0.title }.all().map(\.title)
            #expect(updated == 2)
            #expect(titles == ["Banana!", "Cherry!"])
        }
    }

    @Test("Recursive queries follow a tree down or up, skip soft-deleted rows, and stop on cycles")
    func recursive() async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "comp_categories""#)
        try await repo.executeRawSQL(#"CREATE TABLE "comp_categories" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL, "parent_id" UUID, "deleted_at" TIMESTAMPTZ)"#)
        func add(_ name: String, under parent: CompCategory?) async throws -> CompCategory {
            try await repo.insert(CompCategory(name: name, parentId: parent?.id))
        }
        let root = try await add("R", under: nil)
        let a = try await add("A", under: root)
        _ = try await add("B", under: root)
        let a1 = try await add("A1", under: a)
        let a2 = try await add("A2", under: a1)
        _ = try await add("A3", under: a2)
        try await repo.delete(CompCategory.self, id: a2.id)
        let x = try await add("X", under: nil)
        let y = try await add("Y", under: x)
        _ = try await repo.update(CompCategory.self, id: x.id, changes: ["parentId": y.id])

        let categories = repo.query(CompCategory.self)
        let subtree = categories.where { $0.id == root.id }.recursive { $0.left.parentId == $0.right.id }
        #expect(try await subtree.orderBy { $0.name }.all().map(\.name) == ["A", "A1", "B", "R"])
        #expect(try await subtree.where { $0.name != "R" }.count() == 3)
        #expect(try await categories.withDeleted().where { $0.id == root.id }.recursive { $0.left.parentId == $0.right.id }.count() == 6)

        let ancestors = categories.where { $0.id == a1.id }.recursive { $0.left.id == $0.right.parentId }
        #expect(try await ancestors.orderBy { $0.name }.all().map(\.name) == ["A", "A1", "R"])

        #expect(try await categories.where { $0.id == x.id }.recursive { $0.left.parentId == $0.right.id }.count() == 2)

        let firstBranch = categories.where { $0.parentId == root.id }.orderBy { $0.name }.limit(1)
            .recursive { $0.left.parentId == $0.right.id }
            .orderBy { $0.name }
        #expect(try await firstBranch.all().map(\.name) == ["A", "A1"])
        #expect(try await firstBranch.where { $0.name == "A1" }.exists())
    }
}
}
