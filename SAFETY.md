# Safety Review

Review date: 2026-09-02
Reviewed revision: `0da2d85` (`master`)
Toolchain: Zig 0.16.0, ReleaseSafe verification

This is a review report, not a claim that the implementation is formally
verified. It covers `leaselinkd`, `kea-leaselink`, the Prometheus server and its
vendored dependencies, the systemd unit, and the local integration harnesses.
The focus is request handling, timers, process and thread behavior, allocation,
bounds checking, logging, failure recovery, and privilege boundaries.

Status annotations reflect remediation through revision `9b0190a`.
`[COMPLETED]` means the finding's unsafe behavior has been remediated in the
current implementation; unmarked findings remain incomplete or only partially
addressed.

## Executive assessment

The durable-intent design is sound in principle: accepted lease state is
written to SQLite before returning `202`, OPNsense calls are serialized, API
calls have a parent-enforced deadline, and short-lived arenas release most
request allocations at well-defined boundaries. Hostnames, IPv4 addresses,
configuration file sizes, manager request storage, and parent-side API frames
all have useful bounds. The service also runs unprivileged with a reasonably
strong systemd filesystem sandbox.

The most important remaining risks are availability and recovery correctness,
not a simple allocator leak. A client can block the manager's single event loop
with an incomplete request; continuous accepted connections can still starve
timers; the API worker is forked after a large metrics thread pool exists; and
several SQLite paths interpret database errors as “not found.” Optional TCP and
plain HTTP modes also create serious security risks when used beyond trusted
loopback test environments.

Priority counts:

| Severity | Count | Meaning |
| --- | ---: | --- |
| High | 8 | Can permit unauthorized DNS changes, terminate or indefinitely stall the manager, invoke unsafe post-fork behavior, or delete/strand valid state. |
| Medium | 10 | Material resource, correctness, spoofing, timing, or diagnostic weakness requiring hardening. |
| Low | 5 | Defense-in-depth, observability, or maintainability weakness. |

No API key or secret was found in normal application logs. The TRACE messages
also avoid request authorization headers and bodies. Debug hook logs do expose
lease metadata, including MAC addresses, and need the controls described below.

## High-severity findings

### H1. One incomplete lease connection can block the entire manager [COMPLETED]

`src/leaselinkd/main.zig:154-170` accepts a connection and calls
`processConnection` synchronously. Only the listening descriptor is set
nonblocking. The accepted descriptor has no receive deadline, and
`processConnection` performs blocking `recv` calls at
`src/leaselinkd/main.zig:642-644` until it sees a complete request or the peer
closes.

This blocks lease intake, signal processing, TTL expiry, reconciliation,
reconfiguration, health checks, and graceful shutdown. Unix-socket permissions
reduce the attacker set to members of the service group, but a broken or
compromised hook is sufficient. TCP mode expands the attacker set.

A controlled local test confirmed the behavior. An incomplete request was held
for eight seconds while a valid hook request was submitted. The valid hook
timed out after 5,025 ms. After the slow peer closed, the manager persisted the
valid event but could no longer return its response, producing `SendFailed`.
This also demonstrates an ambiguous outcome: the hook saw failure even though
the intent reached SQLite.

Recommended fix:

- Set every accepted descriptor nonblocking and use `poll` with one monotonic
  whole-request deadline.
- Bound both header completion time and body completion time.
- Close and count timed-out clients, returning `408` when a response remains
  possible.
- Keep the durable/idempotent request semantics so a hook retry remains safe.
- Add the controlled partial-request case as an integration regression test.

### H2. A continuously nonempty accept queue can still starve timers [COMPLETED]

The main loop drains `accept()` until it returns an error before calling
`serviceTimers` (`src/leaselinkd/main.zig:156-170`). The recent timer ordering
fix prevents the durable SQLite queue from starving health and reconfiguration,
but it does not protect timers from a listener that is continuously readable.

Recommended fix:

- Process a fixed number of accepted requests per loop iteration, or stop after
  a small monotonic time budget.
- Call `serviceTimers` between intake batches.
- Track accepted, active, timed-out, and backlog-rejected connections in
  metrics.
- Add a sustained-arrival test which proves health checks and reconfiguration
  continue while the listener backlog never becomes empty.

### H3. The API worker forks after metrics threads have started [COMPLETED]

`run` starts the httpz metrics server at `src/leaselinkd/main.zig:130-132`.
The first health check then starts the API worker using `fork()` at
`src/leaselinkd/main.zig:961-975`. Every timeout or worker failure can repeat
that fork while the metrics threads are active.

After a multithreaded process forks, the child may safely call only
async-signal-safe operations until `exec`. This child instead allocates memory,
uses the inherited `std.Io`, logs, creates an HTTP client, performs DNS/TLS, and
enters a long-lived request loop. Locks held by a vanished thread at the instant
of fork can remain permanently locked in the child. This is a structural
deadlock and corruption risk even if it is difficult to reproduce under light
load.

The exposure is larger than it first appears. The metrics configuration sets
`workers.count = 1`, but httpz blocking mode uses
`thread_pool.count`, whose default is 32. Existing 10-minute evidence recorded
35 manager threads.

Recommended fix:

- Prefer a separately built API-worker executable started with `posix_spawn` or
  `fork` immediately followed by `exec`.
- Alternatively, create the worker before any threads exist and design a safe
  respawn mechanism that never executes application code in a post-fork child.
- Mark unrelated descriptors close-on-exec and pass only an explicit IPC
  descriptor to the worker.
- Add repeated worker-kill/respawn tests while metrics are scraped concurrently.

### H4. Non-loopback TCP lease intake has no authentication [COMPLETED]

The manager accepts a configurable numeric `tcp_host`, including wildcard or
LAN addresses (`src/leaselinkd/main.zig:305-318`). The lease endpoint has no
token, peer authentication, TLS, or source authorization. Any client that can
reach it can submit valid-looking add and delete events, causing durable DNS
changes through privileged OPNsense credentials.

Recommended fix:

- Restrict TCP validation to loopback by default.
- Require an explicit insecure-development option for any non-loopback bind, or
  implement mTLS/authenticated request signing before supporting remote intake.
- Retain the Unix socket as the production default and optionally verify
  `SO_PEERCRED` in addition to filesystem permissions.
- Document firewall requirements as a secondary control, not the authentication
  mechanism.

### H5. Transport policy and automatic GET redirects can expose Basic credentials [COMPLETED]

Configuration validation accepts both `http://` and `https://`
(`src/leaselinkd/main.zig:223-226`). `apiRequestWithClient` sends the API key and
secret in a Basic authorization header on every request
(`src/leaselinkd/main.zig:1053-1062`). Basic authentication provides no
confidentiality. A non-loopback HTTP URL exposes credentials and mutable DNS
operations to interception.

There is a second credential boundary in the same call: Zig's `fetch` follows
up to three redirects for bodyless GET requests by default. The authorization
value is placed in the standard `headers.authorization` override rather than
the client's `privileged_headers` collection. Cross-origin redirect handling
strips `privileged_headers`, but does not clear that standard override. A
health or reconciliation GET redirected to another origin can therefore carry
the OPNsense Basic credential to that origin.

Recommended fix:

- Require HTTPS in normal mode.
- Permit HTTP only behind an explicit test/development flag and only for a
  loopback destination.
- Disable redirects for every authenticated API request and treat 3xx as an
  error. If redirects are intentionally supported later, rebuild credentials
  only after an exact scheme/host/port origin check.
- Emit a startup ERROR and refuse operation when production configuration would
  send credentials over cleartext.

### H6. `Content-Length` can overflow request arithmetic and terminate a ReleaseSafe build [COMPLETED]

`headerContentLength` accepts any `usize`. The expression
`at + 4 + content_length` at `src/leaselinkd/main.zig:653` is evaluated before
the 64 KiB request-buffer limit is applied. A syntactically valid maximum-size
`Content-Length` can overflow. ReleaseSafe arithmetic traps terminate the
daemon, after which systemd restarts it.

Recommended fix:

- Compute `body_start` only after checking the header delimiter position.
- Reject when `content_length > buffer.len - body_start` before adding lengths.
- Return `413 Payload Too Large` for an oversized body.
- Parse header names case-insensitively, reject conflicting duplicate
  `Content-Length` headers, and reject unsupported transfer encodings.
- Add boundary tests for zero, exactly fitting, one byte too large, `usize`
  maximum, duplicate headers, and partial bodies.

### H7. SQLite errors can be interpreted as absence and trigger remote deletion [COMPLETED]

Several query helpers treat every result other than `SQLITE_ROW` as a benign
miss. The most dangerous is `reconcileOwner` at
`src/leaselinkd/main.zig:862-873`: `SQLITE_BUSY`, `SQLITE_IOERR`, corruption, or
another step failure returns `false`, and the caller then deletes the remote
OPNsense override at `src/leaselinkd/main.zig:851-855`.

The same error-as-absence pattern appears in `ownerFor`, `desiredIpFor`,
`nextDesired`, and `lookup`. SQLite bind return codes are also ignored.

Recommended fix:

- Switch explicitly on `SQLITE_ROW` and `SQLITE_DONE`; convert every other code
  to an error.
- Check all bind results.
- Include `sqlite3_extended_errcode` and a safely copied `sqlite3_errmsg` in
  diagnostic logs.
- On any local uncertainty, fail closed: do not delete or mark a remote record
  clean.
- Add tests using a busy database and injected step failures; assert that no
  OPNsense delete is attempted.

### H8. Multi-step database updates can strand a successful remote mutation [COMPLETED]

After a successful OPNsense add/update, `applyDesired` first marks the durable
row clean, then updates the legacy `overrides` table, and only then schedules a
reconfigure (`src/leaselinkd/main.zig:783-787`). If the second database write
fails, `serviceOneDesired` calls `scheduleRetry`, but `markApplied` has already
set `dirty=0`; `scheduleRetry` does not restore it. The remote override may
therefore exist without a scheduled Unbound reconfigure and without eligible
retry work until a later full reconciliation.

Deletion has a related split-update sequence at
`src/leaselinkd/main.zig:789-796`; once the desired row is deleted, retry
scheduling for that hostname has no row to update.

Recommended fix:

- Decide whether the legacy `overrides` table is still needed. Remove it if all
  reads have migrated to `desired_overrides`.
- Otherwise update related local tables in one SQLite transaction, check the
  commit result, and mark clean only as the final local step.
- Persist pending-reconfigure intent so a restart or local write failure cannot
  lose it.
- Make retry scheduling explicitly set `dirty=1` and verify a row was changed.

## Medium-severity findings

### M1. Metrics uses 32 request threads, large preallocation, and no connection timeouts [COMPLETED]

The code intends one metrics worker but configures the wrong httpz field
(`src/leaselinkd/main.zig:43`). In blocking mode, httpz defaults to 32 request
threads, a backlog of 500, 32 KiB per-thread buffers, 64 pre-created HTTP
connection objects, and a large-buffer pool. The existing torture evidence
shows 35 manager threads and approximately 1.29 GiB of virtual address space at
the end of the run, while RSS remained near 18 MiB. This is mostly bounded
reservation, but it obscures leak analysis and increases fork risk.

Neither request nor keepalive timeouts are configured. If metrics binds to
`0.0.0.0`, slow clients can occupy the pool indefinitely.

Recommended fix:

- Set `thread_pool.count = 1`; `workers.count` is not the controlling field in
  this build mode.
- Set small request and keepalive deadlines and a low request-count limit.
- Set a small metrics request-body limit because the endpoint needs no body.
- Keep loopback as the default; require a firewall or authenticated reverse
  proxy for remote scraping.
- Add a thread-count and slow-metrics-client regression test.

### M2. The metrics dependency performs a non-atomic read of an atomically
updated counter

The active vendored `metrics.zig` `CounterVec` increments label values with
`@atomicRmw`, but its `write` path copies `kv.value_ptr.*` and reads `count`
normally (`zig-pkg/metrics-*/src/counter.zig:223-239`). Map membership is
protected by a shared lock, but increments also hold only the shared lock, so
that lock does not serialize the count access. Concurrent API activity and
metrics scraping can therefore race under Zig's memory model.

Recommended fix:

- Patch or update the dependency so rendering uses `@atomicLoad` for the count.
- Submit the fix upstream and pin a reviewed commit.
- Run a race detector when the Zig/C toolchain supports the complete binary, or
  add a high-concurrency dependency test around scrape plus increment.

### M3. OPNsense response allocation is unbounded inside the worker [COMPLETED]

The parent rejects a worker response length above 128 KiB, but the child first
allows `std.http.Client.fetch` to grow an allocating writer without a response
limit (`src/leaselinkd/main.zig:1053-1068`). A faulty or hostile OPNsense endpoint
can consume substantial worker memory before the parent learns the size. The
parent deadline eventually kills the worker, but repeated requests can repeat
the allocation pressure. `MEMORY.md` currently overstates this as a fully
bounded response path.

Recommended fix:

- Use a limited writer or streaming reader capped at `max_api_frame_bytes`.
- Reject an oversized `Content-Length` before reading, while still enforcing a
  streaming cap for chunked or missing-length responses.
- Test fixed-length and chunked oversized replies and verify bounded worker RSS.

### M4. The hook batch size and total execution time are unbounded [COMPLETED]

`KEA_LEASES4_SIZE` is parsed directly into `usize` and used as the loop bound
(`src/kea_hook/main.zig:124-127`). Every entry creates several formatted
environment names in the process-lifetime arena. Every forwarded lease also
gets a fresh per-call timeout, so a large batch can block for
`count * timeout_seconds`. The first transmission failure aborts the remainder
of the batch.

`postTcp` also allocates a zero-terminated host using `page_allocator` without
freeing it (`src/kea_hook/main.zig:257`). A normal one-shot event hides this,
but a batch makes the leak linear within that process.

Recommended fix:

- Impose a documented maximum batch size.
- Use one overall monotonic batch deadline plus a bounded per-entry deadline.
- Free `host_z`, or allocate it from a resettable per-entry arena.
- Reuse buffers and environment-name storage across iterations.
- Define and test partial-batch behavior so later valid entries are not silently
  abandoned after one transport failure.

### M5. Wall-clock timers and weak numeric limits permit jumps and overflow

Health, reconciliation, reconfiguration, retry eligibility, and lease expiry
use wall-clock seconds. Clock corrections can delay or prematurely trigger
operational timers. Most timer configuration fields are checked only for being
positive; `record_ttl_seconds`, `reconcile_seconds`, `throttle_seconds`,
`health_check_seconds`, and `max_backoff_ms` have no practical upper bound.
Addition and doubling at `src/leaselinkd/main.zig:553`, `:595`, `:612`,
`:626-629`, and lease expiry at `:708-709` can overflow in ReleaseSafe.
`valid-lifetime` is input-controlled and can parse as any `i64`.

Recommended fix:

- Use monotonic time for in-process deadlines and cadence.
- Keep Unix time only for durable lease-expiry timestamps, using checked or
  saturating arithmetic.
- Give every configuration duration a practical maximum and enforce the same
  bounds in the hook and packaging validator.
- Cap lease lifetime independently of the configured fallback.
- Add tests for extreme values and simulated forward/backward clock changes.

### M6. DNS validation is synchronous and can dominate startup and the main
loop

Each DNS resolver gets a blocking two-second poll
(`src/leaselinkd/main.zig:428-447`). Startup checks every desired record against
every resolver before accepting queued lease connections. Normal durable work
also performs all DNS queries in the single manager loop. A large ledger or
unresponsive resolver list can delay service readiness, intake, timers, and
shutdown for a long time.

Recommended fix:

- Apply an overall DNS-validation budget, not two seconds multiplied without
  bound by every resolver and record.
- Move bulk startup validation to incremental scheduled work after the listener
  is servicing requests.
- Cache resolver health briefly and skip repeatedly failing resolvers within a
  bounded interval.
- Expose DNS query count, failure, latency, and skipped-budget metrics.

### M7. DNS replies are easy to spoof or misassociate

The UDP socket is not connected to the configured resolver and uses `recv`
rather than checking a `recvfrom` source. The query ID is the low 16 bits of
wall-clock seconds, so every query in the same second shares a predictable ID
(`src/leaselinkd/main.zig:435`). Reply validation checks only that ID and then
accepts any matching A record in the answer section. It does not verify the QR
bit, opcode, original question, truncation flag, source address, or answer-name
relationship.

A forged matching response can incorrectly suppress an OPNsense update. This
does not grant OPNsense API access, but it compromises the validation decision.

Recommended fix:

- Connect the UDP socket to the selected resolver or validate the full source
  address returned by `recvfrom`.
- Generate query IDs from `std.crypto.random`.
- Validate response flags, exactly one matching question, class/type, and the
  CNAME/answer chain for the requested name.
- Treat truncated UDP responses explicitly, with bounded TCP fallback if that
  interoperability is required.

### M8. Reconciliation rewrites all desired records and resets their backoff

Every reconciliation ends with:

```sql
UPDATE desired_overrides SET dirty=1,next_attempt=0 WHERE present=1
```

(`src/leaselinkd/main.zig:858-860`). When DNS validation is disabled,
unavailable, or mismatched, every desired record is sent to OPNsense again each
reconciliation interval. The update also clears the scheduled delay for records
already backing off after failures. A large ledger can therefore become a
permanent write workload and can amplify an OPNsense outage.

Recommended fix:

- Compare the remote ownership/UUID inventory with desired state and dirty only
  missing or uncertain rows.
- Preserve `next_attempt` and failure counts unless new authoritative lease data
  changes the desired record.
- Add reconciliation metrics for scanned, matched, dirtied, deleted, and failed
  records.
- Test a large stable ledger with DNS disabled and assert that reconciliation
  performs no unnecessary writes.

### M9. Signal-interrupted I/O and broken pipes are not handled robustly

The raw `poll`, `read`, `write`, `recv`, and `send` loops generally treat
`EINTR` as failure instead of retrying. A SIGUSR1/SIGUSR2/SIGTERM arriving
during API IPC or hook transport can therefore kill the API worker or fail a
lease event unnecessarily. Writes do not use `MSG_NOSIGNAL`, and SIGPIPE is not
explicitly ignored. A peer that closes at the wrong time can terminate the
writing process rather than returning an error.

Recommended fix:

- Retry `EINTR` while recomputing the remaining monotonic deadline.
- Ignore SIGPIPE process-wide before threads start, or use
  `send(..., MSG_NOSIGNAL)` where available.
- Distinguish timeout, cancellation, peer close, and internal worker failure in
  metrics and logs.
- Add signal-storm and peer-close tests around every IPC phase.

### M10. Default logging can become a resource problem and DEBUG permits log
injection

At INFO, every accepted lease and every OPNsense POST is logged. At burst rates
this can dominate CPU and journal/disk usage. DEBUG additionally logs full lease
payloads, MAC addresses, arguments, and unvalidated environment fields such as
interface and subnet values (`src/kea_hook/main.zig:48`, `:82`, `:105`). Those
fields can contain control characters or newlines and forge journal-looking
entries. The argv formatter currently emits byte arrays, producing large but
low-value logs.

OPNsense worker errors are collapsed to one sentinel, after which the parent
prints certificate advice even for HTTP status, parsing, allocation, and other
non-certificate failures (`src/leaselinkd/main.zig:949-952`). SQLite errors omit
the database error code and message.

Recommended fix:

- Make per-event success logs DEBUG, or sample/rate-limit them; retain aggregate
  counters at INFO/SIGUSR1.
- Escape control characters in every externally sourced log field.
- Redact or hash MAC addresses in payload-level diagnostics and document DEBUG
  data sensitivity.
- Send a bounded structured error code from the API worker to the parent instead
  of one undifferentiated sentinel.
- Rate-limit repeated identical DNS/API/database warnings.

## Low-severity findings

### L1. Unknown configuration keys are silently ignored [COMPLETED]

Both manager and hook JSON parsing use `ignore_unknown_fields = true`. A typo in
a safety-sensitive field silently selects its default. Reject unknown keys in
`--config-check`, or at least emit a warning listing them. Compatibility aliases
should be explicit rather than relying on general permissiveness.

### L2. `queue_max_events` and documented queue behavior do not match the code

`queue_max_events` is validated but never used. `PendingEvent` is unused, and
the listener backlog is always the compile-time `512`. README text describing
an in-memory startup queue and shutdown draining does not match the current
SQLite-driven implementation; shutdown exits and leaves durable work for the
next start. Remove the dead setting/type or implement the promised behavior,
then align documentation and tests.

### L3. Small response writes do not guarantee complete delivery [COMPLETED]

`respond` calls `send` once and checks only for a negative result
(`src/leaselinkd/main.zig:699-701`). A short positive write is treated as
success. Use the same deadline-aware send-all routine as the hook and include
SIGPIPE protection.

### L4. Process metrics omit the API worker [COMPLETED]

`/metrics` samples `/proc/self/statm` and `RUSAGE_SELF`, so the RSS, virtual
memory, and CPU gauges cover only the manager. The API worker owns HTTP/TLS
allocation and can be the component that grows. Export worker PID-lifecycle,
RSS/PSS, CPU, FD, and restart counters from the parent, or name existing gauges
explicitly as manager-only. Continue collecting both processes in soak tests.

### L5. Error messages and service hardening can be tightened

The `--api-test` alarm message always says 60 seconds even when
`api_test_timeout_seconds` differs. Its `_exit(124)` bypasses deferred worker
cleanup outside a systemd cgroup. The sources explicitly define
`_FORTIFY_SOURCE=0`. The unit has strong basics but can additionally evaluate
`CapabilityBoundingSet=`, `PrivateDevices=`, `ProtectClock=`,
`ProtectKernelTunables=`, `ProtectKernelModules=`, `ProtectControlGroups=`,
`RestrictSUIDSGID=`, `LockPersonality=`, `RestrictRealtime=`, explicit address
families, core-dump restrictions, and an intentional `TimeoutStopSec`.

Apply systemd restrictions only after testing SQLite, Unix sockets, DNS,
IPv4/IPv6 HTTPS, certificate loading, and API-worker startup. Do not add a
syscall filter blindly around the current `fork` design.

## Allocation and ownership review

The following allocation paths are appropriately bounded or lifetime-scoped:

- Manager lease parsing uses a 64 KiB stack buffer and a per-connection arena.
- Timer work, health checks, and reconciliation use short-lived arenas that are
  deinitialized after each service pass.
- API-worker per-request arenas are released after every request.
- Parent-side API endpoint, payload, and returned frame lengths are capped at
  128 KiB.
- Configuration and secret files are capped at 128 KiB; hook configuration is
  capped at 64 KiB.
- Metrics labels are chosen from the fixed GET/POST method set, so label
  cardinality is bounded.

The important allocation exceptions are M1, M3, and M4: the oversized metrics
thread pool and buffer reserves, unbounded child-side HTTP response writer, and
batch-hook lifetime allocations. The process initialization arena intentionally
retains configuration, credentials, and metrics registry storage for process
lifetime; that retention is not by itself a leak.

## Timing and restart behavior

Normal OPNsense calls are serialized through one worker. The parent enforces
`api_timeout_seconds`, kills and reaps the worker after IPC timeout/failure, and
starts a new worker for the next call. This caps the parent wait but does not
make a mutating request transactional: a remote mutation can succeed just
before timeout. Durable reconciliation is therefore essential and must fail
closed.

Health failure uses capped exponential backoff. Durable-record failure uses
SQLite backoff. Reconfigure failure retries every one second without
exponential backoff, which can add pressure during an OPNsense outage. Use a
capped, jittered backoff for reconfigure while preserving the fact that a later
successful mutation still needs only one pending reconfigure.

Systemd uses `Restart=on-failure` with `RestartSec=2`. Normal SIGTERM exits
successfully and is not an application failure. Shutdown latency is currently
bounded by neither an accepted-client timeout nor an overall DNS work budget;
an API operation may also use a configured deadline of up to one hour. Define
an application shutdown deadline shorter than systemd's stop timeout and stop
starting new durable work after shutdown is requested.

## Verification performed

- `zig build test -Doptimize=ReleaseSafe` passed, including unit, resolver, and
  mock-OPNsense integration tests.
- The controlled slow-client test reproduced H1 and retained evidence in
  `/tmp/leaselinkd-safety-slowloris-2`.
- The earlier ten-minute torture evidence confirmed the stable 35-thread
  manager shape and bounded RSS plateau relevant to M1.
- Static inspection covered every raw socket/pipe read and write, timer update,
  SQLite prepare/bind/step path, arena boundary, signal handler, metrics access,
  and API-worker lifecycle in the Zig agents.
- Valgrind 3.25.1 was present but could not start because this system's stripped
  glibc loader lacks the required `memcmp` redirection symbol. No conclusion
  about leak freedom is drawn from that failed invocation. Install the matching
  glibc debug-symbol package before treating Valgrind as an available gate.

## Recommended remediation order

1. Fix H1, H2, and H6 together: deadline-aware nonblocking intake, safe length
   arithmetic, and a per-loop accept budget.
2. Replace the post-thread `fork` worker design and set the actual metrics
   thread-pool count and timeouts.
3. Enforce production transport boundaries: authenticated local intake and
   HTTPS-only OPNsense credentials.
4. Make every SQLite result explicit, make local state transitions
   transactional, and ensure reconciliation fails closed.
5. Bound API responses in the child before allocation and add worker failure
   and oversized-response tests.
6. Move cadence to monotonic clocks, cap all numeric inputs, and budget DNS and
   shutdown work.
7. Harden DNS reply association and stop blanket reconciliation rewrites.
8. Bound batch-hook work, repair the TCP allocation, harden signal I/O, and
   reduce/redact logs.
9. Apply the defense-in-depth systemd and observability improvements after the
   behavior changes have regression coverage.

Until the high-severity items are resolved, keep lease intake on the protected
Unix socket, keep metrics on loopback, require HTTPS for real OPNsense access,
and treat members of the `leaselinkd` group as trusted service principals.
