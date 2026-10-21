/// Specifies the target for ON CONFLICT clause in upsert operations.
public enum ConflictTarget: Sendable {
    /// Conflict on specific columns: ON CONFLICT (col1, col2)
    case columns([String])
    /// Conflict on a named constraint: ON CONFLICT ON CONSTRAINT name
    case constraint(String)

    var sql: String {
        switch self {
        case .columns(let columns): "(\(columns.map { $0.snakeCase().quoted }.joined(separator: ", ")))"
        case .constraint(let name): "ON CONSTRAINT \(name.quoted)"
        }
    }
}

/// What an insert does with a record that conflicts with an existing row, like Ecto's `on_conflict`.
public enum ConflictAction: Sendable {
    /// Skip the record: `ON CONFLICT DO NOTHING`. Without a target, a violation of any unique
    /// or exclusion constraint skips it.
    case nothing(on: ConflictTarget? = nil)
    /// Update the existing row with the record's `columns`, or with all its inserted columns:
    /// `ON CONFLICT … DO UPDATE SET`.
    case replace(on: ConflictTarget, columns: [String]? = nil)

    /// The ON CONFLICT clause of an insert of `insertedColumns`.
    func sql(insertedColumns: [String]) throws -> String {
        switch self {
        case .nothing(let target):
            return "ON CONFLICT \(target.map { "\($0.sql) " } ?? "")DO NOTHING"
        case .replace(let target, let columns):
            if columns?.isEmpty == true {
                throw SpectroError.invalidSchema(reason: "Conflict replacement columns must not be empty; use nil to update all inserted columns")
            }
            let updated = columns?.map { $0.snakeCase() } ?? insertedColumns
            let set = updated.map { "\($0.quoted) = EXCLUDED.\($0.quoted)" }.joined(separator: ", ")
            return "ON CONFLICT \(target.sql) DO UPDATE SET \(set)"
        }
    }
}
