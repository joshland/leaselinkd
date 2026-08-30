#!/usr/bin/env bash
# Install an OPNsense firewall CA certificate into Arch Linux's system trust store.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: trust-firewall-certificate.sh FIREWALL_CA_PEM [ANCHOR_NAME]

Validate and install FIREWALL_CA_PEM as a system trust anchor, then rebuild
the Arch Linux trust store. ANCHOR_NAME defaults to opnsense-firewall-ca.crt.

Obtain the CA certificate through a trusted administrative channel and verify
the SHA-256 fingerprint printed by this script before relying on it.
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# -lt 1 || $# -gt 2 ]]; then
    usage >&2
    exit 64
fi
if [[ $EUID -ne 0 ]]; then
    printf '%s\n' 'Run this script as root (for example, with sudo).' >&2
    exit 1
fi

certificate=$1
anchor_name=${2:-opnsense-firewall-ca.crt}
if [[ ! -f $certificate ]]; then
    printf 'Certificate file not found: %s\n' "$certificate" >&2
    exit 1
fi
if [[ $anchor_name == */* || $anchor_name != *.crt ]]; then
    printf '%s\n' 'ANCHOR_NAME must be a filename ending in .crt.' >&2
    exit 64
fi

for command in awk openssl update-ca-trust install; do
    command -v "$command" >/dev/null || {
        printf 'Required command not found: %s\n' "$command" >&2
        exit 1
    }
done

openssl x509 -in "$certificate" -noout >/dev/null
if ! openssl x509 -in "$certificate" -noout -text | awk '
    /X509v3 Basic Constraints: critical/ { critical = 1; next }
    critical && /CA:TRUE/ { valid = 1 }
    END { exit !valid }
'; then
    printf '%s\n' 'Refusing to trust this certificate: it is not a CA with a critical Basic Constraints extension.' >&2
    printf '%s\n' 'Generate a standards-compliant firewall CA and sign a server certificate with it.' >&2
    exit 1
fi
anchor=/etc/ca-certificates/trust-source/anchors/$anchor_name
install -Dm644 "$certificate" "$anchor"
update-ca-trust extract

printf 'Installed trust anchor: %s\n' "$anchor"
openssl x509 -in "$anchor" -noout -subject -issuer -fingerprint -sha256
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt "$anchor"
printf '%s\n' 'Trust store updated. Re-run leaselinkd --api-test to verify OPNsense TLS.'
