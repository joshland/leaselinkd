#!/usr/bin/env python3
"""Validate the Kea DHCPv4 settings required by kea-leaselink.

Usage: check-kea-config.py [KEA_DHCP4_JSON]
Default: /etc/kea/kea-dhcp4.conf
"""
import json
import sys

PATH = sys.argv[1] if len(sys.argv) == 2 else "/etc/kea/kea-dhcp4.conf"
if len(sys.argv) > 2:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)

try:
    with open(PATH, encoding="utf-8") as source:
        root = json.load(source)
except (OSError, json.JSONDecodeError) as error:
    print(f"FAIL: cannot read valid JSON from {PATH}: {error}", file=sys.stderr)
    sys.exit(2)

dhcp4 = root.get("Dhcp4")
if not isinstance(dhcp4, dict):
    print("FAIL: top-level Dhcp4 object is missing")
    sys.exit(1)

failures = 0
def check(condition, message):
    global failures
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures += 1

for key in ("ddns-send-updates", "ddns-override-client-update", "ddns-override-no-update"):
    check(dhcp4.get(key) is True, f"{key} is true")
check(dhcp4.get("hostname-char-set") == "[^A-Za-z0-9.-]", "hostname-char-set permits letters, digits, dots, and hyphens")

hooks = dhcp4.get("hook-libraries", [])
if not isinstance(hooks, list):
    hooks = []
matches = [hook for hook in hooks if isinstance(hook, dict) and hook.get("library") == "/usr/lib/kea/hooks/libdhcp_run_script.so"]
check(len(matches) == 1, "exactly one libdhcp_run_script.so hook is configured")
if matches:
    params = matches[0].get("parameters")
    check(isinstance(params, dict), "run-script hook has a parameters object")
    if isinstance(params, dict):
        check(params.get("name") == "/usr/share/kea/scripts/kea-leaselink", "run-script hook name is /usr/share/kea/scripts/kea-leaselink")
        check(params.get("sync") is False, "run-script hook sync is false")

print("Hook captures: KEA_LEASE4_ADDRESS, KEA_LEASE4_HWADDR, KEA_LEASE4_HOSTNAME, KEA_LEASE4_VALID_LIFETIME, KEA_LEASE4_SUBNET_ID, KEA_QUERY4_INTERFACE.")
print(f"Summary: {failures} failure(s).")
sys.exit(1 if failures else 0)
