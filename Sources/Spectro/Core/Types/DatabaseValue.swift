import Foundation
@preconcurrency import PostgresNIO

/// A Swift type stored in one PostgreSQL column: Spectro's counterpart of `Ecto.Type`.
///
/// `@Column`, `@ID`, and `@ForeignKey` accept any conforming type, and query
/// filters bind conforming values. Built-in conformances:
///
/// - `String`, `Int`, `Bool`, `UUID`, `Date`, `Double`, `Float`, `Data` (`bytea`), and
///   `Decimal` (`numeric`)
/// - arrays of conforming types, stored as PostgreSQL arrays such as `text[]`
/// - `Optional` of a conforming type, stored as a nullable column
/// - `[String: Value]` dictionaries of `Codable` conforming values, stored as `jsonb`
///
/// Conform your own types:
///
/// ```swift
/// // Stored as its raw value in a text, varchar, or PostgreSQL enum column.
/// enum Status: String, Codable, DatabaseValue { case draft, published }
///
/// // Stored as jsonb.
/// struct Address: Codable, JSONBValue { var city: String }
/// ```
///
/// Any other type implements `toPostgresData()` and `fromPostgresData(_:)`, and
/// optionally `cast(_:)` for changesets and `postgresType` for arrays.
public protocol DatabaseValue: Sendable {
    /// Encode the value as a query parameter.
    func toPostgresData() throws -> PostgresData

    /// Decode a column value. Returns `nil` for SQL NULL or a value that cannot be decoded.
    static func fromPostgresData(_ data: PostgresData) -> Self?

    /// Convert external input, such as a changeset parameter, to this type.
    /// Returns `nil` for input that cannot be converted. The default accepts only `Self`.
    static func cast(_ value: any Sendable) -> Self?

    /// The PostgreSQL type of an encoded value. Arrays of this type need it to be a type
    /// with an array type, such as `.text` or `.jsonb`. The default, `.null`, lets the
    /// server infer the type, and does not support arrays.
    static var postgresType: PostgresDataType { get }

    /// The classification recorded in schema metadata. The default is `.custom`.
    static var fieldType: FieldType { get }
}

extension DatabaseValue {
    public static func cast(_ value: any Sendable) -> Self? { value as? Self }
    public static var postgresType: PostgresDataType { .null }
    public static var fieldType: FieldType { .custom }
}

// MARK: - Scalars

extension String: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(string: self) }

    public static func fromPostgresData(_ data: PostgresData) -> String? {
        if let string = data.string { return string }
        // Types created by extensions or CREATE TYPE, such as citext and enums, have OIDs
        // from 16384 and send their text in the binary format too.
        guard data.type.rawValue >= 16384, let value = data.value else { return nil }
        return value.getString(at: value.readerIndex, length: value.readableBytes)
    }

    public static var postgresType: PostgresDataType { .text }
    public static var fieldType: FieldType { .string }
}

extension Int: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(int: self) }
    public static func fromPostgresData(_ data: PostgresData) -> Int? { data.int }

    public static func cast(_ value: any Sendable) -> Int? {
        if let number = value as? Int { return number }
        return (value as? String).flatMap(Int.init)
    }

    public static var postgresType: PostgresDataType { .int8 }
    public static var fieldType: FieldType { .int }
}

extension Bool: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(bool: self) }
    public static func fromPostgresData(_ data: PostgresData) -> Bool? { data.bool }

    public static func cast(_ value: any Sendable) -> Bool? {
        if let boolean = value as? Bool { return boolean }
        switch value as? String {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    public static var postgresType: PostgresDataType { .bool }
    public static var fieldType: FieldType { .bool }
}

extension UUID: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(uuid: self) }
    public static func fromPostgresData(_ data: PostgresData) -> UUID? { data.uuid }

    public static func cast(_ value: any Sendable) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        return (value as? String).flatMap(UUID.init(uuidString:))
    }

    public static var postgresType: PostgresDataType { .uuid }
    public static var fieldType: FieldType { .uuid }
}

extension Date: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(date: self) }
    public static func fromPostgresData(_ data: PostgresData) -> Date? { data.date }

    /// Accepts a `Date` or an ISO 8601 string, with or without fractional seconds.
    public static func cast(_ value: any Sendable) -> Date? {
        if let date = value as? Date { return date }
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    public static var postgresType: PostgresDataType { .timestamptz }
    public static var fieldType: FieldType { .date }
}

extension Double: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(double: self) }
    public static func fromPostgresData(_ data: PostgresData) -> Double? { data.double }

    /// Accepts finite numbers and numeric strings.
    public static func cast(_ value: any Sendable) -> Double? {
        let number: Double?
        if let v = value as? Double { number = v }
        else if let v = value as? Int { number = Double(v) }
        else if let v = value as? Float { number = Double(v) }
        else { number = (value as? String).flatMap(Double.init) }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    public static var postgresType: PostgresDataType { .float8 }
    public static var fieldType: FieldType { .double }
}

extension Float: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(float: self) }
    public static func fromPostgresData(_ data: PostgresData) -> Float? { data.float }

    /// Accepts finite numbers and numeric strings.
    public static func cast(_ value: any Sendable) -> Float? {
        let number: Float?
        if let v = value as? Float { number = v }
        else if let v = value as? Double { number = Float(v) }
        else if let v = value as? Int { number = Float(v) }
        else { number = (value as? String).flatMap(Float.init) }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    public static var postgresType: PostgresDataType { .float4 }
    public static var fieldType: FieldType { .float }
}

extension Data: DatabaseValue {
    public func toPostgresData() -> PostgresData { PostgresData(bytes: [UInt8](self)) }

    public static func fromPostgresData(_ data: PostgresData) -> Data? {
        data.bytes.map { Data($0) }
    }

    public static var postgresType: PostgresDataType { .bytea }
}

/// Stored as `numeric`, without binary floating-point rounding. `Decimal` holds 38 significant
/// digits: decoding a longer value fails rather than rounding it, and NaN cannot be stored.
extension Decimal: DatabaseValue {
    public func toPostgresData() throws -> PostgresData {
        // PostgresNIO traps on a NaN numeric.
        guard !isNaN else {
            throw SpectroError.invalidParameter(name: "value", value: "NaN", reason: "Decimal NaN cannot be stored as numeric")
        }
        return PostgresData(numeric: PostgresNumeric(decimal: self))
    }

    public static func fromPostgresData(_ data: PostgresData) -> Decimal? {
        if let int = data.int { return Decimal(int) }
        guard let string = data.string, string != "NaN", significantDigits(string) <= 38 else { return nil }
        return Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Accepts decimals, integers, finite doubles, and plain numeric strings such as `"-12.50"`.
    /// Strings with separators, units, or exponents, such as `"1,000"`, are rejected.
    public static func cast(_ value: any Sendable) -> Decimal? {
        let result: Decimal?
        switch value {
        case let v as Decimal: result = v
        case let v as Int: result = Decimal(v)
        // The shortest description avoids binary rounding: 0.1 becomes 0.1, not 0.1000000000000000055.
        case let v as Double: result = v.isFinite ? Decimal(string: "\(v)", locale: Locale(identifier: "en_US_POSIX")) : nil
        case let v as String: result = isPlainNumber(v) ? Decimal(string: v, locale: Locale(identifier: "en_US_POSIX")) : nil
        default: result = nil
        }
        return result.flatMap { $0.isNaN ? nil : $0 }
    }

    public static var postgresType: PostgresDataType { .numeric }

    /// An optional sign, then digits with at most one decimal point.
    private static func isPlainNumber(_ string: String) -> Bool {
        let body = string.first == "-" || string.first == "+" ? string.dropFirst() : Substring(string)
        return body.contains(where: \.isASCIIDigit) && body.filter { $0 == "." }.count <= 1
            && body.allSatisfy { $0.isASCIIDigit || $0 == "." }
    }

    /// Digits of a numeric's text without leading and trailing zeros, which `Decimal` stores in its exponent.
    private static func significantDigits(_ numeric: String) -> Int {
        let digits = numeric.filter(\.isASCIIDigit)
        return digits.drop { $0 == "0" }.reversed().drop { $0 == "0" }.count
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

// MARK: - Raw-value enums

extension DatabaseValue where Self: RawRepresentable, RawValue: DatabaseValue {
    /// Encodes the raw value. A `String` raw value is sent without a declared type, so it
    /// is accepted by text, varchar, and PostgreSQL enum columns alike.
    public func toPostgresData() throws -> PostgresData {
        var data = try rawValue.toPostgresData()
        if RawValue.self == String.self { data.type = .null }
        return data
    }

    public static func fromPostgresData(_ data: PostgresData) -> Self? {
        RawValue.fromPostgresData(data).flatMap(Self.init(rawValue:))
    }

    /// Accepts the type itself or one of its raw values.
    public static func cast(_ value: any Sendable) -> Self? {
        if let value = value as? Self { return value }
        return RawValue.cast(value).flatMap(Self.init(rawValue:))
    }

    public static var postgresType: PostgresDataType { RawValue.postgresType }
}

// MARK: - JSONB

/// A `Codable` type stored as `jsonb`, like an embedded schema or a map in Ecto.
///
/// ```swift
/// struct Address: Codable, JSONBValue { var city: String }
///
/// @Schema("users")
/// struct User {
///     @ID var id: UUID
///     @Column var address: Address = Address(city: "")
/// }
/// ```
///
/// Values are encoded with a `JSONEncoder` that writes dates as ISO 8601 strings with
/// milliseconds, as Ecto does. Changesets accept the type itself or a JSON object such as a
/// decoded request body.
public protocol JSONBValue: DatabaseValue, Codable {}

extension JSONBValue {
    public func toPostgresData() throws -> PostgresData { PostgresData(jsonb: try jsonEncoder().encode(self)) }
    public static func fromPostgresData(_ data: PostgresData) -> Self? { decodeJSON(data) }
    public static func cast(_ value: any Sendable) -> Self? { castJSON(value) }
    public static var postgresType: PostgresDataType { .jsonb }
}

/// Stored as `jsonb`, like an Ecto `:map`.
extension Dictionary: DatabaseValue where Key == String, Value: DatabaseValue & Codable {
    public func toPostgresData() throws -> PostgresData { PostgresData(jsonb: try jsonEncoder().encode(self)) }
    public static func fromPostgresData(_ data: PostgresData) -> Self? { decodeJSON(data) }
    public static func cast(_ value: any Sendable) -> Self? { castJSON(value) }
    public static var postgresType: PostgresDataType { .jsonb }
}

/// Dates in jsonb are ISO 8601 strings, readable in SQL and by other applications.
private func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
    return encoder
}

private func jsonDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        guard let date = Date.cast(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date")
        }
        return date
    }
    return decoder
}

private func decodeJSON<T: Decodable>(_ data: PostgresData) -> T? {
    // json columns send plain text; jsonb prefixes a version byte.
    let json: Data? = switch data.type {
    case .jsonb: data.jsonb
    case .json: data.bytes.map { Data($0) }
    case .text, .varchar: data.string.map { Data($0.utf8) }
    default: nil
    }
    return json.flatMap { try? jsonDecoder().decode(T.self, from: $0) }
}

private func castJSON<T: Decodable>(_ value: any Sendable) -> T? {
    if let value = value as? T { return value }
    let json: Data?
    if let string = value as? String {
        json = Data(string.utf8)
    } else if JSONSerialization.isValidJSONObject(value) {
        json = try? JSONSerialization.data(withJSONObject: value)
    } else {
        json = nil
    }
    return json.flatMap { try? jsonDecoder().decode(T.self, from: $0) }
}

// MARK: - Arrays

/// Stored as a one-dimensional PostgreSQL array, such as `text[]` or `uuid[]`.
///
/// The element type must have a PostgreSQL array type. Raw-value enums are stored as
/// arrays of their raw values, so use a `text[]` column rather than an array of a
/// PostgreSQL enum type.
extension Array: DatabaseValue where Element: DatabaseValue {
    public func toPostgresData() throws -> PostgresData {
        // PostgresNIO traps on an element type without an array type.
        guard PostgresDataType.arrayTypes[Element.postgresType] != nil else {
            throw SpectroError.invalidParameter(
                name: "value",
                value: String(describing: self),
                reason: "\(Element.self) has no PostgreSQL array type; set its postgresType"
            )
        }
        return PostgresData(array: try map { try $0.toPostgresData() }, elementType: Element.postgresType)
    }

    public static func fromPostgresData(_ data: PostgresData) -> [Element]? {
        guard let items = data.array else { return nil }
        var result: [Element] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let element = Element.fromPostgresData(item) else { return nil }
            result.append(element)
        }
        return result
    }

    /// Accepts an array whose every element `Element.cast` accepts.
    public static func cast(_ value: any Sendable) -> [Element]? {
        if let value = value as? [Element] { return value }
        guard let items = value as? [any Sendable] else { return nil }
        var result: [Element] = []
        for item in items {
            guard let element = Element.cast(item) else { return nil }
            result.append(element)
        }
        return result
    }

    public static var postgresType: PostgresDataType {
        PostgresDataType.arrayTypes[Element.postgresType] ?? .null
    }
}

extension PostgresDataType {
    /// Array types of the element types Spectro encodes. PostgresNIO keeps its own table internal.
    fileprivate static let arrayTypes: [PostgresDataType: PostgresDataType] = [
        .text: .textArray, .varchar: .varcharArray, .int8: .int8Array, .int4: .int4Array,
        .int2: .int2Array, .bool: .boolArray, .uuid: .uuidArray, .timestamptz: .timestamptzArray,
        .date: .dateArray, .float8: .float8Array, .float4: .float4Array, .numeric: .numericArray,
        .bytea: .byteaArray, .jsonb: .jsonbArray,
    ]

    /// The SQL name of the array type whose elements have this type, such as `bigint[]`.
    var arrayTypeName: String? {
        let names: [PostgresDataType: String] = [
            .text: "text[]", .varchar: "varchar[]", .int8: "bigint[]", .int4: "integer[]",
            .int2: "smallint[]", .bool: "boolean[]", .uuid: "uuid[]", .timestamptz: "timestamptz[]",
            .date: "date[]", .float8: "double precision[]", .float4: "real[]", .numeric: "numeric[]",
            .bytea: "bytea[]", .jsonb: "jsonb[]",
        ]
        return names[self]
    }
}

// MARK: - Optionals

/// A nullable column. `nil` is stored as SQL NULL.
extension Optional: DatabaseValue where Wrapped: DatabaseValue {
    public func toPostgresData() throws -> PostgresData {
        // An untyped NULL fits any column, including PostgreSQL enums.
        guard let value = self else { return PostgresData(type: .null, value: nil) }
        return try value.toPostgresData()
    }

    /// Decodes SQL NULL as `.some(nil)`; returns `nil` only for a value that cannot be decoded.
    public static func fromPostgresData(_ data: PostgresData) -> Wrapped?? {
        guard data.value != nil else { return .some(nil) }
        return Wrapped.fromPostgresData(data).map { .some($0) }
    }

    public static func cast(_ value: any Sendable) -> Wrapped?? {
        Wrapped.cast(value).map { .some($0) }
    }

    public static var postgresType: PostgresDataType { Wrapped.postgresType }
    public static var fieldType: FieldType { Wrapped.fieldType }
}

/// Lets schema metadata see through `Optional` to the stored type.
protocol OptionalDatabaseValue {
    static var wrappedValueType: any DatabaseValue.Type { get }
}

extension Optional: OptionalDatabaseValue where Wrapped: DatabaseValue {
    static var wrappedValueType: any DatabaseValue.Type { Wrapped.self }
}
