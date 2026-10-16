#!/usr/bin/env python3
"""Actual generated routing + bundled Xray, loopback only; no TUN, routes or VPN credentials.

Verifies native-interface freedom sockets and a SOCKS VPN transport, including
TCP, UDP, IPv6, first-match country rules, FakeDNS, real-DNS inspection and restart.
"""
import argparse
from collections import defaultdict
import http.server
import ipaddress
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import struct
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def receive(sock, length):
    result = b""
    while len(result) < length:
        part = sock.recv(length - len(result))
        if not part:
            raise EOFError()
        result += part
    return result


def destination(sock):
    kind = receive(sock, 1)[0]
    if kind == 1:
        host = socket.inet_ntop(socket.AF_INET, receive(sock, 4))
    elif kind == 4:
        host = socket.inet_ntop(socket.AF_INET6, receive(sock, 16))
    elif kind == 3:
        host = receive(sock, receive(sock, 1)[0]).decode()
    else:
        raise ValueError("Invalid SOCKS address")
    return host, struct.unpack("!H", receive(sock, 2))[0]


def address(host, port):
    try:
        ip = ipaddress.ip_address(host)
        return bytes([1 if ip.version == 4 else 4]) + ip.packed + struct.pack("!H", port)
    except ValueError:
        encoded = host.encode()
        return bytes([3, len(encoded)]) + encoded + struct.pack("!H", port)


def socks(port, host, target_port, command=1):
    control = socket.create_connection(("127.0.0.1", port), timeout=3)
    control.sendall(b"\x05\x01\x00")
    assert receive(control, 2) == b"\x05\x00"
    control.sendall(bytes([5, command, 0]) + address(host, target_port))
    reply = receive(control, 3)
    if reply[1] != 0:
        control.close()
        raise OSError("SOCKS connection rejected")
    endpoint = destination(control)
    return control, endpoint


class ThreadServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def start(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def dns_answer(query):
    offset = 12
    while query[offset]:
        offset += 1 + query[offset]
    offset += 1
    qtype = struct.unpack("!H", query[offset:offset + 2])[0]
    question = query[12:offset + 4]
    answer = b""
    if qtype == 1:
        answer = b"\xc0\x0c\x00\x01\x00\x01" + struct.pack("!IH", 30, 4) + socket.inet_aton("127.0.0.1")
    return query[:2] + struct.pack("!HHHHH", 0x8180, 1, bool(answer), 0, 0) + question + answer


class DNS(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            while True:
                length = struct.unpack("!H", receive(self.request, 2))[0]
                answer = dns_answer(receive(self.request, length))
                self.request.sendall(struct.pack("!H", len(answer)) + answer)
        except (EOFError, OSError):
            pass


class HTTP(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"local-routing-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class HTTP6(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6


counts = {"tcp": defaultdict(int), "udp": defaultdict(int)}


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            header = receive(self.request, 2)
            receive(self.request, header[1]); self.request.sendall(b"\x05\x00")
            header = receive(self.request, 3)
            host, port = destination(self.request)
            if header[1] == 1:
                counts["tcp"][port] += 1
                if not host.replace(".", "").isdigit() and ":" not in host:
                    host = "127.0.0.1"
                with socket.create_connection((host, port), timeout=3) as remote:
                    self.request.sendall(b"\x05\x00\x00" + address("127.0.0.1", 1))
                    while True:
                        readable, _, _ = select.select([self.request, remote], [], [], 3)
                        if not readable:
                            return
                        for source in readable:
                            data = source.recv(65536)
                            if not data:
                                return
                            (remote if source is self.request else self.request).sendall(data)
            elif header[1] == 3:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                    udp.bind(("127.0.0.1", 0))
                    self.request.sendall(b"\x05\x00\x00" + address(*udp.getsockname()))
                    while True:
                        readable, _, _ = select.select([self.request, udp], [], [], 5)
                        if not readable or self.request in readable:
                            return
                        data, client = udp.recvfrom(65536)
                        host, port, payload = unpack_udp(data)
                        counts["udp"][port] += 1
                        if ":" not in host and not host.replace(".", "").isdigit():
                            host = "127.0.0.1"
                        with socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET, socket.SOCK_DGRAM) as remote:
                            remote.settimeout(2); remote.sendto(payload, (host, port))
                            response = remote.recv(65536)
                            udp.sendto(b"\x00\x00\x00" + address(host, port) + response, client)
        except (EOFError, OSError, ValueError):
            pass


def unpack_udp(data):
    import io
    class Reader(io.BytesIO):
        recv = io.BytesIO.read
    stream = Reader(data)
    assert receive(stream, 3) == b"\x00\x00\x00"
    host, port = destination(stream)
    return host, port, stream.read()


def udp_request(port, host, target_port, payload):
    control, endpoint = socks(port, "0.0.0.0", 0, 3)
    with control, socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        udp.settimeout(3)
        udp.sendto(b"\x00\x00\x00" + address(host, target_port) + payload, endpoint)
        return unpack_udp(udp.recv(65536))[2]


def http_request(port, host, target_port):
    control, _ = socks(port, host, target_port)
    with control:
        control.sendall(b"GET / HTTP/1.0\r\nHost: fixture.example\r\n\r\n")
        data = b""
        while True:
            part = control.recv(65536)
            if not part:
                break
            data += part
        assert b"local-routing-ok" in data, data[:100]


def dns_query(host):
    name = b"".join(bytes([len(label)]) + label.encode() for label in host.split(".")) + b"\x00"
    return b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + name + b"\x00\x01\x00\x01"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", type=Path, default=ROOT / "Runtime")
    runtime = parser.parse_args().runtime_root.resolve()
    binary = runtime / "xray/xray"
    dns = start(ThreadServer(("127.0.0.1", 0), DNS))
    relay = start(ThreadServer(("127.0.0.1", 0), Relay))
    web = start(http.server.ThreadingHTTPServer(("127.0.0.1", 0), HTTP))
    web6 = start(HTTP6(("::1", 0), HTTP))
    echo = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); echo.bind(("127.0.0.1", 0))
    def echoes():
        while True:
            data, client = echo.recvfrom(65536); echo.sendto(data, client)
    threading.Thread(target=echoes, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="tunneldeck-routing-") as temporary:
        temp = Path(temporary); os.chmod(temp, 0o700)
        fixture = temp / "routing-fixture"
        build = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip()
        objects = sorted((Path(build) / "TunnelCore.build").glob("*.swift.o"))
        assert objects, "Run swift build before routing_smoke.py"
        subprocess.run(["xcrun", "swiftc", "-I", str(Path(build) / "Modules"), str(Path(__file__).with_name("RoutingFixture.swift")),
                        *map(str, objects), "-o", str(fixture)], check=True, timeout=60)
        # Synthetic GeoIP covers only loopback; the production database is tested separately.
        cidr = b"\x0a\x04\x7f\x00\x00\x01\x10\x20"
        entry = b"\x0a\x02RU\x12" + bytes([len(cidr)]) + cidr
        (temp / "geoip.dat").write_bytes(b"\x0a" + bytes([len(entry)]) + entry)
        for mode, scenario in [("native", "country"), ("proxy", "country"), ("proxy", "default"), ("proxy", "direct-default")]:
            traffic, probe, real_dns, system_probe = free_port(), free_port(), free_port(), free_port()
            config_path = temp / f"{mode}-{scenario}.json"
            subprocess.run([str(fixture), str(config_path), str(traffic), str(probe), str(real_dns), str(relay.server_address[1]), mode, scenario, str(system_probe)], check=True)
            config = json.loads(config_path.read_text())
            for server in config["dns"]["servers"]:
                if server["address"].startswith("tcp://"):
                    server["address"] = f"tcp://127.0.0.1:{dns.server_address[1]}"
            next(item for item in config["outbounds"] if item["tag"] == "td-dns-out")["settings"]["port"] = dns.server_address[1]
            next(item for item in config["inbounds"] if item["tag"] == "td-system-probe")["settings"].update(address="127.0.0.1", port=web.server_port)
            config_path.write_text(json.dumps(config))
            env = dict(os.environ, XRAY_LOCATION_ASSET=str(temp), TUNNELDECK_FAKE_DNS_CACHE=str(temp / "fake"))
            checked = subprocess.run([str(binary), "run", "-test", "-config", str(config_path)], env=env, capture_output=True, text=True)
            assert checked.returncode == 0, checked.stdout + checked.stderr
            def launch():
                log = (temp / f"{mode}-{scenario}.log").open("ab")
                process = subprocess.Popen([str(binary), "run", "-config", str(config_path)], env=env, stdout=log, stderr=log)
                for _ in range(100):
                    assert process.poll() is None, "Router exited"
                    try:
                        with socket.create_connection(("127.0.0.1", traffic), timeout=.1):
                            return process, log
                    except OSError:
                        time.sleep(.05)
                raise AssertionError("Router did not start")
            process, log = launch()
            try:
                before = counts["tcp"][web.server_port]
                http_request(traffic, "vpn.example", web.server_port)
                if mode == "proxy":
                    assert counts["tcp"][web.server_port] > before, "VPN rule bypassed selected proxy"
                before = counts["tcp"][web.server_port]
                http_request(traffic, "direct.example", web.server_port)
                assert counts["tcp"][web.server_port] == before, "Direct rule used VPN proxy"
                http_request(traffic, "::1", web6.server_port)
                before = counts["tcp"][web.server_port]
                http_request(traffic, "country.example", web.server_port)
                assert (counts["tcp"][web.server_port] == before) == (scenario in ("country", "direct-default") or mode == "native"), "Country/default precedence mismatch"
                try:
                    http_request(traffic, "blocked.example", web.server_port)
                    raise AssertionError("Blocked domain passed")
                except (EOFError, OSError, AssertionError) as error:
                    assert str(error) != "Blocked domain passed"
                payload = b"routing-udp-fixture"
                udp_before = counts["udp"][echo.getsockname()[1]]
                assert udp_request(traffic, "direct.example", echo.getsockname()[1], payload) == payload
                assert counts["udp"][echo.getsockname()[1]] == udp_before, "Direct UDP used VPN proxy"
                assert udp_request(traffic, "vpn.example", echo.getsockname()[1], payload) == payload
                if mode == "proxy":
                    assert counts["udp"][echo.getsockname()[1]] > udp_before, "VPN UDP bypassed selected proxy"
                query = dns_query("vpn.example")
                answer = udp_request(traffic, "198.18.0.2", 53, query)
                fake_ip = socket.inet_ntoa(answer[-4:])
                assert ipaddress.ip_address(fake_ip) in ipaddress.ip_network("198.19.0.0/16"), fake_ip
                http_request(traffic, fake_ip, web.server_port)
                # Browsers use FakeDNS identities, including for country rules.
                # A domain-only SOCKS request does not exercise this recovery path.
                country_answer = udp_request(traffic, "198.18.0.2", 53, dns_query("country.example"))
                country_fake = socket.inet_ntoa(country_answer[-4:])
                before = counts["tcp"][web.server_port]
                http_request(traffic, country_fake, web.server_port)
                assert (counts["tcp"][web.server_port] == before) == (scenario in ("country", "direct-default") or mode == "native"), "FakeDNS country/default precedence mismatch"
                with socket.create_connection(("127.0.0.1", real_dns), timeout=3) as client:
                    client.sendall(struct.pack("!H", len(query)) + query)
                    answer = receive(client, struct.unpack("!H", receive(client, 2))[0])
                    assert socket.inet_ntoa(answer[-4:]) == "127.0.0.1", "Real DNS inspector returned a fake IP"
                before = counts["tcp"][web.server_port]
                http_request(probe, "direct.example", web.server_port)
                if mode == "proxy":
                    assert counts["tcp"][web.server_port] > before, "Diagnostic probe was diverted by a direct rule"
                before = counts["tcp"][web.server_port]
                http_request(traffic, "198.18.0.3", 443)
                if mode == "proxy":
                    assert counts["tcp"][web.server_port] > before, "System-path diagnostic was diverted by user rules"
                process.terminate(); process.wait(timeout=10); log.close()
                process, log = launch()
                http_request(traffic, fake_ip, web.server_port)
                print(f"PASS {mode}/{scenario}: TCP, UDP, IPv6, block, DNS, forced VPN probe, cached FakeDNS after restart")
            finally:
                process.terminate(); process.wait(timeout=10); log.close()
    for server in (dns, relay, web, web6):
        server.shutdown(); server.server_close()
    print("Routing smoke passed; no system routes, DNS settings or external VPN sessions were changed.")


if __name__ == "__main__":
    main()
