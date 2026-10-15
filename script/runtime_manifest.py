#!/usr/bin/env python3
"""Verify pinned release inputs, or record final source/bundle engine hashes."""
import hashlib
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
release_inputs = {
    "xray/xray": "ef4dcf1839b70d56583bbeb23de1d9977694f671e8eab3a98b4826f9d6f2cbe5",
    "bin/hev-socks5-tunnel": "c72e2d99b698542105e10777a5105a60bb04f4d80bfbf95f20f3365cb77e5d47",
    "licenses/HevSocks5Tunnel-LICENSE": "3cca1a91ca82e9b9c41852945ef15858f932828ceeb765b86bc1fe3f39127514",
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
    ("amneziawg-go", "bin/amneziawg-go", "3.1.20260828",
     "https://github.com/amnezia-vpn/amneziawg-go/tree/v3.1.20260828"),
    ("awg", "bin/awg", "3.1.20260812",
     "https://github.com/amnezia-vpn/amneziawg-tools/tree/v3.1.20260812"),
    ("xray", "xray/xray", "26.3.27+tunneldeck.1",
     "https://github.com/XTLS/Xray-core/tree/v26.3.27"),
    ("hev-socks5-tunnel", "bin/hev-socks5-tunnel", "2.19.0",
     "https://github.com/heiher/hev-socks5-tunnel/releases/tag/2.19.0"),
]
manifest = [{"name": name, "path": path, "version": version, "source": source,
             "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
            for name, path, version, source in entries]
for entry in manifest:
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
