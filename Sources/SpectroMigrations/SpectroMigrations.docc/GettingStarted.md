# Getting started with Swift migrations

Add a migration executable to your package, register a declaration, and preview its SQL.

## Overview

### Add the package and target

Use Spectro 2.1.0 or later in `Package.swift`:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.6.0")
```

Install the matching development CLI with Mint, then run initialization from your application package:

```sh
mint install roost-framework/Spectro@2.6.0
spectro migrate init --target MyAppMigrations
```

For development against a local checkout, use a local package dependency, `.package(name: "Spectro", path: "../Spectro")`, and build that checkout's `spectro` product instead. The 2.0 CLI does not contain these commands.

Initialization creates `.spectro.json` and the following target layout:

```text
Sources/MyAppMigrations/
    EntryPoint.swift
    Migrations.swift
    Migrations/
```

It prints this declaration for you to add to the package's `targets` array:

```swift
.executableTarget(
    name: "MyAppMigrations",
    dependencies: [.product(name: "SpectroMigrations", package: "Spectro")]
)
```

Use the package identity of your Spectro dependency. Initialization leaves `Package.swift` unchanged and refuses to overwrite an existing descriptor or target. Keep the application and migration target in the same package, and commit `Package.resolved`.

### Generate and register a change

```sh
spectro generate migration CreateUsers
```

Fill `Migrations/CreateUsers.swift` with a declaration such as the ``CreateTable`` example on the module's landing page. Keep the generated `id`: it identifies that historical change for its entire lifetime.

Add the instance to `Migrations.swift`:

```swift
import SpectroMigrations

let migrations = MigrationRegistry {
    CreateUsers()
}
```

Registration is explicit. A source file alone does not add a migration. An empty declaration compiles but fails planning once registered. The generated empty `get {}` accessor supports Swift 6.0; a populated declaration can use the shorter `var change: MigrationPlan { ... }` form.

`EntryPoint.swift` contains the program entry point:

```swift
import SpectroMigrations

@main
struct MigrationMain {
    static func main() async {
        await MigrationCommand.main(migrations: migrations)
    }
}
```

Keep the file named `EntryPoint.swift`; `main.swift` uses Swift's other entry-point convention.

### Preview and apply

```sh
spectro migrate plan
spectro migrate plan --direction down
```

Planning compiles all registered changes without connecting to PostgreSQL. SwiftPM may still download dependencies and build the executable. Inspect both directions before applying the change.

Export credentials and use an existing database:

```sh
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=postgres
export DB_PASSWORD=postgres
export DB_NAME=myapp_dev
spectro migrate up
spectro migrate status
spectro migrate down --step 1
```

The executable does not load `.env` automatically. Provision the database first, for example with `spectro database create myapp_dev`. Omitting `--step` on `down` rolls back **all** completed migrations.

### Next steps

- <doc:DeclaringChanges> describes columns, indexes, and references.
- <doc:AdoptingSQL> keeps existing SQL history in the same executable.
- <doc:CommandsAndConfiguration> covers descriptor discovery, previews, and credentials.
- <doc:Deployment> explains the artifact to ship.
