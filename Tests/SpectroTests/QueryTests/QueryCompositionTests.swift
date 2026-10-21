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

    @Test("Projections select expressions, window functions, and grouped aggregates")
    func expressions() async throws {
        try await withLibrary { lib in
            let totals = lib.posts
                .groupBy { $0.compAuthorId }
                .having { .fragment("sum(\($0.views)) > \(100)") }
                .select { ($0.compAuthorId, $0.expression("sum(\($0.views))", as: Int.self), $0.expression("count(*) * \(10)", as: Int.self)) }
                .orderBy(sql: { "sum(\($0.views))" }, .desc)
            let rows = try await totals.all()
            #expect(rows.map(\._0) == [lib.ana.id, lib.bo.id])
            #expect(rows.map(\._1) == [310, 200])
            #expect(rows.map(\._2) == [20, 20])
            #expect(try await totals.count() == 2)
            #expect(try await totals.limit(1).all().map(\._1) == [310])
            let statement = try totals.statement()
            #expect(statement.parameters.map(\.int) == [10, 100])
            #expect(statement.sql.contains(#"(count(*) * $1) AS "spectro_select_2""#))
            #expect(statement.sql.contains(#"GROUP BY "comp_posts"."comp_author_id" HAVING (sum("comp_posts"."views") > $2)"#))

            let ranked = try await lib.posts
                .select { ($0.title, $0.expression("rank() OVER (PARTITION BY \($0.compAuthorId) ORDER BY \($0.views) DESC)", as: Int.self)) }
                .orderBy { $0.title }
                .all()
            #expect(ranked.map(\._1) == [2, 1, 1, 2])

            let wide = try await lib.posts
                .where { $0.title == "Cherry" }
                .select { ($0.title, $0.views, $0.likes, $0.compAuthorId, $0.editorId, $0.expression("\($0.views) + \($0.likes)", as: Int.self)) }
                .all()
            let row = try #require(wide.first)
            #expect(wide.count == 1)
            #expect(row.0 == "Cherry" && row.1 == 150 && row.2 == 150 && row.5 == 300)
            #expect(row.3 == lib.bo.id && row.4 == lib.ana.id)

            let none = try await lib.posts.where { $0.views > 1000 }.select { $0.expression("max(\($0.views))", as: Int?.self) }.all()
            #expect(none == [nil])
            let boosted = try await lib.posts.where { $0.likes > 100 }.select { $0.expression("\($0.views) + \(5)", as: Int.self) }.all()
            #expect(boosted == [155])

            let prolific = lib.posts.groupBy { $0.compAuthorId }.having { _ in .fragment("count(*) > \(1)") }.select { $0.compAuthorId }
            let names = try await lib.repo.query(CompAuthor.self).where { $0.id.in(prolific) }.orderBy { $0.name }.all().map(\.name)
            #expect(names == ["Ana", "Bo"])
        }
    }

    @Test("Lateral joins select rows for each row, and window filters keep ranked rows")
    func lateralAndQualify() async throws {
        try await withLibrary { lib in
            let authors = lib.repo.query(CompAuthor.self)
            let most = try await authors
                .joinLateral { author in lib.posts.where { $0.compAuthorId == author.id }.orderBy({ $0.views }, .desc).limit(1) }
                .orderBy { $0.name }
                .executeJoin(with: CompPost.self)
                .all()
            #expect(most.map { "\($0.0.name):\($0.1?.title ?? "")" } == ["Ana:Banana", "Bo:Cherry"])

            let best = try await authors
                .where { $0.name != "Bo" }
                .leftJoinLateral(as: "best") { author in lib.posts.where { $0.compAuthorId == author.id && $0.views > 100 }.limit(1) }
                .orderBy { $0.name }
                .executeJoin(with: CompPost.self, as: "best")
                .all()
            #expect(best.map(\.0.name) == ["Ana", "Cy"])
            #expect(best.map { $0.1?.title } == ["Banana", nil])

            let busy = authors
                .joinLateral { author in lib.posts.where { $0.compAuthorId == author.id } }
                .where { $0.table(CompPost.self).views == 300 }
            #expect(try await busy.count() == 1)
            let missing = authors.joinLateral { _ in lib.posts.where { $0.table(CompAuthor.self, as: "nobody").name == "Ana" } }
            await #expect(throws: SpectroError.self) { try await missing.all() }

            let top = lib.posts
                .where { $0.views > 20 }
                .qualify { "row_number() OVER (PARTITION BY \($0.compAuthorId) ORDER BY \($0.views) DESC) <= \(1)" }
                .orderBy { $0.title }
            #expect(try await top.all().map(\.title) == ["Banana", "Cherry"])
            #expect(try await top.count() == 2)
            #expect(try await top.limit(1).all().map(\.title) == ["Banana"])
        }
    }

    @Test("Distinct grouped aggregates keep their groups' ordering and limit, and composed queries reject locks and partial rows")
    func distinctGroupsAndComposedChecks() async throws {
        try await withLibrary { lib in
            let grouped = lib.posts.distinct().groupBy { $0.compAuthorId }
            #expect(try await grouped.orderBy { $0.compAuthorId }.limit(1).groupedCount().count == 1)
            #expect(try await grouped.orderBy(sql: { _ in "count(*)" }).groupedCount().count == 2)

            let locked = lib.posts.lock()
            await #expect(throws: SpectroError.self) { try await locked.union(lib.posts).all() }
            await #expect(throws: SpectroError.self) { try await lib.posts.selectFields { $0.title }.union(lib.posts).all() }
            await #expect(throws: SpectroError.self) { try await lib.posts.lock().recursive { $0.left.id == $0.right.id }.all() }

            var authors: [UUID] = []
            let joined = lib.repo.query(CompAuthor.self).join(CompPost.self) { $0.left.id == $0.right.compAuthorId }
            for try await batch in joined.batches(of: 1) { authors += batch.map(\.id) }
            #expect(authors.count == 2 && Set(authors) == [lib.ana.id, lib.bo.id])

            let edited = try await lib.posts.where { $0.editorId != $0.compAuthorId }.count()
            let editedReversed = try await lib.posts.where { $0.compAuthorId != $0.editorId }.count()
            #expect(edited == 2 && editedReversed == 2)
        }
    }

    @Test("Bulk writes go through distinct rows")
    func distinctWrites() async throws {
        try await withLibrary { lib in
            let ordered = lib.posts.distinct().orderBy { $0.title }
            #expect(try await ordered.updateAll { [$0.likes.increment(by: 1)] } == 4)
            #expect(try await ordered.limit(1).deleteAll() == 1)

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
