#!/usr/bin/env bash
# Fetch, but never trust, the CA certificate presented by the configured firewall.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: fetch-firewall-certificate.sh [--host HOST] [--port PORT] OUTPUT_PEM

Fetch the certificate chain from an OPNsense HTTPS endpoint, select its last
CA certificate (or its sole certificate), and write it to OUTPUT_PEM with mode
0600. HOST and PORT default to the opnsense_url in /etc/leaselinkd/config.json.

This script does not install or trust the fetched certificate. Verify the
printed SHA-256 fingerprint through a trusted channel before passing OUTPUT_PEM
to trust-firewall-certificate.sh.
EOF
}

host=''
port=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --host) host=${2:?--host requires a value}; shift 2 ;;
        --port) port=${2:?--port requires a value}; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; break ;;
        -*) usage >&2; exit 64 ;;
        *) break ;;
    esac
done
if [[ $# -ne 1 ]]; then
    usage >&2
    exit 64
fi
output=$1
if [[ -e $output ]]; then
    printf 'Refusing to overwrite existing output: %s\n' "$output" >&2
    exit 1
fi
if [[ -z $host ]]; then
    config=/etc/leaselinkd/config.json
    [[ -r $config ]] || { printf 'Cannot read %s; provide --host and --port.\n' "$config" >&2; exit 1; }
    url=$(sed -n 's/.*"opnsense_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n 1)
    [[ $url == https://* ]] || { printf 'opnsense_url must be an HTTPS URL.\n' >&2; exit 1; }
    authority=${url#https://}
    authority=${authority%%/*}
    if [[ $authority == \[* ]]; then
        host=${authority%%\]*}
        host=${host#[}
        remainder=${authority#*]}
        [[ $remainder == :* ]] && port=${remainder#:}
    elif [[ $authority == *:* ]]; then
        host=${authority%:*}
        port=${authority##*:}
    else
        host=$authority
    fi
fi
port=${port:-443}
[[ $port =~ ^[0-9]{1,5}$ ]] && (( port >= 1 && port <= 65535 )) || { printf 'Invalid port: %s\n' "$port" >&2; exit 64; }

for command in awk install openssl; do
    command -v "$command" >/dev/null || { printf 'Required command not found: %s\n' "$command" >&2; exit 1; }
done

temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
connect_host=$host
[[ $host == *:* ]] && connect_host="[$host]"
# s_client may return nonzero for the expected untrusted chain; extraction below
# is the authoritative success check.
openssl s_client -connect "${connect_host}:${port}" -servername "$host" -showcerts </dev/null >"$temporary/chain.pem" 2>"$temporary/openssl.log" || true
awk -v dir="$temporary" '
    /-----BEGIN CERTIFICATE-----/ { number++; file = dir "/cert." number ".pem"; in_certificate = 1 }
    in_certificate { print > file }
    /-----END CERTIFICATE-----/ { close(file); in_certificate = 0 }
' "$temporary/chain.pem"

shopt -s nullglob
certificates=("$temporary"/cert.*.pem)
(( ${#certificates[@]} > 0 )) || { printf 'No certificate was returned by %s:%s.\n' "$host" "$port" >&2; exit 1; }
selected=''
for certificate in "${certificates[@]}"; do
    if openssl x509 -in "$certificate" -noout -text | grep -q 'CA:TRUE'; then
        selected=$certificate
    fi
done
if [[ -z $selected ]]; then
    printf 'No CA certificate was presented by %s:%s.\n' "$host" "$port" >&2
    printf '%s\n' 'The firewall is presenting only its server certificate; export the issuing CA through System > Trust instead.' >&2
    exit 1
fi

install -Dm600 "$selected" "$output"
printf 'Fetched certificate from %s:%s into %s\n' "$host" "$port" "$output"
openssl x509 -in "$output" -noout -subject -issuer -fingerprint -sha256
if ! openssl x509 -in "$output" -noout -text | awk '
    /X509v3 Basic Constraints: critical/ { critical = 1; next }
    critical && /CA:TRUE/ { valid = 1 }
    END { exit !valid }
'; then
    printf '%s\n' 'WARNING: this CA certificate does not have a critical Basic Constraints extension.' >&2
    printf '%s\n' 'Strict TLS clients will reject it; do not install it as a trust anchor.' >&2
fi
printf '%s\n' 'Verify this fingerprint out of band, then install it with trust-firewall-certificate.sh.'
