# Manually provision OPNsense for `leaselinkd`

Use this procedure when the automated OPNsense provisioning script is not
appropriate. It creates a dedicated least-privilege API identity for
`leaselinkd`; do not use an administrator API key.

## Prerequisites

- Administrator access to the OPNsense WebGUI.
- The OPNsense HTTPS address and port reachable from the DHCP host.
- A secure way to transfer the generated API key and secret to the DHCP host.
- The firewall CA certificate available through a trusted administrative
  channel when the WebGUI uses a private or self-signed certificate.

## 1. Create the API group

Open **System → Access → Groups**, add a group, and save it with:

| Field | Value |
| --- | --- |
| Group Name | `unbound_api` |
| Description | `Unbound API Access` |

Assign exactly these privileges:

- `Diagnostics: System Health`
- `Services: Unbound`
- `Services: Unbound DNS: Access Lists`
- `Services: Unbound DNS: Advanced`
- `Services: Unbound DNS: Edit Host and Domain Override`
- `Services: Unbound DNS: General`
- `System: Status`

The `Services: Unbound` privilege allows the manager to call the health and
reconfigure endpoints. The host/domain override privilege allows its add,
update, lookup, and delete operations.

## 2. Create the API user

Open **System → Access → Users**, add a user, and save it with:

| Field | Value |
| --- | --- |
| Username | `leaselinkd` |
| Full Name | `LeaseLink` |
| Password | Generate a long random password and save it in the approved secret store. |
| Group membership | `unbound_api` |
| Login shell | Leave at the default/no-shell value unless interactive firewall login is deliberately required. |

Do not give this user **All pages**, administrator membership, a shell, SSH
access, or unrelated configuration privileges.

## 3. Generate and capture the API key

While editing the `leaselinkd` user, use the **API Keys** section to add a
key. OPNsense displays or downloads the API key and secret only when the key
is created. Store both values immediately in a secure secret manager.

Copy the values to the DHCP host as `/etc/leaselinkd/secrets.json`:

```json
{
  "api_key": "OPNSENSE_API_KEY",
  "api_secret": "OPNSENSE_API_SECRET"
}
```

The secret file is root-readable only; do not put either value in
`config.json`, service logs, a shell history, or source control. If the API
secret is lost, revoke the key in OPNsense and create a replacement rather
than attempting to recover it.

## 4. Trust the firewall certificate

`leaselinkd` verifies the firewall's HTTPS certificate. If the firewall uses
a private or self-signed CA, fetch the presented CA without trusting it,
verify its fingerprint, and then install it on the DHCP host:

```sh
sudo /usr/share/leaselinkd/fetch-firewall-certificate.sh /secure/path/firewall-ca.pem
sudo /usr/share/leaselinkd/trust-firewall-certificate.sh /secure/path/firewall-ca.pem
```

If the fetch helper reports that no CA was presented, export the issuing CA
from **System → Trust** instead. TLS servers normally do not send root CA
certificates in their handshake.

Do not disable TLS verification for the manager.

The CA must have a **critical** `Basic Constraints: CA:TRUE` extension.
Otherwise strict TLS clients reject it even after installation. If the fetch
helper reports this warning, create a new internal CA in **System → Trust →
Authorities**, issue a **Server Certificate** for the firewall in **System →
Trust → Certificates** (including the firewall DNS name and/or IP as a SAN),
and select it in **System → Settings → Administration → Web GUI → SSL
Certificate** before fetching the replacement CA.

## 5. Configure and verify the manager

Set the manager URL in `/etc/leaselinkd/config.json`, including the
`/api/unbound` suffix exactly once:

```json
{
  "opnsense_url": "https://FIREWALL:PORT/api/unbound",
  "domain": "YOUR_DNS_DOMAIN"
}
```

Then validate the local configuration and remote API access:

```sh
sudo leaselinkd --config-check
sudo leaselinkd --api-test --loglevel DEBUG
```

`--api-test` performs a health check and calls Unbound reconfigure. A
successful run confirms certificate trust, HTTP Basic authentication, the API
URL, required privileges, and the manager's ability to apply Unbound changes.

## Required API operations

The configured identity must be able to perform these operations relative to
the configured `opnsense_url`:

| Operation | Method and path |
| --- | --- |
| Health check | `GET /service/status` |
| Find override | `GET /settings/search_host_override` |
| Add override | `POST /settings/add_host_override` |
| Update override | `POST /settings/set_host_override/<uuid>` |
| Delete override | `POST /settings/del_host_override/<uuid>` |
| Apply changes | `POST /service/reconfigure` |

For the complete request/response contract, see
[OPNsense Unbound API](./OPNsense_Unbound.md).
