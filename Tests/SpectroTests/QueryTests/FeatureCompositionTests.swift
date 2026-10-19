import Foundation
import Testing
import Spectro

@Schema("feature_composition_accounts")
private struct CompositionAccount {
    @ID var id: UUID
    @Column("email_address") var email: String = ""
    @Column var managerId: UUID?
    @SoftDelete var deletedAt: Date?
}

extension DatabaseIntegrationTests {
    @Suite("Feature composition")
    struct FeatureCompositionTests {
        @Test("Constraint recovery, aliased joins and inspection share the transaction")
        func transactionComposition() async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS feature_composition_accounts (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    email_address TEXT NOT NULL,
                    manager_id UUID REFERENCES feature_composition_accounts(id),
                    deleted_at TIMESTAMPTZ,
                    CONSTRAINT composition_email_key UNIQUE (email_address)
                )
                """)
            try await repo.executeRawSQL("TRUNCATE feature_composition_accounts")

            try await repo.transaction { transaction in
                let tx = try #require(transaction as? TransactionRepo)
                let manager = try await tx.insert(Changeset<CompositionAccount>.cast(nil,
                    params: ["email": "manager@example.test"], permitted: ["email"]))
                let changeset = Changeset<CompositionAccount>.cast(nil,
                    params: ["email": "worker@example.test", "managerId": manager.id],
                    permitted: ["email", "managerId"])
                    .uniqueConstraint("email", name: "composition_email_key", message: "already used")
                let worker = try await tx.insert(changeset)

                do {
                    try await tx.savepoint { sp -> Void in
                        _ = try await sp.insert(changeset)
                    }
                    Issue.record("Expected the duplicate email to fail")
                } catch let error as SpectroError {
                    #expect(error.fieldErrors?.errors == ["email": ["already used"]])
                    #expect(error.serverError?.sqlState == "23505")
                }

                let base = tx.query(CompositionAccount.self)
                    .where { $0.email == "worker@example.test" }
                    .leftJoin(CompositionAccount.self, as: "manager", on: {
                        $0.left.managerId == $0.right.id && $0.right.email == "manager@example.test"
                    })
                let joined = try base.executeJoin(with: CompositionAccount.self, as: "manager")
                let statement = try joined.statement()
                #expect(statement.sql.contains("\"manager\".\"email_address\""))
                #expect(!statement.sql.contains("@example.test"))
                #expect(statement.parameters.map(\.string) == ["manager@example.test", "worker@example.test"])
                #expect(try await joined.explain().isEmpty == false)
                let measured = try await joined.timedAll()
                #expect(measured.rows.count == 1)
                #expect(measured.rows.first?.0.id == worker.id)
                #expect(measured.rows.first?.1?.id == manager.id)
                #expect(measured.duration >= .zero)

                let projection = base.select { $0.email }
                #expect(try await projection.explain().isEmpty == false)
                #expect(try await projection.timedAll().rows == ["worker@example.test"])

                try await tx.delete(CompositionAccount.self, id: manager.id)
                let hidden = try await joined.timedAll()
                #expect(hidden.rows.count == 1)
                #expect(hidden.rows.first?.1 == nil)
                let includingDeleted = try base.withDeleted()
                    .executeJoin(with: CompositionAccount.self, as: "manager")
                #expect(try await includingDeleted.timedAll().rows.first?.1?.id == manager.id)
            }
            #expect(try await repo.query(CompositionAccount.self).count() == 1)
            #expect(try await repo.query(CompositionAccount.self).withDeleted().count() == 2)
        }
    }
}
