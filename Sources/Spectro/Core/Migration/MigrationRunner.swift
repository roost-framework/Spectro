import Foundation
@preconcurrency import PostgresKit
import SpectroCommon

/// Shared migration lifecycle. The session lock spans discovery and all selected transactions.
///
/// Use a direct or session-pooled PostgreSQL connection. Each migration and its
/// ledger update share a transaction; earlier successful migrations stay committed
/// if a later migration fails. See <doc:SQLMigrations>.
public final class MigrationRunner: Sendable {
    private let connection: DatabaseConnection
    private let sources: [MigrationSource]
    private let legacyDirectory: URL?
    private let lockTimeout: Duration
    internal static let lockKey: Int = 0x5350454354524F

    /// Creates a runner over SQL directories and prepared definitions.
    ///
    /// The timeout bounds waiting for the migration advisory lock, separately
    /// from connection acquisition and SQL execution.
    public init(connection: DatabaseConnection, sources: [MigrationSource], lockTimeout: Duration = .seconds(30)) {
        self.connection = connection
        self.sources = sources
        self.lockTimeout = lockTimeout
        self.legacyDirectory = nil
    }

    internal init(connection: DatabaseConnection, legacyDirectory: URL, lockTimeout: Duration) {
        self.connection = connection
        self.sources = [.sqlDirectory(legacyDirectory)]
        self.legacyDirectory = legacyDirectory
        self.lockTimeout = lockTimeout
    }

    /// Creates tracking objects while holding the migration session lock.
    public func ensureMigrationTableExists() async throws {
        try await withLockedSession { session in
            try await self.ensureMigrationTableExists(using: session)
        }
    }

    private func ensureMigrationTableExists(using session: TransactionContext) async throws {
        let createEnumSql = """
            DO $$ BEGIN
                CREATE TYPE migration_status AS ENUM ('pending', 'completed', 'failed');
            EXCEPTION WHEN duplicate_object THEN null; END $$;
            """
        try await session.execute(createEnumSql)

        let createTableSql = """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                applied_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
                status migration_status NOT NULL DEFAULT 'pending'
            );
            """
        try await session.execute(createTableSql)
    }

    /// Reads ledger records without creating tracking objects on a fresh database.
    public func getMigrationStatus() async throws -> [MigrationRecord] {
        try await getMigrationStatus(using: connection)
    }

    private func getMigrationStatus(using executor: any QueryExecutor) async throws -> [MigrationRecord] {
        // Inspecting status must not require DDL privileges, including on a fresh database.
        let exists = try await executor.executeQuery(
            sql: "SELECT to_regclass('schema_migrations') IS NOT NULL AS present",
            parameters: [],
            resultMapper: { $0.makeRandomAccess()[data: "present"].bool ?? false }
        ).first ?? false
        guard exists else { return [] }

        let sql = """
            SELECT version, name, applied_at, status
            FROM schema_migrations
            ORDER BY version ASC
            """
        return try await executor.executeQuery(sql: sql, parameters: []) { row in
            let r = row.makeRandomAccess()
            guard let version = r[data: "version"].string else {
                throw SpectroError.resultDecodingFailed(column: "version", expectedType: "String")
            }
            guard let name = r[data: "name"].string else {
                throw SpectroError.resultDecodingFailed(column: "name", expectedType: "String")
            }
            guard let appliedAt = r[data: "applied_at"].date else {
                throw SpectroError.resultDecodingFailed(column: "applied_at", expectedType: "Date")
            }
            guard let statusString = r[data: "status"].string else {
                throw SpectroError.resultDecodingFailed(column: "status", expectedType: "String")
            }
            return MigrationRecord(
                version: version,
                name: name,
                appliedAt: appliedAt,
                status: MigrationStatus(rawValue: statusString) ?? .pending
            )
        }
    }

    /// Applies pending migrations in ascending full-ID order under the session lock.
    public func runMigrations() async throws {
        try await withLockedSession { session in
            // Legacy files are still loaded only when selected, preserving the 2.0 API.
            let catalog = try self.legacyDirectory == nil ? MigrationCatalog.load(sources: self.sources) : []
            try await self.ensureMigrationTableExists(using: session)
            let records = try await self.getMigrationStatus(using: session)
            let statuses = Dictionary(uniqueKeysWithValues: records.map { ($0.version, $0.status) })
            if let directory = self.legacyDirectory {
                let pending = try MigrationCatalog.discoverFiles(in: directory).filter {
                    statuses[$0.version] == nil || statuses[$0.version] == .pending
                }
                for file in pending {
                    let migration = try MigrationCatalog.loadSQLFile(file)
                    try await self.apply(migration, sql: migration.upSQL, status: .completed, using: session)
                }
            } else {
                for migration in catalog where statuses[migration.version] == nil || statuses[migration.version] == .pending {
                    try await self.apply(migration, sql: migration.upSQL, status: .completed, using: session)
                }
            }
        }
    }

    /// Rolls back completed migrations in descending full-ID order.
    ///
    /// The selected batch is checked for missing or irreversible history before
    /// execution. `nil` selects all completed migrations; zero is a no-op and
    /// negative values are invalid. Schema rollback does not restore deleted rows.
    public func runRollback(steps: Int? = nil) async throws {
        guard steps == nil || steps! >= 0 else {
            throw SpectroError.invalidParameter(name: "steps", value: String(steps!), reason: "Must be nonnegative")
        }
        if legacyDirectory == nil && steps == 0 { return }
        try await withLockedSession { session in
            let catalog = try self.legacyDirectory == nil ? MigrationCatalog.load(sources: self.sources) : []
            try await self.ensureMigrationTableExists(using: session)
            let records = try await self.getMigrationStatus(using: session)
            let completed = records.filter { $0.status == .completed }
            if let directory = self.legacyDirectory {
                let versions = Set(completed.map(\.version))
                let files = try MigrationCatalog.discoverFiles(in: directory).filter { versions.contains($0.version) }
                for file in files.suffix(steps ?? files.count).reversed() {
                    let migration = try MigrationCatalog.loadSQLFile(file)
                    if case .sql(let sql) = migration.rollback {
                        try await self.apply(migration, sql: sql, status: .pending, using: session)
                    }
                }
            } else {
                let byVersion = Dictionary(uniqueKeysWithValues: catalog.map { ($0.version, $0) })
                let selected = completed.sorted { $0.version < $1.version }.suffix(steps ?? completed.count).reversed()
                // Preflight the entire selection before executing even its first migration.
                let rollback = try selected.map { record -> (PreparedMigration, String) in
                    guard let migration = byVersion[record.version] else {
                        throw MigrationPlanningError(migrationID: record.version,
                                                     reason: "Applied migration is missing from this artifact")
                    }
                    switch migration.rollback {
                    case .sql(let sql): return (migration, sql)
                    case .irreversible(let reason):
                        throw MigrationPlanningError(migrationID: record.version, reason: "Irreversible: " + reason)
                    }
                }
                for (migration, sql) in rollback {
                    try await self.apply(migration, sql: sql, status: .pending, using: session)
                }
            }
        }
    }

    internal func insertMigrationRecord(_ record: MigrationRecord) async throws {
        try await withLockedSession { session in
            try await self.ensureMigrationTableExists(using: session)
            try await session.execute("""
                INSERT INTO schema_migrations (version, name, status)
                VALUES ($1, $2, $3::migration_status)
                ON CONFLICT (version) DO NOTHING;
                """, [
                    PostgresData(string: record.version),
                    PostgresData(string: record.name),
                    PostgresData(string: record.status.rawValue)
                ])
        }
    }

    // MARK: - Private

    private func withLockedSession<T: Sendable>(
        _ work: @Sendable (TransactionContext) async throws -> T
    ) async throws -> T {
        guard lockTimeout >= .zero else {
            throw SpectroError.invalidParameter(name: "lockTimeout", value: "\(lockTimeout)", reason: "Must be nonnegative")
        }
        return try await connection.withMigrationSession { session in
            // PostgreSQL 14+ can notice a closed client during long-running SQL,
            // rather than retaining its transaction and locks until SQL finishes.
            // This setting is confined to the disposable migration session.
            try await session.execute("""
                SELECT set_config(name, '100ms', false) FROM pg_settings
                WHERE name = 'client_connection_check_interval'
                """)
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: self.lockTimeout)
            while true {
                try Task.checkCancellation()
                let acquired = try await session.query(
                    "SELECT pg_try_advisory_lock($1::bigint) AS acquired", [.init(int: Self.lockKey)]
                ) { $0.makeRandomAccess()[data: "acquired"].bool == true }.first == true
                if acquired { break }
                guard clock.now < deadline else { throw MigrationError.lockTimeout }
                try await clock.sleep(until: min(deadline, clock.now.advanced(by: .milliseconds(50))))
            }
            // DatabaseConnection closes the reserved session on every exit path.
            return try await work(session)
        }
    }

    private func apply(
        _ migration: PreparedMigration, sql: String, status: MigrationStatus, using session: TransactionContext
    ) async throws {
        let statements = try SQLStatementParser.parse(sql)
        try Task.checkCancellation()
        guard migration.runsInTransaction else {
            // Each statement commits on its own; the ledger records the migration last.
            for statement in statements {
                try Task.checkCancellation()
                try await session.execute(statement)
            }
            try await updateMigrationStatus(migration, status: status, using: session)
            return
        }
        try await session.execute("BEGIN ISOLATION LEVEL READ COMMITTED")
        do {
            for statement in statements {
                try Task.checkCancellation()
                try await session.execute(statement)
            }
            try await updateMigrationStatus(migration, status: status, using: session)
            try Task.checkCancellation()
            try await session.execute("COMMIT")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            do { try await session.execute("ROLLBACK") }
            catch let rollbackError {
                throw SpectroError.transactionAndRollbackFailed(original: error, rollback: rollbackError)
            }
            throw SpectroError.transactionFailed(underlying: error)
        }
    }

    private func updateMigrationStatus(
        _ migration: PreparedMigration, status: MigrationStatus, using transaction: TransactionContext
    ) async throws {
        let sql = """
            INSERT INTO schema_migrations (version, name, status)
            VALUES ($1, $2, $3::migration_status)
            ON CONFLICT(version)
              DO UPDATE SET status=$3::migration_status, applied_at=CURRENT_TIMESTAMP;
            """
        try await transaction.execute(sql, [
            PostgresData(string: migration.version),
            PostgresData(string: migration.name),
            PostgresData(string: status.rawValue)
        ])
    }

}
