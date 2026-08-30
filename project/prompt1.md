Goals:

We're going to build a hook-based kea-dhcp4 scrtip which updates unbound overrides on a remote OPNsense server using the opnsense api.

goals: 
- a binary prefferably written in zig 0.16.0 to catch events and call the OPNsense machine with dns updates
- a python-based reconciliation script to check kea records and OPNsense Unbound records (CRUD)
- yay-compliant packages

project directory: ./  (~/_git/lease-management/)

config files:
- /etc/leaselinkd/hook.json
- /etc/leaselinkd/secrets.json

dhcp server:
Model name:                              AMD Ryzen 5 8500G w/ Radeon 740M Graphics
NAME="Arch Linux"
PRETTY_NAME="Arch Linux"
extra/kea 1:3.2.0-2 [installed]

kea plugins:
    "hooks-libraries": [
    { "library": "/usr/lib/kea/hooks/libdhcp_pgsql.so"      },
    { "library": "/usr/lib/kea/hooks/libdhcp_lease_cmds.so" },
    { "library": "/usr/lib/kea/hooks/libdhcp_host_cmds.so"  },
    {
          "library": "/usr/lib/kea/hooks/libdhcp_run_script.so",
          "parameters": {
              "name": "/usr/share/kea/scripts/kea-leaselink",
              "sync": false
    }}],

firewall:
opnsense 26.7

secret.conf:
{
"resource1": "payload1"
"resource2": "payload2"
}

config.json:
{
"opnsense":{ "url": "[url]", "apikey": "[[SECRET:resource1]]"},
"kea": {"pghost":"host", "pguser": "user", "pgpass":"[[SECRET:resource2]]", "dbname": "dbname"}
}
