#!/usr/bin/env sh
set -eu

manager=$1
hook=$2
tmp=$(mktemp -d)
manager_pid=''
opnsense_pid=''
cleanup() {
  [ -z "$manager_pid" ] || kill "$manager_pid" 2>/dev/null || true
  [ -z "$opnsense_pid" ] || kill "$opnsense_pid" 2>/dev/null || true
  if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then printf '%s\n' "integration files kept at $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT INT TERM

python3 tests/mock_opnsense.py "$tmp/opnsense.port" "$tmp/opnsense.log" >"$tmp/mock.log" 2>&1 &
opnsense_pid=$!
for _ in $(seq 1 50); do [ -f "$tmp/opnsense.port" ] && break; sleep 0.05; done
port=$(cat "$tmp/opnsense.port")
metrics_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat > "$tmp/config.json" <<EOF
{"opnsense_url":"http://127.0.0.1:$port/api/unbound","db_path":"$tmp/ledger.sqlite","socket_path":"$tmp/unbound.sock","metrics_port":$metrics_port,"domain":"test","throttle_seconds":1,"health_check_seconds":3600}
EOF
cat > "$tmp/secrets.json" <<'EOF'
{"api_key":"key","api_secret":"secret"}
EOF
cat > "$tmp/hook.json" <<EOF
{"leaselinkd_address":"unix://$tmp/unbound.sock"}
EOF
"$manager" --config "$tmp/config.json" --secret "$tmp/secrets.json" --config-check >"$tmp/config-check.log" 2>&1
grep -q 'configuration check passed' "$tmp/config-check.log"
test ! -e "$tmp/ledger.sqlite"
"$manager" --help >"$tmp/manager-help.log"
grep -q '^ Usage: leaselinkd \[OPTIONS\]' "$tmp/manager-help.log"
grep -q -- '--config <PATH>' "$tmp/manager-help.log"
grep -q -- '--secret <PATH>' "$tmp/manager-help.log"
"$hook" --help >"$tmp/hook-help.log"
grep -q '^ Usage: kea-leaselink \[OPTIONS\] EVENT' "$tmp/hook-help.log"
grep -q -- '--config <PATH>' "$tmp/hook-help.log"
"$manager" --config "$tmp/config.json" --secret "$tmp/secrets.json" --api-test >"$tmp/api-test.log" 2>&1
grep -q 'API test passed' "$tmp/api-test.log"
grep -q 'GET /api/unbound/service/status' "$tmp/opnsense.log"
grep -q 'POST /api/unbound/service/reconfigure' "$tmp/opnsense.log"
kill "$opnsense_pid"
wait "$opnsense_pid" 2>/dev/null || true
rm -f "$tmp/opnsense.port"
OPNSENSE_BIND_PORT="$port" OPNSENSE_DELAY_SECONDS=6 python3 tests/mock_opnsense.py "$tmp/opnsense.port" "$tmp/opnsense.log" >"$tmp/mock.log" 2>&1 &
opnsense_pid=$!
for _ in $(seq 1 50); do [ -f "$tmp/opnsense.port" ] && break; sleep 0.05; done
timeout_started=$(date +%s)
if LEASELINKD_CONFIG="$tmp/config.json" LEASELINKD_SECRETS="$tmp/secrets.json" "$manager" --api-test >"$tmp/api-timeout.log" 2>&1; then exit 1; fi
test $(($(date +%s) - timeout_started)) -lt 6
grep -q 'ApiTimeout' "$tmp/api-timeout.log"
kill "$opnsense_pid"
wait "$opnsense_pid" 2>/dev/null || true
rm -f "$tmp/opnsense.port"
OPNSENSE_BIND_PORT="$port" python3 tests/mock_opnsense.py "$tmp/opnsense.port" "$tmp/opnsense.log" >"$tmp/mock.log" 2>&1 &
opnsense_pid=$!
for _ in $(seq 1 50); do [ -f "$tmp/opnsense.port" ] && break; sleep 0.05; done
: > "$tmp/opnsense.log"
LEASELINKD_CONFIG="$tmp/config.json" LEASELINKD_SECRETS="$tmp/secrets.json" "$manager" --loglevel DEBUG >"$tmp/manager.log" 2>&1 &
manager_pid=$!
for _ in $(seq 1 50); do [ -S "$tmp/unbound.sock" ] && break; sleep 0.05; done
[ -S "$tmp/unbound.sock" ]
grep -q 'leaselinkd v3.0.2 starting; architecture=' "$tmp/manager.log"
grep -q 'config: api=' "$tmp/manager.log"
grep -q 'OPNsense startup health check passed: api=' "$tmp/manager.log"
for _ in $(seq 1 50); do python3 -c "import urllib.request; assert b'leaselinkd_process_resident_memory_bytes' in urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics').read()" && break; sleep 0.05; done
python3 -c "import urllib.request; assert b'leaselinkd_process_resident_memory_bytes' in urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics').read()"

KEA_LEASE4_HOSTNAME=printer KEA_LEASE4_ADDRESS=192.0.2.50 KEA_LEASE4_HWADDR=00:11:22:33:44:55 "$hook" --config "$tmp/hook.json" --loglevel DEBUG lease4_committed >"$tmp/hook-add.log" 2>&1
grep -q 'lease operation complete: event=lease4_committed manager_api=passed' "$tmp/hook-add.log"
for _ in $(seq 1 50); do [ -f "$tmp/opnsense.log" ] && break; sleep 0.05; done
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" "SELECT hostname || ':' || uuid || ':' || ip_address FROM overrides" | grep -qx 'printer:override-uuid:192.0.2.50' && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" "SELECT hostname || ':' || uuid || ':' || ip_address FROM overrides" | grep -qx 'printer:override-uuid:192.0.2.50'
grep -q 'POST /api/unbound/settings/add_host_override Basic a2V5OnNlY3JldA==' "$tmp/opnsense.log"
python3 -c "import urllib.request; assert b'leaselinkd_lease_events_total 1' in urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics').read()"
for _ in $(seq 1 30); do test "$(grep -c 'service/reconfigure' "$tmp/opnsense.log")" -eq 1 && break; sleep 0.1; done
test "$(grep -c 'service/reconfigure' "$tmp/opnsense.log")" -eq 1

KEA_LEASE4_HOSTNAME=printer KEA_LEASE4_ADDRESS=192.0.2.50 KEA_LEASE4_HWADDR=00:11:22:33:44:55 "$hook" --config "$tmp/hook.json" --loglevel DEBUG lease4_release
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM overrides' | grep -qx 0 && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM overrides' | grep -qx 0
grep -q 'POST /api/unbound/settings/del_host_override/override-uuid' "$tmp/opnsense.log"
for _ in $(seq 1 30); do test "$(grep -c 'service/reconfigure' "$tmp/opnsense.log")" -eq 2 && break; sleep 0.1; done
test "$(grep -c 'service/reconfigure' "$tmp/opnsense.log")" -eq 2
KEA_LEASE4_HOSTNAME=renewed KEA_LEASE4_ADDRESS=192.0.2.60 KEA_LEASE4_HWADDR=00:11:22:33:44:66 "$hook" --config "$tmp/hook.json" lease4_committed
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" "SELECT ip_address FROM overrides WHERE hostname='renewed'" | grep -qx 192.0.2.60 && break; sleep 0.05; done
KEA_LEASE4_HOSTNAME=renewed KEA_LEASE4_ADDRESS=192.0.2.61 KEA_LEASE4_HWADDR=00:11:22:33:44:66 "$hook" --config "$tmp/hook.json" lease4_renew
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" "SELECT ip_address FROM overrides WHERE hostname='renewed'" | grep -qx 192.0.2.61 && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" "SELECT ip_address FROM overrides WHERE hostname='renewed'" | grep -qx 192.0.2.61
grep -q 'tracked lease IP changed: event=lease4_renew host=renewed previous_ip=192.0.2.60 new_ip=192.0.2.61' "$tmp/manager.log"
grep -q 'POST /api/unbound/settings/set_host_override/override-uuid' "$tmp/opnsense.log"
grep -q '"description":"Managed by leaselinkd; leaselinkd:renewed:' "$tmp/opnsense.log"
KEA_LEASE4_HOSTNAME=renewed KEA_LEASE4_ADDRESS=192.0.2.61 KEA_LEASE4_HWADDR=00:11:22:33:44:66 "$hook" --config "$tmp/hook.json" lease4_decline
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" "SELECT count(*) FROM overrides WHERE hostname='renewed'" | grep -qx 0 && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" "SELECT count(*) FROM overrides WHERE hostname='renewed'" | grep -qx 0
python3 tests/burst_lease_events.py "$tmp/unbound.sock" 32 burst
for _ in $(seq 1 600); do test "$(sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM overrides')" -eq 32 && break; sleep 0.05; done
test "$(sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM overrides')" -eq 32
test "$(grep -c 'POST /api/unbound/settings/add_host_override' "$tmp/opnsense.log")" -eq 34
# The manager's startup health check and all subsequent API calls share one HTTP/1.1 worker connection.
test "$(sed -n 's/.* peer=\([0-9][0-9]*\) body=.*/\1/p' "$tmp/opnsense.log" | sort -u | wc -l | tr -d ' ')" -eq 1
env -u KEA_LEASE4_HOSTNAME KEA_LEASE4_ADDRESS=192.0.2.61 "$hook" --config "$tmp/hook.json" lease4_renew >"$tmp/hostname-less-renew.log" 2>&1
grep -q 'hostname-less lease4_renew deferred' "$tmp/hostname-less-renew.log"
LEASES4_SIZE=1 LEASES4_AT0_HOSTNAME=batchhost LEASES4_AT0_ADDRESS=192.0.2.70 LEASES4_AT0_HWADDR=00:11:22:33:44:77 LEASES4_AT0_VALID_LIFETIME=3600 "$hook" --config "$tmp/hook.json" leases4_committed
for _ in $(seq 1 50); do sqlite3 "$tmp/ledger.sqlite" "SELECT ip_address FROM overrides WHERE hostname='batchhost'" | grep -qx 192.0.2.70 && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" "SELECT ip_address FROM overrides WHERE hostname='batchhost'" | grep -qx 192.0.2.70
if KEA_LEASELINK_CONFIG="$tmp/hook.json" KEA_LEASE4_HOSTNAME=loopback KEA_LEASE4_ADDRESS=127.0.0.1 KEA_LEASE4_HWADDR=00:11:22:33:44:55 "$hook" --loglevel DEBUG lease4_committed >"$tmp/loopback.log" 2>&1; then exit 1; fi
grep -q 'invalid or loopback IPv4 lease address' "$tmp/loopback.log"
test "$(grep -c 'settings/add_host_override' "$tmp/opnsense.log")" -eq 35
resync_searches=$(grep -c 'GET /api/unbound/settings/search_host_override' "$tmp/opnsense.log" || true)
kill -USR2 "$manager_pid"
for _ in $(seq 1 30); do grep -q 'SIGUSR2 requested SQLite-to-OPNsense resync' "$tmp/manager.log" && break; sleep 0.1; done
grep -q 'SIGUSR2 requested SQLite-to-OPNsense resync' "$tmp/manager.log"
for _ in $(seq 1 30); do test "$(grep -c 'GET /api/unbound/settings/search_host_override' "$tmp/opnsense.log" || true)" -gt "$resync_searches" && break; sleep 0.1; done
test "$(grep -c 'GET /api/unbound/settings/search_host_override' "$tmp/opnsense.log" || true)" -gt "$resync_searches"
kill -USR1 "$manager_pid"
for _ in $(seq 1 30); do grep -q 'metrics: runtime=' "$tmp/manager.log" && break; sleep 0.1; done
grep -q 'metrics: runtime=' "$tmp/manager.log"
# Capture the final state while the daemon is still alive; KEEP_TEST_TMP=1
# preserves this artifact for manual load-test inspection.
python3 -c "import pathlib, urllib.request; pathlib.Path('$tmp/metrics-final.prom').write_bytes(urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics').read())"
grep -q '^leaselinkd_lease_events_total ' "$tmp/metrics-final.prom"
grep -q '^leaselinkd_opnsense_api_requests_total' "$tmp/metrics-final.prom"
