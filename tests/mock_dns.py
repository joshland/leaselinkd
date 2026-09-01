#!/usr/bin/env python3
"""Minimal UDP DNS fixture for the burst test.

It records every query and returns NXDOMAIN. This forces leaselinkd to apply
each lease through the mock OPNsense API while exercising its native resolver.
"""
import socket
import sys


port_file, log_file = sys.argv[1:]
server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.bind(("127.0.0.1", 0))
with open(port_file, "w", encoding="utf-8") as out:
    out.write(str(server.getsockname()[1]))

while True:
    query, peer = server.recvfrom(2048)
    qdcount = int.from_bytes(query[4:6], "big") if len(query) >= 6 else -1
    with open(log_file, "a", encoding="utf-8") as out:
        out.write(f"query bytes={len(query)} qdcount={qdcount}\n")
    if len(query) < 12:
        continue
    reply = bytearray(query)
    reply[2] = (reply[2] & 0x7f) | 0x80  # QR=1
    reply[3] = (reply[3] & 0xf0) | 3  # NXDOMAIN
    reply[6:12] = b"\0" * 6  # no answers, authority, or additional records
    server.sendto(reply, peer)
