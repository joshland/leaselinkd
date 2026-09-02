#!/usr/bin/env python3
"""Validate the Kea DHCPv4 and kea-leaselink hook configuration.

Usage: check-kea-config.py [KEA_DHCP4_JSON [HOOK_JSON]]
Defaults: /etc/kea/kea-dhcp4.conf and /etc/leaselinkd/hook.json
"""
import json
import os
import sys
from pathlib import Path
from urllib.parse import urlparse

DEFAULT_KEA_CONFIG = Path("/etc/kea/kea-dhcp4.conf")
DEFAULT_HOOK_CONFIG = Path("/etc/leaselinkd/hook.json")
HOOK_EXECUTABLE = Path("/usr/share/kea/scripts/kea-leaselink")
LOG_LEVELS = {"ERROR", "WARN", "INFO", "DEBUG", "TRACE"}
failures = 0


def usage() -> None:
    print(__doc__.strip(), file=sys.stderr)


def load_json(path: Path) -> object:
    try:
        with path.open(encoding="utf-8") as source:
            return json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        print(f"FAIL: cannot read valid JSON from {path}: {error}", file=sys.stderr)
        raise SystemExit(2) from error


def check(condition: bool, message: str) -> None:
    global failures
    print(("PASS: " if condition else "FAIL: ") + message)
    if not condition:
        failures += 1


def valid_manager_address(value: object) -> bool:
    if not isinstance(value, str) or not value:
        return False
    parsed = urlparse(value)
    if parsed.scheme == "unix":
        return parsed.path.startswith("/")
    if parsed.scheme != "tcp" or not parsed.hostname:
        return False
    try:
        return parsed.port is not None and 1 <= parsed.port <= 65535
    except ValueError:
        return False


def main() -> int:
    if len(sys.argv) > 3:
        usage()
        return 2

    kea_path = Path(sys.argv[1]) if len(sys.argv) >= 2 else DEFAULT_KEA_CONFIG
    hook_path = Path(sys.argv[2]) if len(sys.argv) == 3 else DEFAULT_HOOK_CONFIG
    root = load_json(kea_path)
    hook_config = load_json(hook_path)

    check(isinstance(root, dict), f"{kea_path} has a top-level JSON object")
    dhcp4 = root.get("Dhcp4") if isinstance(root, dict) else None
    check(isinstance(dhcp4, dict), "top-level Dhcp4 object is present")
    if not isinstance(dhcp4, dict):
        print(f"Summary: {failures} failure(s).")
        return 1

    for key in ("ddns-send-updates", "ddns-override-client-update", "ddns-override-no-update"):
        check(dhcp4.get(key) is True, f"{key} is true")
    check(dhcp4.get("hostname-char-set") == "[^A-Za-z0-9.-]", "hostname-char-set permits letters, digits, dots, and hyphens")

    hooks = dhcp4.get("hooks-libraries")
    check(isinstance(hooks, list), "hooks-libraries is an array")
    matches = [
        hook for hook in hooks
        if isinstance(hook, dict) and hook.get("library") == "/usr/lib/kea/hooks/libdhcp_run_script.so"
    ] if isinstance(hooks, list) else []
    check(len(matches) == 1, "exactly one libdhcp_run_script.so hook is configured")
    if matches:
        params = matches[0].get("parameters")
        check(isinstance(params, dict), "run-script hook has a parameters object")
        if isinstance(params, dict):
            check(params.get("name") == str(HOOK_EXECUTABLE), f"run-script parameters.name is {HOOK_EXECUTABLE}")
            check(params.get("sync") is False, "run-script hook sync is false")

    check(HOOK_EXECUTABLE.is_file(), f"hook executable exists at {HOOK_EXECUTABLE}")
    check(os.access(HOOK_EXECUTABLE, os.X_OK), "hook executable is executable")

    check(isinstance(hook_config, dict), f"{hook_path} has a top-level JSON object")
    if isinstance(hook_config, dict):
        address = hook_config.get("leaselinkd_address")
        timeout = hook_config.get("timeout_seconds")
        loglevel = hook_config.get("loglevel")
        check(valid_manager_address(address), "hook leaselinkd_address is unix:///absolute/path or tcp://host:port")
        check(isinstance(timeout, int) and not isinstance(timeout, bool) and 1 <= timeout <= 3600, "hook timeout_seconds is an integer from 1 to 3600")
        check(isinstance(loglevel, str) and loglevel in LOG_LEVELS, "hook loglevel is ERROR, WARN, INFO, or DEBUG")

    print("Hook captures: LEASE4_ADDRESS, LEASE4_HWADDR, LEASE4_HOSTNAME, LEASE4_VALID_LIFETIME, LEASE4_SUBNET_ID, QUERY4_IFACE_NAME.")
    print(f"Summary: {failures} failure(s).")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
