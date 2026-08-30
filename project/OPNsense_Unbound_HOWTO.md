# Connect `leaselinkd` to OPNsense

This is the shortest safe path to connect the DHCP host to an OPNsense
firewall. It creates a dedicated least-privilege API account, transfers only
its generated API key and secret, establishes TLS trust, and verifies the
connection.

## 1. Provision the firewall API account

Copy the packaged
[`provision-opnsense-leaselinkd.php`](../packaging/provision-opnsense-leaselinkd.php)
to the firewall through a trusted administrator session, then run it as root:

```sh
sudo scp /usr/share/leaselinkd/provision-opnsense-leaselinkd.php root@FIREWALL:/root/
ssh root@FIREWALL 'php /root/provision-opnsense-leaselinkd.php'
```

On its first run it creates:

- group `unbound_api` — **Unbound API Access**;
- user `leaselinkd` — **LeaseLink**;
- the requested health, Unbound, Unbound DNS, override, and system-status
  privileges; and
- a randomly generated password and API key/secret.

Subsequent runs are idempotent: they report the existing group, required
privileges, user, API-key count, membership, and selected Web GUI certificate.
They never rotate an existing password or API secret. The script also audits
the selected certificate for validity, `CA:FALSE`, server-auth usage, a DNS
SAN, and a chain to its configured CA; it exits nonzero if that TLS audit
fails. Generated credentials are written once to
`/root/leaselinkd-bootstrap.json` with mode `0600`; they are not printed.
Copy them securely to the DHCP host and remove the firewall copy immediately:

```sh
scp root@FIREWALL:/root/leaselinkd-bootstrap.json /secure/path/
ssh root@FIREWALL 'rm /root/leaselinkd-bootstrap.json /root/provision-opnsense-leaselinkd.php'
```

OPNsense stores only a hash of the API secret, so this bootstrap file is the
only recovery opportunity. If it is lost, delete the API key in OPNsense and
provision a new account.

## 2. Establish TLS trust on the DHCP host

Export the firewall CA certificate through a trusted administrative channel, or
fetch it without trusting it using the installed helper. Verify its fingerprint,
then install it:

```sh
sudo /usr/share/leaselinkd/fetch-firewall-certificate.sh /secure/path/firewall-ca.pem
sudo /usr/share/leaselinkd/trust-firewall-certificate.sh /secure/path/firewall-ca.pem
```

The fetch helper reads `opnsense_url` from
`/etc/leaselinkd/config.json`, connects to that HTTPS host and port, writes
an actually presented CA certificate with mode `0600`, and prints its SHA-256
fingerprint. It does **not** change the trust store. TLS servers commonly omit
their root CA from the presented chain; in that case the helper stops without
writing a file and you must export the issuing CA through **System → Trust**.
Compare the fingerprint with one obtained from a trusted firewall-administration
channel before running the trust helper.

The CA must have a **critical** `Basic Constraints: CA:TRUE` extension. The
existing `x762-it` self-signed certificate does not meet that requirement, so
strict TLS clients reject it even when it is installed locally. Create a new
internal CA under **System → Trust → Authorities**, create a **Server
Certificate** from that CA under **System → Trust → Certificates** with the
firewall's DNS name as a `DNS:` SAN, and select that server certificate under
**System → Settings → Administration → Web GUI → SSL Certificate**. An IP SAN
alone is insufficient for Zig 0.16's native TLS verifier. Ensure the DHCP host
can resolve that DNS name to the firewall, then fetch and install the new CA
certificate before running the API test.

If the manager configuration is not present yet, specify the endpoint
explicitly:

```sh
sudo /usr/share/leaselinkd/fetch-firewall-certificate.sh \
  --host 10.76.2.5 --port 8443 /secure/path/firewall-ca.pem
```

Validate the firewall's **currently presented Web GUI certificate** before
attempting any API call. This makes a read-only TLS connection and checks the
certificate dates, IP/DNS identity, server extensions, and chain against the
system trust store:

```sh
sudo /usr/share/leaselinkd/check-firewall-certificate.sh \
  --host 10.76.2.5 --port 8443
```

To prove that the currently selected Web GUI certificate was signed by one
specific CA before it is installed system-wide, pass the exported CA PEM:

```sh
sudo /usr/share/leaselinkd/check-firewall-certificate.sh \
  --host 10.76.2.5 --port 8443 --ca-file /secure/path/firewall-ca.pem
```

Do not continue to the API test until this reports zero failures. In
particular, a self-issued Web GUI certificate is not the same thing as a
separate server certificate signed by the installed CA.

## 3. Configure the manager

Create `/etc/leaselinkd/secrets.json` from the API values in the bootstrap
file; it must contain only these two fields:

```json
{
  "api_key": "…",
  "api_secret": "…"
}
```

Set the firewall URL in `/etc/leaselinkd/config.json` to the DNS name present
in the server certificate's `DNS:` SAN. Include the HTTPS port when it is
non-default and include `/api/unbound` exactly once:

```json
{
  "opnsense_url": "https://fw0.ashbyte.com:8443/api/unbound",
  "domain": "ashbyte.com"
}
```

Keep the remaining installed configuration fields unchanged unless you have a
specific operational need to alter them.

## 4. Verify and start

```sh
sudo leaselinkd --config-check
sudo leaselinkd --api-test --loglevel DEBUG
sudo systemctl enable --now leaselinkd.service
```

`--api-test` performs `GET /service/status` and deliberately calls
`POST /service/reconfigure`, so run it only when applying Unbound is safe.
