import Foundation
import PostgresNIO

/// Raw SQL for a query, like Ecto's `fragment`. Interpolated fields become qualified
/// column names and interpolated values become bound parameters, so values are never
/// spliced into the SQL text.
///
/// ```swift
/// let users = try await repo.query(User.self)
///     .where { .fragment("lower(\($0.email)) = lower(\(email))") }
///     .where { .fragment("\($0.settings) ? 'beta'") }   // a literal ? stays an operator
///     .all()
/// ```
///
/// Interpolate a `QueryField` or a `JoinField` for a column, any `DatabaseValue` for a
/// parameter, another `SQLFragment` to compose, or `identifier:` for a quoted name.
public struct SQLFragment: Sendable, ExpressibleByStringInterpolation {
    let sql: String
    let parameters: [PostgresData]
    let referencedTables: Set<JoinTableReference>

    public init(stringLiteral value: String) {
        self.init(stringInterpolation: StringInterpolation(literal: value))
    }

    public init(stringInterpolation: StringInterpolation) {
        self.sql = stringInterpolation.sql
        self.parameters = stringInterpolation.parameters
        self.referencedTables = stringInterpolation.referencedTables
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var sql = ""
        var parameters: [PostgresData] = []
        var referencedTables: Set<JoinTableReference> = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            sql.reserveCapacity(literalCapacity + interpolationCount * 2)
        }

        init(literal: String) {
            appendLiteral(literal)
        }

        public mutating func appendLiteral(_ literal: String) {
            sql += literal.replacingOccurrences(of: "?", with: String(literalQuestionMark))
        }

        /// A column of the queried model, qualified with its table.
        public mutating func appendInterpolation<V>(_ field: QueryField<V>) {
            sql += field.qualifiedName
        }

        /// A column of a joined table, qualified with its alias.
        public mutating func appendInterpolation<V>(_ field: JoinField<V>) {
            sql += field.qualifiedName
            referencedTables.insert(field.tableReference)
        }

        /// A bound parameter.
        public mutating func appendInterpolation(_ value: some DatabaseValue) {
            sql += "?"
            parameters.append(convertToPostgresData(value))
        }

        /// Another fragment, with its parameters.
        public mutating func appendInterpolation(_ fragment: SQLFragment) {
            sql += fragment.sql
            parameters += fragment.parameters
            referencedTables.formUnion(fragment.referencedTables)
        }

        /// A double-quoted identifier, such as a function or column name chosen at runtime.
        public mutating func appendInterpolation(identifier: String) {
            appendLiteral(identifier.quoted)
        }
    }
}

extension QueryCondition {
    /// A condition written in SQL. See `SQLFragment`.
    public static func fragment(_ fragment: SQLFragment) -> QueryCondition {
        QueryCondition(sql: fragment.sql, parameters: fragment.parameters, referencedTables: fragment.referencedTables)
    }
}

/// Stands in for a literal `?` in fragment SQL until placeholders are numbered.
/// U+E000 is a private-use character that SQL text does not otherwise contain.
let literalQuestionMark: Character = "\u{E000}"

/// Number `?` placeholders `$1`, `$2`, … in one left-to-right pass over assembled SQL,
/// and restore literal question marks from fragments.
func renumberPlaceholders(in sql: String) -> String {
    var result = ""
    result.reserveCapacity(sql.utf8.count)
    var counter = 0
    for char in sql {
        if char == "?" {
            counter += 1
            result += "$\(counter)"
        } else if char == literalQuestionMark {
            result.append("?")
        } else {
            result.append(char)
        }
    }
    return result
}
