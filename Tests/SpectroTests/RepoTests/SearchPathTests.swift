import Foundation
import Testing
@testable import Spectro

@Schema("tenant_notes")
struct TenantNote {
    @ID var id: UUID
    @Column var body: String
}

extension DatabaseIntegrationTests {
@Suite("Schemas through search_path", .serialized)
struct SearchPathTests {
    @Test("SET LOCAL search_path points a transaction's statements at a tenant schema")
    func tenantSchema() async throws {
        let repo = try await TestDatabase.sharedRepo()
        try await repo.executeRawSQL(#"DROP SCHEMA IF EXISTS "tenant_a" CASCADE"#)
        try await repo.executeRawSQL(#"DROP TABLE IF EXISTS "tenant_notes""#)
        try await repo.executeRawSQL(#"CREATE SCHEMA "tenant_a""#)
        for schema in ["public", "tenant_a"] {
            try await repo.executeRawSQL(#"CREATE TABLE "\#(schema)"."tenant_notes" ("id" UUID PRIMARY KEY DEFAULT gen_random_uuid(), "body" TEXT NOT NULL)"#)
        }

        let tenantCount = try await repo.transaction { tx in
            try await tx.executeRawSQL(#"SET LOCAL search_path TO "tenant_a""#)
            let note = try await tx.insert(TenantNote(body: "tenant"))
            _ = try await tx.update(TenantNote.self, id: note.id, changes: ["body": "tenant!"])
            return try await tx.query(TenantNote.self).where { $0.body == "tenant!" }.count()
        }
        #expect(tenantCount == 1)

        // The setting ended with the transaction: the pool reads the public table again.
        #expect(try await repo.query(TenantNote.self).count() == 0)
        let rows = try await repo.executeRawQuery(sql: #"SELECT count(*) AS "count" FROM "tenant_a"."tenant_notes""#)
        #expect(rows.first?.makeRandomAccess()[data: "count"].int == 1)
        try await repo.executeRawSQL(#"DROP SCHEMA "tenant_a" CASCADE"#)
    }
}
}
