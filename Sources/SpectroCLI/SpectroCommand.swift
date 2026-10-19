import ArgumentParser
import Foundation

@main
struct SpectroCommand: AsyncParsableCommand {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            if arguments.count >= 2, arguments[0] == "migrate",
               ["up", "down", "status", "plan"].contains(arguments[1]),
               let project = try MigrationProject.discover() {
                let status = try await MigrationProjectLauncher.run(project: project, arguments: Array(arguments.dropFirst()))
                exit(withError: ExitCode(rawValue: status))
            }
        } catch { exit(withError: error) }
        await main(nil)
    }
    static let configuration = CommandConfiguration(
        commandName: "spectro",
        abstract: "Manage PostgreSQL databases and SQL or Swift migrations.",
        discussion: """
            Start a Swift migration target with:
              spectro migrate init --target MyAppMigrations

            With .spectro.json, migration commands launch your project's executable through SwiftPM. \
            Without it, SQL migrations are read from Sources/Migrations in the current directory.

            Use 'spectro help migrate' for setup and configuration, or \
            'spectro help generate migration' for file generation.
            """,
        version: "2.6.0",
        subcommands: [
            DatabaseGroup.self,
            MigrateGroup.self,
            GenerateGroup.self,
            Test.self,
        ]
    )
}

struct DatabaseGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "database",
        abstract: "Create or drop PostgreSQL databases.",
        discussion: """
            Credential options override .env in the current directory, then process environment. \
            DB_HOST and DB_PORT default to localhost and 5432. DB_USER defaults to postgres; \
            DB_PASSWORD defaults to an empty string. Supply the database name as an argument \
            or with --database; these commands connect through the postgres maintenance database.

            These commands manage the database itself. Use 'spectro migrate' for schema changes.
            """,
        subcommands: [Create.self, Drop.self]
    )
}

struct MigrateGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Set up, preview, apply and roll back migrations.",
        discussion: """
            Swift workflow:
              spectro migrate init --target MyAppMigrations
              Add the printed target to Package.swift.
              spectro generate migration CreateUsers
              Fill in the declaration and register CreateUsers() in Migrations.swift.
              spectro migrate plan
              spectro migrate up

            A .spectro.json in the nearest Swift package selects the project's executable. \
            Up, down, status and plan run through SwiftPM, which may build or resolve dependencies. \
            Help and plan do not connect to PostgreSQL. Database commands use DB_HOST, DB_PORT, \
            DB_USER, DB_PASSWORD and DB_NAME from process environment, plus credential options. \
            The Swift executable does not automatically read .env.

            Without a descriptor, up/down/status use SQL files in Sources/Migrations in the \
            current directory. SQL commands load .env there; options override .env, then environment. \
            Plan requires a Swift migration target. Omitting --step on down rolls back all applied migrations.
            """,
        subcommands: [Migrate.self, Rollback.self, Status.self, InitializeMigrations.self, PlanMigrations.self]
    )
}

struct GenerateGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate a Swift declaration or SQL migration file.",
        subcommands: [GenerateMigration.self]
    )
}
