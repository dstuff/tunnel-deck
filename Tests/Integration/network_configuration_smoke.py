#!/usr/bin/env python3
"""Exercise the real helper route transaction with recorded system commands only."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    build = Path(subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=ROOT, text=True).strip())
    objects = sorted((build / "TunnelCore.build").glob("*.swift.o"))
    assert objects, "Run swift build first"
    with tempfile.TemporaryDirectory(prefix="tunneldeck-network-test-") as directory:
        temporary = Path(directory)
        main = temporary / "main.swift"
        shutil.copyfile(Path(__file__).with_name("NetworkConfigurationFixture.swift"), main)
        binary = temporary / "network-fixture"
        subprocess.run(["xcrun", "swiftc", "-I", str(build / "Modules"),
                        str(ROOT / "Sources/TunnelDeckHelper/NetworkConfiguration.swift"), str(main),
                        *map(str, objects), "-o", str(binary)], cwd=ROOT, check=True, timeout=60)
        subprocess.run([str(binary)], check=True, timeout=15)


if __name__ == "__main__":
    main()
