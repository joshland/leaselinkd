#!/usr/bin/env python3
"""DNS-aware, bounded-state lease/metrics torture harness.

The harness owns a real leaselinkd process and a local mock OPNsense API.  It
submits concurrent lease bursts, scrapes metrics, watches manager output for
fatal conditions, and retains the same memory evidence as memory_soak.sh.

Examples:
  python3 tests/torture_test.py --manager zig-out/bin/leaselinkd \
    --dns-server 10.0.0.1 --domain lab.example \
    --dns-host printer=10.0.0.20 --fail-host torturefail0=10.250.0.1
"""
import argparse
import concurrent.futures
import csv
import http.client
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time


FAILURE_PATTERNS = (
    "[ERROR] lease event failed:",
    "[ERROR] persisting lease intent failed:",
    "[WARN] durable lease work failed:",
    "[WARN] OPNsense health check failed:",
    "OutOfMemory",
)
HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


def fail(message):
    raise RuntimeError(message)


def parse_host_ip(value):
    try:
        host, address = value.split("=", 1)
        if not HOST_RE.fullmatch(host):
            raise ValueError("host label must be 1-63 letters, digits, or hyphens")
        socket.inet_aton(address)
    except (ValueError, OSError) as error:
        raise argparse.ArgumentTypeError(f"expected LABEL=IPv4: {error}") from error
    return host, address


def parse_dns_server(value):
    host, separator, port = value.rpartition(":")
    if not separator:
        host, port = value, "53"
    try:
        socket.inet_aton(host)
        parsed_port = int(port)
        if not 1 <= parsed_port <= 65535:
            raise ValueError("port out of range")
    except (ValueError, OSError) as error:
        raise argparse.ArgumentTypeError(f"expected IPv4[:port]: {error}") from error
    return host, parsed_port


def dns_query(server, fqdn, timeout):
    query_id = int(time.monotonic_ns() & 0xFFFF)
    question = b"".join(bytes((len(label),)) + label.encode("ascii") for label in fqdn.rstrip(".").split(".")) + b"\0\0\1\0\1"
    query = struct.pack("!HHHHHH", query_id, 0x0100, 1, 0, 0, 0) + question
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(timeout)
        client.sendto(query, server)
        response, _ = client.recvfrom(2048)
    if len(response) < 12:
        fail(f"DNS response for {fqdn} is truncated")
    response_id, flags, questions, answers, _, _ = struct.unpack("!HHHHHH", response[:12])
    if response_id != query_id:
        fail(f"DNS response ID mismatch for {fqdn}")
    offset = 12

    def skip_name(index):
        while True:
            if index >= len(response):
                fail(f"DNS name is truncated for {fqdn}")
            length = response[index]
            if length & 0xC0 == 0xC0:
                return index + 2
            index += 1
            if length == 0:
                return index
            index += length

    for _ in range(questions):
        offset = skip_name(offset) + 4
    addresses = []
    for _ in range(answers):
        offset = skip_name(offset)
        if offset + 10 > len(response):
            fail(f"DNS answer is truncated for {fqdn}")
        record_type, record_class, _, length = struct.unpack("!HHIH", response[offset:offset + 10])
        offset += 10
        if offset + length > len(response):
            fail(f"DNS RDATA is truncated for {fqdn}")
        if record_type == 1 and record_class == 1 and length == 4:
            addresses.append(socket.inet_ntoa(response[offset:offset + 4]))
        offset += length
    return flags & 0xF, addresses


def validate_dns(args, output):
    checks = []
    for host, expected in args.dns_host:
        rcode, addresses = dns_query(args.dns_server, f"{host}.{args.domain}", args.dns_timeout)
        if rcode != 0 or expected not in addresses:
            fail(f"DNS startup validation failed for {host}.{args.domain}: rcode={rcode}, addresses={addresses}, expected={expected}")
        checks.append((host, expected, rcode, " ".join(addresses), "match"))
    fail_host, fail_ip = args.fail_host
    rcode, addresses = dns_query(args.dns_server, f"{fail_host}.{args.domain}", args.dns_timeout)
    if rcode == 0 and fail_ip in addresses:
        fail(f"DNS fail record {fail_host}.{args.domain} unexpectedly resolves to {fail_ip}")
    checks.append((fail_host, fail_ip, rcode, " ".join(addresses), "mismatch"))
    for index in range(args.force_hosts):
        host = f"{args.force_prefix}{index}"
        rcode, addresses = dns_query(args.dns_server, f"{host}.{args.domain}", args.dns_timeout)
        if rcode == 0 and fail_ip in addresses:
            fail(f"DNS force host {host}.{args.domain} unexpectedly resolves to {fail_ip}")
        checks.append((host, fail_ip, rcode, " ".join(addresses), "force-mismatch"))
    with (output / "dns-startup.csv").open("w", newline="", encoding="utf-8") as file:
        writer = csv.writer(file)
        writer.writerow(("hostname", "expected_ip", "rcode", "addresses", "expectation"))
        writer.writerows(checks)


class Harness:
    def __init__(self, args, output):
        self.args, self.output = args, output
        self.manager = None
        self.mock = None
        self.manager_pid = None
        self.port = None
        self.metrics_port = reserve_port()
        self.failures = []
        self.failure_lock = threading.Lock()
        self.stop_watcher = threading.Event()

    def start(self):
        port_file = self.output / "opnsense.port"
        self.mock = subprocess.Popen([sys.executable, "tests/mock_opnsense.py", str(port_file), str(self.output / "opnsense.log")], stdout=(self.output / "mock.log").open("w"), stderr=subprocess.STDOUT)
        wait_for(lambda: port_file.exists(), "mock OPNsense port file")
        self.port = port_file.read_text(encoding="utf-8").strip()
        config = {
            "opnsense_url": f"http://127.0.0.1:{self.port}/api/unbound",
            "db_path": str(self.output / "ledger.sqlite"),
            "socket_path": str(self.output / "unbound.sock"),
            "metrics_port": self.metrics_port,
            "dns_servers": [f"{self.args.dns_server[0]}:{self.args.dns_server[1]}"],
            "domain": self.args.domain,
            "throttle_seconds": self.args.throttle_seconds,
            "health_check_seconds": self.args.health_seconds,
            "reconcile_seconds": self.args.reconcile_seconds,
        }
        (self.output / "config.json").write_text(json.dumps(config), encoding="utf-8")
        (self.output / "secrets.json").write_text('{"api_key":"key","api_secret":"secret"}', encoding="utf-8")
        manager_log = (self.output / "manager.log").open("w", encoding="utf-8")
        self.manager = subprocess.Popen([self.args.manager, "--config", str(self.output / "config.json"), "--secret", str(self.output / "secrets.json"), "--loglevel", "TRACE"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        self.manager_pid = self.manager.pid
        self.watcher = threading.Thread(target=self.watch_manager, args=(manager_log,), daemon=True)
        self.watcher.start()
        wait_for(lambda: (self.output / "unbound.sock").exists(), "manager Unix socket")
        wait_for(lambda: self.metrics(), "metrics endpoint")

    def watch_manager(self, log):
        for line in self.manager.stdout:
            log.write(line)
            log.flush()
            if any(pattern in line for pattern in FAILURE_PATTERNS):
                with self.failure_lock:
                    self.failures.append(line.rstrip())
            if self.stop_watcher.is_set():
                break

    def metrics(self):
        try:
            client = http.client.HTTPConnection("127.0.0.1", self.metrics_port, timeout=3)
            client.request("GET", "/metrics")
            response = client.getresponse()
            body = response.read()
            client.close()
            if response.status != 200 or b"leaselinkd_process_resident_memory_bytes" not in body:
                return False
            return body
        except OSError:
            return False

    def submit(self, round_number, index):
        if self.args.dns_host and index % self.args.good_every == 0:
            host, address = self.args.dns_host[index % len(self.args.dns_host)]
        else:
            host = f"{self.args.force_prefix}{index % self.args.force_hosts}"
            address = self.args.fail_host[1]
        body = json.dumps({"event": "lease4_committed", "timestamp": 0, "lease": {"hostname": host, "ip-address": address, "mac-address": f"02:00:{round_number & 255:02x}:{index >> 8:02x}:{index & 255:02x}:01"}}, separators=(",", ":")).encode()
        request = b"POST /lease_event HTTP/1.1\r\nHost: localhost\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(self.args.request_timeout)
            client.connect(str(self.output / "unbound.sock"))
            client.sendall(request)
            return client.recv(64).split(b"\r\n", 1)[0]

    def burst(self, round_number):
        started = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.args.lease_workers) as pool:
            replies = list(pool.map(lambda index: self.submit(round_number, index), range(self.args.batch_size)))
        accepted = sum(reply.startswith(b"HTTP/1.1 202") for reply in replies)
        return accepted, int((time.monotonic() - started) * 1000)

    def sample(self, index, elapsed, metric_body):
        worker = child_pid(self.manager_pid)
        row = [int(time.time()), round(elapsed, 3), index, status_field(self.manager_pid, "VmRSS"), status_field(self.manager_pid, "VmSize"), smaps_rollup(self.manager_pid, "Pss"), smaps_rollup(self.manager_pid, "Private_Dirty"), fd_count(self.manager_pid), status_field(self.manager_pid, "Threads"), worker or 0, status_field(worker, "VmRSS") if worker else 0, status_field(worker, "VmSize") if worker else 0, fd_count(worker) if worker else 0, status_field(worker, "Threads") if worker else 0, file_size(self.output / "ledger.sqlite"), file_size(self.output / "ledger.sqlite-wal")]
        with (self.output / "samples.csv").open("a", newline="", encoding="utf-8") as file:
            csv.writer(file).writerow(row)
        (self.output / f"metrics-{index}.prom").write_bytes(metric_body)
        if index % self.args.map_every == 0:
            capture_process(self.manager_pid, "manager", index, self.output)
            if worker:
                capture_process(worker, "worker", index, self.output)
        os.kill(self.manager_pid, signal.SIGUSR1)

    def assert_healthy(self):
        if self.manager.poll() is not None:
            fail(f"manager exited with status {self.manager.returncode}")
        with self.failure_lock:
            if self.failures:
                fail("manager failure gate: " + self.failures[0])

    def stop(self):
        self.stop_watcher.set()
        for process in (self.manager, self.mock):
            if process and process.poll() is None:
                process.terminate()
        for process in (self.manager, self.mock):
            if process:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()


def reserve_port():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(predicate, description, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    fail(f"timed out waiting for {description}")


def status_field(pid, key):
    if not pid:
        return 0
    try:
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith(key + ":"):
                return int(line.split()[1])
    except FileNotFoundError:
        pass
    return 0


def smaps_rollup(pid, key):
    if not pid:
        return 0
    try:
        for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
            if line.startswith(key + ":"):
                return int(line.split()[1])
    except FileNotFoundError:
        pass
    return 0


def child_pid(pid):
    try:
        children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        return int(children[0]) if children else None
    except FileNotFoundError:
        return None


def fd_count(pid):
    try:
        return len(list(Path(f"/proc/{pid}/fd").iterdir()))
    except (FileNotFoundError, TypeError):
        return 0


def file_size(path):
    try:
        return path.stat().st_size
    except FileNotFoundError:
        return 0


def capture_process(pid, name, index, output):
    for command, suffix in ((["pmap", "-x", str(pid)], "pmap"), (["lsof", "-nP", "-p", str(pid)], "lsof")):
        with (output / f"{suffix}-{name}-{index}.txt").open("w", encoding="utf-8") as file:
            subprocess.run(command, stdout=file, stderr=subprocess.STDOUT, check=False)
    try:
        (output / f"smaps-{name}-{index}.txt").write_text(Path(f"/proc/{pid}/smaps").read_text())
    except FileNotFoundError:
        pass


def api_writes(log):
    try:
        return sum(1 for line in log.read_text(encoding="utf-8").splitlines() if "POST /api/unbound/settings/" in line)
    except FileNotFoundError:
        return 0


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manager", required=True, help="leaselinkd binary to execute")
    parser.add_argument("--dns-server", required=True, type=parse_dns_server, help="internal IPv4 DNS server, optionally with :port")
    parser.add_argument("--domain", required=True, help="DNS domain appended to lease labels")
    parser.add_argument("--dns-host", action="append", default=[], type=parse_host_ip, help="known matching DNS LABEL=IPv4; repeatable")
    parser.add_argument("--fail-host", required=True, type=parse_host_ip, help="DNS LABEL=IPv4 which must be missing or mismatched")
    parser.add_argument("--duration", type=float, default=600, help="test runtime in seconds (default: 600)")
    parser.add_argument("--batch-size", type=int, default=512, help="lease requests per round (default: 512)")
    parser.add_argument("--lease-workers", type=int, default=128, help="concurrent lease submitters (default: 128)")
    parser.add_argument("--force-prefix", default="torturefail", help="bounded host-label prefix which must not resolve to the fail IP")
    parser.add_argument("--force-hosts", type=int, default=512, help="number of fixed force-update host labels (default: 512)")
    parser.add_argument("--good-every", type=int, default=8, help="use a known matching DNS host every N requests (default: 8)")
    parser.add_argument("--submit-sleep", type=float, default=1, help="sleep after every burst (default: 1)")
    parser.add_argument("--metrics-sleep", type=float, default=.5, help="sleep after each metrics scrape (default: .5)")
    parser.add_argument("--health-seconds", type=int, default=5)
    parser.add_argument("--reconcile-seconds", type=int, default=300)
    parser.add_argument("--throttle-seconds", type=int, default=1)
    parser.add_argument("--dns-timeout", type=float, default=2)
    parser.add_argument("--request-timeout", type=float, default=10)
    parser.add_argument("--map-every", type=int, default=10, help="capture pmap/smaps/lsof every N rounds (default: 10)")
    parser.add_argument("--output", type=Path, default=None, help="evidence directory; default is a fresh /tmp directory")
    args = parser.parse_args()
    if min(args.duration, args.batch_size, args.lease_workers, args.force_hosts, args.good_every, args.map_every) <= 0:
        parser.error("duration, batch size, workers, force hosts, good interval, and map interval must be positive")
    if not HOST_RE.fullmatch(args.force_prefix) or len(f"{args.force_prefix}{args.force_hosts - 1}") > 63:
        parser.error("force prefix and count must create valid host labels of at most 63 characters")
    return args


def main():
    args = parse_args()
    output = args.output or Path(tempfile.mkdtemp(prefix="leaselinkd-torture-"))
    output.mkdir(parents=True, exist_ok=True)
    (output / "run.txt").write_text("\n".join(f"{key}={value}" for key, value in sorted(vars(args).items()) if key != "output") + "\n", encoding="utf-8")
    print(f"evidence directory: {output}", flush=True)
    validate_dns(args, output)
    harness = Harness(args, output)
    with (output / "samples.csv").open("w", newline="", encoding="utf-8") as file:
        csv.writer(file).writerow(("epoch", "elapsed_s", "round", "manager_rss_kib", "manager_vmsize_kib", "manager_pss_kib", "manager_private_dirty_kib", "manager_fds", "manager_threads", "worker_pid", "worker_rss_kib", "worker_vmsize_kib", "worker_fds", "worker_threads", "ledger_bytes", "wal_bytes"))
    try:
        harness.start()
        started, round_number = time.monotonic(), 0
        while time.monotonic() - started < args.duration:
            accepted, elapsed_ms = harness.burst(round_number)
            if accepted != args.batch_size:
                fail(f"round {round_number}: accepted {accepted}/{args.batch_size} lease requests")
            print(f"round={round_number} lease_requests={accepted}/{args.batch_size} elapsed_ms={elapsed_ms}", flush=True)
            time.sleep(args.submit_sleep)
            metric_body = harness.metrics()
            if not metric_body:
                fail(f"round {round_number}: metrics endpoint failed")
            print(f"round={round_number} metrics=status:200 bytes={len(metric_body)}", flush=True)
            harness.sample(round_number, time.monotonic() - started, metric_body)
            harness.assert_healthy()
            round_number += 1
            time.sleep(args.metrics_sleep)
        final_metrics = harness.metrics()
        if not final_metrics:
            fail("final metrics endpoint scrape failed")
        harness.sample(round_number, time.monotonic() - started, final_metrics)
        harness.assert_healthy()
        subprocess.run(["sqlite3", str(output / "ledger.sqlite"), ".dump"], stdout=(output / "ledger.sql").open("w"), check=True)
        writes = api_writes(output / "opnsense.log")
        if writes == 0:
            fail("mock OPNsense received no host-override writes; force-update path was not exercised")
        (output / "summary.txt").write_text(f"rounds={round_number}\napi_host_override_writes={writes}\n", encoding="utf-8")
        print(f"complete rounds={round_number} api_host_override_writes={writes}", flush=True)
    finally:
        harness.stop()
        print(f"evidence retained at {output}", file=sys.stderr, flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"torture test failed: {error}", file=sys.stderr)
        sys.exit(1)
