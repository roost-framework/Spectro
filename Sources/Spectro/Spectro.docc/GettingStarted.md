# Getting started with Spectro

Install the library, define a model, and query a PostgreSQL database.

## Overview

### Add the package

Spectro requires Swift 6.0 or later and supports macOS 13 or later and Linux. Add the package dependency and the `SpectroKit` product to your application target:

```swift
.package(url: "https://github.com/roost-framework/Spectro.git", from: "2.6.0")
```

```swift
.target(
    name: "MyApp",
    dependencies: [.product(name: "SpectroKit", package: "Spectro")]
)
```

The library's module name is `Spectro`. The optional `SpectroMigrations` product belongs on your migration executable target; ordinary ORM consumers do not need it.

### Define a model

```swift
import Foundation
import Spectro

@Schema("users")
struct User {
    @ID var id: UUID
    @Column var name: String
    @Column var email: String
    @Timestamp var createdAt: Date
}
```

The macro generates model initialization, schema metadata, row mapping, and `Encodable` conformance. Property names map to snake case column names by default. Model definitions do not create database tables: use migrations to establish the matching schema.

### Create the database schema

For a SQL migration, the equivalent table is:

```sql
-- migrate:up
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    email TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- migrate:down
DROP TABLE users;
```

See <doc:SQLMigrations> for the existing directory workflow. The **SpectroMigrations** API collection documents the optional Swift DSL and compiled executable workflow.

### Connect and query

```swift
let client = try Spectro(
    hostname: "localhost",
    username: "postgres",
    password: "postgres",
    database: "myapp_dev"
)
let repo = client.repository()

let inserted = try await repo.insert(User(name: "Alice", email: "alice@example.com"))
let users = try await repo.query(User.self)
    .where { $0.name == "Alice" }
    .orderBy({ $0.createdAt }, .desc)
    .limit(10)
    .all()

let fetched = try await repo.get(User.self, id: inserted.id)
await client.shutdown()
```

Use one client for the application's database lifetime and call `shutdown()` on both success and failure paths during teardown. The example uses local development credentials; configure deployed applications through their environment or configuration provider.

If the `Spectro` module name makes a type reference ambiguous, use the equivalent ``SpectroClient`` alias. Continue with <doc:SchemasAndChangesets>, <doc:QueriesAndRelationships>, and <doc:TransactionsAndConfiguration>.
