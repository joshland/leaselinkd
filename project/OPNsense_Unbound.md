# OPNsense Unbound API

This project manages OPNsense Unbound **Host Overrides** through its native
JSON API. The manager's configured `opnsense_url` includes the API prefix, for
example `https://firewall.example:8443/api/unbound`. Requests use HTTP Basic
authentication with the configured API key as the username and API secret as
the password. API credentials must never be logged.

## Verified endpoints

| Purpose | Method and path relative to `opnsense_url` | Request body | Successful response |
| --- | --- | --- | --- |
| Health | `GET /service/status` | none | service status, including `"status":"running"` |
| Find overrides | `GET /settings/search_host_override` | none | rows containing host, domain, and UUID |
| Read override | `GET /settings/get_host_override/<uuid>` | none | `host` object |
| Add override | `POST /settings/add_host_override` | host wrapper below | `{"result":"saved","uuid":"…"}` |
| Update override | `POST /settings/set_host_override/<uuid>` | host wrapper below | `{"result":"saved"}` |
| Delete override | `POST /settings/del_host_override/<uuid>` | `{}` | successful 2xx response |
| Apply changes | `POST /service/reconfigure` | `{}` | successful 2xx response |
| Full restart (diagnostic use) | `POST /service/restart` | `{}` | successful 2xx response |

The add response supplies the UUID persisted by `leaselinkd`. Update does
not need to return a UUID: the existing UUID remains valid. `reconfigure` is
the manager's normal, throttled apply action; `restart` was tested only to
compare behavior during diagnosis.

## Host override payload

```json
{
  "host": {
    "enabled": "1",
    "hostname": "codecheck",
    "domain": "ashbyte.com",
    "rr": "A",
    "server": "10.111.1.1"
  }
}
```

The complete DNS name is `hostname.domain`. OPNsense stored and returned this
payload unchanged in the test, and a UDP A query to the firewall's port 53
returned the configured address after `/service/reconfigure`.

## Experiment results and guardrails

The repeatable probe is `tests/opnsense_unbound_demo.py`. Against the test
firewall it verified this sequence:

1. Service health was `running`.
2. `codecheck.ashbyte.com` was absent.
3. Adding `10.111.1.1`, then reconfiguring, returned that A record from DNS.
4. Updating the same UUID to `10.211.1.1`, then reconfiguring, returned the
   updated A record.
5. Deleting the UUID and reconfiguring made the name return NXDOMAIN.

Using `127.255.255.255` and `127.255.254.254` was not a valid functional
test: despite successful API writes and read-back, DNS returned an unrelated
`0.0.0.17` result. Do not send `127.0.0.0/8` lease addresses to OPNsense
Unbound. The hook and manager reject loopback IPv4 addresses for add/update
events, while still allowing removal events to clear an existing ledger entry.

The firewall used in the experiment presented an untrusted self-signed TLS
chain. The probe supports `--insecure` for this manual diagnostic only. The
Zig manager intentionally verifies HTTPS against the host trust store. Zig
0.16's native verifier requires the configured API DNS hostname to appear as
a `DNS:` SAN; an `IP Address:` SAN alone is not sufficient. Install the
firewall CA before production use with the packaged helper:

```sh
sudo /usr/share/leaselinkd/trust-firewall-certificate.sh /path/to/firewall-ca.pem
sudo leaselinkd --api-test --loglevel DEBUG
```

The helper validates the PEM, installs it as an Arch trust anchor, rebuilds
the system trust store, and prints the certificate's SHA-256 fingerprint. Get
the CA through a trusted administrative channel and verify that fingerprint;
the helper intentionally does not fetch and automatically trust a certificate
from the network.
