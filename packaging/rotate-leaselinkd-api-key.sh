#!/usr/bin/env bash
# Rotate in two safe phases: add and validate a replacement, then optionally
# revoke the still-working predecessor.
set -euo pipefail
usage(){ cat <<'EOF'
Usage: rotate-leaselinkd-api-key.sh --firewall HOST [--firewall-user USER] [--revoke-old-key]

Requires SSH access to the firewall and its provision-opnsense-leaselinkd.php
in /root. It creates a second key, securely fetches its one-time bootstrap
file, verifies it through leaselinkd, restarts the service, and only revokes
the previous key when --revoke-old-key is supplied.
EOF
}
firewall='' user=root revoke=0
while (($#)); do case "$1" in --firewall)firewall=${2:?missing value};shift 2;;--firewall-user)user=${2:?missing value};shift 2;;--revoke-old-key)revoke=1;shift;;-h|--help)usage;exit 0;;*)usage >&2;exit 64;;esac;done
[[ -n $firewall ]] || { usage >&2; exit 64; }
for command in ssh scp sudo python3; do command -v "$command" >/dev/null || { printf 'Missing required command: %s\n' "$command" >&2;exit 1;};done
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT; bootstrap="$work/bootstrap.json"; old="$work/old-key"
sudo python3 - "$old" <<'PY'
import json, os, sys
with open('/etc/leaselinkd/secrets.json', encoding='utf-8') as f: value=json.load(f)['api_key']
fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
with os.fdopen(fd,'w',encoding='utf-8') as f:f.write(value)
PY
ssh "${user}@${firewall}" 'rm -f /root/leaselinkd-bootstrap.json && php /root/provision-opnsense-leaselinkd.php --rotate-api-key'
scp "${user}@${firewall}:/root/leaselinkd-bootstrap.json" "$bootstrap"; chmod 600 "$bootstrap"
sudo leaselinkd --secret "$bootstrap" --api-test
sudo python3 - "$bootstrap" <<'PY'
import json, os, sys, tempfile
with open(sys.argv[1], encoding='utf-8') as f: source=json.load(f)
result={key:source[key] for key in ('api_key','api_secret')}
if not all(isinstance(value,str) and value for value in result.values()):raise SystemExit('replacement bootstrap has no API credentials')
path='/etc/leaselinkd/secrets.json';fd,tmp=tempfile.mkstemp(dir=os.path.dirname(path),prefix='.secrets.')
with os.fdopen(fd,'w',encoding='utf-8') as f:json.dump(result,f,indent=2);f.write('\n')
os.chmod(tmp,0o600);os.replace(tmp,path)
PY
sudo systemctl restart leaselinkd.service
if ((revoke)); then ssh "${user}@${firewall}" "php /root/provision-opnsense-leaselinkd.php --revoke-api-key $(<"$old")"; fi
printf '%s\n' 'API key rotation complete. Remove /root/leaselinkd-bootstrap.json from the firewall if it remains.'
