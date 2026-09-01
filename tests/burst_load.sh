#!/usr/bin/env sh
set -eu

manager=$1
count=$2
tmp=$(mktemp -d)
manager_pid=''
opnsense_pid=''
dns_pid=''
cleanup() {
  [ -z "$manager_pid" ] || kill "$manager_pid" 2>/dev/null || true
  [ -z "$opnsense_pid" ] || kill "$opnsense_pid" 2>/dev/null || true
  [ -z "$dns_pid" ] || kill "$dns_pid" 2>/dev/null || true
  if [ "${KEEP_TEST_TMP:-0}" = 1 ]; then printf '%s\n' "burst test files kept at $tmp" >&2; else rm -rf "$tmp"; fi
}
trap cleanup EXIT INT TERM

python3 tests/mock_opnsense.py "$tmp/opnsense.port" "$tmp/opnsense.log" >"$tmp/mock.log" 2>&1 &
opnsense_pid=$!
for _ in $(seq 1 50); do [ -f "$tmp/opnsense.port" ] && break; sleep 0.05; done
port=$(cat "$tmp/opnsense.port")
metrics_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
dns_settings=''
if [ "${DNS_VALIDATION:-0}" = 1 ]; then
  python3 tests/mock_dns.py "$tmp/dns.port" "$tmp/dns.log" >"$tmp/dns-mock.log" 2>&1 &
  dns_pid=$!
  for _ in $(seq 1 50); do [ -f "$tmp/dns.port" ] && break; sleep 0.05; done
  dns_port=$(cat "$tmp/dns.port")
  dns_settings=",\"dns_servers\":[\"127.0.0.1:$dns_port\"]"
fi
cat > "$tmp/config.json" <<EOF
{"opnsense_url":"http://127.0.0.1:$port/api/unbound","db_path":"$tmp/ledger.sqlite","socket_path":"$tmp/unbound.sock","metrics_port":$metrics_port,"domain":"test","throttle_seconds":60,"health_check_seconds":3600$dns_settings}
EOF
cat > "$tmp/secrets.json" <<'EOF'
{"api_key":"key","api_secret":"secret"}
EOF
"$manager" --config "$tmp/config.json" --secret "$tmp/secrets.json" >"$tmp/manager.log" 2>&1 &
manager_pid=$!
for _ in $(seq 1 100); do [ -S "$tmp/unbound.sock" ] && break; sleep 0.05; done
[ -S "$tmp/unbound.sock" ]
python3 tests/burst_lease_events.py "$tmp/unbound.sock" "$count" "load$count" | tee "$tmp/load-result.txt"
for _ in $(seq 1 100); do sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM desired_overrides WHERE present=1' | grep -qx "$count" && break; sleep 0.05; done
sqlite3 "$tmp/ledger.sqlite" 'SELECT count(*) FROM desired_overrides WHERE present=1' | grep -qx "$count"
if [ "${DNS_VALIDATION:-0}" = 1 ]; then
  required_completions=${DNS_MIN_COMPLETIONS:-$count}
  [ "$required_completions" -gt 0 ] && [ "$required_completions" -le "$count" ]
  # Desired work is serialized deliberately; allow two minutes for a 512-item
  # DNS-validation/API burst on a slow local or CI host.
  for _ in $(seq 1 2400); do
    dns_queries=$(grep -c '^query ' "$tmp/dns.log" 2>/dev/null || true)
    api_adds=$(grep -c 'POST /api/unbound/settings/add_host_override ' "$tmp/opnsense.log" 2>/dev/null || true)
    [ "$dns_queries" -ge "$required_completions" ] && [ "$api_adds" -ge "$required_completions" ] && break
    sleep 0.05
  done
  [ "$dns_queries" -ge "$required_completions" ]
  [ "$api_adds" -ge "$required_completions" ]
  printf 'dns_queries=%s api_add_responses=%s required_completions=%s\n' "$dns_queries" "$api_adds" "$required_completions" | tee "$tmp/dns-api-result.txt"
fi
python3 -c "import pathlib, urllib.request; pathlib.Path('$tmp/metrics-final.prom').write_bytes(urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics').read())"
grep -qx "leaselinkd_lease_events_total $count" "$tmp/metrics-final.prom"
