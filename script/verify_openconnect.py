#!/usr/bin/env python3
"""Reject external dylibs and an accidental deployment-target increase."""
from pathlib import Path
import re
import subprocess
import sys


def verify(binary):
    binary = Path(binary)
    architecture = subprocess.check_output(["/usr/bin/lipo", "-archs", str(binary)], text=True).strip()
    if architecture != "arm64":
        raise SystemExit(f"Unexpected OpenConnect architecture: {architecture}")
    libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(binary)], text=True)
    for line in libraries.splitlines()[1:]:
        dependency = line.strip().split(" (compatibility", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"External OpenConnect dependency: {dependency}")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(binary)], text=True)
    minimum = re.search(r"\n\s+minos ([0-9.]+)", commands)
    if not minimum or tuple(map(int, minimum[1].split(".")[:2])) > (14, 0):
        raise SystemExit("OpenConnect deployment target must be macOS 14.0 or earlier")
    version = subprocess.run([str(binary.resolve()), "--version"], check=True, text=True,
                             capture_output=True, env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"})
    if "v9.21" not in version.stdout or "OpenSSL 3.6.2" not in version.stdout:
        raise SystemExit("Unexpected OpenConnect/OpenSSL version")
    print("Verified OpenConnect 9.21 / OpenSSL 3.6.2: arm64, macOS 14, Apple system dylibs only")


if __name__ == "__main__":
    verify(sys.argv[1])
