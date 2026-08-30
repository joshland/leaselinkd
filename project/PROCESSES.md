# Processes

The system operates through the following processes:

| PID | Component | Role |
|-----|-----------|------|
| 1   | `kea`    | DHCP service, triggers hook.
| 2   | `leaselinkd` | HTTP server handling `/lease_event`, CRUD with OPNsense, and periodic reconciliation of managed overrides.
| 3   | `kea-leaselink` (spawned) | For each lease event, this temporary process builds the JSON payload and posts to `leaselinkd`; exits immediately. Its exit status is ignored by Kea.

### Workflow Example
1. **Lease Assigned** – Kea receives a DHCP request, writes the lease database entry, then executes `/usr/share/kea/scripts/kea-leaselink lease4_committed` with environment variables set as per `kea-notes.md`.
2. **Hook Execution** – The Zig binary reads `$1`, reads env vars, builds:
   ```json
   {"event":"lease4_committed","timestamp":...,"lease":{"hostname":"client1","ip-address":"192.168.1.10","mac-address":"00:11:22:33:44:55"}}
   ```
   and POSTs to `leaselinkd` at `/lease_event`.
3. **Server Processing** – The manager queues the event, calls `add_or_update_override`, stores UUID in SQLite, and throttles a reconfigure call if allowed.
4. **Periodic Reconcile** – At the configured interval, the server compares SQLite desired state with managed OPNsense overrides, performs necessary adds, updates, or deletes, then performs a throttled `reconfigure`.

All processes use simple JSON over HTTP on a protected AF_UNIX socket; no external authentication is performed because the socket is only writable by the same user that runs the DHCP server.
