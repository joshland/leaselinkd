# Configuration reference

`leaselinkd` and `kea-leaselink` read separate JSON files. Unknown fields are
ignored for forward compatibility. The manager does not use PostgreSQL
connection or cron-scheduling fields.

## `/etc/leaselinkd/config.json`

```json
{
  "opnsense_url": "https://fw0.example.com:8443/api/unbound",
  "loglevel": "INFO",
  "domain": "example.com",
  "managed_description": "Managed by leaselinkd",
  "record_ttl_seconds": 86400,
  "reconcile_seconds": 300,
  "queue_max_events": 512,
  "db_path": "/var/lib/leaselinkd/dhcpdb.sqlite",
  "listen_type": "unix",
  "socket_path": "/run/leaselinkd/fifo.pipe",
  "tcp_host": "127.0.0.1",
  "tcp_port": 9080,
  "dns_servers": ["10.0.0.1:53", "10.0.0.2:53"],
  "throttle_seconds": 10,
  "health_check_seconds": 60,
  "initial_backoff_ms": 100,
  "max_backoff_ms": 10000,
  "api_timeout_seconds": 5,
  "api_test_timeout_seconds": 60
}
```

`opnsense_url` is required and must begin with `https://` or `http://`; it
includes `/api/unbound` exactly once. For HTTPS, use a DNS hostname covered by
a `DNS:` SAN on the firewall Web GUI certificate. `listen_type` is `unix` by
default; set it to `tcp` only when using the local TCP listener.

`dns_servers` lists IPv4 UDP resolver endpoints used to validate A records.
Each endpoint is `ADDRESS` or `ADDRESS:PORT`; port `53` is used when omitted.
An empty list disables DNS validation for backward-compatible deployments.

All timeout values are seconds and must be between 1 and 3600. The manager
retries failed health checks with exponential backoff beginning at
`initial_backoff_ms` and capped at `max_backoff_ms`.
`managed_description` is stored in each OPNsense host override created or
updated by the manager, making managed records identifiable in the Web GUI.
The manager appends a stable per-host ownership marker to it. `record_ttl_seconds`
expires unrefreshed desired records; `reconcile_seconds` controls managed-record
orphan and duplicate cleanup through OPNsense's search API.

## `/etc/leaselinkd/secrets.json`

```json
{
  "api_key": "YOUR_OPNSENSE_API_KEY",
  "api_secret": "YOUR_OPNSENSE_API_SECRET"
}
```

This file is root-readable only. Do not place credentials in `config.json`,
logs, shell history, or source control. The legacy aliases `apik_key` and
`apikey_secret` are accepted for compatibility.

## `/etc/leaselinkd/hook.json`

```json
{
  "leaselinkd_address": "unix:///run/leaselinkd/fifo.pipe",
  "timeout_seconds": 2,
  "loglevel": "INFO"
}
```

Use `tcp://127.0.0.1:9080` for `leaselinkd_address` only when the manager is
configured with `"listen_type": "tcp"`. `timeout_seconds` bounds the hook's
complete connection, send, and response operation.

## Log-level precedence and test overrides

Both configuration files accept `ERROR`, `WARN`, `INFO`, or `DEBUG` for
`loglevel`. An explicit `--loglevel` argument overrides the configured value.

For one-off tests, `leaselinkd --config PATH --secret PATH` overrides its
normal files, and `kea-leaselink --config PATH` overrides its hook file. The
legacy environment overrides remain supported: `LEASELINKD_CONFIG`,
`LEASELINKD_SECRETS`, and `KEA_LEASELINK_CONFIG`.
