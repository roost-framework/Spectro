import Foundation
@preconcurrency import PostgresNIO

public protocol TupleBuildable: Sendable {
    static func build(from row: PostgresRow, fields: [String]) throws -> Self
}

public struct Tuple2<A: Sendable, B: Sendable>: TupleBuildable, Sendable {
    public let _0: A
    public let _1: B

    public init(_ a: A, _ b: B) {
        self._0 = a
        self._1 = b
    }

    public static func build(from row: PostgresRow, fields: [String]) throws -> Tuple2<A, B> {
        let ra = row.makeRandomAccess()
        let a: A = try extractValue(from: ra[data: fields[0]])
        let b: B = try extractValue(from: ra[data: fields[1]])
        return Tuple2(a, b)
    }
}

public struct Tuple3<A: Sendable, B: Sendable, C: Sendable>: TupleBuildable, Sendable {
    public let _0: A
    public let _1: B
    public let _2: C

    public init(_ a: A, _ b: B, _ c: C) {
        self._0 = a
        self._1 = b
        self._2 = c
    }

    public static func build(from row: PostgresRow, fields: [String]) throws -> Tuple3<A, B, C> {
        let ra = row.makeRandomAccess()
        let a: A = try extractValue(from: ra[data: fields[0]])
        let b: B = try extractValue(from: ra[data: fields[1]])
        let c: C = try extractValue(from: ra[data: fields[2]])
        return Tuple3(a, b, c)
    }
}

public struct Tuple4<A: Sendable, B: Sendable, C: Sendable, D: Sendable>: TupleBuildable, Sendable {
    public let _0: A
    public let _1: B
    public let _2: C
    public let _3: D

    public init(_ a: A, _ b: B, _ c: C, _ d: D) {
        self._0 = a
        self._1 = b
        self._2 = c
        self._3 = d
    }

    public static func build(from row: PostgresRow, fields: [String]) throws -> Tuple4<A, B, C, D> {
        let ra = row.makeRandomAccess()
        let a: A = try extractValue(from: ra[data: fields[0]])
        let b: B = try extractValue(from: ra[data: fields[1]])
        let c: C = try extractValue(from: ra[data: fields[2]])
        let d: D = try extractValue(from: ra[data: fields[3]])
        return Tuple4(a, b, c, d)
    }
}

public enum TupleMapper {
    public static func mapRow(_ row: PostgresRow, selectedFields: [String], to type: any TupleBuildable.Type) throws -> any TupleBuildable {
        try type.build(from: row, fields: selectedFields)
    }
}

func extractValue<T>(from data: PostgresData) throws -> T {
    guard let type = T.self as? any DatabaseValue.Type,
          let result = type.fromPostgresData(data) as? T else {
        throw SpectroError.resultDecodingFailed(column: "unknown", expectedType: String(describing: T.self))
    }
    return result
}
