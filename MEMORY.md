# Memory Requirements

The **leaselinkd** system is designed to run on a modest home/enterprise DHCP host. `leaselinkd` is serial: it processes one lease event at a time and makes native Zig HTTP(S) calls directly—there is no long-lived external process or `curl` child per API request.

| Component | Description | Approx. RAM (MiB) |
|-----------|-------------|---------------------|
| **Kea DHCP4** | Core server, hooks library, `libdhcp_run_script.so` | 8 – 12 (depends on lease table size)
| **leaselinkd (Zig)** | HTTP listener, SQLite ledger, native HTTP/TLS client | 10–20; first HTTPS connection may temporarily use more for CA/TLS buffers
| **kea-leaselink binary** | One-shot event forwarder | < 2 transient
| `sqlite3` DB file | Persistent hostname/UUID/IP ledger | ~0.5 MiB for 100 hosts; WAL files are normal
| **OPNsense Unbound** | DNS resolver, dynamic overrides cache | 16 – 24 (depends on zones)
|
| **Total Peak** | Combined over all services | ≈ 35 MiB + OPNsense overhead | 

## Recommendations

* Allocate at least **512 MiB** of RAM to the host running this package, providing headroom for OPNsense and any other network services.
* Keep `/var/lib/leaselinkd` persistent and writable by `leaselinkd:leaselinkd`; do not move the ledger to ephemeral `/run` storage.

Memory usage is mostly *static*. The key dynamic consumers are:

1. **SQLite** – The table is `overrides(hostname, uuid, ip_address)`. It contains no API secrets. Database and WAL growth scale with override churn.
2. **JSON handling** – Inbound lease requests are capped at 64 KiB. JSON allocation is brief and per event.
3. **Native HTTP/TLS** – At most one OPNsense request is active per lease operation. Responses are bounded in memory; unexpected large responses should be investigated.
4. **Timers** – Reconfigure is coalesced by `throttle_seconds`; health retry doubles from `initial_backoff_ms` to `max_backoff_ms`.

### Monitoring Tips

* Scrape `http://127.0.0.1:9108/metrics` with Prometheus for process RSS, virtual memory, CPU time, lease intake, and OPNsense API behavior; use `ps -o pid,rss,cmd` for an immediate local check.
* Send `SIGUSR1` to `leaselinkd` to log runtime, API, health, and reconfigure counters to the journal.
* Use `journalctl -u leaselinkd.service` for health, API, and malformed payload failures.
* For a reproducible leak investigation, run `sh tests/memory_soak.sh
  zig-out/bin/leaselinkd zig-out/bin/kea-leaselink 10800`. It retains a
  bounded-host end-to-end evidence directory with `samples.csv`, periodic
  Prometheus scrapes, manager TRACE lifecycle logs, API traffic, SQLite dump,
  and periodic `pmap`, full `smaps`, and `lsof` snapshots for both manager and
  API worker. Set `SOAK_METRICS_ENABLED=false` for a no-scrape control run;
  `SOAK_MAP_EVERY=12` captures mappings once per minute at the default
  five-second interval. `TRACE` is deliberately verbose and should only be
  enabled during time-bounded diagnosis.
* Ensure only Kea is added to the `leaselinkd` group; the Unix socket is group-writable and API secrets are systemd credentials.
* Verify OPNsense’s `/var/run/opnsense-dyn.conf.d/overrides.json` does not grow out of hand – if it exceeds a few megabytes, review the reconciliation logic.

### DNS resolver regression guard

The native UDP resolver must retain two layers of coverage. `zig build test`
includes hermetic byte-level and local-fixture tests for the DNS question
header, A-record parsing, NXDOMAIN, FORMERR, and malformed replies; these are
the required CI gate and must not depend on the Internet. Before a release or
when diagnosing resolver interoperability, run a public smoke test against a
chosen recursive resolver (for example `1.1.1.1`):

* `host one.one.one.one 1.1.1.1` must return `1.1.1.1` (and may also return
  `1.0.0.1`).
* `host example.example 1.1.1.1` must return NXDOMAIN.

An unexpected `FORMERR` for either query indicates a DNS wire-format problem
in the client request, such as an incorrect DNS header question count. Do not
make this public check a hermetic CI dependency; resolvers and network access
may be unavailable there.

---

The above estimates are conservative and should be revisited once real deployment metrics are available.
