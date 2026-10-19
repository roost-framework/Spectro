import Foundation
import Testing
import PostgresKit
@testable import Spectro

private protocol ConstraintErrorParsing {
    static func parse(from buffer: inout ByteBuffer) throws -> Self
}

extension PostgresMessage.Error: ConstraintErrorParsing {}

private func parseConstraintMessage<Message: ConstraintErrorParsing>(
    _: Message.Type, from buffer: inout ByteBuffer
) throws -> Message {
    try Message.parse(from: &buffer)
}

private func syntheticConstraintError(
    sqlState: String, constraintName: String, tableName: String? = "changeset_constraint_children"
) throws -> SpectroError {
    var buffer = ByteBuffer()
    var fields: [(PostgresMessage.Error.Field, String)] = [
        (PostgresMessage.Error.Field.severity, "ERROR"),
        (.sqlState, sqlState),
        (.message, "constraint violation"),
        (.constraintName, constraintName),
    ]
    if let tableName { fields.append((.tableName, tableName)) }
    for (field, value) in fields {
        buffer.writeInteger(field.rawValue)
        buffer.writeNullTerminatedString(value)
    }
    let response = try parseConstraintMessage(PostgresMessage.Error.self, from: &buffer)
    return .queryExecutionFailed(sql: "INSERT", error: PostgresError.server(response))
}

@Schema("changeset_constraint_parents")
private struct ConstraintParent {
    @ID var id: UUID
    @Column var name: String
}

@Schema("changeset_constraint_children")
private struct ConstraintChild {
    @ID var id: UUID
    @Column("display_name") var name: String = ""
    @Column var parentId: UUID
    @Column var amount: Int
}

@Schema("changeset_constraint_origin_source")
private struct ConstraintOriginSource {
    @ID var id: UUID
    @Column var amount: Int
}

@Schema("changeset_constraint_partitioned")
private struct ConstraintPartitioned {
    @ID var id: UUID
    @Column var amount: Int
    @Column var bucket: Int
}

extension DatabaseIntegrationTests {
    @Suite("Changeset database constraints")
    struct ChangesetConstraintTests: Sendable {
        private func repoWithTables() async throws -> GenericDatabaseRepo {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_parents (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL
                )
                """)
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_children (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
                    display_name TEXT NOT NULL,
                    parent_id UUID NOT NULL,
                    amount INT NOT NULL,
                    CONSTRAINT changeset_children_name_key UNIQUE (display_name),
                    CONSTRAINT changeset_children_parent_fkey FOREIGN KEY (parent_id)
                        REFERENCES changeset_constraint_parents (id),
                    CONSTRAINT changeset_children_amount_check CHECK (amount >= 0)
                )
                """)
            return repo
        }

        private func child(
            _ name: String, parentId: UUID, amount: Int = 1
        ) -> Changeset<ConstraintChild> {
            Changeset.cast(nil,
                params: ["name": name, "parentId": parentId, "amount": amount],
                permitted: ["name", "parentId", "amount"])
        }

        private func constraintError(
            _ work: () async throws -> Void
        ) async -> SpectroError? {
            do {
                try await work()
                Issue.record("Expected a constraint violation")
            } catch let error as SpectroError {
                return error
            } catch {
                Issue.record("Expected SpectroError, got \(error)")
            }
            return nil
        }

        @Test("Local validation still reports validationError")
        func localValidation() {
            let changeset = Changeset<ConstraintChild>.cast(nil,
                params: ["name": ""], permitted: ["name"])
                .validateRequired(["name"])
                .uniqueConstraint("name", name: "changeset_children_name_key")
            do {
                _ = try changeset.applyChanges()
                Issue.record("Expected local validation to fail")
            } catch let error as SpectroError {
                if case .validationError = error {} else {
                    Issue.record("Expected validationError")
                }
                #expect(error.fieldErrors == nil)
                #expect(changeset.errorPayload.errors == ["name": ["can't be blank"]])
            } catch {
                Issue.record("Expected SpectroError")
            }
        }

        @Test("A composite constraint maps every declared field once")
        func compositeConstraint() throws {
            let changeset = Changeset<ConstraintChild>.cast(nil,
                params: [:], permitted: [])
                .uniqueConstraint("name", name: "children_composite_key")
                .uniqueConstraint("parentId", name: "children_composite_key", message: "is already paired")
                .uniqueConstraint("name", name: "children_composite_key")
            let original = try syntheticConstraintError(
                sqlState: "23505", constraintName: "children_composite_key")
            let error = try #require(changeset.constraintFailure(for: original))
            #expect(error.fieldErrors?.errors == [
                "name": ["has already been taken"],
                "parentId": ["is already paired"],
            ])
            #expect(error.serverError?.constraintName == "children_composite_key")
        }

        @Test("Constraint mapping fails closed when PostgreSQL omits the origin table")
        func missingConstraintOrigin() throws {
            let changeset = Changeset<ConstraintChild>.cast(nil, params: [:], permitted: [])
                .checkConstraint("amount", name: "changeset_children_amount_check")
            let original = try syntheticConstraintError(
                sqlState: "23514", constraintName: "changeset_children_amount_check", tableName: nil)
            #expect(changeset.constraintFailure(for: original) == nil)
        }

        @Test("A trigger constraint on another table is never mapped to the changeset")
        func triggerConstraintOrigin() async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_origin_source (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), amount INT NOT NULL,
                    CONSTRAINT shared_origin_amount_check CHECK (amount >= 0)
                )
                """)
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_origin_audit (
                    id UUID PRIMARY KEY, amount INT NOT NULL,
                    CONSTRAINT shared_origin_amount_check CHECK (amount > 0)
                )
                """)
            try await repo.executeRawSQL("""
                CREATE OR REPLACE FUNCTION changeset_constraint_origin_trigger()
                RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN
                    IF NEW.amount = 0 THEN
                        INSERT INTO changeset_constraint_origin_audit (id, amount)
                        VALUES (NEW.id, NEW.amount);
                    END IF;
                    RETURN NEW;
                END;
                $$
                """)
            try await repo.executeRawSQL("DROP TRIGGER IF EXISTS changeset_origin_trigger ON changeset_constraint_origin_source")
            try await repo.executeRawSQL("""
                CREATE TRIGGER changeset_origin_trigger
                BEFORE INSERT OR UPDATE ON changeset_constraint_origin_source
                FOR EACH ROW EXECUTE FUNCTION changeset_constraint_origin_trigger()
                """)

            let existing = try await repo.insert(Changeset<ConstraintOriginSource>.cast(nil,
                params: ["amount": 1], permitted: ["amount"]))
            for inTransaction in [false, true] {
                let insert = Changeset<ConstraintOriginSource>.cast(nil,
                    params: ["amount": 0], permitted: ["amount"])
                    .checkConstraint("amount", name: "shared_origin_amount_check")
                let insertError = await constraintError {
                    if inTransaction {
                        try await repo.transaction { tx -> Void in _ = try await tx.insert(insert) }
                    } else {
                        _ = try await repo.insert(insert)
                    }
                }
                #expect(insertError?.fieldErrors == nil)
                #expect(insertError?.serverError?.tableName == "changeset_constraint_origin_audit")
                #expect(insertError?.serverError?.constraintName == "shared_origin_amount_check")

                let update = Changeset.cast(existing,
                    params: ["amount": 0], permitted: ["amount"])
                    .checkConstraint("amount", name: "shared_origin_amount_check")
                let updateError = await constraintError {
                    if inTransaction {
                        try await repo.transaction { tx -> Void in _ = try await tx.update(update) }
                    } else {
                        _ = try await repo.update(update)
                    }
                }
                #expect(updateError?.fieldErrors == nil)
                #expect(updateError?.serverError?.tableName == "changeset_constraint_origin_audit")
                #expect(updateError?.serverError?.constraintName == "shared_origin_amount_check")

                let ownInsert = Changeset<ConstraintOriginSource>.cast(nil,
                    params: ["amount": -1], permitted: ["amount"])
                    .checkConstraint("amount", name: "shared_origin_amount_check")
                let ownError = await constraintError {
                    if inTransaction {
                        try await repo.transaction { tx -> Void in _ = try await tx.insert(ownInsert) }
                    } else {
                        _ = try await repo.insert(ownInsert)
                    }
                }
                #expect(ownError?.fieldErrors?.errors == ["amount": ["is invalid"]])
                #expect(ownError?.serverError?.tableName == "changeset_constraint_origin_source")
            }
        }

        @Test("A partition leaf can be declared as the physical constraint origin")
        func partitionConstraintOrigin() async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_partitioned (
                    id UUID DEFAULT gen_random_uuid(), amount INT NOT NULL, bucket INT NOT NULL,
                    CONSTRAINT partition_amount_check CHECK (amount > 0)
                ) PARTITION BY LIST (bucket)
                """)
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS changeset_constraint_partitioned_one
                PARTITION OF changeset_constraint_partitioned FOR VALUES IN (1)
                """)
            let base = Changeset<ConstraintPartitioned>.cast(nil,
                params: ["amount": -1, "bucket": 1], permitted: ["amount", "bucket"])
            let implicit = await constraintError {
                _ = try await repo.insert(base.checkConstraint("amount", name: "partition_amount_check"))
            }
            #expect(implicit?.serverError?.tableName == "changeset_constraint_partitioned_one")
            #expect(implicit?.fieldErrors == nil)

            let explicit = await constraintError {
                _ = try await repo.insert(base.checkConstraint("amount", name: "partition_amount_check",
                    onTable: "changeset_constraint_partitioned_one"))
            }
            #expect(explicit?.fieldErrors?.errors == ["amount": ["is invalid"]])
            #expect(explicit?.serverError?.tableName == "changeset_constraint_partitioned_one")
        }

        @Test("Unique insert maps an exact index name to the schema field")
        func uniqueInsert() async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let name = "unique-\(UUID())"
            _ = try await repo.insert(child(name, parentId: parent.id))
            let error = await constraintError {
                _ = try await repo.insert(child(name, parentId: parent.id)
                    .uniqueConstraint("name", name: "changeset_children_name_key", message: "already used"))
            }
            #expect(error?.fieldErrors?.errors == ["name": ["already used"]])
            #expect(error?.serverError?.sqlState == "23505")
            #expect(error?.serverError?.constraintName == "changeset_children_name_key")
            if case .changesetFailed(_, let underlying)? = error {
                #expect(underlying is SpectroError)
            } else {
                Issue.record("Expected changesetFailed")
            }
        }

        @Test("Unique update maps a custom database column to its schema field", arguments: [false, true])
        func uniqueUpdate(inTransaction: Bool) async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let taken = "taken-\(UUID())"
            _ = try await repo.insert(child(taken, parentId: parent.id))
            let second = try await repo.insert(child("other-\(UUID())", parentId: parent.id))
            let changeset = Changeset.cast(second, params: ["name": taken], permitted: ["name"])
                .uniqueConstraint("name", name: "changeset_children_name_key")
            let error = await constraintError {
                if inTransaction {
                    try await repo.transaction { tx -> Void in
                        _ = try await tx.update(changeset)
                    }
                } else {
                    _ = try await repo.update(changeset)
                }
            }
            #expect(error?.fieldErrors?.errors == ["name": ["has already been taken"]])
            #expect(error?.serverError?.sqlState == "23505")
        }

        @Test("Foreign key and check violations map to declared fields")
        func foreignKeyAndCheck() async throws {
            let repo = try await repoWithTables()
            let missingParent = await constraintError {
                _ = try await repo.insert(child("orphan-\(UUID())", parentId: UUID())
                    .foreignKeyConstraint("parentId", name: "changeset_children_parent_fkey"))
            }
            #expect(missingParent?.fieldErrors?.errors == ["parentId": ["does not exist"]])
            #expect(missingParent?.serverError?.sqlState == "23503")

            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let negative = await constraintError {
                _ = try await repo.insert(child("negative-\(UUID())", parentId: parent.id, amount: -1)
                    .checkConstraint("amount", name: "changeset_children_amount_check", message: "must be positive"))
            }
            #expect(negative?.fieldErrors?.errors == ["amount": ["must be positive"]])
            #expect(negative?.serverError?.sqlState == "23514")
        }

        @Test("Foreign key and check declarations also map update failures")
        func foreignKeyAndCheckUpdates() async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let existing = try await repo.insert(child("updates-\(UUID())", parentId: parent.id))

            let missingParent = await constraintError {
                _ = try await repo.update(Changeset.cast(existing,
                    params: ["parentId": UUID()], permitted: ["parentId"])
                    .foreignKeyConstraint("parentId", name: "changeset_children_parent_fkey"))
            }
            #expect(missingParent?.fieldErrors?.errors == ["parentId": ["does not exist"]])
            #expect(missingParent?.serverError?.sqlState == "23503")

            let negative = await constraintError {
                _ = try await repo.update(Changeset.cast(existing,
                    params: ["amount": -1], permitted: ["amount"])
                    .checkConstraint("amount", name: "changeset_children_amount_check"))
            }
            #expect(negative?.fieldErrors?.errors == ["amount": ["is invalid"]])
            #expect(negative?.serverError?.sqlState == "23514")
        }

        @Test("Unregistered name or wrong SQLSTATE preserves the original database error")
        func unmatchedDeclarations() async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let name = "unmatched-\(UUID())"
            _ = try await repo.insert(child(name, parentId: parent.id))
            let wrongName = await constraintError {
                _ = try await repo.insert(child(name, parentId: parent.id)
                    .uniqueConstraint("name", name: "some_other_index"))
            }
            let wrongState = await constraintError {
                _ = try await repo.insert(child(name, parentId: parent.id)
                    .checkConstraint("name", name: "changeset_children_name_key"))
            }
            for error in [wrongName, wrongState] {
                #expect(error?.fieldErrors == nil)
                #expect(error?.serverError?.sqlState == "23505")
                if case .queryExecutionFailed? = error {} else {
                    Issue.record("Expected original queryExecutionFailed, got \(String(describing: error))")
                }
            }
        }

        @Test("A declaration targeting an unknown schema field fails before SQL")
        func unknownField() async throws {
            let repo = try await repoWithTables()
            let error = await constraintError {
                _ = try await repo.insert(child("unknown-\(UUID())", parentId: UUID())
                    .uniqueConstraint("display_name", name: "changeset_children_name_key"))
            }
            if case .invalidField(_, let field)? = error {
                #expect(field == "display_name")
            } else {
                Issue.record("Expected invalidField")
            }
        }

        @Test("A savepoint restores a transaction after mapped constraint failure")
        func savepointRecovery() async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let taken = "tx-taken-\(UUID())"
            let kept = "tx-kept-\(UUID())"
            try await repo.transaction { transaction in
                let tx = try #require(transaction as? TransactionRepo)
                _ = try await tx.insert(self.child(taken, parentId: parent.id))
                do {
                    try await tx.savepoint { sp -> Void in
                        _ = try await sp.insert(self.child(taken, parentId: parent.id)
                            .uniqueConstraint("name", name: "changeset_children_name_key"))
                    }
                    Issue.record("Expected a mapped constraint violation")
                } catch let error as SpectroError {
                    #expect(error.fieldErrors?.errors == ["name": ["has already been taken"]])
                    #expect(error.serverError?.sqlState == "23505")
                }
                _ = try await tx.insert(self.child(kept, parentId: parent.id))
            }
            let all = try await repo.all(ConstraintChild.self)
            #expect(all.contains { $0.name == kept })
        }

        @Test("Mapped field errors survive transaction wrapping")
        func transactionWrapper() async throws {
            let repo = try await repoWithTables()
            let parent = try await repo.insert(ConstraintParent(name: "parent-\(UUID())"))
            let name = "wrapped-\(UUID())"
            _ = try await repo.insert(child(name, parentId: parent.id))
            let error = await constraintError {
                try await repo.transaction { transaction in
                    _ = try await transaction.insert(self.child(name, parentId: parent.id)
                        .uniqueConstraint("name", name: "changeset_children_name_key"))
                }
            }
            #expect(error?.fieldErrors?.errors == ["name": ["has already been taken"]])
            #expect(error?.serverError?.sqlState == "23505")
            if case .transactionFailed? = error {} else {
                Issue.record("Expected transactionFailed wrapper")
            }
        }
    }
}
