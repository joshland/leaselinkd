#!/usr/bin/env bash
# Diagnose TLS prerequisites for leaselinkd's OPNsense HTTPS connection.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: check-firewall-certificate.sh --host HOST [--port PORT] [--ca-file PEM]

Connect read-only to an OPNsense Web GUI, inspect its presented leaf
certificate, and verify it against a trust bundle or a specific issuing CA.
The default CA file is Arch Linux's system trust bundle.

Examples:
  check-firewall-certificate.sh --host 10.76.2.5 --port 8443
  check-firewall-certificate.sh --host 10.76.2.5 --port 8443 \
    --ca-file /etc/ca-certificates/trust-source/anchors/opnsense-firewall-ca.crt
EOF
}

host=''
port=443
ca_file=/etc/ssl/certs/ca-certificates.crt
while (($#)); do
    case "$1" in
        --host) host=${2:?missing host}; shift 2 ;;
        --port) port=${2:?missing port}; shift 2 ;;
        --ca-file) ca_file=${2:?missing CA file}; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z $host ]]; then
    printf '%s\n' '--host is required.' >&2
    usage >&2
    exit 2
fi
if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
    printf '%s\n' '--port must be between 1 and 65535.' >&2
    exit 2
fi
if [[ ! -r $ca_file ]]; then
    printf 'Cannot read CA file: %s\n' "$ca_file" >&2
    exit 2
fi
for command in awk openssl mktemp; do
    command -v "$command" >/dev/null || { printf 'Missing required command: %s\n' "$command" >&2; exit 2; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
chain=$work/chain.pem
leaf=$work/leaf.pem
log=$work/openssl.log

# s_client commonly exits nonzero for an untrusted chain. The diagnostic below
# deliberately evaluates that condition rather than treating it as a fetch error.
openssl s_client -connect "${host}:${port}" -servername "$host" -showcerts </dev/null >"$chain" 2>"$log" || true
awk '
    /-----BEGIN CERTIFICATE-----/ { capture=1 }
    capture { print }
    /-----END CERTIFICATE-----/ { exit }
' "$chain" >"$leaf"
if ! openssl x509 -in "$leaf" -noout >/dev/null 2>&1; then
    printf 'FAIL: %s:%s did not present a readable TLS certificate.\n' "$host" "$port" >&2
    sed -n '1,12p' "$log" >&2
    exit 1
fi

failures=0
warnings=0
fail() { printf 'FAIL: %s\n' "$*"; failures=$((failures + 1)); }
warn() { printf 'WARN: %s\n' "$*"; warnings=$((warnings + 1)); }
pass() { printf 'PASS: %s\n' "$*"; }

printf 'Firewall TLS diagnostic for %s:%s\n' "$host" "$port"
printf 'Trust source: %s\n' "$ca_file"
openssl x509 -in "$leaf" -noout -subject -issuer -serial -dates -fingerprint -sha256

if openssl x509 -in "$leaf" -noout -checkend 0 >/dev/null; then
    pass 'leaf certificate is currently within its validity period'
else
    fail 'leaf certificate is expired or not yet valid'
fi

if [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    verify_name=(-verify_ip "$host")
    expected_san="IP Address:${host}"
else
    verify_name=(-verify_hostname "$host")
    expected_san="DNS:${host}"
fi
if openssl verify -purpose sslserver -CAfile "$ca_file" "${verify_name[@]}" "$leaf" >"$work/verify.out" 2>&1; then
    pass "certificate chains to the selected trust source and identifies ${expected_san}"
else
    fail "certificate does not chain to the selected trust source and identify ${expected_san}"
    sed 's/^/  openssl: /' "$work/verify.out"
    printf '%s\n' '  Install the issuing CA, or select a Web GUI server certificate signed by that CA.'
fi

subject=$(openssl x509 -in "$leaf" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
issuer=$(openssl x509 -in "$leaf" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')
if [[ $subject == "$issuer" ]]; then
    warn 'the Web GUI certificate is self-issued; this only works when this exact certificate is explicitly trusted'
fi

details=$(openssl x509 -in "$leaf" -noout -text)
if grep -q 'CA:TRUE' <<<"$details"; then
    fail 'Web GUI certificate has CA:TRUE; issue a separate server certificate with CA:FALSE'
elif grep -q 'Basic Constraints:' <<<"$details"; then
    pass 'leaf Basic Constraints does not grant CA authority'
else
    warn 'leaf lacks a Basic Constraints extension (a server certificate should state CA:FALSE)'
fi
if grep -q 'TLS Web Server Authentication' <<<"$details"; then
    pass 'leaf Extended Key Usage permits TLS Web Server Authentication'
else
    warn 'leaf lacks a TLS Web Server Authentication extended-key-usage extension'
fi
if grep -q 'Digital Signature' <<<"$details"; then
    pass 'leaf Key Usage includes Digital Signature'
else
    warn 'leaf Key Usage does not include Digital Signature'
fi

# Zig 0.16's native certificate verifier currently compares only dNSName SAN
# entries. It does not match iPAddress SANs and does not fall back to the CN
# whenever any SAN extension exists. Treat this as a manager compatibility
# requirement even though OpenSSL and Python can verify an IP SAN correctly.
if [[ $host =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    fail 'leaselinkd cannot use an IP-address API URL with Zig 0.16 TLS; use a DNS hostname with a matching DNS SAN'
else
    if grep -Fq "DNS:${host}" <<<"$details"; then
        pass "leaf has the DNS SAN required by Zig TLS: DNS:${host}"
    else
        fail "leaf lacks the DNS SAN required by Zig TLS: DNS:${host}"
    fi
fi

printf 'Summary: %d failure(s), %d warning(s).\n' "$failures" "$warnings"
((failures == 0))
