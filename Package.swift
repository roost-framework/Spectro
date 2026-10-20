// swift-tools-version: 6.1

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Spectro",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "SpectroCommon", targets: ["SpectroCommon"]),
        .library(name: "SpectroKit", targets: ["Spectro"]),
        .library(name: "SpectroMigrations", targets: ["SpectroMigrations"]),
        .executable(name: "spectro", targets: ["SpectroCLI"]),
    ],
    traits: [
        // Libraries that only use SpectroKit can depend on Spectro with `traits: []` to skip these tools' dependencies.
        .trait(name: "CLI", description: "The spectro command and its ArgumentParser and Noora dependencies."),
        .trait(name: "Migrations", description: "SpectroMigrations' command-line entry point and its ArgumentParser dependency."),
        // Without it, the spectro command prints plain text and Noora is not fetched.
        .trait(name: "RichTerminal", description: "Colors, spinners, prompts, and tables in the spectro command (Noora).",
               enabledTraits: ["CLI"]),
        .default(enabledTraits: ["CLI", "Migrations", "RichTerminal"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-kit.git", from: "2.7.0"),
        .package(url: "https://github.com/vapor/sql-kit.git", from: "3.30.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
        .package(url: "https://github.com/vapor/async-kit.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.34.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/tuist/Noora", .upToNextMajor(from: "0.15.0")),
    ],
    targets: [
        .target(
            name: "SpectroCommon",
            dependencies: [],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .macro(
            name: "SpectroMacros",
            dependencies: [
                "SpectroCommon",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SpectroMacros",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Spectro",
            dependencies: [
                "SpectroCommon",
                "SpectroMacros",
                .product(name: "PostgresKit", package: "postgres-kit"),
                .product(name: "SQLKit", package: "sql-kit"),
                .product(name: "AsyncKit", package: "async-kit"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/Spectro",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "SpectroMigrations",
            dependencies: [
                "Spectro", "SpectroCommon",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["Migrations"])),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpectroMigrationsTests",
            dependencies: ["SpectroMigrations", "Spectro", "SpectroCommon"],
            resources: [.copy("Resources/LegacySQL")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "SpectroCLI",
            dependencies: [
                "SpectroCommon",
                "Spectro",
                .product(name: "ArgumentParser", package: "swift-argument-parser", condition: .when(traits: ["CLI"])),
                .product(name: "Noora", package: "Noora", condition: .when(traits: ["RichTerminal"])),
            ],
            path: "Sources/SpectroCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SpectroTests",
            dependencies: [
                "SpectroCommon",
                "Spectro",
                "SpectroMigrations",
                "SpectroCLI",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/SpectroTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
