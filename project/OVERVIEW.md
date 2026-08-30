# Overview

The `KEA‑DNS‑MGR` project provides a **dhcp4 → dns** bridge for an environment that runs both the **Kea DHCP server** and **OPNsense Unbound DNS**.  All code lives under the repository root `/home/joshua/_git/lease-management`.

* **Runtime components**
  * `leaselinkd` – Zig HTTP service (systemd unit) that accepts lease events, talks to Unbound over its API and can do scheduled reconciliation with Kea’s PostgreSQL lease table.
  * `kea-leaselink` – Zig executable registered as a `libdhcp_run_script.so` hook in Kea. It receives environment variables for every lease event and forwards them to `leaselinkd` via an AF_UNIX socket or optional TCP port.
* **Configuration**
  * `/etc/leaselinkd/config.json` – runtime options (URLs, auth keys, DB & scheduling)
  * `/etc/leaselinkd/secrets.json` – secrets only file; read by the binaries at startup.
  * `/etc/leaselinkd/hook.json` – informs `kea-leaselink` where `leaselinkd` listens.

The result is an idempotent, throttle‑aware DNS overlay that reflects the current Kea lease set and keeps OPNsense Unbound in sync without manual intervention.
