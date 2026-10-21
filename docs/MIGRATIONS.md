# Swift migrations

Spectro **2.1.0** adds the optional **SpectroMigrations** product. Existing SpectroKit applications and SQL migration directories retain their API and workflow. The same material is available as linked guides and API reference in the [DocC website](../Documentation/README.md).

Your application owns a compiled migration executable. The installed spectro CLI scaffolds files and launches that executable through SwiftPM during development. Production runs the built executable directly. Keep the app and migration target in the same package and commit Package.resolved so they use the same dependency versions.

- [Set up a target](#set-up-a-target)
- [Declare historical changes](#declare-historical-changes)
- [Explicit rollback and SQL](#explicit-rollback-and-sql)
- [Commands and configuration](#commands-and-configuration)
- [Adopt existing SQL](#adopt-existing-sql)
- [Deploy a compiled artifact](#deploy-a-compiled-artifact)
- [Verify the distribution contract](#verify-the-distribution-contract)
- [Troubleshooting](#troubleshooting)

For every command and option, see the [CLI reference](CLI.md).

## Set up a target

For the 2.1.0 release, add the package dependency and install the matching CLI:

~~~swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.1.0")
~~~

~~~sh
mint install roost-framework/Spectro@2.1.0
spectro --version
~~~

For development against a local checkout, a consumer package can use a local dependency:

~~~swift
.package(name: "Spectro", path: "../Spectro")
~~~

For local development, build the CLI from this checkout and put the resulting executable on your shell's path. The 2.0.0 CLI does not include this workflow. This example uses an external cache to keep generated artifacts outside the source checkout:

~~~sh
# Run from this Spectro checkout.
swift build --scratch-path "$HOME/.cache/spectro-cli" --product spectro
export PATH="$(swift build --scratch-path "$HOME/.cache/spectro-cli" --show-bin-path):$PATH"
spectro migrate --help
~~~

Then change to your application package and initialize the target:

~~~sh
spectro migrate init --target MyAppMigrations
~~~

This creates .spectro.json, EntryPoint.swift, Migrations.swift and a Migrations directory under Sources/MyAppMigrations. It prints this target declaration for you to add to Package.swift:

~~~swift
.executableTarget(
    name: "MyAppMigrations",
    dependencies: [.product(name: "SpectroMigrations", package: "Spectro")]
)
~~~

Use the identity of your Spectro package dependency in the package argument. The command leaves Package.swift unchanged and refuses to overwrite an existing descriptor or source target.

The descriptor is:

~~~json
{
  "formatVersion": 1,
  "migrations": {
    "product": "MyAppMigrations",
    "sourceDirectory": "Sources/MyAppMigrations"
  }
}
~~~

Discovery stops at the nearest Package.swift. Source paths must stay inside that package, including when ancestors are symlinks. Malformed descriptors and failed builds are errors.

Generate a declaration:

~~~sh
spectro generate migration CreateUsers
~~~

The command creates `Sources/MyAppMigrations/Migrations/CreateUsers.swift` and prints the registration line to add to `Migrations.swift`:

~~~swift
import SpectroMigrations

let migrations = MigrationRegistry {
    CreateUsers()
}
~~~

Registration is explicit. Unregistered files are not migrations. An empty generated declaration compiles but fails planning when registered. Its explicit empty getter supports Swift 6.0; after adding operations, the shorthand below also works.

EntryPoint.swift supplies the program entry point:

~~~swift
import SpectroMigrations

@main
struct MigrationMain {
    static func main() async {
        await MigrationCommand.main(migrations: migrations)
    }
}
~~~

Keep this in EntryPoint.swift; a file named main.swift uses Swift's other entry-point convention.

## Declare historical changes

~~~swift
import SpectroMigrations

struct CreateUsers: Migration {
    static let id = "1791129600_create_users"

    var change: MigrationPlan {
        CreateTable("users") { table in
            table.column("id", .uuid).primaryKey().default(.sql("gen_random_uuid()"))
            table.column("email", .text).notNull()
            table.column("display_name", .text)
            table.column("active", .boolean).notNull().default(true)
            table.timestamps()
        }

        CreateIndex("users_email_index", on: "users", columns: ["email"]).unique()
    }
}
~~~

There is no implicit primary key. Columns are nullable unless marked notNull or primaryKey. String defaults are literal strings; .sql explicitly accepts a trusted PostgreSQL expression. Identifiers are quoted separately, including a dot inside a name. Use the schema argument to qualify an object.

timestamps creates created_at and updated_at as TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP. It does not refresh updated_at when a row changes.

~~~swift
struct ExtendUserProfile: Migration {
    static let id = "1791129601_extend_user_profile"

    var change: MigrationPlan {
        AlterTable("users") { table in
            table.rename("display_name", to: "nickname")
            table.add("bio", .text)
        }
    }
}
~~~

Rollback drops bio, then renames nickname back to display_name. Both top-level operations and operations inside AlterTable reverse order. There is no automatic CASCADE or IF EXISTS.

~~~swift
struct ReshapePosts: Migration {
    static let id = "1791129603_reshape_posts"

    var change: MigrationPlan {
        CreateEnum("post_state", values: ["draft", "published"])
        AlterTable("posts") { table in
            table.remove("legacy_slug", .varchar(length: 80)).notNull().default("")
            table.alter("views", type: .bigint, from: .integer)
            table.setNotNull("title")
            table.setDefault("state", .sql("'draft'"), from: nil)
            table.check("posts_views_nonnegative", sql: "views >= 0")
            table.unique("posts_slug_key", columns: ["slug"])
            table.foreignKey("editor_id", references: "users", onDelete: .setNull)
        }
        RenameTable("posts", to: "articles")
    }
}
~~~

Each alteration has an automatic rollback: remove adds the column back as described by its modifiers, without its data, so a NOT NULL column needs a default for the rows that exist then; alter restores the old type; setNotNull and dropNotNull invert each other; setDefault restores the old default, nil meaning none; check, unique, and foreignKey drop their constraint. A type change must not need a USING expression, and its rollback fails if the values no longer fit the old type. dropConstraint and DropIndex cannot be inverted, so they belong in an explicit Reversible or Irreversible branch. CreateEnum creates a type for .named columns and drops it on rollback.

~~~swift
struct CreateIssues: Migration {
    static let id = "1791129602_create_issues"

    var change: MigrationPlan {
        CreateTable("issues") { table in
            table.column("id", .uuid).primaryKey().default(.sql("gen_random_uuid()"))
            table.column("author_id", .uuid)
                .notNull().references("users", column: "id", onDelete: .restrict)
            table.column("title", .text).notNull()
            table.column("priority", .integer).notNull().default(0)
            table.check("issues_priority_nonnegative", sql: "priority >= 0")
            table.timestamps()
        }

        CreateIndex("issues_author_id_index", on: "issues", columns: ["author_id"])
    }
}
~~~

A reference defaults to a table_column_fkey constraint name. Supply name for an explicit name, and schema separately for a referenced schema. It does not create an index. Supported delete actions are noAction, restrict, cascade, setNull and setDefault. SET NULL cannot accompany a non-null column; SET DEFAULT requires a declared default.

The typed column vocabulary is uuid, text, varchar(length:), smallint, integer, bigint, real, doublePrecision, numeric(precision:scale:), boolean, date, timestamp, timestamptz, bytea, json and jsonb, arrays of any of them with .array, and other types by name with .named, such as an enum or citext. Named B-tree indexes support multiple columns, unique(), whereSQL for a trusted partial predicate, and concurrently(). Composite primary keys and other PostgreSQL features use explicit SQL.

### Indexes built concurrently

PostgreSQL builds or drops an index CONCURRENTLY without blocking writes, but not inside a transaction. Declare such a migration with runsInTransaction set to false, like Ecto's @disable_ddl_transaction:

~~~swift
struct IndexIssueTitles: Migration {
    static let id = "1791129604_index_issue_titles"
    static let runsInTransaction = false

    var change: MigrationPlan {
        CreateIndex("issues_title_index", on: "issues", columns: ["title"]).concurrently()
    }
}
~~~

Each statement of such a migration commits on its own, and the ledger records the migration after its last statement, so a failure leaves the statements before it applied and the migration pending. Before running it again, undo what it applied; a failed CREATE INDEX CONCURRENTLY leaves an INVALID index to drop. Planning rejects a concurrent index operation in a migration that runs in a transaction. A SQL file opts out the same way, as in dbmate: write `-- migrate:up transaction:false`.

## Explicit rollback and SQL

~~~swift
struct AddEmailConstraint: Migration {
    static let id = "1791129603_add_email_constraint"

    var change: MigrationPlan {
        SQL(
            up: "ALTER TABLE users ADD CONSTRAINT users_email_present CHECK (btrim(email) <> '')",
            down: "ALTER TABLE users DROP CONSTRAINT users_email_present"
        )
    }
}
~~~

~~~swift
struct ReplaceLegacyLabels: Migration {
    static let id = "1791129604_replace_legacy_labels"

    var change: MigrationPlan {
        Reversible {
            DropTable("legacy_labels")
        } down: {
            CreateTable("legacy_labels") { table in
                table.column("name", .text).notNull()
            }
        }
    }
}
~~~

Explicit branches execute their listed operations forward, in declaration order. A nested Reversible selects the enclosing direction; its chosen branch is not inverted again. A paired SQL operation inside an explicit branch executes its up script, just as a CreateTable creates a table there.

Recreating a dropped table restores its shape, not its former rows. Declare unrecoverable changes deliberately:

~~~swift
struct NormalizeEmail: Migration {
    static let id = "1791129605_normalize_email"

    var change: MigrationPlan {
        Irreversible("The original spelling of email addresses is not retained") {
            SQL("UPDATE users SET email = lower(email)")
        }
    }
}
~~~

Unpaired SQL and DropTable require an explicit branch. Empty explicit branches are rejected. Irreversible cannot appear inside an explicit down branch. If a selected rollback batch contains an irreversible migration, the entire batch fails preflight before changing the database.

Raw SQL runs in the same transaction as typed operations and the ledger update. Prepared SQL rejects transaction control. CREATE INDEX CONCURRENTLY needs a migration that does not run in a transaction; see Indexes built concurrently. Dollar-quoted function bodies, escape strings, quoted identifiers and nested comments retain their statement boundaries.

## Commands and configuration

~~~sh
spectro migrate --help
spectro help migrate plan
spectro migrate plan
spectro migrate plan --direction down
spectro migrate plan --migration 1791129600_create_users --direction down
spectro migrate up
spectro migrate status
spectro migrate down --step 1
~~~

Without the installed CLI, use `swift run MyAppMigrations` followed by the same subcommand and options. The built executable also provides help: `MyAppMigrations --help` or `MyAppMigrations down --help`.

`plan` previews **all registered migrations** without connecting to PostgreSQL, regardless of the database's applied state. `--migration` selects one full ID; `--direction` accepts `up` (the default) or `down`. Up previews follow ascending IDs, and down previews follow descending IDs and each migration's rollback order. Unknown IDs and irreversible down previews fail before printing a partial plan.

“Offline” means no database access: SwiftPM may still resolve dependencies or compile the project. Planning validates definitions and statement boundaries; PostgreSQL validates full SQL syntax and schema references at execution. `status` reads the ledger without creating it and reports applied IDs missing from the artifact.

**Omitting --step rolls back all completed migrations.** Zero is a no-op; negative values are rejected. Rollback preflights the selected applied IDs before executing anything. Missing history never causes an older migration to be rolled back instead.

The executable loads configuration only for database commands:

| Setting | Behavior |
|---|---|
| DB_HOST | Defaults to localhost |
| DB_PORT | Defaults to 5432; must be an integer from 1 through 65535 |
| DB_USER | Required unless --username supplies it |
| DB_PASSWORD | Required unless --password supplies it; an empty password is allowed |
| DB_NAME | Required unless --database supplies it |

The executable reads process environment, **not .env files**. Export values in your shell or deployment configuration. The legacy SQL CLI retains its existing flags > .env > environment > defaults precedence. Swift generation and initialization do not need credentials.

~~~sh
export DB_HOST=localhost
export DB_PORT=5432
export DB_USER=postgres
export DB_PASSWORD=postgres
export DB_NAME=myapp_dev
spectro migrate up
~~~

The database must already exist. Use `spectro database create myapp_dev` or your usual database provisioning process first. Unlike Swift generation, legacy SQL generation requires database access to record its pending migration. See the [CLI reference](CLI.md#database-configuration) for the two configuration policies.

A custom configuration provider can return Spectro.DatabaseConfiguration, including TLS and pool settings:

~~~swift
await MigrationCommand.main(
    migrations: migrations,
    configuration: { try DatabaseConfiguration.fromEnvironment() }
)
~~~

Import Spectro when referring to DatabaseConfiguration. The provider runs lazily, and credential flags preserve its other settings. It owns its environment policy; use the default provider for the strict DB_PORT validation described above. MigrationCommand.run(arguments:migrations:configuration:) returns an exit code for embedding or tests without exiting the host process.

## Adopt existing SQL

Copy existing files unchanged into Sources/MyAppMigrations/LegacySQL. Add this argument to the executable target:

~~~swift
resources: [.copy("LegacySQL")]
~~~

Register the resource directory alongside Swift migrations:

~~~swift
let migrations = MigrationRegistry {
    SQLMigrations(bundle: .module, directory: "LegacySQL")
    CreateUsers()
}
~~~

Bundle.module exists only for a target with resources. Missing directories fail planning. Resource lookup is independent of the working directory.

SQL and Swift use the same schema_migrations ledger, full migration ID, lexical ordering, advisory lock and transaction engine. Keep old SQL filenames, contents and IDs. Do not translate an applied SQL file into a new Swift ID: that would describe another migration. Duplicate full IDs across either source fail before execution. Legacy SQL files with an empty down section retain their existing no-op behavior.

The generator assigns an epoch_seconds_lower_snake_case ID once. Keep it unchanged, and retain every applied migration in later artifacts. Different names with the same timestamp remain distinct IDs and sort lexically. Use historical names and types directly; do not derive a migration from current application models. Bodies must be deterministic and are captured once when the registry is assembled.

## Deploy a compiled artifact

Build on the deployment platform from the same revision and Package.resolved as the application:

~~~sh
swift build -c release --product MyAppMigrations
swift build -c release --show-bin-path
~~~

Copy MyAppMigrations and **all required SwiftPM resource bundles** from the reported directory into the artifact. Ship the platform's Swift/system runtime libraries as required. Keep resource bundles beside the executable. A macOS binary cannot serve as a Linux deployment artifact.

Run the binary in a dedicated deployment step with database environment supplied:

~~~sh
/path/to/artifact/MyAppMigrations plan
/path/to/artifact/MyAppMigrations up
~~~

This needs no Swift compiler, SwiftPM, Mint or source checkout. A failed migration step must fail the deployment. The entry point handles SIGINT/SIGTERM, including as Linux PID 1; process termination closes database sockets so PostgreSQL can roll back and release the session lock. The installed CLI forwards termination to its child process group and retains the child's exit status.

Use a direct PostgreSQL connection or session pooling. Migration execution reserves one connection and holds the existing advisory lock for the command; each migration and its tracking update share a transaction. A later migration failing does not undo earlier committed migrations. The default lock wait is 30 seconds. A network partition still depends on PostgreSQL/TCP disconnect detection.

## Verify the distribution contract

From this repository, with Python 3, psql and a local PostgreSQL role permitted to create disposable databases and roles:

~~~sh
python3 scripts/migrations_acceptance.py --artifact-dir /tmp/spectro-migrations-artifact
~~~

The harness builds a separate Swift 6.0 consumer in release mode, copies its executables/resources out of the build directory, disables compiler lookup, and exercises SQL adoption, rollback, concurrency, missing history and interruption. It always uses fresh databases and removes them afterward. --build-root selects an external build cache; --skip-build reuses that cache.

On Linux, validate the same artifact in a container containing runtime libraries only:

~~~sh
docker build -t spectro-migrations-runtime \
  -f Tests/Fixtures/SwiftMigrationsConsumer/Dockerfile.runtime \
  /tmp/spectro-migrations-artifact
python3 scripts/migrations_acceptance.py --skip-build \
  --runtime-image spectro-migrations-runtime --docker-network host
~~~

Build with the Swift version used by Dockerfile.runtime. The fixture includes additional executables solely to exercise missing and duplicate history and termination. Normal applications need one migration executable.

The [IssueTracker example](../Examples/IssueTracker/README.md) adds a compiled Swift migration to its existing SQL history and verifies data over HTTP after rollback/reapply and restart. Its Peregrine toolchain requirements are separate from Spectro's Swift 6.0 floor.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `migrate init` or `plan` is unknown | Install the 2.1 CLI and check `spectro --version`, or build it from a local checkout. The 2.0 CLI does not include these commands. |
| `No Swift migrations configured in this package` | Run `init` in the application package and keep `.spectro.json` beside its `Package.swift`. Discovery stops at the nearest package boundary. |
| SwiftPM cannot find the migration product | Add the executable target printed by `init` to `Package.swift`; match its product name to `.spectro.json`. |
| A generated declaration is absent from `plan` | Add its instance to `MigrationRegistry` in `Migrations.swift`. Source files are not registered automatically. |
| `Migration is empty` | Fill the generated `change` body before registering and applying it. |
| Credentials are missing although `.env` exists | Export `DB_USER`, `DB_PASSWORD`, and `DB_NAME`, pass credential options, or provide application configuration. The executable does not automatically load `.env`. |
| SwiftPM fails while requesting command help | Use `spectro help migrate <command>` for the launcher's reference without building the project. |
| SQL resources are missing after deployment | Copy the SwiftPM resource bundles beside the executable; run from the complete artifact. |
| Rollback reports missing history | Deploy an artifact containing the applied IDs. Keep existing SQL filenames, contents, and registration unchanged. |
| A down preview fails on an irreversible migration | The whole-catalog down plan includes that migration. Inspect a specific reversible ID with `--migration`; this does not change what an actual rollback batch may select. |
