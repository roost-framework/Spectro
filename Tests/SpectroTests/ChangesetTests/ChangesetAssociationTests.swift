import Foundation
import Testing
@testable import Spectro

@Schema("assoc_authors")
struct AssocAuthor {
    @ID var id: UUID
    @Column var name: String
    @Column var postCount: Int = 0
    @HasMany var assocPosts: [AssocPost]
    @HasOne var assocProfile: AssocProfile?
    @ManyToMany(junctionTable: "assoc_author_tags") var assocTags: [AssocTag]
}

@Schema("assoc_tags")
struct AssocTag {
    @ID var id: UUID
    @Column var name: String
}

@Schema("assoc_posts")
struct AssocPost {
    @ID var id: UUID
    @Column var title: String
    @ForeignKey var assocAuthorId: UUID
}

@Schema("assoc_profiles")
struct AssocProfile {
    @ID var id: UUID
    @Column var bio: String
    @ForeignKey var assocAuthorId: UUID
}

private struct Prepared: Error {}

extension DatabaseIntegrationTests {
@Suite("Changeset associations and preparations", .serialized)
struct ChangesetAssociationTests {
    private func withTables(_ body: (GenericDatabaseRepo) async throws -> Void) async throws {
        let repo = try await TestDatabase.sharedRepo()
        for table in ["assoc_author_tags", "assoc_tags", "assoc_profiles", "assoc_posts", "assoc_authors"] {
            try await repo.executeRawSQL("DROP TABLE IF EXISTS \(table.quoted)")
        }
        try await repo.executeRawSQL(#"CREATE TABLE "assoc_authors" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL, "post_count" INTEGER NOT NULL DEFAULT 0)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "assoc_posts" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "title" TEXT NOT NULL UNIQUE, "assoc_author_id" UUID NOT NULL REFERENCES "assoc_authors"("id"))"#)
        try await repo.executeRawSQL(#"CREATE TABLE "assoc_profiles" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "bio" TEXT NOT NULL, "assoc_author_id" UUID NOT NULL REFERENCES "assoc_authors"("id"))"#)
        try await repo.executeRawSQL(#"CREATE TABLE "assoc_tags" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL UNIQUE)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "assoc_author_tags" ("assoc_author_id" UUID NOT NULL REFERENCES "assoc_authors"("id"), "assoc_tag_id" UUID NOT NULL REFERENCES "assoc_tags"("id"), PRIMARY KEY ("assoc_author_id", "assoc_tag_id"))"#)
        try await body(repo)
    }

    private func post(_ post: AssocPost?, _ params: [String: any Sendable]) -> Changeset<AssocPost> {
        Changeset.cast(post, params: params, permitted: ["title"]).validateRequired(["title"])
    }

    private func profile(_ profile: AssocProfile?, _ params: [String: any Sendable]) -> Changeset<AssocProfile> {
        Changeset.cast(profile, params: params, permitted: ["bio"])
    }

    @Test("An insert writes cast records with their foreign key, and returns them loaded")
    func insert() async throws {
        try await withTables { repo in
            let changeset = Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                .castAssoc(\.$assocPosts, params: [["title": "One"], ["title": "Two"]], with: post)
                .castAssoc(\.$assocProfile, params: ["bio": "Hi"], with: profile)
            let author = try await repo.insert(changeset)
            #expect(author.assocPosts.map(\.title) == ["One", "Two"])
            #expect(author.assocPosts.allSatisfy { $0.assocAuthorId == author.id })
            #expect(author.assocProfile?.bio == "Hi")
            #expect(try await repo.query(AssocPost.self).where { $0.assocAuthorId == author.id }.count() == 2)
        }
    }

    @Test("Invalid records invalidate the changeset, and a failed write rolls back the record")
    func failures() async throws {
        try await withTables { repo in
            let invalid = Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                .castAssoc(\.$assocPosts, params: [["title": "One"], ["title": ""]], with: post)
            #expect(!invalid.isValid)
            #expect(invalid.errors["assocPosts[1].title"] == ["can't be blank"])
            await #expect(throws: SpectroError.self) { try await repo.insert(invalid) }

            let duplicate = Changeset<AssocAuthor>.cast(nil, params: ["name": "Bo"], permitted: ["name"])
                .castAssoc(\.$assocPosts, params: [["title": "Same"], ["title": "Same"]], with: post)
            await #expect(throws: SpectroError.self) { try await repo.insert(duplicate) }
            #expect(try await repo.query(AssocAuthor.self).count() == 0)

            let unloaded = try await repo.insert(AssocAuthor(name: "Cy", postCount: 0))
            let notPreloaded = Changeset.cast(unloaded, params: [:], permitted: [])
                .castAssoc(\.$assocPosts, params: [], with: post)
            #expect(notPreloaded.errors["assocPosts"] == ["must be preloaded before casting"])
        }
    }

    @Test("An update changes, inserts, and replaces the loaded records")
    func update() async throws {
        try await withTables { repo in
            let created = try await repo.insert(
                Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                    .castAssoc(\.$assocPosts, params: [["title": "Keep"], ["title": "Drop"]], with: post)
                    .castAssoc(\.$assocProfile, params: ["bio": "Old"], with: profile)
            )
            let author = try await repo.query(AssocAuthor.self).where { $0.id == created.id }
                .preload(\.$assocPosts).preload(\.$assocProfile).first()!
            let keep = try #require(author.assocPosts.first { $0.title == "Keep" })
            let params: [[String: any Sendable]] = [["id": keep.id.uuidString, "title": "Kept"], ["title": "New"]]

            let strict = Changeset.cast(author, params: [:], permitted: []).castAssoc(\.$assocPosts, params: params, with: post)
            #expect(strict.errors["assocPosts"] == ["is invalid"])

            let updated = try await repo.update(
                Changeset.cast(author, params: ["name": "Ana M"], permitted: ["name"])
                    .castAssoc(\.$assocPosts, params: params, onReplace: .delete, with: post)
                    .castAssoc(\.$assocProfile, params: ["bio": "New"], with: profile)
            )
            #expect(updated.name == "Ana M")
            #expect(updated.assocPosts.map(\.title) == ["Kept", "New"])
            #expect(updated.assocPosts.first?.id == keep.id)
            #expect(updated.assocProfile?.bio == "New")
            let titles = try await repo.query(AssocPost.self).orderBy { $0.title }.all().map(\.title)
            #expect(titles == ["Kept", "New"])

            let reloaded = try await repo.query(AssocAuthor.self).where { $0.id == created.id }.preload(\.$assocProfile).first()!
            let withoutProfile = try await repo.update(
                Changeset.cast(reloaded, params: [:], permitted: []).castAssoc(\.$assocProfile, params: nil, onReplace: .delete, with: profile)
            )
            #expect(withoutProfile.assocProfile == nil)
            #expect(try await repo.query(AssocProfile.self).count() == 0)
        }
    }

    @Test("Association writes stay atomic in a caller's transaction, and has-one params with another key replace the record")
    func atomicityAndReplacement() async throws {
        try await withTables { repo in
            let created = try await repo.insert(
                Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                    .castAssoc(\.$assocPosts, params: [["title": "Gone"]], with: post)
                    .castAssoc(\.$assocProfile, params: ["bio": "Old"], with: profile)
            )
            let author = try await repo.query(AssocAuthor.self).where { $0.id == created.id }
                .preload(\.$assocPosts).preload(\.$assocProfile).first()!
            let gone = try #require(author.assocPosts.first)
            try await repo.delete(AssocPost.self, id: gone.id)

            let changeset = Changeset.cast(author, params: ["name": "Renamed"], permitted: ["name"])
                .castAssoc(\.$assocPosts, params: [["title": "Added"], ["id": gone.id.uuidString, "title": "Edited"]], with: post)
            try await repo.transaction { tx in
                do { _ = try await tx.update(changeset) } catch {}
            }
            #expect(try await repo.reload(author)?.name == "Ana")
            #expect(try await repo.query(AssocPost.self).count() == 0)

            let replaced = try await repo.update(
                Changeset.cast(author, params: [:], permitted: [])
                    .castAssoc(\.$assocProfile, params: ["id": UUID().uuidString, "bio": "Fresh"], onReplace: .delete, with: profile)
            )
            #expect(replaced.assocProfile?.bio == "Fresh")
            #expect(replaced.assocProfile?.id != author.assocProfile?.id)
            #expect(try await repo.query(AssocProfile.self).count() == 1)

            let belongsTo = Changeset<NestBook>.cast(nil, params: [:], permitted: [])
                .castAssoc(\.$nestAuthor, params: [:], with: { author, params in Changeset.cast(author, params: params, permitted: ["name"]) })
            #expect(belongsTo.errors["nestAuthor"] == ["is not a has-one relationship"])
        }
    }

    private func tag(_ tag: AssocTag?, _ params: [String: any Sendable]) -> Changeset<AssocTag> {
        Changeset.cast(tag, params: params, permitted: ["name"]).validateRequired(["name"])
    }

    private func tagNames(of author: AssocAuthor, in repo: GenericDatabaseRepo) async throws -> [String] {
        let loaded = try await repo.query(AssocAuthor.self).where { $0.id == author.id }.preload(\.$assocTags).first()
        return (loaded?.assocTags.map(\.name) ?? []).sorted()
    }

    @Test("Many-to-many casts insert records and join rows, and puts link and unlink stored records")
    func manyToMany() async throws {
        try await withTables { repo in
            let created = try await repo.insert(
                Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                    .castAssoc(\.$assocTags, params: [["name": "swift"], ["name": "sql"]], with: tag)
            )
            #expect(created.assocTags.map(\.name) == ["swift", "sql"])
            #expect(try await tagNames(of: created, in: repo) == ["sql", "swift"])

            let elixir = try await repo.insert(AssocTag(name: "elixir"))
            let author = try await repo.query(AssocAuthor.self).where { $0.id == created.id }.preload(\.$assocTags).first()!
            let sql = try #require(author.assocTags.first { $0.name == "sql" })

            let strict = Changeset.cast(author, params: [:], permitted: []).putAssoc(\.$assocTags, [sql, elixir])
            #expect(strict.errors["assocTags"] == ["is invalid"])

            let updated = try await repo.update(
                Changeset.cast(author, params: [:], permitted: []).putAssoc(\.$assocTags, [sql, elixir], onReplace: .delete)
            )
            #expect(updated.assocTags.map(\.name) == ["sql", "elixir"])
            #expect(try await tagNames(of: author, in: repo) == ["elixir", "sql"])
            // Replacing a many-to-many record deletes its join row, not the record.
            #expect(try await repo.query(AssocTag.self).count() == 3)

            let reloaded = try await repo.query(AssocAuthor.self).where { $0.id == created.id }.preload(\.$assocTags).first()!
            let edited = try await repo.update(
                Changeset.cast(reloaded, params: [:], permitted: [])
                    .putAssoc(\.$assocTags, [tag(sql, ["name": "postgres"]), tag(nil, ["name": "new"])], onReplace: .delete)
            )
            #expect(edited.assocTags.map(\.name) == ["postgres", "new"])
            #expect(try await tagNames(of: author, in: repo) == ["new", "postgres"])

            let invalid = Changeset.cast(reloaded, params: [:], permitted: [])
                .putAssoc(\.$assocTags, [tag(nil, ["name": ""])], onReplace: .delete)
            #expect(invalid.errors["assocTags[0].name"] == ["can't be blank"])
        }
    }

    @Test("Has-many and has-one puts move stored records and insert changesets")
    func puts() async throws {
        try await withTables { repo in
            let ana = try await repo.insert(AssocAuthor(name: "Ana", postCount: 0))
            let bo = try await repo.insert(AssocAuthor(name: "Bo", postCount: 0))
            let moved = try await repo.insert(AssocPost(title: "Moved", assocAuthorId: bo.id))

            let author = try await repo.query(AssocAuthor.self).where { $0.id == ana.id }
                .preload(\.$assocPosts).preload(\.$assocProfile).first()!
            let updated = try await repo.update(
                Changeset.cast(author, params: [:], permitted: [])
                    .putAssoc(\.$assocPosts, [moved])
                    .putAssoc(\.$assocProfile, profile(nil, ["bio": "Hi"]))
            )
            #expect(updated.assocPosts.map(\.assocAuthorId) == [ana.id])
            #expect(try await repo.reload(moved)?.assocAuthorId == ana.id)
            #expect(updated.assocProfile?.bio == "Hi")

            let withProfile = try await repo.query(AssocAuthor.self).where { $0.id == ana.id }.preload(\.$assocProfile).first()!
            let strict = Changeset.cast(withProfile, params: [:], permitted: []).putAssoc(\.$assocProfile, nil as AssocProfile?)
            #expect(strict.errors["assocProfile"] == ["is invalid"])
            let cleared = try await repo.update(
                Changeset.cast(withProfile, params: [:], permitted: []).putAssoc(\.$assocProfile, nil as AssocProfile?, onReplace: .delete)
            )
            #expect(cleared.assocProfile == nil)
            #expect(try await repo.query(AssocProfile.self).count() == 0)
        }
    }

    @Test("Preparations run in the write's transaction, and not for an invalid changeset")
    func preparations() async throws {
        try await withTables { repo in
            let counted = Changeset<AssocAuthor>.cast(nil, params: ["name": "Ana"], permitted: ["name"])
                .prepareChanges { changeset, tx in
                    let existing = try await tx.query(AssocAuthor.self).count()
                    return changeset.putChange("postCount", value: existing + 10)
                }
            let author = try await repo.insert(counted)
            #expect(author.postCount == 10)

            let invalid = Changeset<AssocAuthor>.cast(nil, params: ["name": ""], permitted: ["name"])
                .validateRequired(["name"])
                .prepareChanges { _, _ in throw Prepared() }
            do {
                _ = try await repo.insert(invalid)
                Issue.record("An invalid changeset was inserted")
            } catch let error as SpectroError {
                guard case .validationError = error else { throw error }
            }

            let failing = Changeset.cast(author, params: ["name": "Bo"], permitted: ["name"])
                .prepareChanges { changeset, tx in
                    _ = try await tx.insert(AssocPost(title: "Audit", assocAuthorId: author.id))
                    throw Prepared()
                }
            await #expect(throws: (any Error).self) { try await repo.update(failing) }
            #expect(try await repo.query(AssocPost.self).count() == 0)
            #expect(try await repo.reload(author)?.name == "Ana")
        }
    }
}
}
