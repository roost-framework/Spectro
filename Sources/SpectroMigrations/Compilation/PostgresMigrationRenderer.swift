import Foundation
import SpectroCommon

internal enum PostgresMigrationRenderer {
    static func identifier(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains("\0"), name.utf8.count <= 63 else {
            throw MigrationPlanningError(reason: "Identifiers must contain 1...63 UTF-8 bytes and no NUL")
        }
        return name.quoted
    }

    static func qualified(_ name: String, schema: String?) throws -> String {
        if let schema { return try identifier(schema) + "." + identifier(name) }
        return try identifier(name)
    }

    static func type(_ type: MigrationColumnType) throws -> String {
        switch type {
        case .uuid: return "UUID"
        case .text: return "TEXT"
        case .integer: return "INTEGER"
        case .bigint: return "BIGINT"
        case .boolean: return "BOOLEAN"
        case .timestamptz: return "TIMESTAMPTZ"
        case .jsonb: return "JSONB"
        case .smallint: return "SMALLINT"
        case .real: return "REAL"
        case .doublePrecision: return "DOUBLE PRECISION"
        case .date: return "DATE"
        case .timestamp: return "TIMESTAMP"
        case .bytea: return "BYTEA"
        case .json: return "JSON"
        case .array(let element): return try Self.type(element) + "[]"
        case .named(let name, let schema): return try qualified(name, schema: schema)
        case .varchar(let length):
            guard (1...10_485_760).contains(length) else { throw MigrationPlanningError(reason: "Invalid varchar length") }
            return "VARCHAR(\(length))"
        case .numeric(let precision, let scale):
            guard (1...1000).contains(precision), (0...precision).contains(scale) else {
                throw MigrationPlanningError(reason: "Numeric requires precision 1...1000 and scale 0...precision")
            }
            return "NUMERIC(\(precision), \(scale))"
        }
    }

    static func value(_ value: MigrationDefault) throws -> String {
        switch value {
        case .string(let string):
            guard !string.contains("\0") else { throw MigrationPlanningError(reason: "A text default cannot contain NUL") }
            let escaped = string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
            return "E'\(escaped)'"
        case .integer(let number): return String(number)
        case .floating(let number):
            guard number.isFinite else { throw MigrationPlanningError(reason: "A numeric default must be finite") }
            return String(number)
        case .boolean(let boolean): return boolean ? "TRUE" : "FALSE"
        case .sql(let sql):
            return try expression(sql)
        }
    }

    static func expression(_ sql: String) throws -> String {
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sql.contains("\0") else {
            throw MigrationPlanningError(reason: "A trusted SQL expression must not be empty or contain NUL")
        }
        // Closing parentheses, commas and constraints must survive a trailing -- comment.
        return sql + "\n"
    }

    static func referenceName(_ column: ColumnDefinition, table: String) -> String? {
        column.reference.map { $0.name ?? "\(table)_\(column.name)_fkey" }
    }

    static func column(_ column: ColumnDefinition, table: String) throws -> String {
        if let issue = column.issues.first { throw MigrationPlanningError(reason: issue) }
        var result = try identifier(column.name) + " " + type(column.type)
        if column.primary { result += " PRIMARY KEY" }
        else if column.required { result += " NOT NULL" }
        if let defaultValue = column.defaultValue { result += " DEFAULT " + (try value(defaultValue)) }
        if let reference = column.reference {
            guard !(reference.action == .setNull && (column.required || column.primary)) else {
                throw MigrationPlanningError(reason: "ON DELETE SET NULL conflicts with a non-null column")
            }
            guard reference.action != .setDefault || column.defaultValue != nil else {
                throw MigrationPlanningError(reason: "ON DELETE SET DEFAULT requires an explicit default")
            }
            let name = referenceName(column, table: table)!
            result += " CONSTRAINT \(try identifier(name)) REFERENCES \(try qualified(reference.table, schema: reference.schema))"
            result += " (\(try identifier(reference.column))) ON DELETE \(reference.action.rawValue)"
        }
        return result
    }
}
