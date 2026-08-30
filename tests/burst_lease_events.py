#!/usr/bin/env python3
"""Submit a concurrent burst of lease events to a manager Unix socket.

Usage: burst_lease_events.py SOCKET COUNT [PREFIX]
Prints accepted/rejected counts and exits nonzero unless every submission is
accepted. Designed for 256, 512, and double-512 queue/backpressure tests.
"""
import concurrent.futures
import socket
import sys
import time

path, count = sys.argv[1], int(sys.argv[2])
prefix = sys.argv[3] if len(sys.argv) > 3 else "burst"

def submit(index):
    body = ('{"event":"lease4_committed","timestamp":0,"lease":'
            '{"hostname":"%s%d","ip-address":"10.200.%d.%d",'
            '"mac-address":"00:11:22:33:%02x:%02x"}}' %
            (prefix, index, (index // 254) % 254 + 1, index % 254 + 1, index // 256, index % 256)).encode()
    request = b"POST /lease_event HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(10)
        client.connect(path)
        client.sendall(request)
        return client.recv(64).split(b"\r\n", 1)[0]

started = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=min(count, 128)) as pool:
    replies = list(pool.map(submit, range(count)))
accepted = sum(reply.startswith(b"HTTP/1.1 202") for reply in replies)
print("submitted=%d accepted=%d rejected=%d elapsed_ms=%d" % (count, accepted, count - accepted, (time.monotonic() - started) * 1000))
sys.exit(0 if accepted == count else 1)
