import SpectroCommon

/// A deterministic, historical schema change. The generator assigns its ID once.
///
/// Describe historical names and types directly, independently of current models
/// and runtime environment. Add an instance to ``MigrationRegistry`` to register it.
public protocol Migration: Sendable {
    /// The stable full ID, in `epoch_seconds_lower_snake_case` form.
    static var id: String { get }
    /// The ordered operations, captured once when the migration is registered.
    @MigrationBuilder var change: MigrationPlan { get }
    /// Whether the migration runs in one transaction, `true` by default, like Ecto's
    /// `@disable_ddl_transaction` when `false`. Concurrent index operations need `false`;
    /// then a failure leaves the statements before it applied.
    static var runsInTransaction: Bool { get }
}

extension Migration {
    public static var runsInTransaction: Bool { true }
}

/// A value that contributes operations to a migration.
public protocol MigrationStep: Sendable {
    /// The immutable plan contributed by this operation.
    var migrationPlan: MigrationPlan { get }
}
