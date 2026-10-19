import Foundation
import Testing
@testable import Spectro

@Schema("alias_join_people")
private struct AliasJoinPerson {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
    @Column var managerId: UUID?
    @SoftDelete var deletedAt: Date?
}

@Schema("alias_join_other")
private struct AliasJoinOther {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
}

extension DatabaseIntegrationTests {
    @Suite("Aliased joins")
    struct AliasJoinTests {
        @Test("Original join method references remain source compatible")
        func originalMethodReferences() async throws {
            let repo = try await TestDatabase.sharedRepo()
            let base = repo.query(AliasJoinPerson.self)
            typealias Condition = (JoinBuilder<AliasJoinPerson, AliasJoinOther>) -> QueryCondition
            typealias JoinedRows = [(AliasJoinPerson, AliasJoinOther?)]

            let join: (AliasJoinOther.Type, Condition) -> Query<AliasJoinPerson> = base.join(_:on:)
            let leftJoin: (AliasJoinOther.Type, Condition) -> Query<AliasJoinPerson> = base.leftJoin(_:on:)
            let rightJoin: (AliasJoinOther.Type, Condition) -> Query<AliasJoinPerson> = base.rightJoin(_:on:)
            let condition: Condition = { $0.left.id == $0.right.id }
            let joined = join(AliasJoinOther.self, condition)
            #expect(try joined.statement().sql.contains("INNER JOIN"))
            #expect(try leftJoin(AliasJoinOther.self, condition).statement().sql.contains("LEFT JOIN"))
            #expect(throws: SpectroError.self) {
                try rightJoin(AliasJoinOther.self, condition).statement()
            }

            let executeJoin: (AliasJoinOther.Type) throws -> JoinQuery<AliasJoinPerson, AliasJoinOther> = joined.executeJoin(with:)
            _ = try executeJoin(AliasJoinOther.self)

            let joinAndExecute: (AliasJoinOther.Type, Condition) async throws -> JoinedRows = base.joinAndExecute(_:on:)
            let leftJoinAndExecute: (AliasJoinOther.Type, Condition) async throws -> JoinedRows = base.leftJoinAndExecute(_:on:)
            _ = joinAndExecute
            _ = leftJoinAndExecute
        }

        @Test("Self joins and repeated aliases decode the selected occurrence")
        func selfAndRepeatedJoins() async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS alias_join_people (
                    id UUID PRIMARY KEY, display_name TEXT NOT NULL,
                    manager_id UUID, deleted_at TIMESTAMPTZ
                )
                """)
            try await repo.executeRawSQL("TRUNCATE alias_join_people")

            let chief = UUID(), manager = UUID(), worker = UUID(), independent = UUID()
            _ = try await repo.executeRawQuery(sql: """
                INSERT INTO alias_join_people (id, display_name, manager_id) VALUES
                ($1, 'Chief', NULL), ($2, 'Manager', $1),
                ($3, 'Worker', $2), ($4, 'Independent', NULL)
                """, parameters: [.init(uuid: chief), .init(uuid: manager), .init(uuid: worker), .init(uuid: independent)])

            let pair = try #require(try await repo.query(AliasJoinPerson.self)
                .where { $0.name == "Worker" }
                .join(AliasJoinPerson.self, as: "manager", on: {
                    $0.left.managerId == $0.right.id && $0.right.name == "Manager"
                })
                .executeJoin(with: AliasJoinPerson.self, as: "manager")
                .where { $0.joined.name == "Manager" }
                .first())
            #expect(pair.0.id == worker)
            #expect(pair.1?.id == manager)
            #expect(pair.1?.name == "Manager")

            let grandparent = try #require(try await repo.query(AliasJoinPerson.self)
                .where { $0.name == "Worker" }
                .join(AliasJoinPerson.self, as: "manager", on: { $0.left.managerId == $0.right.id })
                .join(AliasJoinPerson.self, as: "grandmanager", on: {
                    $0.table(AliasJoinPerson.self, as: "manager").managerId == $0.right.id
                })
                .executeJoin(with: AliasJoinPerson.self, as: "grandmanager")
                .first())
            #expect(grandparent.0.id == worker)
            #expect(grandparent.1?.id == chief)

            let missing = try #require(try await repo.query(AliasJoinPerson.self)
                .where { $0.name == "Independent" }
                .leftJoin(AliasJoinPerson.self, as: "manager", on: { $0.left.managerId == $0.right.id })
                .executeJoin(with: AliasJoinPerson.self, as: "manager")
                .first())
            #expect(missing.1 == nil)

            try await repo.executeRawSQL("UPDATE alias_join_people SET deleted_at = NOW() WHERE display_name = 'Chief'")
            let hidden = try await repo.query(AliasJoinPerson.self)
                .where { $0.name == "Worker" }
                .join(AliasJoinPerson.self, as: "manager", on: { $0.left.managerId == $0.right.id })
                .leftJoin(AliasJoinPerson.self, as: "grandmanager", on: {
                    $0.table(AliasJoinPerson.self, as: "manager").managerId == $0.right.id
                })
                .executeJoin(with: AliasJoinPerson.self, as: "grandmanager")
                .first()
            #expect(hidden?.1 == nil)

            let visible = try await repo.query(AliasJoinPerson.self)
                .withDeleted()
                .where { $0.name == "Worker" }
                .join(AliasJoinPerson.self, as: "manager", on: { $0.left.managerId == $0.right.id })
                .join(AliasJoinPerson.self, as: "grandmanager", on: {
                    $0.table(AliasJoinPerson.self, as: "manager").managerId == $0.right.id
                })
                .executeJoin(with: AliasJoinPerson.self, as: "grandmanager")
                .first()
            #expect(visible?.1?.id == chief)

            let transactional = try await repo.transaction { tx in
                try await tx.query(AliasJoinPerson.self)
                    .where { $0.name == "Worker" }
                    .join(AliasJoinPerson.self, as: "manager", on: { $0.left.managerId == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "manager")
                    .first()
            }
            #expect(transactional?.1?.id == manager)
        }

        @Test("Invalid, duplicate, ambiguous, and missing aliases fail before SQL execution")
        func invalidAliases() async throws {
            let repo = try await TestDatabase.sharedRepo()
            let base = repo.query(AliasJoinPerson.self)

            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "bad alias", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "bad alias")
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self)
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "manager")
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .join(AliasJoinPerson.self, as: "grandmanager", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self)
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "missing")
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: {
                    $0.table(AliasJoinPerson.self, as: "missing").id == $0.right.id
                }).executeJoin(with: AliasJoinPerson.self, as: "manager")
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: {
                    $0.table(AliasJoinOther.self, as: "manager").id == $0.right.id
                }).executeJoin(with: AliasJoinPerson.self, as: "manager")
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "manager")
                    .where { $0.table(AliasJoinOther.self, as: "manager").name == "Manager" }
                    .inspectionContext()
            }
            #expect(throws: SpectroError.self) {
                try base.join(AliasJoinPerson.self, as: "manager", on: { $0.left.id == $0.right.id })
                    .executeJoin(with: AliasJoinPerson.self, as: "manager")
                    .orderBy { $0.table(AliasJoinOther.self, as: "manager").name }
                    .inspectionContext()
            }
        }
    }
}
