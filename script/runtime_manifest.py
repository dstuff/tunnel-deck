#!/usr/bin/env python3
"""Verify pinned release inputs, or record final source/bundle engine hashes."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
release_inputs = {
    "bin/openconnect": "a111ab17121c5ed7b4a08cadb8c680e6dbe004ef131a2ce124aa405cd3656d21",
    "xray/xray": "55141dd823f4410df6e763e70310fb830f59b1982a335e4e0c1a8ecf4661c317",
    "bin/hev-socks5-tunnel": "c72e2d99b698542105e10777a5105a60bb04f4d80bfbf95f20f3365cb77e5d47",
    "licenses/HevSocks5Tunnel-LICENSE": "3cca1a91ca82e9b9c41852945ef15858f932828ceeb765b86bc1fe3f39127514",
    "openconnect/vpnc-script": "f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742",
    "licenses/OpenConnect-COPYING.LGPL": "dc626520dcd53a22f727af3ee42c770e56c97a64fe3adb063799d8ab032fe551",
    "licenses/OpenSSL-LICENSE.txt": "7d5450cb2d142651b8afa315b5f238efc805dad827d91ba367d8516bc9d49e7a",
}
if len(sys.argv) > 2:
    if sys.argv[2:] != ["--verify-pins"]:
        raise SystemExit("usage: runtime_manifest.py ROOT [--verify-pins]")
    for path, expected in release_inputs.items():
        actual = hashlib.sha256((root / path).read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(f"Release checksum mismatch: {path}")
    raise SystemExit(0)
entries = [
    ("openconnect", "bin/openconnect", "9.21",
     "https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz"),
    ("vpnc-script", "openconnect/vpnc-script", "ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101",
     "https://gitlab.com/openconnect/vpnc-scripts/-/blob/ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101/vpnc-script"),
    ("amneziawg-go", "bin/amneziawg-go", "3.1.20260828",
     "https://github.com/amnezia-vpn/amneziawg-go/tree/v3.1.20260828"),
    ("awg", "bin/awg", "3.1.20260812",
     "https://github.com/amnezia-vpn/amneziawg-tools/tree/v3.1.20260812"),
    ("xray", "xray/xray", "26.3.27+tunneldeck.2",
     "https://github.com/XTLS/Xray-core/tree/v26.3.27"),
    ("hev-socks5-tunnel", "bin/hev-socks5-tunnel", "2.19.0",
     "https://github.com/heiher/hev-socks5-tunnel/releases/tag/2.19.0"),
]
manifest = [{"name": name, "path": path, "version": version, "source": source,
             "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
            for name, path, version, source in entries]
for entry in manifest:
    if entry["name"] == "openconnect":
        entry.update({
            "distribution": "TunnelDeck standalone source build; static OpenSSL; Apple system dylibs only",
            "sourceArchiveSha256": "5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58",
            "tlsLibrary": "OpenSSL 3.6.2 (static)",
            "tlsSourceArchive": "https://github.com/openssl/openssl/releases/download/openssl-3.6.2/openssl-3.6.2.tar.gz",
            "tlsSourceArchiveSha256": "aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f",
            "systemCAFile": "/etc/ssl/cert.pem",
            "minimumMacOS": "14.0",
            "buildScript": "script/build_openconnect.sh",
            "buildScriptSha256": hashlib.sha256((Path(__file__).resolve().parent / "build_openconnect.sh").read_bytes()).hexdigest(),
        })
    if entry["name"] == "xray":
        patch = Path(__file__).resolve().parent / "xray_compat.patch"
        entry.update({
            "distribution": "TunnelDeck modified source build",
            "sourceArchive": "https://github.com/XTLS/Xray-core/archive/refs/tags/v26.3.27.tar.gz",
            "sourceArchiveSha256": "992a4997e6bb846d11469435d687f99ef812fcde1e0a009bb8e95189ea20331d",
            "patch": "script/xray_compat.patch",
            "patchSha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
            "toolchain": "go1.26.0",
            "buildScript": "script/build_xray_compat.sh",
        })
(root / "versions.json").write_text(json.dumps(manifest, indent=2) + "\n")
