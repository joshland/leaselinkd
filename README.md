# leaselinkd

`leaselinkd` synchronizes Kea DHCPv4 lease events to OPNsense Unbound host overrides.

It consists of two small Zig 0.16 binaries:

- `leaselinkd` is the persistent local service. It accepts lease events, keeps a SQLite hostname-to-override UUID ledger, calls the OPNsense Unbound API, health-checks OPNsense, and defers Unbound reconfiguration to coalesce bursts of changes.
- `kea-leaselink` is invoked by Kea's `libdhcp_run_script.so` hook. It converts the event environment into JSON, sends it to the manager, and exits.

## Install

On Arch Linux, build and install the included package:

```sh
makepkg -si
sudoedit /etc/leaselinkd/config.json
sudoedit /etc/leaselinkd/secrets.json
sudo systemctl enable --now leaselinkd.service
```

To create a new Arch package build without changing the application version,
increment `pkgrel` with `scripts/buildnumber.sh`. It asks for confirmation by
default; use `scripts/buildnumber.sh --add` for a non-interactive increment
or `scripts/buildnumber.sh --reset` to set `pkgrel` back to `1`.

When upgrading the package, an already-running `leaselinkd.service` is
automatically restarted. An inactive service remains inactive.

The package declares `kea`, `sqlite`, `systemd`, `ca-certificates`, `openssl`,
and Python with Psycopg and Typer as runtime dependencies. `zig` is a build
dependency; Python also powers the one-shot lease importer and the package test
suite's local mock API server.

The package installs:

| Path | Purpose |
| --- | --- |
| `/usr/bin/leaselinkd` | Manager service |
| `/usr/share/kea/scripts/kea-leaselink` | Kea run-script target |
| `/usr/share/leaselinkd/fetch-firewall-certificate.sh` | Fetch the firewall-presented CA certificate without trusting it |
| `/usr/share/leaselinkd/trust-firewall-certificate.sh` | Install a trusted firewall CA into Arch's system trust store |
| `/usr/share/leaselinkd/check-firewall-certificate.sh` | Diagnose firewall certificate identity, extensions, and trust-chain failures |
| `/usr/share/leaselinkd/check-kea-config.py` | Validate Kea DDNS, run-script settings, and hook transport configuration |
| `/usr/share/leaselinkd/keadb-leaselinkd-sync` | One-shot import of active Kea PostgreSQL leases |
| `/usr/share/leaselinkd/setup-leaselinkd.sh` | Regular-user, sudo-assisted first-run setup and Kea bootstrap |
| `/usr/share/leaselinkd/decommission-leaselinkd.sh` | Stop the service and optionally delete owned remote overrides |
| `/usr/share/leaselinkd/cleanup-leaselinkd-permissions.sh` | Explicit service-account and group cleanup after decommissioning |
| `/usr/share/leaselinkd/rotate-leaselinkd-api-key.sh` | Safe replacement-key creation, validation, and optional old-key revocation |
| `/etc/leaselinkd/config.json` | Non-secret manager settings |
| `/etc/leaselinkd/secrets.json` | OPNsense credentials |
| `/etc/leaselinkd/hook.json` | Hook transport setting |

## Configuration

For a fast end-to-end firewall setup, including creation of the dedicated
OPNsense group/user/API key, secure credential transfer, TLS trust, and
verification, see [OPNsense Unbound HOWTO](project/OPNsense_Unbound_HOWTO.md).
For the equivalent WebGUI-only procedure, see
[OPNsense manual provisioning](project/OPNsense_Manual_Provisioning.md).

For a guided initial setup from an ordinary console account, use the packaged
assistant. It deliberately starts at the firewall Web UI and does not use an
API credential until the firewall-side provisioner (or the manual Web UI flow)
has created one:

```sh
/usr/share/leaselinkd/setup-leaselinkd.sh --firewall fw0.example.net \
  --domain example.net --transfer-provisioner --bootstrap /secure/leaselinkd-bootstrap.json
```

It fetches the presented CA without trusting it, requires an out-of-band
fingerprint confirmation, installs and validates the CA, writes the local
configuration, checks that supported Unbound is running, enables the manager,
and runs the one-shot Kea importer. Re-running it is safe; it only replaces the
configured endpoint/domain and supplied credentials.

`/etc/leaselinkd/config.json`:

```json
{
  "opnsense_url": "https://10.0.0.1/api/unbound",
  "domain": "local",
  "db_path": "/var/lib/leaselinkd/dhcpdb.sqlite",
  "listen_type": "unix",
  "socket_path": "/run/leaselinkd/fifo.pipe",
  "tcp_host": "127.0.0.1",
  "tcp_port": 9080,
  "dns_servers": ["10.0.0.1:53"],
  "throttle_seconds": 10,
  "health_check_seconds": 60,
  "initial_backoff_ms": 100,
  "max_backoff_ms": 10000,
  "api_timeout_seconds": 5,
  "api_test_timeout_seconds": 60
}
```

`/etc/leaselinkd/secrets.json` must be readable only by the service owner:

```json
{
  "api_key": "OPNSENSE_API_KEY",
  "api_secret": "OPNSENSE_API_SECRET"
}
```

The default transport is a Unix socket. To use local TCP instead, set `listen_type` to `"tcp"` and configure the hook with:

```json
{ "leaselinkd_address": "tcp://127.0.0.1:9080", "timeout_seconds": 2 }
```

`api_timeout_seconds` limits each manager-to-OPNsense API call (default `5`), while `api_test_timeout_seconds` sets the complete `--api-test` deadline (default `60`). `timeout_seconds` limits the hook's complete connection, send, and response sequence to the manager (default `2`). All timeout values must be between 1 and 3600 seconds.
`dns_servers` lists IPv4 UDP resolver endpoints used to validate A records. Each endpoint is `ADDRESS` or `ADDRESS:PORT`; port `53` is used when omitted. An empty list disables DNS validation for backward-compatible deployments. Before applying a desired record, `leaselinkd` queries every configured resolver; a matching address is logged as redundant and avoids an OPNsense write. Startup validates every desired hostname, logging `ERROR` for missing or mismatched records and `WARN` for multiple A records. Missing or mismatched records are queued immediately for an OPNsense update.
`queue_max_events` bounds the startup-only in-memory lease queue (default and maximum `512`). The manager accepts and coalesces burst events by hostname, serializes firewall writes, and drains queued work after SIGTERM/SIGINT while systemd's stop grace period remains available. One dedicated API worker owns a persistent HTTP/1.1 client, so normal serialized writes reuse its firewall connection. If an API call reaches its deadline or the worker connection fails, the manager terminates that worker and starts a fresh one for the next request; a timed-out mutation is not retried automatically because its remote outcome is unknown.

Lease intake is durable: a `202` means the latest desired state has committed to SQLite, where it survives restarts and coalesces subsequent events for the same hostname. `record_ttl_seconds` defaults to 86400; expiry turns an unrefreshed record into a durable delete. `reconcile_seconds` defaults to 300 and removes remote overrides carrying this manager's ownership marker when no desired record remains. Managed descriptions end in `; leaselinkd:<hostname>:<owner-id>`, where the random owner ID lets reconciliation identify stale records and duplicates without touching manual overrides.

## Import existing Kea leases

After starting the manager and before relying on future Kea hook events, import
active named leases once with:

```sh
sudo /usr/share/leaselinkd/keadb-leaselinkd-sync
```

Use `--help` to view importer options or `--version` to report its release.

When no database options are supplied, the importer reads PostgreSQL connection
details from `Dhcp4.lease-database` in `/etc/kea/kea-dhcp4.conf`; run it as a
user permitted to read that file. It reads the manager address from
`/etc/leaselinkd/hook.json`. It supports explicit credentials when that is
more appropriate, including a password file to avoid command-history exposure:

```sh
sudo /usr/share/leaselinkd/keadb-leaselinkd-sync \
  --db-host 127.0.0.1 --db-port 5432 --db-name kea --db-user kea \
  --db-password-file /etc/kea/lease-db-password
```

Use `--dsn` as an alternative connection form, `--manager-address` to override
the hook transport, and `--dry-run` to inspect eligible rows. The importer only
sends `state = 0` leases whose expiration is still in the future. It sends the
remaining lifetime rather than Kea's original lifetime so manager expiry stays
aligned with the database. A single trailing DNS root dot is normalized (for
example, `host.` becomes `host`); other names that are not a single DNS host
label, and loopback leases, are reported and skipped. It fails rather than
choosing between duplicate active hostnames, because one Unbound override can
only have one IPv4 address.
This is a bootstrap import, not a periodic full mirror: normal Kea release and
expiry hooks remain responsible for removals after the import.

## Service account and permissions

The package creates an `leaselinkd` system user and group. The service runs as this unprivileged account; systemd owns `/run/leaselinkd` and `/var/lib/leaselinkd` as `leaselinkd:leaselinkd`.

The manager creates its Unix socket as mode `0660`, owned by that account and group; its runtime directory is intentionally `0750`. The package's sysusers policy adds `kea` to `leaselinkd`, so Kea can traverse the directory and use the socket without receiving access to manager secrets. After installing or upgrading, restart Kea so its process receives that supplementary group:

```sh
sudo usermod -aG leaselinkd kea
sudo systemctl restart kea-dhcp4
```

The `usermod` command is only needed to repair an existing installation whose
package upgrade has not yet applied the sysusers policy. Confirm with
`id kea`; its groups must include `leaselinkd`.

`/etc/leaselinkd/hook.json` is deliberately `root:leaselinkd` mode `0640`: it contains only the manager address and is readable by the `kea` user through its `leaselinkd` group membership. `secrets.json` remains root-readable only. The systemd unit passes it to `leaselinkd` using `LoadCredential`, so do not relax its file mode.

The package's tmpfiles policy enforces these ownership and mode expectations on the configuration directories, runtime directory, and state directory. To apply them immediately after a manual permission change, run:

```sh
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/leaselinkd.conf
```

The manager uses Zig's native HTTP(S) client and HTTP Basic authentication; it does not invoke `curl`. HTTPS certificates are verified against the host trust store. For a self-signed OPNsense certificate, install its issuing CA into the Arch Linux system trust store before starting the manager. Restrict the API key to the Unbound operations it needs and keep the manager’s listener local.

## Kea setup

Configure Kea's run-script hook to invoke the packaged hook:

```json
{
  "library": "/usr/lib/kea/hooks/libdhcp_run_script.so",
  "parameters": {
    "name": "/usr/share/kea/scripts/kea-leaselink",
    "sync": false
  }
}
```

Kea supplies the hook point as the first argument and lease values through `LEASE4_ADDRESS`, `LEASE4_HOSTNAME`, and `LEASE4_HWADDR` (the hook also accepts older `KEA_`-prefixed aliases). Committed/renewed leases create or update A overrides; release, expiry, decline, and recovery events remove the saved override. Some Kea renewal callbacks omit a hostname; the hook records no DNS change for those and relies on the following authoritative `leases4_committed` batch, whose records are read from `LEASES4_SIZE` and `LEASES4_AT<n>_HOSTNAME`, `_ADDRESS`, `_HWADDR`, and `_VALID_LIFETIME`.

## Operations and logging

Both programs accept an optional log level:

```sh
leaselinkd --loglevel DEBUG
kea-leaselink --loglevel DEBUG lease4_committed
```

Set `"loglevel": "DEBUG"` (or `ERROR`, `WARN`, or `INFO`) in either
program's `config.json` to make it the default. An explicit `--loglevel`
command-line argument takes precedence.

Valid levels are `ERROR`, `WARN`, `INFO` (the default), and `DEBUG`.
At normal startup the manager logs its version, build architecture, safe
effective configuration, listener, and authenticated firewall health result.
DEBUG adds hook lease inputs and manager-transmission timing, payloads,
periodic health checks, and scheduler activity. Hook INFO logs identify the
lease operation and manager transmission result with call and total duration;
WARN/ERROR logs identify delivery failures, timeouts, and incomplete input.
Credentials are never logged.

For one-off testing, `--config PATH` overrides either program's normal
configuration file. `leaselinkd --secret PATH` likewise overrides its normal
secrets file; these command-line paths take precedence over the legacy
`LEASELINKD_CONFIG`, `LEASELINKD_SECRETS`, and `KEA_LEASELINK_CONFIG`
environment overrides. This permits a non-production test without changing
`/etc`:

```sh
leaselinkd --config ./firewall-test.json --secret ./firewall-test-secrets.json --api-test --loglevel DEBUG
kea-leaselink --config ./hook-test.json lease4_committed
```

Before an API test, confirm the certificate using the same operating-system
trust store as the manager. This test does not authenticate or alter the
firewall:

```sh
python3 tests/test_firewall_certificate.py --url https://10.76.2.5:8443
```

To test a CA before installing it system-wide, add `--ca-file /path/to/ca.pem`.

Validate configuration and ledger access without starting a listener:

```sh
sudo leaselinkd --config-check
```

Validate the Kea DHCPv4 DDNS settings and the one relevant entry among its
possibly multiple hook libraries:

```sh
python3 /usr/share/leaselinkd/check-kea-config.py /etc/kea/kea-dhcp4.conf /etc/leaselinkd/hook.json
```

Validate OPNsense reachability and deliberately trigger an Unbound reconfigure:

```sh
sudo leaselinkd --api-test
```

`--api-test` changes remote state by requesting `/service/reconfigure`; use it only when that reload is acceptable.
The complete status-and-reconfigure sequence has a hard 60-second deadline and exits with status `124` if it times out.
Every individual OPNsense API request has a five-second deadline. A timed-out operational request is recorded as a failure, allowing the health-check backoff loop to continue.

Both executables provide Typer-style CLI documentation:

```sh
leaselinkd --help
kea-leaselink --help
```

Request a manager snapshot with SIGUSR1:

```sh
sudo systemctl kill -s USR1 leaselinkd.service
journalctl -u leaselinkd.service -n 30
```

The snapshot includes active configuration (excluding secrets), runtime, received lease events, API GET/POST and failure counts, health-check counts, and completed reconfigures.

Request an immediate SQLite-to-OPNsense resync with SIGUSR2:

```sh
sudo systemctl kill -s USR2 leaselinkd.service
```

The manager removes stale owned overrides, queues current SQLite desired records
for reapplication, and coalesces any required Unbound reconfigure.

## Development

Build and run the automated checks:

```sh
zig build test -Doptimize=ReleaseSafe
```

The integration test starts the real manager on a temporary Unix socket, invokes the real hook for committed, renewed, and removal leases, uses a local HTTP/1.1 OPNsense API stub, checks the SQLite ledger, managed tag, deferred reconfigures, persistent connection reuse, concurrent burst handling, Basic authentication, and SIGUSR1 reporting.

## Current scope

The event-driven lease-to-Unbound path is implemented. `leaselinkd` does not
connect to PostgreSQL or use cron-scheduling configuration. The separate
`keadb-leaselinkd-sync` utility can optionally import active leases from Kea's
PostgreSQL lease database.
