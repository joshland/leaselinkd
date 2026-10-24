# Zig 0.17.0 migration plan

Status: complete — released as 3.1.0 and verified live on dhcp01 against OPNsense `https://10.76.2.5:8443` (IP SAN) · Branch: `zig-0.17` · Baseline: `1b9628d` (3.0.5, Zig 0.16.0)

Decisions (2026-10-24): release as **3.1.0**; advertise IP-SAN API URLs now and
validate them in the live environment; keep metrics at `3676413` (inclusive
histogram bounds). `SAFETY.md` stays as-is: it is a dated review of `0da2d85`
on Zig 0.16 and should be re-run rather than edited.

## Summary

The current tree does **not** build with Zig 0.17.0. The failures are small and
mechanical. A scratch port that applies every change below built cleanly with
the installed Zig 0.17.0, whose `std` is identical to `references/zig-0.17.0`.
That port passed `zig build test -Doptimize=ReleaseSafe` (12/12 steps, 3 + 9
unit tests, and the full mock-OPNsense integration run) and also built with
`-Doptimize=ReleaseSmall`. The ReleaseSmall binaries were 745 KB
(`leaselinkd`) and 199 KB (`kea-leaselink`). Every top-level function was
force-compiled with `refAllDecls`, so lazy analysis does not hide unreferenced
code.

The upgrade has three parts:

1. **Dependencies:** `httpz` and `metrics` must move to their upstream Zig 0.17
   commits. The pinned versions fail in their own `build.zig`.
2. **Hard source breaks:** `@cImport` and `**` were removed, and `dupeZ` and
   `bufPrintZ` no longer exist.
3. **Behavior changes worth taking:** IP-address SAN TLS verification, and
   inclusive histogram bucket bounds.

## 1. Dependency updates (required)

| Package | Current pin | Target | Why |
|---|---|---|---|
| `httpz` | `9b14af9` (tip of `zig-0.16.0` branch) | `e8272bf` (master, 2026-10-14) | `8aeb4e5` ports to 0.17. Later commits return `ConnectionClosed` on a 0-byte read and use `shutdown` instead of `close` to wake blocked `recv` (relevant to the metrics listener's shutdown). |
| `metrics` | `1621f82` (2026-04-27) | `3676413` (master, 2026-10-10) | `ac16729` ports to 0.17 (`@typeInfo` struct `fields` → `field_names`/`field_types`). `3676413` makes histogram upper bounds inclusive. |
| `websocket` (transitive) | `b70e733` | `f2b3bad` | Pulled in automatically by the new httpz. |

Failure today: `zig-pkg/{httpz,metrics}-*/build.zig` use `b.args`, which was
removed from `std.Build`. The replacement is `run.addPassthruArgs()`. Upstream
has already fixed this, so don't patch the vendored copies.

Neither repository has a `zig-0.17` branch yet. `master` is the 0.17 line. Pin
exact commits, as we do now:

```sh
zig fetch --save=httpz   "git+https://github.com/karlseguin/http.zig?ref=master#e8272bfd5727aade0dcee3e2aba6c50f57c374b6"
zig fetch --save=metrics "git+https://github.com/karlseguin/metrics.zig?ref=master#3676413b54c8b36c3aca2c22500aaf065ff2b45d"
```

Resulting hashes:

- `httpz-0.0.0-PNVzrNAXCQDHb-rRH2jq07A3Ekv3GS6XOTkiqZJtKeqv`
- `metrics-0.0.0-W7G4eIqtAQDVZUfnac9O7sSc12T4Mf4E0wVrbQMJzAPu`
- transitive `metrics-0.0.0-W7G4eGWhAQC-…` (httpz's own pin, `ac16729`)
- `websocket-0.1.0-ZPISdbERBQCnk2-…`

`zig-pkg/` is committed (82 files). Delete the four old package directories and
commit the four new ones.

Notes:

- **Duplicate metrics package.** Our pin and httpz's internal pin are different
  commits, so two copies of `metrics` get compiled. This was already true in
  0.16. It's harmless because httpz's metrics are rendered through
  `httpz.writeMetrics`, but pinning ours to `ac16729` would remove the
  duplicate at the cost of the histogram fix. **Recommendation:** keep
  `3676413`.
- **CounterVec locking.** metrics `3676413` doesn't change CounterVec
  rendering, so the existing lock that serializes metrics mutation and
  rendering (3.0.5 changelog) is still required.
- **`minimum_zig_version`.** metrics still declares `0.16.0` upstream. That's
  cosmetic and doesn't affect us.

## 2. Required source changes

| # | Change | Where | Fix |
|---|---|---|---|
| 1 | `@cImport` / `@cInclude` / `@cDefine` removed from the language | `src/leaselinkd/main.zig:6-24`, `src/leaselinkd/prometheus.zig:4-8`, `src/kea_hook/main.zig:3-14` | Move the includes into headers, translate them with `b.addTranslateC`, and replace each block with `const c = @import("c");`. See §2.1. |
| 2 | Array repetition `**` removed (now a parse error) | `src/leaselinkd/main.zig:543` | `var reply: [12]u8 = @splat(0);` |
| 3 | `Allocator.dupeZ` removed (deprecated in 0.16) | `kea_hook/main.zig:255`; `leaselinkd/main.zig:272,295,300,336,358,460` | `allocator.dupeSentinel(u8, s, 0)` |
| 4 | `std.fmt.bufPrintZ` removed (deprecated in 0.16) | `leaselinkd/main.zig:1119`; `prometheus.zig:174,204` | `std.mem.printSentinel(buf, fmt, args, 0)` |

### 2.1 Translate-C wiring

Add `src/c/leaselinkd.h`. It covers both the manager and `prometheus.zig`,
which share one module:

```c
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <spawn.h>
#include <fcntl.h>
#include <sys/wait.h>
#include <sys/random.h>
#include <sqlite3.h>
#include <stdio.h>
#include <sys/resource.h>
```

Add `src/c/kea_hook.h`, which includes `sys/socket.h`, `sys/un.h`,
`netinet/in.h`, `arpa/inet.h`, `poll.h`, `fcntl.h`, `time.h`, `signal.h`, and
`unistd.h`.

In `build.zig`:

```zig
const manager_c = b.addTranslateC(.{ .root_source_file = b.path("src/c/leaselinkd.h"), .target = target, .optimize = optimize });
manager_c.defineCMacro("_GNU_SOURCE", "1");
manager_c.defineCMacro("_FORTIFY_SOURCE", "0");
const manager_c_mod = manager_c.createModule();
const hook_c = b.addTranslateC(.{ .root_source_file = b.path("src/c/kea_hook.h"), .target = target, .optimize = optimize });
hook_c.defineCMacro("_FORTIFY_SOURCE", "0");
```

Then add `.{ .name = "c", .module = manager_c_mod }` to the manager executable
and to the `resolver_tests` imports, and `.{ .name = "c", .module = hook_c.createModule() }`
to the hook. Share one `manager_imports` slice so the executable and its test
module can't drift apart.

`build.zig.zon` `.paths` already includes `src`, so the new headers are packaged without further changes.

## 3. Recommended cleanups (they compile on 0.17 but are deprecated)

Do these in the same branch so that 0.18 doesn't repeat this exercise. All were
verified in the scratch port.

| API | Count | Replacement |
|---|---|---|
| `std.fmt.allocPrint(a, …)` | 15 | `a.print(…)` |
| `std.fmt.bufPrint(…)` | 3 | `std.mem.print(…)` |
| `std.mem.indexOf` / `indexOfScalar` | 1 / 1 | `std.mem.find` / `findScalar` |
| `std.mem.lastIndexOf` / `lastIndexOfScalar` | 1 / 5 | `std.mem.findLast` / `findScalarLast` |
| `@intFromEnum` | 3 | `@backingInt`. `zig fmt` rewrites this automatically, and the 0.17 langref no longer documents `@intFromEnum`. |

Run `zig fmt src build.zig` last. On the current tree, `zig fmt --check` with
0.17 flags `src/common.zig` (`@intFromEnum`) and fails to parse
`src/leaselinkd/main.zig` (`**`).

## 4. Behavior changes to adopt and document

### 4.1 TLS: IP-address SANs now verify

Zig 0.17's `std.crypto.Certificate.Parsed.verifyHostName` matches `iPAddress`
SANs (`checkIpAddress`). I verified this empirically with a 0.17
`std.http.Client` probe:

| URL | Certificate SAN | Result |
|---|---|---|
| `https://127.0.0.1` | `IP:127.0.0.1` | 200 |
| `https://localhost` | `DNS:localhost` | 200 |
| `https://127.0.0.1` | `DNS:localhost` only | `TlsInitializationFailed` (correct) |

Our tooling still enforces the 0.16 limitation:

- `packaging/check-firewall-certificate.sh:126-137` hard-fails any IP API URL.
  Change it to require `IP Address:<host>` for an IP URL, which line 88 already
  computes as `expected_san`, and `DNS:<host>` otherwise.
- `packaging/provision-opnsense-leaselinkd.php:38,61` fails when there's no DNS
  SAN. Accept an IP SAN too, and update the closing advice.
- `README.md` / `project/OPNsense_*` guidance that requires a DNS hostname
  should say that IP SANs are supported.

Caveat: with an IP host, the 0.17 TLS client still sends the literal IP in SNI.
OPNsense lighttpd tolerates this, but confirm it against the real firewall
before advertising support.

### 4.2 Histogram buckets are now inclusive (`le` semantics)

With metrics `3676413`, an observation exactly equal to a bound such as `5` ms
now lands in `le="5"` instead of the next bucket. This is the correct
Prometheus behavior. It affects `leaselinkd_lease_event_request_duration_milliseconds`
and the API latency `HistogramVec`. Expect a slight downward shift in
quantiles on the Grafana dashboard. The dashboard needs no structural change.
Note this in the CHANGELOG.

## 5. Toolchain, packaging, and documentation

- `build.zig.zon`: set `.minimum_zig_version = "0.17.0"`.
- `PKGBUILD`: change `makedepends=('zig')` to `makedepends=('zig>=0.17.0' 'zig<0.18.0')`
  so that an Arch zig bump can't silently break `build()`.
- Update the version references:
  - `AGENTS.md` ("Zig `0.16.0`")
  - `README.md:5` ("Zig 0.16 binaries")
  - `TESTING.md:14`
  - `SAFETY.md:5`. Re-baseline its line-number citations, because the
    `@cImport` removal shifts `main.zig` by about 18 lines.
- `CHANGELOG.md`: add a version section covering the toolchain, dependency
  bumps, the IP-SAN support, and the histogram semantics.
- Version: run `scripts/change_version.sh`. I recommend **3.1.0**, because the
  user-visible changes (IP-SAN support, histogram semantics, toolchain floor)
  go beyond a patch. If 3.0.5 hasn't been released yet, you could fold this
  into it instead. See the open questions.

## 6. Execution order (each step leaves the tree buildable)

1. **Dependencies:** run the two `zig fetch --save` commands, replace
   `zig-pkg/`, and set `minimum_zig_version`.
2. **Hard breaks:** add `src/c/*.h`, wire translate-C in `build.zig`, and apply
   the `**`, `dupeZ`, and `bufPrintZ` fixes.
3. **Check:** `zig build -Doptimize=ReleaseSafe` and
   `zig build test -Doptimize=ReleaseSafe`.
4. **Cleanups:** apply §3, run `zig fmt`, then `zig fmt --check src build.zig`
   and the tests again.
5. **TLS:** change the packaging checks (§4.1). Optionally add an integration
   case that runs the mock OPNsense over HTTPS with an IP-SAN cert. Skip it if
   the host-trust-store requirement makes that impractical in CI.
6. **Packaging and docs:** update PKGBUILD, the docs, and the CHANGELOG, and
   bump the version.
7. **Validation beyond unit tests:**
   - `makepkg` with `ReleaseSmall`.
   - `tests/burst_load.sh … 512`, with and without `DNS_VALIDATION=1`.
   - A 10-minute `tests/memory_soak.sh`. Compare RSS with the archived
     `10m-tests` / `1h-tests` 0.16 results, because the `std.Io` and http
     client internals changed.
   - `leaselinkd --config-check` and `--api-test` against the real OPNsense.
   - `SIGUSR1` and `SIGUSR2` on a staging host.
8. **Commit:** one commit per step above. Don't stage `state.json`.

## 7. Risks

- **Translate-C output differences.** Macro-derived constants such as
  `SIG_IGN`, `POLL*`, `O_*`, and `SQLITE_TRANSIENT` all translated and passed
  tests. Translation now runs as a cached build step instead of at compile
  time. Watch for this if cross-compiling for a different libc.
- **httpz master is unbranched.** Pinning a commit hash shields us from future
  master churn.
- **Untested at runtime:** real-firewall TLS (DNS or IP SAN), the long soak,
  and the API-worker restart under the production systemd sandbox.

## 8. Pre-existing issue found (not caused by 0.17)

`src/kea_hook/main.zig:51` logs `argv={any}`. That prints each argument as a
byte array, and it already did so in the 0.16 soak logs. Formatting the
arguments as strings (for example, joining them or looping with `{s}`) would
make DEBUG output readable.

## Local validation done

- `zig build test -Doptimize=ReleaseSafe`: 12/12 steps passed.
- `zig build -Doptimize=ReleaseSmall`: built 745 KB and 199 KB binaries.
- `zig fmt --check`: clean.
- `tests/burst_load.sh … 512`: 512/512 accepted.
- `check-firewall-certificate.sh` against local IP-SAN and DNS-SAN servers:
  correct pass and fail in each case.

Live result: the first deployment failed with `UnknownHostName` because
dhcp01's system resolver (glibc `getaddrinfo`, falling back to Quad9) could not
resolve `fw0.ashbyte.com`. That was not a 0.17 regression, and the API worker
now reports it explicitly. Switching `opnsense_url` to the IP SAN resolved it.
The 1-hour soaks were stopped at 26 minutes by host memory pressure, with no
growth up to that point; see `zig017-tests.tar.gz`.
