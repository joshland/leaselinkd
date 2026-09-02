#!/usr/bin/env sh
# Run a bounded-state, end-to-end memory soak against the local mock OPNsense.
# Usage: sh tests/memory_soak.sh MANAGER HOOK [DURATION_SECONDS] [OUTPUT_DIR]
set -eu

manager=$1
hook=$2
duration=${3:-10800}
output=${4:-$(mktemp -d -t leaselinkd-memory-soak.XXXXXX)}
interval=${SOAK_INTERVAL_SECONDS:-5}
hosts=${SOAK_HOSTS:-128}
loglevel=${SOAK_LOGLEVEL:-TRACE}
map_every=${SOAK_MAP_EVERY:-12}
metrics_enabled=${SOAK_METRICS_ENABLED:-true}

[ "$duration" -gt 0 ]
[ "$interval" -gt 0 ]
[ "$hosts" -gt 0 ]
[ "$map_every" -gt 0 ]
case "$metrics_enabled" in true|false) ;; *) printf '%s\n' 'SOAK_METRICS_ENABLED must be true or false' >&2; exit 2 ;; esac
mkdir -p "$output"
manager_pid=''
opnsense_pid=''
cleanup() {
  [ -z "$manager_pid" ] || kill "$manager_pid" 2>/dev/null || true
  [ -z "$opnsense_pid" ] || kill "$opnsense_pid" 2>/dev/null || true
  [ -z "$manager_pid" ] || wait "$manager_pid" 2>/dev/null || true
  [ -z "$opnsense_pid" ] || wait "$opnsense_pid" 2>/dev/null || true
  printf '%s\n' "memory-soak evidence kept at $output" >&2
}
trap cleanup EXIT INT TERM

python3 tests/mock_opnsense.py "$output/opnsense.port" "$output/opnsense.log" >"$output/mock.log" 2>&1 &
opnsense_pid=$!
for _ in $(seq 1 100); do [ -f "$output/opnsense.port" ] && break; sleep 0.05; done
[ -f "$output/opnsense.port" ]
port=$(cat "$output/opnsense.port")
metrics_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
cat > "$output/config.json" <<EOF
{"opnsense_url":"http://127.0.0.1:$port/api/unbound","db_path":"$output/ledger.sqlite","socket_path":"$output/unbound.sock","metrics_enabled":$metrics_enabled,"metrics_port":$metrics_port,"domain":"test","throttle_seconds":1,"health_check_seconds":5,"reconcile_seconds":30}
EOF
cat > "$output/secrets.json" <<'EOF'
{"api_key":"key","api_secret":"secret"}
EOF
cat > "$output/hook.json" <<EOF
{"leaselinkd_address":"unix://$output/unbound.sock","timeout_seconds":5}
EOF
printf '%s\n' 'epoch,elapsed_s,event_index,manager_rss_kib,manager_vmsize_kib,manager_pss_kib,manager_private_dirty_kib,manager_fds,manager_threads,worker_pid,worker_rss_kib,worker_vmsize_kib,worker_fds,worker_threads,ledger_bytes,wal_bytes' > "$output/samples.csv"
printf 'duration_seconds=%s\ninterval_seconds=%s\nhosts=%s\nloglevel=%s\nmap_every_samples=%s\nmetrics_enabled=%s\nmanager=%s\nhook=%s\n' "$duration" "$interval" "$hosts" "$loglevel" "$map_every" "$metrics_enabled" "$manager" "$hook" > "$output/run.txt"

"$manager" --config "$output/config.json" --secret "$output/secrets.json" --loglevel "$loglevel" >"$output/manager.log" 2>&1 &
manager_pid=$!
for _ in $(seq 1 100); do [ -S "$output/unbound.sock" ] && break; sleep 0.05; done
[ -S "$output/unbound.sock" ]

field() { awk -v key="$2" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' "$1"; }
capture_diagnostics() {
  diagnostic_index=$1
  pmap -x "$manager_pid" > "$output/pmap-manager-$diagnostic_index.txt" 2>&1 || true
  cat "/proc/$manager_pid/smaps" > "$output/smaps-manager-$diagnostic_index.txt" 2>/dev/null || true
  lsof -nP -p "$manager_pid" > "$output/lsof-manager-$diagnostic_index.txt" 2>&1 || true
  if [ -n "$worker_pid" ] && [ -d "/proc/$worker_pid" ]; then
    pmap -x "$worker_pid" > "$output/pmap-worker-$diagnostic_index.txt" 2>&1 || true
    cat "/proc/$worker_pid/smaps" > "$output/smaps-worker-$diagnostic_index.txt" 2>/dev/null || true
    lsof -nP -p "$worker_pid" > "$output/lsof-worker-$diagnostic_index.txt" 2>&1 || true
  fi
}
sample() {
  sample_index=$1
  epoch=$(date +%s)
  worker_pid=$(awk '{print $1}' "/proc/$manager_pid/task/$manager_pid/children" 2>/dev/null || true)
  manager_rss=$(field "/proc/$manager_pid/status" VmRSS)
  manager_vm=$(field "/proc/$manager_pid/status" VmSize)
  manager_pss=$(field "/proc/$manager_pid/smaps_rollup" Pss)
  manager_dirty=$(field "/proc/$manager_pid/smaps_rollup" Private_Dirty)
  manager_fds=$(ls "/proc/$manager_pid/fd" 2>/dev/null | wc -l | tr -d ' ')
  manager_threads=$(field "/proc/$manager_pid/status" Threads)
  worker_rss=0 worker_vm=0 worker_fds=0 worker_threads=0
  if [ -n "$worker_pid" ] && [ -r "/proc/$worker_pid/status" ]; then
    worker_rss=$(field "/proc/$worker_pid/status" VmRSS)
    worker_vm=$(field "/proc/$worker_pid/status" VmSize)
    worker_fds=$(ls "/proc/$worker_pid/fd" 2>/dev/null | wc -l | tr -d ' ')
    worker_threads=$(field "/proc/$worker_pid/status" Threads)
  fi
  ledger_bytes=$(wc -c < "$output/ledger.sqlite" 2>/dev/null || printf 0)
  wal_bytes=$(wc -c < "$output/ledger.sqlite-wal" 2>/dev/null || printf 0)
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$epoch" "$((epoch - started))" "$sample_index" "$manager_rss" "$manager_vm" "$manager_pss" "$manager_dirty" "$manager_fds" "$manager_threads" "${worker_pid:-0}" "$worker_rss" "$worker_vm" "$worker_fds" "$worker_threads" "$ledger_bytes" "$wal_bytes" >> "$output/samples.csv"
  if [ "$metrics_enabled" = true ]; then python3 -c "import pathlib, urllib.request; pathlib.Path('$output/metrics-$sample_index.prom').write_bytes(urllib.request.urlopen('http://127.0.0.1:$metrics_port/metrics', timeout=3).read())"; fi
  if [ $((sample_index % map_every)) -eq 0 ]; then capture_diagnostics "$sample_index"; fi
  kill -USR1 "$manager_pid"
}

started=$(date +%s)
index=0
sample "$index"
while [ $(( $(date +%s) - started )) -lt "$duration" ]; do
  host=$((index % hosts))
  octet=$((index % 250 + 1))
  KEA_LEASE4_HOSTNAME="soak$host" KEA_LEASE4_ADDRESS="10.201.$((host / 250 + 1)).$octet" KEA_LEASE4_HWADDR="02:00:00:00:$((host / 256)):$(printf '%02x' "$host")" "$hook" --config "$output/hook.json" --loglevel "$loglevel" lease4_committed >>"$output/hook.log" 2>&1
  index=$((index + 1))
  sample "$index"
  sleep "$interval"
done
sample "$index"
sqlite3 "$output/ledger.sqlite" '.dump' > "$output/ledger.sql"
grep -E '(/service/status|add_host_override|set_host_override|service/reconfigure)' "$output/opnsense.log" | awk '{ counts[$2]++ } END { for (path in counts) print path, counts[path] }' | sort > "$output/api-summary.txt"
printf 'completed_events=%s\n' "$index" >> "$output/run.txt"
