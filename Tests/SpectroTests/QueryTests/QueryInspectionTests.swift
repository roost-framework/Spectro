import Foundation
import PostgresNIO
import Testing
@testable import Spectro

@Schema("inspection_records")
private struct InspectionRecord {
    @ID var id: UUID
    @Column var name: String = ""
}

@Schema("inspection_details")
private struct InspectionDetail {
    @ID var id: UUID
    @ForeignKey var recordId: UUID
    @Column var name: String = ""
}

private actor InspectionExecutor: QueryExecutor {
    private(set) var calls: [(sql: String, parameters: [PostgresData])] = []

    func executeQuery<T: Sendable>(
        sql: String,
        parameters: [PostgresData],
        resultMapper: @Sendable @escaping (PostgresRow) throws -> T
    ) async throws -> [T] {
        calls.append((sql, parameters))
        return []
    }
}

private enum InspectionFailure: Error { case expected }

private actor FailingInspectionExecutor: QueryExecutor {
    private(set) var callCount = 0

    func executeQuery<T: Sendable>(
        sql: String,
        parameters: [PostgresData],
        resultMapper: @Sendable @escaping (PostgresRow) throws -> T
    ) async throws -> [T] {
        callCount += 1
        throw InspectionFailure.expected
    }
}

extension DatabaseIntegrationTests {
    @Suite("Query inspection")
    struct QueryInspectionTests {
        @Test("Statements preserve SQL and bind ordering across query forms")
        func statements() throws {
            let executor = InspectionExecutor()
            let base = Query(schema: InspectionRecord.self, executor: executor)
                .where { $0.name == "Alice" }
                .join(InspectionDetail.self, on: {
                    ($0.left.id == $0.right.recordId) && ($0.right.name == "visible")
                })

            let model = try base.statement()
            #expect(model.sql.contains("$1"))
            #expect(model.sql.contains("$2"))
            #expect(!model.sql.contains("Alice"))
            #expect(!model.sql.contains("visible"))
            #expect(model.parameters.map(\.string) == ["visible", "Alice"])

            let projection = try base.select { $0.name }.statement()
            #expect(projection.sql.hasPrefix("SELECT \"inspection_records\".\"name\""))
            #expect(projection.parameters.map(\.string) == ["visible", "Alice"])

            let joined = try base.executeJoin(with: InspectionDetail.self).statement()
            #expect(joined.sql.contains("__spectro_left_0"))
            #expect(joined.sql.contains("__spectro_right_0"))
            #expect(joined.parameters.map(\.string) == ["visible", "Alice"])
        }

        @Test("EXPLAIN and timed execution use the same binds and execute once")
        func executionBehavior() async throws {
            let executor = InspectionExecutor()
            let query = Query(schema: InspectionRecord.self, executor: executor)
                .where { $0.name == "private value" }
            let statement = try query.statement()
            #expect(await executor.calls.isEmpty)

            let lines = try await query.explain()
            #expect(lines.isEmpty)
            let measured = try await query.timedAll()
            #expect(measured.rows.isEmpty)
            #expect(measured.duration >= .zero)

            let calls = await executor.calls
            #expect(calls.count == 2)
            #expect(calls[0].sql == "EXPLAIN \(statement.sql)")
            #expect(calls[1].sql == statement.sql)
            #expect(calls[0].parameters.first?.string == "private value")
            #expect(calls[1].parameters.first?.string == "private value")
        }

        @Test("Timed execution propagates the original error after one attempt")
        func timedFailure() async throws {
            let executor = FailingInspectionExecutor()
            let query = Query(schema: InspectionRecord.self, executor: executor)
            do {
                _ = try await query.timedAll()
                Issue.record("Expected executor failure")
            } catch InspectionFailure.expected {
                #expect(await executor.callCount == 1)
            }
        }

        @Test("PostgreSQL returns a plan for a bound query in a transaction")
        func postgresPlanInTransaction() async throws {
            let repo = try await TestDatabase.sharedRepo()
            try await repo.executeRawSQL("""
                CREATE TABLE IF NOT EXISTS inspection_records (
                    id UUID PRIMARY KEY DEFAULT gen_random_uuid(), name TEXT NOT NULL
                )
                """)
            try await repo.executeRawSQL("TRUNCATE inspection_records")

            try await repo.transaction { transaction in
                _ = try await transaction.insert(InspectionRecord(name: "transaction row"))
                let query = transaction.query(InspectionRecord.self)
                    .where { $0.name == "transaction row" }
                let statement = try query.statement()
                #expect(statement.parameters.first?.string == "transaction row")
                let plan = try await query.explain()
                #expect(!plan.isEmpty)
                let measured = try await query.timedAll()
                #expect(measured.rows.map(\.name) == ["transaction row"])
            }
        }
    }
}
