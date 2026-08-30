#!/usr/bin/env python3
"""Verify the OPNsense Web GUI certificate before running leaselinkd.

This makes a TLS connection only: it does not authenticate, call the API, or
modify firewall configuration.  With no --ca-file it uses the operating
system trust store, exactly as the production Zig client does.
"""
import argparse
import socket
import ssl
import sys
from urllib.parse import urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://10.76.2.5:8443", help="firewall HTTPS URL")
    parser.add_argument("--ca-file", help="optional PEM CA file, for testing before system installation")
    args = parser.parse_args()

    parsed = urlparse(args.url)
    if parsed.scheme != "https" or not parsed.hostname:
        parser.error("--url must be an https URL with a host")
    port = parsed.port or 443
    context = ssl.create_default_context(cafile=args.ca_file)
    try:
        with socket.create_connection((parsed.hostname, port), timeout=10) as tcp:
            with context.wrap_socket(tcp, server_hostname=parsed.hostname) as tls:
                peer = tls.getpeercert()
                subject = ", ".join("=".join(part) for group in peer.get("subject", ()) for part in group)
                issuer = ", ".join("=".join(part) for group in peer.get("issuer", ()) for part in group)
                sans = ", ".join(f"{kind}:{value}" for kind, value in peer.get("subjectAltName", ()))
                print(f"TLS verification passed for {parsed.hostname}:{port}")
                print(f"subject: {subject}")
                print(f"issuer: {issuer}")
                print(f"SAN: {sans or 'none'}")
                print(f"protocol: {tls.version()}; cipher: {tls.cipher()[0]}")
    except (OSError, ssl.SSLError) as error:
        print(f"TLS verification failed for {parsed.hostname}:{port}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
