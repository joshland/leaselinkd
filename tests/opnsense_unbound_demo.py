#!/usr/bin/env python3
"""Exercise the OPNsense Unbound host-override flow used by leaselinkd.

The script is deliberately dependency-free.  It uses the same API paths and
JSON shape as src/leaselinkd/main.zig and sends direct UDP DNS requests to
confirm that reconfigure has made each mutation live.
"""
import argparse
import base64
import json
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.request


HOSTNAME = "codecheck"
DOMAIN = "ashbyte.com"
FIRST_IP = "10.111.1.1"
SECOND_IP = "10.211.1.1"


class CheckFailed(RuntimeError):
    pass


def credentials(path):
    values = {}
    with open(path, encoding="utf-8") as source:
        for line in source:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, separator, value = line.partition("=")
            if not separator:
                raise CheckFailed(f"invalid credentials line in {path!r}")
            values[key.strip()] = value.strip()
    if not values.get("key") or not values.get("secret"):
        raise CheckFailed("credentials file must contain key= and secret= lines")
    return values["key"], values["secret"]


class OpnSense:
    def __init__(self, base_url, key, secret, insecure):
        self.base_url = base_url.rstrip("/") + "/api/unbound"
        token = base64.b64encode(f"{key}:{secret}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Accept": "application/json"}
        self.context = ssl._create_unverified_context() if insecure else None

    def request(self, method, endpoint, body=None):
        data = None if body is None else json.dumps(body).encode()
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + endpoint, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=10) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")
            raise CheckFailed(f"{method} {endpoint}: HTTP {exc.code}: {detail}") from exc
        except urllib.error.URLError as exc:
            raise CheckFailed(f"{method} {endpoint}: {exc.reason}") from exc
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError as exc:
            raise CheckFailed(f"{method} {endpoint}: invalid JSON response: {raw!r}") from exc


def find_override(api, hostname, domain):
    """Return the UUID of an exact override, if search_host_override exposes it."""
    response = api.request("GET", "/settings/search_host_override")
    stack = [response]
    while stack:
        value = stack.pop()
        if isinstance(value, dict):
            if value.get("hostname") == hostname and value.get("domain") == domain:
                uuid = value.get("uuid")
                if uuid:
                    return uuid
            stack.extend(value.values())
        elif isinstance(value, list):
            stack.extend(value)
    return None


def _skip_dns_name(message, offset):
    while True:
        if offset >= len(message):
            raise CheckFailed("malformed DNS name")
        length = message[offset]
        if length & 0xC0 == 0xC0:
            return offset + 2
        offset += 1
        if length == 0:
            return offset
        offset += length


def dns_answer(server, name, expected=None, require_absent=False):
    wire_name = b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\0"
    query_id = 0xC0DE
    packet = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + wire_name + struct.pack("!HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(10)
        udp.sendto(packet, (server, 53))
        response, _ = udp.recvfrom(4096)
    if len(response) < 12:
        raise CheckFailed("DNS response was truncated")
    returned_id, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", response[:12])
    if returned_id != query_id or questions != 1:
        raise CheckFailed("DNS response did not match query")
    rcode = flags & 0x0F
    offset = _skip_dns_name(response, 12) + 4  # question type and class
    addresses = []
    for _ in range(answers):
        offset = _skip_dns_name(response, offset)
        if offset + 10 > len(response):
            raise CheckFailed("malformed DNS answer")
        record_type, record_class, _, data_len = struct.unpack("!HHIH", response[offset:offset + 10])
        offset += 10
        if offset + data_len > len(response):
            raise CheckFailed("truncated DNS answer data")
        if record_type == 1 and record_class == 1 and data_len == 4:
            addresses.append(socket.inet_ntoa(response[offset:offset + 4]))
        offset += data_len
    if require_absent:
        if expected not in addresses:
            return f"override absent (rcode={rcode}, A={addresses or 'none'})"
        raise CheckFailed(f"DNS still contains the deleted A record {expected} for {name}: {addresses}")
    if rcode != 0 and expected not in addresses:
        raise CheckFailed(f"DNS returned rcode={rcode} for {name}")
    if expected not in addresses:
        raise CheckFailed(f"DNS did not contain expected A record {expected} for {name}; received {addresses or 'no A records'} (rcode={rcode})")
    return expected


def wait_for_dns(server, name, expected=None, require_absent=False):
    last_error = None
    for _ in range(12):
        try:
            return dns_answer(server, name, expected, require_absent)
        except (CheckFailed, socket.timeout, OSError) as exc:
            last_error = exc
            time.sleep(1)
    raise CheckFailed(f"DNS did not converge: {last_error}")


def apply_unbound(api, action):
    api.request("POST", f"/service/{action}", {})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://10.76.2.5:8443", help="OPNsense base URL")
    parser.add_argument("--dns-server", default="10.76.2.5", help="DNS server queried on UDP port 53")
    parser.add_argument("--credentials", default="fw0.x762.erickson.lol_api_kea_apikey.txt")
    parser.add_argument("--insecure", action="store_true", help="do not verify the HTTPS certificate")
    parser.add_argument("--service-action", choices=("reconfigure", "restart"), default="reconfigure",
                        help="apply Unbound changes (default: reconfigure, as used by leaselinkd)")
    args = parser.parse_args()

    key, secret = credentials(args.credentials)
    api = OpnSense(args.url, key, secret, args.insecure)
    fqdn = f"{HOSTNAME}.{DOMAIN}"
    applied = "reconfigured" if args.service_action == "reconfigure" else "restarted"
    created_uuid = None
    try:
        print("1. health check:", json.dumps(api.request("GET", "/service/status"), sort_keys=True))
        existing = find_override(api, HOSTNAME, DOMAIN)
        print("2. existing demo override:", "present" if existing else "absent")
        if existing:
            raise CheckFailed(f"refusing to alter pre-existing {fqdn} override ({existing})")

        body = {"host": {"enabled": "1", "hostname": HOSTNAME, "domain": DOMAIN, "rr": "A", "server": FIRST_IP}}
        reply = api.request("POST", "/settings/add_host_override", body)
        created_uuid = reply.get("uuid")
        if not created_uuid:
            raise CheckFailed(f"add_host_override returned no uuid: {reply}")
        print("3. created demo override:", created_uuid, json.dumps(reply, sort_keys=True))
        stored = api.request("GET", f"/settings/get_host_override/{created_uuid}")
        print("   API read-back:", json.dumps(stored, sort_keys=True))
        apply_unbound(api, args.service_action)
        print(f"4. Unbound {applied}")
        print("5. DNS A record:", wait_for_dns(args.dns_server, fqdn, FIRST_IP))

        body["host"]["server"] = SECOND_IP
        update_reply = api.request("POST", f"/settings/set_host_override/{created_uuid}", body)
        stored = api.request("GET", f"/settings/get_host_override/{created_uuid}")
        print("6. updated demo override:", SECOND_IP, json.dumps(update_reply, sort_keys=True))
        print("   API read-back:", json.dumps(stored, sort_keys=True))
        apply_unbound(api, args.service_action)
        print(f"   Unbound {applied}; DNS A record:", wait_for_dns(args.dns_server, fqdn, SECOND_IP))

        api.request("POST", f"/settings/del_host_override/{created_uuid}", {})
        created_uuid = None
        print("7. deleted demo override")
        apply_unbound(api, args.service_action)
        print(f"   Unbound {applied}")
        if find_override(api, HOSTNAME, DOMAIN):
            raise CheckFailed("deleted override is still present in the OPNsense configuration")
        print("8. DNS record:", wait_for_dns(args.dns_server, fqdn, SECOND_IP, require_absent=True))
    finally:
        if created_uuid:
            print("cleanup: deleting created override after failure", file=sys.stderr)
            try:
                api.request("POST", f"/settings/del_host_override/{created_uuid}", {})
                apply_unbound(api, args.service_action)
            except CheckFailed as cleanup_error:
                print(f"cleanup failed: {cleanup_error}", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (CheckFailed, socket.timeout, OSError) as error:
        print(f"FAILED: {error}", file=sys.stderr)
        sys.exit(1)
