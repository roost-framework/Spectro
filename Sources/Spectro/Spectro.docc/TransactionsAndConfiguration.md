# Transactions and configuration

Share connection settings and keep transactional work on the supplied repository.

## Overview

### Configure a client

```swift
let configuration = DatabaseConfiguration(
    hostname: "localhost",
    port: 5432,
    username: "postgres",
    password: "postgres",
    database: "myapp_dev",
    maxConnectionsPerEventLoop: 4,
    numberOfThreads: 2
)
let client = try Spectro(configuration: configuration)
```

``DatabaseConfiguration`` also accepts `tlsConfiguration` when your deployment requires TLS. ``DatabaseConnection`` validates connection settings before allocating its event-loop threads and honors the supplied TLS configuration.

`DatabaseConfiguration.fromEnvironment()` reads `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, and `DB_NAME` from process environment. The username, password, and database are required. Host defaults to `localhost`; an absent or noninteger port falls back to `5432`. The default Swift migration command provider has a stricter port policy, documented in its API collection.

The library does not automatically read `.env`. The legacy SQL CLI has its own `.env` loading policy. Keep configuration loading at your application's boundary and pass the resulting value to Spectro.

### Execute one transaction

```swift
let user = try await client.transaction { tx in
    let inserted = try await tx.insert(
        User(name: "Alice", email: "alice@example.com")
    )
    let fetched = try await tx.get(User.self, id: inserted.id)
    return fetched
}
```

Transactions use `READ COMMITTED` isolation. The closure receives a ``Repo`` backed by the reserved transaction connection. Use that `tx` for all work that belongs in the transaction, including query builders and changeset writes. Throwing rolls back; successful completion commits.

Calling a separately captured pooled repository inside the closure performs work outside that transaction. Pass `any Repo` to application functions so they can receive either a pooled repository or the transaction's repository.

Nested transactions are unsupported and throw `SpectroError.transactionAlreadyStarted`. To roll back one step without aborting the transaction, call `savepoint(_:)` on the ``TransactionRepo``: it releases the savepoint when its body returns, and rolls back to it when the body throws, rethrowing the body's error unchanged. Errors that escape the closure come back wrapped in `SpectroError.transactionFailed`; `SpectroError.serverError` returns the underlying PostgreSQL error's SQLSTATE and constraint, or `nil`. Do not retain the transaction repository or ``TransactionContext`` after the closure returns.

### Shut down cleanly

Call `await client.shutdown()` when the application's database lifetime ends, including failure paths. Reuse the client and its pool during normal operation rather than creating a new connection system for each request.

Migration commands have their own session and transaction lifecycle. See <doc:SQLMigrations> for the SQL facade, or the **SpectroMigrations** API collection for the compiled executable.
