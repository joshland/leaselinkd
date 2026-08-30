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

* Use `ps -o pid,rss,cmd` to monitor resident set size.
* Send `SIGUSR1` to `leaselinkd` to log runtime, API, health, and reconfigure counters to the journal.
* Use `journalctl -u leaselinkd.service` for health, API, and malformed payload failures.
* Ensure only Kea is added to the `leaselinkd` group; the Unix socket is group-writable and API secrets are systemd credentials.
* Verify OPNsense’s `/var/run/opnsense-dyn.conf.d/overrides.json` does not grow out of hand – if it exceeds a few megabytes, review the reconciliation logic.

---

The above estimates are conservative and should be revisited once real deployment metrics are available.
