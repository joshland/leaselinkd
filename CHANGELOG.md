# Changelog

All notable development work is documented here. This project follows semantic versioning; entries describe development milestones and may be packaged together when a release is built.

## Unreleased

## 3.0.1 — Package dependency update

## 3.0.0 — Prometheus observability

- Replaced vendored `http.zig` and `metrics.zig` source trees with pinned Zig
  package dependencies in `build.zig.zon`; `build.zig` now imports their
  exported `httpz` and `metrics` modules through Zig's package resolver.
- Integrated the supplied Zig `metrics.zig` and `http.zig` libraries. The
  manager now exposes a localhost Prometheus `/metrics` endpoint, including
  lease intake and API latency histograms, API request/error/byte counters,
  health/reconfigure totals, process CPU and memory gauges, and `httpz`
  listener counters.
- Added configurable Prometheus listener settings and a Grafana dashboard for
  operational lease, firewall API, resource, and scrape monitoring.
- Evaluated replacing the Kea hook transport and retained the existing
  Unix-socket/TCP path: it preserves the daemon's serialized durable-ack
  semantics and the Unix-socket permission boundary.

- Added a regular-user, sudo-assisted idempotent setup assistant that begins
  with Web UI/SSH provisioning rather than API access, fetches and verifies the
  firewall certificate, checks the local trust chain, writes configuration,
  validates running Unbound, and bootstraps active Kea leases.
- Extended the firewall provisioner to verify that OPNsense exposes supported
  Unbound status controls and that Unbound is running before it creates access.
  It now supports staged API-key rotation and guarded old-key revocation.
- Added explicit decommissioning, owned-override cleanup, service-account
  cleanup, and API-key rotation helpers. Remote record deletion is opt-in and
  only matches the durable `leaselinkd` ownership marker.
- Made `--api-test` reject an API endpoint whose Unbound status is not
  `running`, rather than treating any successful status response as healthy.

## 2.1.1 — Packaged documentation

- Package the README and operational documentation under
  `/usr/share/doc/leaselinkd-<version>`.

## 2.1.0 — Operational resynchronization
- Added `SIGUSR2` to request an immediate SQLite-to-OPNsense resync through
  the daemon's serialized reconciliation path.
- Added `dns_servers` for native UDP A-record validation before updates and
  during startup reconciliation, including redundant-update, mismatch, and
  multiple-record logging.
- Queue missing or mismatched DNS records for immediate OPNsense update during
  startup validation.
- Fixed the integration test to wait for the daemon's asynchronous first lease
  event to reach SQLite before asserting its ledger entry.
- Include the full queried domain name in DNS lookup failure logs.
- Restart an already-running `leaselinkd.service` after package upgrades
  without enabling or starting an inactive service.
- Reload the systemd manager after package installation and upgrades before
  restarting the active daemon.
- Renamed the Kea PostgreSQL lease importer to `keadb-leaselinkd-sync` and
  added its `--version` report alongside its existing `--help` output.

## 2.0.1 — Configuration and documentation alignment

- Moved the Kea hook transport configuration to `/etc/leaselinkd/hook.json`.
  The hook now uses that path by default and supports `KEA_LEASELINK_CONFIG`
  for test overrides; package and importer defaults follow the new path.
- Expanded `check-kea-config.py` to report the status of required Kea DHCPv4
  keys, run-script parameters, installed hook executable, and hook transport
  configuration values.
- Corrected the validator to inspect Kea's `hooks-libraries` array and report
  the required `parameters.name` path for `kea-leaselink`.
- Corrected legacy product names and Kea's unprefixed `LEASE4_*` and
  `LEASES4_*` hook environment-variable references in the documentation.
- Removed unused PostgreSQL connection and cron-scheduling fields from the
  manager configuration and secrets examples. PostgreSQL remains isolated to
  the explicitly invoked `keadb-leaselinkd-sync` import utility.
- Fixed `leaselinkd --config-check` to validate SQLite path access without
  creating or modifying the configured ledger.
- Added `scripts/buildnumber.sh` to increment the Arch package `pkgrel`
  independently of the application version, interactively or with `--add`,
  and to reset it to `1` with `--reset`.
- Fixed the packaged `/etc/leaselinkd` directory mode at `0750` so upgrades
  match the tmpfiles policy and do not produce a pacman permission warning.

## 2.0.0 — Durable lease delivery and reconciliation

- Established `leaselinkd` as the daemon and public operational identity,
  including its executable, service account,
  systemd unit, configuration and state paths, Unix socket, environment
  variables, hook transport key, ownership marker, packaged helpers, and
  OPNsense provisioning identity. This is a breaking deployment rename.
- Established `kea-leaselink` as the Kea run-script hook executable and
  installed script. Update Kea's run-script `name` setting when deploying.
- Moved the OPNsense provisioning script into the package and installed it as
  `/usr/share/leaselinkd/provision-opnsense-leaselinkd.php`.
- Added the packaged Kea PostgreSQL one-shot importer for active Kea
  PostgreSQL IPv4 leases. It can read the existing Kea lease-database settings
  or accept explicit connection parameters, and preserves remaining lifetime
  when seeding durable manager state.
- Normalized one trailing DNS root dot in imported Kea hostnames and skip/report
  other manager-ineligible hostnames and loopback addresses without aborting a
  bootstrap import.
- Added package-managed membership of Kea's service account in the
  `leaselinkd` group, granting the minimum Unix-socket traversal and write
  access required by the `0750` runtime directory and `0660` socket.
- Fixed hook configuration log-level application: `config.json` is read before
  startup and validation logs, while explicit `--loglevel` still takes
  precedence.
- Replaced the volatile intake queue with durable SQLite desired state: a lease
  event is acknowledged only after its latest per-host intent is committed.
- Added TTL-driven expiry, durable delete tombstones, and capped exponential
  retry scheduling for firewall work that survives manager restarts.
- Added periodic owned-record reconciliation through `search_host_override`.
  The manager removes stale or duplicate owned records and reasserts desired
  records to repair missing remote overrides.
- Added an ownership suffix to managed descriptions:
  `leaselinkd:<hostname>:<owner-id>`, where the random stable owner ID safely
  correlates a host's remote record with its durable desired state.
- Added Kea `leases4_committed` batch-hook support, including its indexed
  `KEA_LEASES4_AT<n>_*` variables. Hostname-less `lease4_renew` callbacks are
  now intentionally deferred because the following committed batch supplies
  the authoritative hostname.
- Corrected the batch and lease environment-variable names to Kea's native
  unprefixed `LEASES4_*`/`LEASE4_*` form while retaining compatibility with
  the earlier `KEA_`-prefixed aliases.

## 1.9.7 — CLI usability and API resilience

- Documented the verified OPNsense Unbound host-override API flow and the
  successful live add, update, reconfigure, DNS, and delete experiment.
- Reject invalid and loopback (`127.0.0.0/8`) IPv4 addresses before add/update
  requests because loopback overrides were accepted by the API but not served
  reliably by the tested Unbound instance; removal events remain permitted.
- Corrected the manager's invalid-event response to return HTTP 422.
- Added a packaged root-only helper to validate and install an OPNsense CA
  certificate into the Arch system trust store.
- Added a non-trusting helper to retrieve the firewall-presented CA certificate
  and report its fingerprint before trust installation.
- Fixed certificate-chain extraction in the fetch helper so OpenSSL diagnostic
  text cannot be appended to the saved PEM.
- Detect non-critical CA Basic Constraints in the certificate helpers and
  document that strict TLS clients require a standards-compliant firewall CA.
- Make the fetch helper fail safely when the firewall does not present a CA,
  rather than saving and mislabeling a lone server certificate as a CA.
- Report the underlying TLS, connection, or HTTP-status failure in DEBUG logs
  for manager API requests, while retaining the stable public request error.
- Added `--config` overrides to both executables and `--secret` to
  `leaselinkd`, allowing explicit non-production configuration testing.
- Added a read-only TLS certificate probe that uses the host trust store (or a
  supplied CA file) before an API test.
- Added a packaged firewall-certificate diagnostic for certificate validity,
  IP/DNS identity, server extensions, and trusted-CA chain failures; failed
  manager API requests now direct operators to it.
- Documented and diagnose Zig 0.16's DNS-SAN-only TLS hostname verification;
  manager API URLs must use a DNS name covered by the server certificate.
- Expanded normal manager startup logs with the version, build architecture,
  safe effective configuration, and authenticated OPNsense health summary.
- Made the OPNsense provisioning script idempotent, with non-secret reports of
  existing identity state and an on-firewall audit of the selected Web GUI
  certificate, its DNS SAN, and its configured CA chain.
- Expanded hook logging with lease inputs, manager-call outcome and timings,
  and explicit WARN/ERROR reporting for incomplete, invalid, timed-out, and
  failed deliveries.
- Added `loglevel` support to both JSON configuration files; explicit CLI
  `--loglevel` values override the configured default.
- Expanded hook DEBUG logging with its full invocation and all consumed Kea
  lease parameters, and made the hook version a distinct startup INFO log.
- Added a packaged Kea DHCPv4 configuration checker for DDNS and run-script
  hook settings; the hook now forwards lease lifetime, subnet ID, and query
  interface alongside its existing lease fields.
- Validate and log the Kea hook point explicitly, forwarding supported
  committed, renew, release, expiry, decline, and recovery operations to the
  manager while rejecting unknown operations.
- Added a bounded 512-event, hostname-coalescing manager intake queue and a
  serialized OPNsense writer to absorb DHCP lease bursts without concurrent
  firewall configuration writes. Managed host overrides now receive the
  configurable `managed_description` tag.
- Replaced per-request API child processes with a persistent, serialized
  HTTP/1.1 worker. Per-call deadlines now terminate and restart the worker on
  timeout or IPC/connection failure, without retrying an indeterminate remote
  mutation automatically.
- Expanded integration coverage for committed-to-renewed override updates,
  removal events, managed-description tagging, persistent connection reuse,
  and a concurrent 32-event intake burst.
- Made lease intent durable in SQLite before returning `202`, with per-host
  coalescing, TTL-driven deletion, and persistent work across restarts.
- Added owned-record reconciliation through `search_host_override`; managed
  descriptions now include hostname and a random stable owner ID, allowing
  stale managed overrides and duplicate owner IDs to be cleaned safely.
- Made the queue limit configurable at startup and drain queued lease work on
  SIGTERM/SIGINT with explicit shutdown logs; added a local concurrent-burst
  harness for 256, 512, and backpressure tests.
- Reworked the configuration reference to remove obsolete reconciliation and
  database fields and document the current manager, secrets, hook, loglevel,
  TLS, and override settings.
- Added a startup version line to the OPNsense provisioning script.
- Expanded the OPNsense connection HOWTO with certificate-fetch usage, endpoint
  overrides, and mandatory out-of-band fingerprint verification.
- Added an OPNsense CLI provisioning script and connection HOWTO for the
  dedicated `unbound_api` group, `leaselinkd` API user, generated credentials,
  TLS trust, and manager verification.
- Added a WebGUI-only manual provisioning guide with the exact least-privilege
  group, user, API key, certificate, and verification requirements.
- Made the manager's per-API and `--api-test` deadlines configurable while retaining their five- and sixty-second defaults.
- Added a configurable two-second end-to-end timeout to the Kea hook's manager forwarding operation.

- Added `leaselinkd --config-check` for offline configuration, secrets, SQLite access, and listener/timer validation.
- Added `leaselinkd --api-test` for a CLI OPNsense status probe followed by an explicit Unbound reconfigure request.
- Added a hard 60-second deadline to `--api-test`; timeout logs an error and exits with status `124`.
- Added `--help`/`-h` output to both executables and a five-second deadline for every OPNsense API call.
- Added integration coverage for both CLI actions.
- Declared Kea, systemd, SQLite, CA certificates, Zig, and test-only Python dependencies in the Arch package; package checks now run the integration suite.

## 1.5.1 — Packaging permissions patch

- Enforced installed configuration, runtime, and state directory ownership and modes through tmpfiles.
- Documented the deliberate `0644` Kea hook configuration mode and root-only OPNsense secrets boundary.

## 1.5.0 — Current development

### Native OPNsense client

- Replaced spawned `curl` calls with Zig `std.http.Client`.
- Added native HTTP Basic authentication, JSON request bodies, bounded response handling, and non-2xx response failures.
- Removed `curl` from Arch runtime dependencies.
- Changed HTTPS behavior from curl's insecure mode to normal system trust-store certificate verification.
- Reworked integration testing to use a local mock OPNsense HTTP server and verify Basic authorization, API paths, UUID responses, and health calls.

### Privilege separation and packaging

- Added an `leaselinkd` system user and group through `sysusers.d`.
- Changed `leaselinkd.service` to run as `leaselinkd:leaselinkd` with systemd hardening settings.
- Added systemd-managed runtime and state directories owned by the service account.
- Added tmpfiles policy for `/etc/leaselinkd`, `/run/leaselinkd`, and `/var/lib/leaselinkd`, including configuration and secret file modes.
- Kept the non-secret Kea hook configuration world-readable (`0644`) so an installed `kea` service account can read its manager address without access to OPNsense secrets.
- Changed the Unix socket to mode `0660` so Kea can connect through membership in the `leaselinkd` group.
- Kept API secrets root-only and passed them to the service with systemd `LoadCredential`.
- Updated tmpfiles and package installation rules for the service account, runtime directories, hook config, systemd unit, and sysusers configuration.

### Documentation

- Added `README.md` with installation, Kea setup, configuration, transport, operational, security, and test instructions.
- Updated `AGENTS.md` with the current event contract, native HTTP client, service-account boundary, logs, signals, and build/test expectations.
- Updated `MEMORY.md` with native TLS memory considerations, request/response bounds, SQLite/WAL persistence, operational monitoring, and security boundaries.

## 1.1.0 — Observability milestone

### Logging and metrics

- Added `--loglevel ERROR|WARN|INFO|DEBUG` to both `leaselinkd` and `kea-leaselink`.
- Added version and effective log-level output at manager startup.
- Added DEBUG output for non-secret configuration, hook payloads, API paths, health checks, and deferred-reconfigure scheduling.
- Added INFO output for lease operations and OPNsense requests.
- Added WARN output for malformed payloads, invalid hostnames, and health-check backoff.
- Added ERROR output for failed lease processing and reconfiguration.
- Added `SIGUSR1` handling in `leaselinkd` to log non-secret configuration and runtime metrics.
- Metrics include runtime, lease events, API GET/POST totals, API failures, health checks/failures, and completed reconfigures.
- Extended integration tests to send SIGUSR1 to the live manager and assert both configuration and metrics output.

## 1.0.0 — Initial event-driven implementation

### Core agents

- Replaced the initial Zig stubs with Zig 0.16-compatible build definitions and two working binaries.
- Implemented the Kea hook's argv/environment processing and JSON event forwarding.
- Implemented a local HTTP `POST /lease_event` server over Unix sockets.
- Added optional TCP listener support to the manager and matching `tcp://host:port` support to the hook.
- Added lease-event parsing for `hostname`, `ip-address`, and `mac-address`.
- Added hostname validation and JSON escaping.
- Implemented add/update/delete mapping for OPNsense Unbound host overrides.
- Added SQLite persistence for hostname → OPNsense UUID/IP mappings.
- Added OPNsense reconfiguration after changes.

### Reliability features

- Added startup and periodic OPNsense `/service/status` health checks.
- Added capped exponential health-check backoff.
- Added deferred reconfiguration using `throttle_seconds` to coalesce lease bursts.

### Test-driven fixes

- Added unit tests for shared input validation and log-level parsing.
- Added an end-to-end test that runs the real manager and real hook against temporary Unix sockets and SQLite.
- Fixed SQLite path handling by passing NUL-terminated paths to the C API.
- Fixed HTTP request reception so a separately written header and body are read according to `Content-Length`.
- Corrected lease JSON decoding to use Kea's hyphenated `ip-address` and `mac-address` fields.
- Added tests for add, release/delete, SQLite persistence, deferred reconfigure, native Basic auth, and SIGUSR1 reporting.

### Arch packaging

- Added an Arch PKGBUILD for `leaselinkd`.
- Corrected package artifact paths for `makepkg` fakeroot execution by using `$startdir` rather than paths relative to `$pkgdir` or the project `src/` directory.
- Added pacman backup declarations for the manager config, secrets template, and hook config.
- Verified package creation and archive contents without installing the resulting package.

## Known limitation

The event-driven DHCP-to-Unbound path is implemented. PostgreSQL lease reconciliation and cron scheduling fields remain in the example configuration as planned future work; they are not active in the current manager.
