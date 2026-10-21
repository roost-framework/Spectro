import Foundation
import Testing
@testable import Spectro

@Schema("fk_squads")
struct Squad {
    @ID var id: UUID
    @Column var name: String
    @HasMany var recruits: [Recruit]
}

@Schema("fk_recruits")
struct Recruit {
    @ID var id: UUID
    @Column var name: String
    @ForeignKey var squadId: UUID?
    @BelongsTo var squad: Squad?
}

extension DatabaseIntegrationTests {
@Suite("Optional foreign keys", .serialized)
struct OptionalForeignKeyTests {
    @Test("A nullable foreign key stores, filters, updates, and preloads both ways")
    func nullable() async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "fk_recruits""#)
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "fk_squads""#)
        try await repo.executeRawSQL(#"CREATE TABLE "fk_squads" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL)"#)
        try await repo.executeRawSQL(#"CREATE TABLE "fk_recruits" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "name" TEXT NOT NULL, "squad_id" UUID REFERENCES "fk_squads"("id"))"#)

        let metadata = await SchemaRegistry.shared.register(Recruit.self)
        let field = try #require(metadata.fields.first { $0.name == "squadId" })
        #expect(field.isForeignKey && field.isNullable)

        let squad = try await repo.insert(Squad(name: "Red"))
        let ana = try await repo.insert(Recruit(name: "Ana", squadId: squad.id))
        let bo = try await repo.insert(Recruit(name: "Bo"))
        #expect(ana.squadId == squad.id)
        #expect(bo.squadId == nil)
        #expect(Recruit().squadId == nil)

        let unassigned = try await repo.query(Recruit.self).where { $0.squadId.isNull() }.all()
        #expect(unassigned.map(\.name) == ["Bo"])
        let assigned = try await repo.query(Recruit.self).where { $0.squadId == squad.id }.all()
        #expect(assigned.map(\.name) == ["Ana"])

        let recruits = try await repo.query(Recruit.self).orderBy { $0.name }.preload(\.$squad).all()
        #expect(recruits.map { $0.squad?.name } == ["Red", nil])
        let squads = try await repo.query(Squad.self).preload(\.$recruits).all()
        #expect(squads.first?.recruits.map(\.name) == ["Ana"])

        let moved = try await repo.update(Recruit.self, id: bo.id, changes: ["squadId": squad.id])
        #expect(moved.squadId == squad.id)
        let removed = try await repo.update(Recruit.self, id: ana.id, changes: ["squadId": UUID?.none])
        #expect(removed.squadId == nil)
        #expect(try await repo.reload(ana)?.squadId == nil)
    }
}
}
