# Architecture Overview

This repository implements a **Kea DHCP ↔‑OPNsense Unbound sync** system comprised of two main components:

1. **leaselinkd** – A Zig HTTP server that exposes an internal API for creating, updating and deleting host overrides in OPNsense’s Unbound DNS. It also reconciles the state of Kea leases with Unbound on a configurable schedule.
2. **kea-leaselink** – A small Zig executable that runs as a *run_script* hook in Kea. For every lease event it converts the set of environment variables defined by Kea into a JSON payload and posts it to `/lease_event` on `leaselinkd`.

Both components are built and packaged into a single **AUR** package (`leaselinkd`). The system is deliberately stateless beyond an SQLite ledger that holds `hostname → uuid` mapping for deletions, and only communicates with OPNsense via HTTP Basic Auth using the keys stored in `/etc/leaselinkd/secrets.json`.

## Key Design Points
- **Serial API Calls** – All CRUD operations to OPNsense are serialized; this ensures deterministic state changes and respects Unbound’s reconfigure limits.
- **Reconfigure Throttling** – The server can only issue a `POST /api/unbound/service/reconfigure` once per *throttle_seconds* (default 10 s). Reconfiguration is grouped after each batch of events when the timer allows.
- **Health‑check** – A background goroutine performs `GET /api/unbound/service/status` every *health_check_seconds* (default 60 s) and triggers exponential back‑off if it fails. Initial wait is *initial_backoff_ms* (100 ms) up to *max_backoff_ms* (10 seconds).
- **Persistence** – SQLite database `dhcpdb.sqlite` is created on first run. It contains a single table (`overrides`) used only for mapping hostname → override UUID.
- **Configuration** – All runtime parameters live in `/etc/leaselinkd/config.json`. Secrets (`api_key`, `api_secret`, PostgreSQL pass) are kept separate in `/etc/leaselinkd/secrets.json`.
- **Transport** – The server accepts incoming requests over **AF_UNIX** socket by default (`/run/leaselinkd/fifo.pipe`). TCP mode is optional and configurable with `listen_type="tcp"` and `tcp_port=9080`.
- **`kea-leaselink` hook** – The hook extracts the following variables from Kea’s environment:
  - `LEASE4_ADDRESS`
  - `LEASE4_HOSTNAME`
  - `LEASE4_HWADDR`
  - optionally `LEASE4_VALID_LIFETIME`, `LEASE4_SUBNET_ID`, and `QUERY4_IFACE_NAME`
  - the hook point as the first argument (`$1`), not an environment variable.
  For `leases4_committed`, Kea instead supplies the indexed `LEASES4_*`
  variables (for example, `LEASES4_AT0_HOSTNAME`).
  These are turned into JSON and POSTed to `/lease_event`.
- **Reconciliation** – At startup and at cron times the manager pulls the active lease list from Kea’s PostgreSQL database, compares to the SQLite ledger and calls OPNsense CRUD functions to bring both systems in sync.

These components together provide a resilient, throttle‑aware, bidirectional DNS state machine for DHCP leases on an Arch Linux server running Kea & OPNsense.
