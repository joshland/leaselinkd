#!/usr/bin/env bash
# Stop the local manager and, when explicitly requested, remove only records
# marked as leaselinkd-owned through the configured authenticated API.
set -euo pipefail
usage(){ cat <<'EOF'
Usage: decommission-leaselinkd.sh [--remove-managed-records] [--purge-local-state] --yes

Stops and disables leaselinkd. --remove-managed-records searches the configured
OPNsense API and deletes only host overrides whose description contains the
leaselinkd ownership marker, then applies Unbound. --purge-local-state removes
the SQLite ledger after the service is stopped. Both are destructive.
EOF
}
remove=0; purge=0; yes=0
while (($#)); do case "$1" in --remove-managed-records)remove=1;;--purge-local-state)purge=1;;--yes)yes=1;;-h|--help)usage;exit 0;;*)usage >&2;exit 64;;esac;shift;done
((yes)) || { printf '%s\n' 'Refusing without --yes.' >&2; exit 64; }
if ((remove)); then
 sudo python3 - <<'PY'
import base64, json, os, ssl, sys, urllib.error, urllib.request
with open('/etc/leaselinkd/config.json', encoding='utf-8') as f: config=json.load(f)
with open('/etc/leaselinkd/secrets.json', encoding='utf-8') as f: secrets=json.load(f)
base=config['opnsense_url'].rstrip('/'); token=base64.b64encode((secrets['api_key']+':'+secrets['api_secret']).encode()).decode()
def call(method,path,body=None):
 data=None if body is None else json.dumps(body).encode(); request=urllib.request.Request(base+path,data=data,method=method,headers={'Authorization':'Basic '+token,'Content-Type':'application/json'})
 with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=15) as r:return json.load(r)
rows=call('GET','/settings/search_host_override').get('rows',[]); ids=[row.get('uuid') for row in rows if row.get('uuid') and '; leaselinkd:' in row.get('description','')]
for item in ids: call('POST','/settings/del_host_override/'+item,{})
if ids: call('POST','/service/reconfigure',{})
print(f'Removed {len(ids)} leaselinkd-managed override(s).')
PY
fi
sudo systemctl disable --now leaselinkd.service
if ((purge)); then sudo rm -f /var/lib/leaselinkd/dhcpdb.sqlite /var/lib/leaselinkd/dhcpdb.sqlite-shm /var/lib/leaselinkd/dhcpdb.sqlite-wal; fi
printf '%s\n' 'Local service is decommissioned. Run cleanup-leaselinkd-permissions.sh only after removing the package or accepting that sysusers will recreate its account on reinstall.'
