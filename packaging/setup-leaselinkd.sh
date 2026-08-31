#!/usr/bin/env bash
# Interactive, idempotent first-run assistant.  It deliberately uses no
# firewall API until the operator has installed a least-privilege API key.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: setup-leaselinkd.sh --firewall HOST --domain DOMAIN [options]

Prepare a leaselinkd node from an ordinary login.  Privileged local actions
prompt through sudo.  Initial firewall provisioning uses the Web UI or the
firewall-side PHP script over SSH; this program makes no API request until it
has installed the generated credentials.

Options:
  --firewall HOST          DNS name in the firewall Web GUI certificate SAN.
  --domain DOMAIN          DNS suffix for Kea host overrides.
  --port PORT              Web GUI HTTPS port (default: 443).
  --firewall-user USER     SSH user for optional transfer (default: root).
  --transfer-provisioner   Copy and run the PHP provisioner through SSH.
  --bootstrap FILE         Credential JSON copied from the firewall.
  --skip-bootstrap         Configure TLS only; do not enable the service.
  -h, --help               Show this help.

The fallback Web UI path is described in OPNsense_Manual_Provisioning.md.
EOF
}

firewall='' domain='' port=443 firewall_user=root transfer=0 bootstrap='' skip_bootstrap=0
while (($#)); do
    case "$1" in
        --firewall) firewall=${2:?missing value}; shift 2 ;;
        --domain) domain=${2:?missing value}; shift 2 ;;
        --port) port=${2:?missing value}; shift 2 ;;
        --firewall-user) firewall_user=${2:?missing value}; shift 2 ;;
        --transfer-provisioner) transfer=1; shift ;;
        --bootstrap) bootstrap=${2:?missing value}; shift 2 ;;
        --skip-bootstrap) skip_bootstrap=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 64 ;;
    esac
done
[[ -n $firewall && -n $domain ]] || { usage >&2; exit 64; }
[[ $port =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || { printf '%s\n' 'Invalid --port.' >&2; exit 64; }
[[ $firewall != *'/'* && $firewall != *:* ]] || { printf '%s\n' '--firewall must be a DNS hostname, not an IP address or URL.' >&2; exit 64; }
[[ $domain =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$|^[A-Za-z0-9]$ ]] || { printf '%s\n' 'Invalid --domain.' >&2; exit 64; }

share_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for command in openssl python3 sudo; do command -v "$command" >/dev/null || { printf 'Missing required command: %s\n' "$command" >&2; exit 1; }; done
printf 'Open the firewall Web UI at https://%s:%s/ and complete the least-privilege setup if SSH provisioning is not used.\n' "$firewall" "$port"
printf 'Send this PHP script to the firewall and run it as root when permitted:\n  scp %q %q@%q:/root/\n  ssh %q@%q %q\n' "$share_dir/provision-opnsense-leaselinkd.php" "$firewall_user" "$firewall" "$firewall_user" "$firewall" 'php /root/provision-opnsense-leaselinkd.php'
if ((transfer)); then
    command -v scp >/dev/null && command -v ssh >/dev/null || { printf '%s\n' 'scp and ssh are required for --transfer-provisioner.' >&2; exit 1; }
    scp "$share_dir/provision-opnsense-leaselinkd.php" "${firewall_user}@${firewall}:/root/provision-opnsense-leaselinkd.php"
    ssh "${firewall_user}@${firewall}" 'php /root/provision-opnsense-leaselinkd.php'
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ca="$work/firewall-ca.pem"
"$share_dir/fetch-firewall-certificate.sh" --host "$firewall" --port "$port" "$ca"
printf '\nVerify this CA fingerprint against the Web UI or another trusted channel before approving the sudo prompt.\n'
read -r -p 'Fingerprint verified? [y/N] ' answer
[[ $answer == y || $answer == Y ]] || { printf '%s\n' 'TLS trust was not changed.' >&2; exit 1; }
sudo "$share_dir/trust-firewall-certificate.sh" "$ca"
sudo "$share_dir/check-firewall-certificate.sh" --host "$firewall" --port "$port"

url="https://${firewall}"
((port == 443)) || url+=":${port}"
url+='/api/unbound'
sudo python3 - "$url" "$domain" <<'PY'
import json, os, sys, tempfile
path = "/etc/leaselinkd/config.json"
with open(path, encoding="utf-8") as stream: config = json.load(stream)
config["opnsense_url"], config["domain"] = sys.argv[1:]
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".config.")
with os.fdopen(fd, "w", encoding="utf-8") as stream: json.dump(config, stream, indent=2); stream.write("\n")
os.chmod(temporary, 0o640); os.replace(temporary, path)
PY
sudo systemd-tmpfiles --create /usr/lib/tmpfiles.d/leaselinkd.conf
if ((skip_bootstrap)); then
    printf 'TLS and configuration are ready. Copy /root/leaselinkd-bootstrap.json securely, then re-run with --bootstrap FILE.\n'
    exit 0
fi
[[ -n $bootstrap && -r $bootstrap ]] || { printf '%s\n' 'Pass --bootstrap FILE after the firewall creates its one-time credential file.' >&2; exit 1; }
sudo python3 - "$bootstrap" <<'PY'
import json, os, sys, tempfile
with open(sys.argv[1], encoding="utf-8") as stream: source = json.load(stream)
result = {key: source[key] for key in ("api_key", "api_secret")}
if not all(isinstance(value, str) and value for value in result.values()): raise SystemExit("bootstrap file has no usable API credentials")
path = "/etc/leaselinkd/secrets.json"; fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".secrets.")
with os.fdopen(fd, "w", encoding="utf-8") as stream: json.dump(result, stream, indent=2); stream.write("\n")
os.chmod(temporary, 0o600); os.replace(temporary, path)
PY
sudo leaselinkd --config-check
sudo leaselinkd --api-test
sudo systemctl enable --now leaselinkd.service
sudo /usr/share/leaselinkd/keadb-leaselinkd-sync
printf 'Setup complete. The Kea bootstrap import is one-shot; normal hooks now maintain records. Remove the transferred bootstrap file from both systems.\n'
