"""Build the shared modules and their resources once for standalone fixtures."""
from functools import lru_cache
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


@lru_cache(maxsize=1)
def fixture_inputs():
    # A dedicated native-build directory gives swiftc fixtures stable object and
    # module locations, independent of Swift Build's app product layout.
    options = ["--build-system", "native", "--scratch-path", str(ROOT / ".build/integration")]
    subprocess.run(["swift", "build", *options, "--target", "TunnelCore"], cwd=ROOT, check=True, timeout=180)
    build = Path(subprocess.check_output(["swift", "build", *options, "--show-bin-path"], cwd=ROOT, text=True).strip())
    objects = []
    for target in ["TunnelCore", "TunnelLocalization"]:
        target_objects = sorted((build / f"{target}.build").glob("*.swift.o"))
        assert target_objects, f"No SwiftPM fixture objects for {target}"
        objects.extend(target_objects)
    return build / "Modules", objects
