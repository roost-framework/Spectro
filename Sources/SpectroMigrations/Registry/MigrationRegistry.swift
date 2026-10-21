import Foundation
import Spectro
import SpectroCommon

/// Registers historical SQL files from a SwiftPM resource bundle.
///
/// Keep filenames and contents unchanged. Resource lookup is independent of the
/// working directory; a missing directory fails when the registry is planned.
public struct SQLMigrations: Sendable {
    internal let directory: URL?
    internal let label: String

    /// Selects a relative directory within a bundle, such as `.module` and `LegacySQL`.
    ///
    /// Absolute paths, empty paths, and parent-directory traversal are invalid.
    public init(bundle: Bundle, directory: String) {
        label = directory
        if !directory.isEmpty, !directory.hasPrefix("/"), !directory.split(separator: "/").contains("..") {
            self.directory = bundle.resourceURL?.appendingPathComponent(directory, isDirectory: true)
        } else {
            self.directory = nil
        }
    }
}

internal enum RegistryEntry: Sendable {
    case swift(String, MigrationPlan, runsInTransaction: Bool)
    case sql(SQLMigrations)
}

/// Captured Swift plans and SQL resource locations produced by the registry builder.
public struct MigrationEntries: Sendable {
    internal let entries: [RegistryEntry]
    internal init(_ entries: [RegistryEntry]) { self.entries = entries }
}

/// Registers migration instances and bundled SQL directories explicitly.
@resultBuilder
public enum MigrationRegistryBuilder {
    public static func buildExpression<M: Migration>(_ migration: M) -> MigrationEntries {
        MigrationEntries([.swift(M.id, migration.change, runsInTransaction: M.runsInTransaction)])
    }
    public static func buildExpression(_ sql: SQLMigrations) -> MigrationEntries { MigrationEntries([.sql(sql)]) }
    public static func buildBlock(_ entries: MigrationEntries...) -> MigrationEntries { combine(entries) }
    public static func buildOptional(_ entries: MigrationEntries?) -> MigrationEntries { entries ?? MigrationEntries([]) }
    public static func buildEither(first: MigrationEntries) -> MigrationEntries { first }
    public static func buildEither(second: MigrationEntries) -> MigrationEntries { second }
    public static func buildArray(_ entries: [MigrationEntries]) -> MigrationEntries { combine(entries) }
    private static func combine(_ entries: [MigrationEntries]) -> MigrationEntries { MigrationEntries(entries.flatMap(\.entries)) }
}

/// An immutable snapshot of explicitly registered declarations and resource locations.
///
/// Swift `change` bodies are evaluated once during registration. Execution order
/// is determined by full migration IDs, independent of registration order.
public struct MigrationRegistry: Sendable {
    private let entries: MigrationEntries

    /// Captures the declared entries without connecting to PostgreSQL.
    public init(@MigrationRegistryBuilder _ content: () -> MigrationEntries) { entries = content() }

    /// Compiles captured plans and validates the combined migration catalog offline.
    ///
    /// - Returns: SQL directory and prepared-definition sources for the shared runner.
    /// - Throws: A planning or file error for invalid declarations, missing resources,
    ///   malformed SQL history, or duplicate full IDs across sources.
    public func sources() throws -> [MigrationSource] {
        let sources = try entries.entries.map { entry -> MigrationSource in
            switch entry {
            case .swift(let id, let plan, let runsInTransaction):
                return .prepared([try MigrationCompiler.prepare(id: id, plan: plan, runsInTransaction: runsInTransaction)])
            case .sql(let resource):
                var isDirectory: ObjCBool = false
                guard let url = resource.directory,
                      FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw MigrationPlanningError(reason: "Missing SQL resource directory: \(resource.label)")
                }
                return .sqlDirectory(url)
            }
        }
        _ = try MigrationCatalog.load(sources: sources)
        return sources
    }
}
