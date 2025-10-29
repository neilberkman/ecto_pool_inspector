# EctoPoolInspector

Production-ready Ecto connection pool monitoring with cluster-aware snapshots.

**WARNING: EXPERIMENTAL - DO NOT USE IN PRODUCTION**

This library is completely untested in real-world scenarios and may contain bugs that could impact your database connections.

## Project Structure

This is an umbrella project containing:

- **apps/ecto_pool_inspector/** - The library itself
- **apps/inspector_test_harness/** - Phoenix app for E2E testing

## Why Umbrella?

The E2E test harness validates the library works in realistic, production-like scenarios:

- Pool exhaustion with concurrent connections
- Stack trace capture under load
- Cluster-wide snapshot aggregation
- Process monitoring and leak detection
- Nested transaction depth tracking

Unit tests prove components work in isolation. E2E tests prove the system solves the actual problem.

## Development

```bash
# Fetch dependencies
mix deps.get

# Run unit tests for the library
mix test apps/ecto_pool_inspector/test

# Run E2E tests (requires PostgreSQL)
cd apps/inspector_test_harness
MIX_ENV=test mix ecto.setup
MIX_ENV=test mix test test/e2e/

# Run all tests
mix test.all
```

## E2E Test Scenarios

### Scenario 1: Pool Saturation
Tests automatic snapshot capture when pool reaches 80% capacity. Validates stack traces, connection tracking, and depth handling.

### Scenario 4: Cluster-Wide RPC
Tests multi-node snapshot aggregation via RPC. Validates the `:all` and specific node targeting APIs.

### Multi-Pool Composite Key
Tests that a single process can hold connections from multiple pools simultaneously (validates the `{{client_pid, pool_pid}, ...}` schema fix).

## Known Issues

### Ecto.Adapters.SQL.Sandbox Compatibility

Currently, E2E tests fail with `:pool_not_discovered` because `Ecto.Adapters.SQL.Sandbox` wraps the pool and changes telemetry behavior. The inspector listens for `:db_connection` telemetry events which aren't emitted the same way in Sandbox mode.

**Solutions being explored:**
1. Use a real pool (non-Sandbox) for E2E tests
2. Add Sandbox-specific telemetry handlers
3. Manual pool PID injection for tests

## Library Documentation

See [apps/ecto_pool_inspector/README.md](apps/ecto_pool_inspector/README.md) for full library documentation, configuration, and usage examples.

## License

MIT
