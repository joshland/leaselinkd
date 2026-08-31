# AGENTS

`leaselinkd` is an event-driven Kea DHCPv4 → OPNsense Unbound bridge, currently version `2.1.1`. It uses a lightweight **agent** model: each executable has one responsibility.

1. **leaselinkd** – Persistent systemd daemon. It receives lease events, serializes OPNsense API operations, stores hostname-to-override UUID mappings in SQLite, defers reconfiguration, and health-checks OPNsense.
2. **kea-leaselink** – One-shot Kea `libdhcp_run_script.so` target. It converts the hook point and Kea environment variables to JSON, forwards one event, and exits.

Both agents share a *Memory* profile described in [MEMORY.md](./MEMORY.md). They are written in Zig `0.16.0` and compiled with release optimisations to minimise runtime footprint.

### Working state

Maintain [`state.json`](./state.json) as the agent's sole short-term working
state. At the start of every session, read it before asking about prior work.
Use this fixed schema only: `objective`, `phase`, `next_action`, `blocker`, and
`verification`. It contains current values required for the next action—not a
conversation summary, history, or completed-work log. Rewrite it after every
substantive step, before the next step begins; preserve the same keys even when
their values are `null`.

### Agent Communication

- **Transport** – `leaselinkd` exposes HTTP over a Unix socket (`/run/leaselinkd/fifo.pipe`) by default; local TCP is optional. The hook supports both `unix:///path` and `tcp://host:port`.
- **Protocol** – JSON over `POST /lease_event`, with `event`, `timestamp`, and lease `hostname`, `ip-address`, and `mac-address` fields.
- **Lease actions** – release, expiry, decline, and recovery delete an override; other valid IPv4 lease events add or update one.
- **OPNsense API** – Native Zig `std.http.Client` with HTTP Basic authentication; no `curl` subprocess. HTTPS verifies against the host trust store.
- **Reconfigure and health** – Reconfigure calls are coalesced by `throttle_seconds`. Health checks call `GET /api/unbound/service/status` at startup and on the configured interval, with capped exponential retry after failure.
- **DNS validation** – `dns_servers` configures one or more IPv4 UDP resolvers. Before an update, an existing matching A record is logged as redundant; startup validates every desired record, reporting errors for missing or mismatched records and warnings for multiple A records.

### Service account and operations

- The package creates `leaselinkd` user/group. The systemd service runs as this unprivileged account and owns `/run/leaselinkd` and `/var/lib/leaselinkd`.
- The Unix socket is mode `0660`; Kea's service account must be a member of `leaselinkd`.
- `/etc/leaselinkd/secrets.json` stays root-readable only and is passed to the service through systemd `LoadCredential`.
- `/etc/leaselinkd/hook.json` contains only the manager transport address and is `root:leaselinkd` mode `0640`, so the `kea` user can read it through its `leaselinkd` group membership without receiving secret access.
- Both binaries support `--loglevel ERROR|WARN|INFO|DEBUG`; avoid logging keys or secrets. Manager startup INFO logs include its version, architecture, safe configuration, and firewall health summary. DEBUG includes payloads, API paths, periodic health checks, and scheduler activity.
- `leaselinkd --config-check` validates parsed config, secrets, timer/listener values, and SQLite ledger access without opening a listener. `leaselinkd --api-test` performs an OPNsense status request and deliberately invokes Unbound reconfigure with a hard 60-second process deadline (exit status `124` on timeout).
- `SIGUSR1` requests a manager configuration and metrics snapshot: `systemctl kill -s USR1 leaselinkd.service`. Metrics include runtime, lease events, API calls/failures, health checks/failures, and reconfigures.
- `SIGUSR2` requests an immediate SQLite-to-OPNsense resync: `systemctl kill -s USR2 leaselinkd.service`. The manager reconciles owned remote overrides and queues durable desired records for reapplication.

### Build & Deployment

All agent binaries are built via the top-level `build.zig`. The artifacts are installed by the Arch PKGBUILD as `/usr/bin/leaselinkd` and `/usr/share/kea/scripts/kea-leaselink`. Validate with `zig build test -Doptimize=ReleaseSafe`; the integration test uses the real manager and hook against a local mock OPNsense API and verifies throttling, Basic authentication, persistence, and SIGUSR1 reporting.

### Change documentation

Update [CHANGELOG.md](./CHANGELOG.md) whenever implementation, packaging, runtime behavior, security boundaries, configuration, or documented limitations change. Keep entries chronological, grouped by semantic version, and include test-driven fixes that affect deployed behavior.

---

`leaselinkd` does not connect to PostgreSQL or use cron-scheduling
configuration. The separate `keadb-leaselinkd-sync` utility can import active Kea
PostgreSQL leases when explicitly invoked. See [MEMORY.md](./MEMORY.md) for
resource, persistence, monitoring, and security guidance.
