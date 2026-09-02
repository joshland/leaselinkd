# Testing `leaselinkd`

This guide covers local, hermetic tests and the longer-running diagnostics used
to investigate memory behavior. Run commands from the repository root.

The tests create temporary Unix sockets, SQLite ledgers, and loopback HTTP
listeners. They do not read production configuration, credentials, or the
production ledger. The DNS-aware torture test is the exception: it sends UDP
queries to the explicitly supplied resolver, but it still uses a local mock
OPNsense API and never contacts a firewall.

## Prerequisites

The regular test suite needs Zig `0.16.0`, Python 3, SQLite, and a C compiler
toolchain. The memory tests additionally use Linux `/proc`, `pmap`, and `lsof`.

Build the binaries used by direct scripts:

```sh
zig build -Doptimize=ReleaseSafe
```

They are then available as `zig-out/bin/leaselinkd` and
`zig-out/bin/kea-leaselink`.

## Fast test gate

Run the required unit, resolver, and end-to-end integration gates:

```sh
zig build test -Doptimize=ReleaseSafe
```

This starts the real manager and hook against the local mock OPNsense service.
It checks lease add/update/removal behavior, persistence, API authentication,
reconfigure throttling, signal reporting, persistent API connection reuse, and
Prometheus output.

To retain the temporary integration directory when diagnosing a failure:

```sh
KEEP_TEST_TMP=1 zig build test -Doptimize=ReleaseSafe
```

The script prints the retained directory path at exit. The normal default is to
remove it.

## Burst and DNS validation test

The burst test submits concurrent lease events through the manager's Unix
socket. It verifies that two distinct bursts do not add a large linear RSS
step.

```sh
sh tests/burst_load.sh zig-out/bin/leaselinkd 512
```

Run the same test through the local UDP DNS fixture:

```sh
DNS_VALIDATION=1 sh tests/burst_load.sh zig-out/bin/leaselinkd 512
```

`tests/mock_dns.py` deliberately returns NXDOMAIN. This makes the manager
perform both its native DNS lookup and the mock OPNsense update. On slower
machines the full 512-item DNS/API completion check can take up to two minutes.

Useful optional variables:

```sh
KEEP_TEST_TMP=1 DNS_VALIDATION=1 DNS_MIN_COMPLETIONS=64 \
  sh tests/burst_load.sh zig-out/bin/leaselinkd 512
```

`DNS_MIN_COMPLETIONS` lowers only the asynchronous completion threshold; the
submission and ledger assertions still cover the complete burst.

## Memory soak test

`tests/memory_soak.sh` is a bounded-state end-to-end test. It starts a manager
and mock OPNsense, reuses a fixed lease-host ring, sends regular hook events,
scrapes metrics, performs five-second health checks, and retains all evidence.

The default duration is three hours. This example runs ten minutes:

```sh
SOAK_INTERVAL_SECONDS=5 SOAK_MAP_EVERY=12 SOAK_LOGLEVEL=TRACE \
  sh tests/memory_soak.sh \
  zig-out/bin/leaselinkd zig-out/bin/kea-leaselink 600 \
  /tmp/leaselinkd-memory-soak-10m-metrics
```

Run an otherwise identical no-metrics control before attributing growth to the
lease path:

```sh
SOAK_INTERVAL_SECONDS=5 SOAK_MAP_EVERY=12 SOAK_LOGLEVEL=TRACE \
  SOAK_METRICS_ENABLED=false \
  sh tests/memory_soak.sh \
  zig-out/bin/leaselinkd zig-out/bin/kea-leaselink 600 \
  /tmp/leaselinkd-memory-soak-10m-no-metrics
```

The output directory is intentionally retained. Important files include:

- `samples.csv`: manager and API-worker RSS, PSS, virtual memory, private
  dirty memory, FD/thread counts, and SQLite/WAL sizes.
- `metrics-*.prom`: the exact Prometheus payload collected each sample.
- `pmap-*`, `smaps-*`, and `lsof-*`: periodic mapping and descriptor snapshots.
- `manager.log`, `hook.log`, and `opnsense.log`: lifecycle, TRACE, hook, and
  mock API evidence.
- `ledger.sql`: final durable desired-state dump.

Compare the first and last `pmap-manager-*.txt` files as well as the
`samples.csv` slopes. Virtual address space alone is not a leak: compare RSS,
PSS, private dirty memory, mapping counts, and FD counts with the control run.

## DNS-aware torture test

`tests/torture_test.py` is the higher-pressure diagnostic. It owns a local mock
OPNsense process and a `TRACE` manager. Per round it submits 512 concurrent
lease-event requests, waits one second, scrapes metrics, waits 0.5 seconds,
and repeats for `--duration` seconds.

It sends real UDP queries to `--dns-server`. Pass known matching resolver data
with one or more `--dns-host LABEL=IPv4` options. Pass `--fail-host LABEL=IPv4`
with an address which that record must not resolve to. The test also validates
that every generated `--force-prefix<N>` host does not resolve to that fail IP.
Those fixed force hosts drive OPNsense writes while keeping ledger cardinality
bounded.

Example one-hour run:

```sh
python3 tests/torture_test.py \
  --manager zig-out/bin/leaselinkd \
  --dns-server 10.0.0.1 \
  --domain lab.example \
  --dns-host printer=10.0.0.20 \
  --dns-host camera=10.0.0.21 \
  --fail-host failcheck=10.250.0.1 \
  --force-prefix torturefail \
  --duration 3600 \
  --output /tmp/leaselinkd-torture-1h
```

Key parameters:

- `--duration SECONDS`: total test time; default `600`.
- `--batch-size COUNT`: lease requests per round; default `512`.
- `--lease-workers COUNT`: concurrent submitters; default `128`.
- `--force-hosts COUNT`: fixed mismatch-host ring size; default `512`.
- `--good-every N`: use a matching `--dns-host` every N requests; default `8`.
- `--submit-sleep` and `--metrics-sleep`: default to `1` and `0.5` seconds.
- `--map-every N`: capture `pmap`, full `smaps`, and `lsof` every N rounds.
- `--output PATH`: required for a predictable evidence location; otherwise a
  fresh `/tmp/leaselinkd-torture-*` directory is created.

The manager acknowledges a lease once it is durable in SQLite, then serializes
remote API work. Therefore `lease_requests=512/512` proves intake capacity, not
that 512 firewall writes completed in that round. Inspect
`api_host_override_writes` in `summary.txt` and `opnsense.log` for remote work.

The torture test fails on rejected lease requests, manager exit, metrics errors,
invalid initial DNS state, known manager API/health/durable-work errors, or no
observed force-path host-override writes. It retains the same process evidence
as the memory soak, plus `dns-startup.csv` and `summary.txt`.

## Profiling follow-up

Use soak or torture evidence first. If RSS/PSS keeps rising after the expected
warm-up, run allocation profilers only against local test binaries, never a
production daemon. `heaptrack` should start the process rather than attach to
it, since its runtime injection mode is documented as unstable. Valgrind is
useful for a short Debug reproduction, but its timing and allocator behavior
are not representative of production.

`pmap`, `smaps`, and the no-metrics control are usually the fastest way to tell
an address-space reservation apart from resident retained memory.
