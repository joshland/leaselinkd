# Servers

The solution involves two logical servers residing on the same host:

1. **Kea DHCP4 Server**
   * Uses the built‑in `libdhcp_run_script.so` hook.
   * When a lease is committed, released or expired Kea sets environment variables (see kea‑notes.md) and then runs the script `/usr/share/kea/scripts/kea-leaselink`. The script receives the event type as `$1`.

2. **leaselinkd Service**
   * A Zig application compiled to a single binary `leaselinkd`.
   * Listens on an AF_UNIX socket at `/run/leaselinkd/fifo.pipe` (default). TCP mode can be switched by editing the config (`listen_type="tcp"`).
   * Starts a background goroutine that:
     * Performs health‑checks every `health_check_seconds`.
     * On success schedules a reconciliation on system boot and at times specified by the cron expression in the configuration.

Both servers are installed via the single AUR package `kea-dns-mgr`. Systemd units (`leaselinkd.service` and `kea-dns-hook.service`) handle start/stop/restart.
