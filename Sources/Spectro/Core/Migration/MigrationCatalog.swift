import Foundation
import SpectroCommon

/// Loads a migration artifact without opening a database connection.
public enum MigrationCatalog {
    /// Loads SQL files and prepared definitions, rejecting duplicate full IDs.
    ///
    /// - Returns: The combined history in ascending lexical ID order.
    /// - Throws: File or planning errors. No database connection is opened.
    public static func load(sources: [MigrationSource]) throws -> [PreparedMigration] {
        var migrations: [PreparedMigration] = []
        var versions = Set<String>()
        for source in sources {
            let entries: [PreparedMigration]
            switch source {
            case .sqlDirectory(let directory):
                entries = try discoverFiles(in: directory).map(loadSQLFile)
            case .prepared(let definitions):
                for definition in definitions { try validate(definition) }
                entries = definitions
            }
            for entry in entries {
                guard versions.insert(entry.version).inserted else {
                    throw MigrationPlanningError(migrationID: entry.version, reason: "Duplicate migration ID across sources")
                }
                migrations.append(entry)
            }
        }
        return migrations.sorted { $0.version < $1.version }
    }

    internal static func discoverFiles(in directory: URL) throws -> [MigrationFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw MigrationError.directoryNotFound(directory.path)
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "sql" }
            .compactMap { url in
                let version = url.deletingPathExtension().lastPathComponent
                let parts = version.split(separator: "_", maxSplits: 1)
                guard parts.count == 2, let timestamp = Double(parts[0]), timestamp > 0,
                      timestamp < Date().timeIntervalSince1970 + 100 * 365 * 24 * 60 * 60 else { return nil }
                return MigrationFile(version: version, name: String(parts[1]), filePath: url)
            }
            .sorted { $0.version < $1.version }
    }

    internal static func loadSQLFile(_ file: MigrationFile) throws -> PreparedMigration {
        let text = try String(contentsOf: file.filePath, encoding: .utf8)
        guard let up = text.range(of: "-- migrate:up"),
              let down = text.range(of: "-- migrate:down"), up.upperBound <= down.lowerBound else {
            throw MigrationError.invalidMigrationFile(file.version)
        }
        // `transaction:false` after a marker, as in dbmate, runs the migration outside a
        // transaction. One flag covers both directions, so either marker sets it.
        func section(after marker: Range<String.Index>) -> (start: String.Index, outside: Bool) {
            let lineEnd = text[marker.upperBound...].firstIndex(where: \.isNewline) ?? text.endIndex
            let outside = text[marker.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces) == "transaction:false"
            return (outside ? lineEnd : marker.upperBound, outside)
        }
        let upSection = section(after: up), downSection = section(after: down)
        let runsInTransaction = !(upSection.outside || downSection.outside)
        let upSQL = text[upSection.start..<down.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        let downSQL = text[downSection.start...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !upSQL.isEmpty else { throw MigrationError.invalidMigrationFile(file.version) }
        return .init(version: file.version, name: file.name, upSQL: upSQL, rollback: .sql(downSQL),
                     runsInTransaction: runsInTransaction)
    }

    private static func validate(_ migration: PreparedMigration) throws {
        guard migration.version.range(of: #"^[0-9]+_[a-z][a-z0-9_]*$"#, options: .regularExpression) != nil,
              let epoch = Double(migration.version.prefix(while: { $0 != "_" })), epoch > 0,
              epoch < Date().timeIntervalSince1970 + 100 * 365 * 24 * 60 * 60 else {
            throw MigrationPlanningError(migrationID: migration.version, reason: "Expected epoch_seconds_lower_snake_case ID")
        }
        try validateSQL(migration.upSQL, version: migration.version)
        switch migration.rollback {
        case .sql(let sql): try validateSQL(sql, version: migration.version)
        case .irreversible(let reason):
            guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MigrationPlanningError(migrationID: migration.version, reason: "An irreversible migration needs a reason")
            }
        }
    }

    private static func validateSQL(_ sql: String, version: String) throws {
        let statements: [String]
        do { statements = try SQLStatementParser.parse(sql) }
        catch { throw MigrationPlanningError(migrationID: version, reason: "Malformed SQL quoting or comment: \(error)") }
        guard !statements.isEmpty else {
            throw MigrationPlanningError(migrationID: version, reason: "Migration SQL must not be empty")
        }
        for (index, statement) in statements.enumerated() {
            let words = statement.uppercased().split { !$0.isLetter && $0 != "_" }
            let first = words.first.map(String.init) ?? ""
            let transaction = ["BEGIN", "START", "COMMIT", "END", "ROLLBACK", "ABORT", "SAVEPOINT", "RELEASE"]
            if transaction.contains(first) || (first == "PREPARE" && words.dropFirst().first == "TRANSACTION") {
                throw MigrationPlanningError(migrationID: version, operationIndex: index,
                                             reason: "Migration SQL must not manage transactions")
            }
        }
    }
}
