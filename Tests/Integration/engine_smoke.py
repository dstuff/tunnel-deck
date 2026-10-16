#!/usr/bin/env python3
"""Unprivileged engine checks: no external server credentials or route changes."""
import base64
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import tempfile
import threading
import uuid

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "Runtime"


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True,
                          timeout=20, **kwargs)


def main():
    global RUNTIME
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime-root", type=Path, default=RUNTIME)
    RUNTIME = parser.parse_args().runtime_root.resolve()
    with tempfile.TemporaryDirectory(prefix="tunneldeck-engines-") as directory:
        temp = Path(directory)
        os.chmod(temp, 0o700)
        cert, key = temp / "cert.pem", temp / "key.pem"
        result = run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048",
                      "-nodes", "-keyout", key, "-out", cert, "-days", "1",
                      "-subj", "/CN=localhost"])
        assert result.returncode == 0, "Local TLS fixture certificate generation failed"
        targets = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                targets.append(self.path)
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, *_):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        public_key = run(["/usr/bin/openssl", "x509", "-in", cert, "-pubkey", "-noout"])
        spki = subprocess.run(["/usr/bin/openssl", "pkey", "-pubin", "-outform", "DER"],
                              input=public_key.stdout.encode(), capture_output=True, timeout=10)
        assert spki.returncode == 0, "Could not calculate local TLS public-key pin"
        pin = "pin-sha256:" + base64.b64encode(hashlib.sha256(spki.stdout).digest()).decode()
        oc_config = temp / "openconnect.conf"
        oc_config.write_text("protocol=anyconnect\nnon-inter\nno-proxy\n"
                             f"server=https://localhost:{server.server_port}/?fixture%2Fsecret\n")
        try:
            # Spaces and a clean environment expose dependencies on the build
            # directory, Homebrew, DYLD_* or the invoking shell's PATH.
            relocated = temp / "Moved TunnelDeck Runtime"
            (relocated / "bin").mkdir(parents=True)
            (relocated / "openconnect").mkdir()
            oc = relocated / "bin/openconnect"
            shutil.copy2(RUNTIME / "bin/openconnect", oc)
            shutil.copy2(RUNTIME / "openconnect/vpnc-script", relocated / "openconnect/vpnc-script")
            env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C", "HOME": str(temp)}
            version = run([oc, "--version"], env=env, cwd=temp)
            assert version.returncode == 0 and "OpenSSL 3.6.2" in version.stdout, version.stderr
            result = run([oc, "--config", oc_config, "--cookieonly", "--no-passwd"], env=env, cwd=temp)
            assert result.returncode != 0 and not targets, "Untrusted local TLS certificate was accepted"
            for trust in [["--servercert", pin], ["--cafile", cert]]:
                targets.clear()
                result = run([oc, "--config", oc_config, "--cookieonly", "--no-passwd", *trust], env=env, cwd=temp)
                assert targets and targets[0] == "/?fixture%2Fsecret", f"Initial camouflage URL changed: {targets}; {result.stderr}"
                assert result.returncode != 0, "Fixture intentionally rejects authentication"
            targets.clear()
            wrong_pin = "pin-sha256:" + base64.b64encode(bytes(32)).decode()
            result = run([oc, "--config", oc_config, "--cookieonly", "--no-passwd", "--servercert", wrong_pin], env=env, cwd=temp)
            assert result.returncode != 0 and not targets, "Wrong server pin was accepted"
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
        print("PASS OpenConnect: relocated binary, clean PATH, TLS trust/pin rejection and acceptance, exact camouflage POST; no login or tunnel")

        test_key = base64.b64encode(bytes([7]) * 32).decode()
        awg_config = temp / "awg.conf"
        awg_config.write_text(f"""[Interface]
PrivateKey = {test_key}
HeaderProtectionKey = {test_key}
S1 = 12
S2 = 13
S3 = 14
S4 = 15
ContentPaddingAddition = 32-128
RekeyAfterTime = 100-130
I1 = <r 10>
I3 = <rc 20>
[Peer]
PublicKey = {test_key}
Endpoint = 127.0.0.1:51820
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 22-30
""")
        # setconf parses the whole file before attempting IPC. This random,
        # nonexistent interface makes it stop before it can modify a device.
        interface = "tdcheck" + uuid.uuid4().hex[:8]
        result = run([RUNTIME / "bin/awg", "setconf", interface, awg_config])
        assert result.returncode != 0 and "No such file or directory" in result.stderr, result.stderr
        assert "Line unrecognized" not in result.stderr, result.stderr
        print("PASS AWG 3.1: official parser accepts header protection, ranges and I1/I3")

        xray_config = temp / "xray.json"
        xray_fixture = {"log": {"loglevel": "warning"}, "inbounds": [],
            "outbounds": [{"protocol": "vless", "tag": "proxy", "settings": {
                "vnext": [{"address": "192.0.2.5", "port": 443, "users": [{
                    "id": "28e21f5c-8e82-44a4-bb91-89e412af903b", "encryption": "none",
                    "flow": "xtls-rprx-vision"}]}]}, "streamSettings": {
                "network": "raw", "security": "reality", "realitySettings": {
                    "serverName": "cover.example", "fingerprint": "chrome",
                    "publicKey": "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE", "shortId": "abcd"}}}]}
        for fingerprint in ["chrome", "tunneldeck_safari15_5"]:
            xray_fixture["outbounds"][0]["streamSettings"]["realitySettings"]["fingerprint"] = fingerprint
            xray_config.write_text(json.dumps(xray_fixture))
            result = run([RUNTIME / "xray/xray", "run", "-test", "-config", xray_config])
            assert result.returncode == 0, result.stderr + result.stdout
        print("PASS Xray: bundled engine accepts VLESS/REALITY with standard and TunnelDeck TLS profiles")


if __name__ == "__main__":
    main()
