# Changelog

## 2.4.0 — 2026-10-17

- Add `restore(_:id:)` to `Repo`. It clears a soft-deleted record's deletion timestamp and returns the record, returns a record that is not deleted unchanged, and throws `SpectroError.notFound` for an unknown id.
- Add `get(_:id:withDeleted:)` to `Repo`. With `withDeleted: true` it returns soft-deleted records too, like `Query.withDeleted()`. Both additions are protocol extensions, so custom `Repo` conformances keep compiling.
- `update(_:id:changes:)` and changeset updates now treat soft-deleted records as missing, as `get` does. They modified soft-deleted records and returned them as if they were active. An update that matches no record now throws `SpectroError.notFound` instead of `SpectroError.databaseError`. If you revive records by setting their deletion timestamp to `nil` through `update`, call `restore` instead.
- Report 2.4.0 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.4.0, and require 2.4.0 in the package installation examples.

[Full comparison with 2.3.3](https://github.com/roost-framework/Spectro/compare/2.3.3...2.4.0)

## 2.3.3 — 2026-10-17

- Exclude soft-deleted records of joined tables from `join`, `leftJoin`, `rightJoin`, and `joinThrough`. Only the queried table's soft-delete filter was applied, so joins returned the joined table's soft-deleted records and typed left joins decoded them, while `preload` and lazy relations on the same models excluded them. `.withDeleted()` still includes them. Every release since soft deletes were added in 2.0.0 is affected.
- Report 2.3.3 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.3, and require 2.3.3 in the package installation examples.

[Full comparison with 2.3.2](https://github.com/roost-framework/Spectro/compare/2.3.2...2.3.3)

## 2.3.2 — 2026-10-11

- Exclude soft-deleted records from `sum`, `avg`, `min`, `max`, their `grouped` forms, and `select`. These read the query's filters without the automatic soft-delete filter, so `select` returned soft-deleted records' values and aggregates counted them, while `all()` and `count()` on the same query excluded them. `.withDeleted()` still includes them. Every release since soft deletes were added in 2.0.0 is affected.
- Report 2.3.2 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.2, and require 2.3.2 in the package installation examples.

[Full comparison with 2.3.1](https://github.com/roost-framework/Spectro/compare/2.3.1...2.3.2)

## 2.3.1 — 2026-10-11

- Fix queries that combine `||` with other filters returning rows those filters should exclude. `Query.where` joined clauses with a bare `AND`, so `.where { $0.a == x || $0.b == y }.where { $0.ownerID == me }` ran as `a = x OR (b = y AND owner_id = me)` and returned other owners' rows matching `a`. The automatic soft-delete filter was combined the same way, so a single `||` condition also returned soft-deleted rows. Each `where` and `having` clause is now parenthesized. Every earlier release is affected; upgrade if any query combines `||` with an ownership, tenant, or authorization filter.
- Report 2.3.1 from `spectro --version`, pin the Mint installation examples and the Mintfile to 2.3.1, and require 2.3.1 in the package installation examples.

[Full comparison with 2.3.0](https://github.com/roost-framework/Spectro/compare/2.3.0...2.3.1)

## 2.3.0 — 2026-10-07

- Put Noora behind a new `RichTerminal` package trait, on by default with `CLI` and `Migrations`. With only `CLI` enabled, the `spectro` command prints plain text: alerts with their takeaways, progress steps, a `[y/N]` confirmation, and aligned tables. Roost enables only `CLI`, so `roost spectro` keeps working without fetching Noora.
- CI builds the `spectro` command without Noora.
- Report 2.3.0 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.3.0.

[Full comparison with 2.2.0](https://github.com/roost-framework/Spectro/compare/2.2.0...2.3.0)

## 2.2.0 — 2026-10-07

- Put the `spectro` command's dependencies (ArgumentParser and Noora) behind the `CLI` package trait, and SpectroMigrations' ArgumentParser dependency behind the `Migrations` trait. Both are on by default. A package that only uses SpectroKit, such as a framework built on Spectro, can depend on it with `traits: []`; SwiftPM then skips fetching those tools' dependencies.
- Require Swift 6.1 (swift-tools-version 6.1), the first version with package traits. Swift 6.0 projects keep resolving Spectro 2.1.x.
- Report 2.2.0 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.2.0.

[Full comparison with 2.1.1](https://github.com/roost-framework/Spectro/compare/2.1.1...2.2.0)

## 2.1.1 — 2026-10-06

- Depend on swift-syntax through its canonical `swiftlang/swift-syntax` URL. Packages that also depend on ESW no longer get SwiftPM's conflicting-identity warning, which future SwiftPM versions turn into an error.
- Report 2.1.1 from `spectro --version` and pin the Mint installation examples and the Mintfile to 2.1.1.

[Full comparison with 2.1.0](https://github.com/roost-framework/Spectro/compare/2.1.0...2.1.1)

## 2.1.0 — 2026-10-06

- Add the optional `SpectroMigrations` product: deterministic Swift declarations, PostgreSQL compilation, explicit registration, reversible schema operations, references/checks, and explicit SQL/irreversible branches.
- Ship a project-owned migration executable with offline `plan`, lazy database configuration, bundled SQL history, and strict rollback preflight for missing or irreversible history.
- Add `spectro migrate init`, configured Swift migration generation, and project-aware command forwarding with exit-status and signal propagation.
- Stop package discovery at the filesystem root so SQL migration commands also work outside Swift packages on macOS.
- Share the existing session lock and transactional engine through `MigrationRunner`; retain `MigrationManager` and the legacy SQL CLI APIs.
- Fix statement splitting for quoted identifiers, PostgreSQL escape strings, bind parameters, and nested comments.
- Add copied release-artifact and compiler-free Linux deployment acceptance, plus a compiled migration scenario in the HTTP example.
- Document Swift target setup, explicit registration, SQL adoption, exported configuration, and compiled deployment; expand launcher and project-executable help with examples, preview options, and rollback defaults.
- Add a merged DocC website with guides and API navigation for Spectro, SpectroMigrations, and SpectroCommon; build and check it with `python3 scripts/build_docs.py`.
- Report the CLI release version with `spectro --version` and pin installation examples and the Mintfile to 2.1.0.

Existing `SpectroKit` consumers need no additional product dependency or protocol changes. The minor version reflects an additive public surface. See the [upgrade guide](docs/UPGRADING-2.1.md) and [migration guide](docs/MIGRATIONS.md).

[Full comparison with 2.0.0](https://github.com/roost-framework/Spectro/compare/2.0.0...2.1.0)

## 2.0.0 — 2026-10-04

Spectro 2.0 focuses on PostgreSQL correctness and application-level validation. It also includes the changeset, pagination, and soft-delete APIs added since 1.2.0.

### Breaking changes

- Custom `Repo` conformers must implement `insert(_ changeset:)` and `update(_ changeset:)`. Spectro's built-in repositories already implement both requirements, including inside transactions.
- Model-returning right joins now throw because their result types cannot represent an absent main model. Reverse the query and use a left join. Typed self joins and repeated tables are rejected until table aliases are supported; typed left joins require a nonnullable primary key on the joined schema.
- Typed joined reads now throw when a present row cannot be decoded, instead of substituting default values or silently omitting it.
- Migration runners require a direct or session-pooled connection and transaction-compatible SQL. Use the 2.0 runner consistently when multiple processes can migrate the same database.

See the [upgrade guide](docs/UPGRADING-2.0.md) for migration examples and operational changes.

### Added

- Changesets with permitted-field casting, validators, serializable errors, uniqueness checks, and repository insert/update support.
- `Query.page(size:page:)` with total counts and navigation metadata.
- Opt-in soft deletes with `@SoftDelete` and `.withDeleted()`.
- A public-API IssueTracker HTTP application and repeatable acceptance command covering transactions, joined reads, competing writes, populated migrations, rollback/reapply, and restart persistence.

### Fixed

- `@Schema` recognizes `@SoftDelete`, generates filtering metadata, and preserves deletion timestamps in decoded models and JSON.
- Migration SQL and status recording now use the same transaction. Competing migration commands serialize through a PostgreSQL advisory lock, with bounded lock waiting and cancellation cleanup.
- Joined models decode from separate projections, preserving IDs, timestamps, custom column mappings, and nullable fields without column collisions. An unmatched left-joined model is `nil`.
- Query parameters follow SQL order across joins, filters, and HAVING clauses; soft-delete filters are qualified in joined queries.
- Changeset casting rejects invalid field types and non-finite numbers before persistence. Both repositories honor custom column names.
- Recursive error formatting no longer crashes when reporting `SpectroError`; transaction failures preserve the original error after successful rollback.
- Database connections honor configured TLS settings and reject invalid settings before allocating event-loop threads.
- Fresh-database migration commands initialize their tracking state, while migration status remains read-only.
- CI propagates test failures. Acceptance build artifacts use a local cache to avoid macOS signing failures caused by Finder metadata in cloud-synced folders.

### Compatibility and validation

- Spectro requires Swift 6.0+ and supports macOS 13+ and Linux with PostgreSQL.
- The core suite contains 368 tests, including concurrent migration processes, cancellation, and macro-defined soft deletes. CI runs PostgreSQL-backed tests on macOS and Linux.
- Building the IssueTracker acceptance application requires Swift 6.3+ and an Xcode 26.3+ SDK on a compatible host (macOS 15.6+ for Xcode 26.3); its package deployment target is macOS 14. Its pinned Peregrine 1.2.0 dependency currently prevents that example from building on Linux; Spectro's core Linux support is unaffected.

[Full comparison with 1.2.0](https://github.com/roost-framework/Spectro/compare/1.2.0...2.0.0)
