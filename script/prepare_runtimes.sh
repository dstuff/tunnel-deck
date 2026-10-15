#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(uname -m)" == "arm64" ]] || { echo "This runtime lock is for Apple Silicon." >&2; exit 1; }
mkdir -p .runtime-sources Runtime/bin Runtime/licenses
fetch() {
    local url="$1" file="$2" digest="$3"
    if [[ ! -f "$file" ]]; then curl -L --fail --max-time 180 "$url" -o "$file"; fi
    echo "$digest  $file" | shasum -a 256 -c -
}
fetch 'https://codeload.github.com/amnezia-vpn/amneziawg-go/tar.gz/refs/tags/v3.1.20260828' \
    .runtime-sources/awg-go.tar.gz 24c656cfb80ff6855702710eaf2e3729fa710bf6bfdbbbdfba01984ccd17de95
fetch 'https://codeload.github.com/amnezia-vpn/amneziawg-tools/tar.gz/refs/tags/v3.1.20260812' \
    .runtime-sources/awg-tools.tar.gz dbd8ce0748d835d18f30bb76720246b7bfc80bd09cd17c379b1c59f683a18493
# The official archive supplies only data/license files. Xray itself is rebuilt
# from pinned source with the separately recorded TunnelDeck compatibility patch.
if [[ ! -f Runtime/xray/geoip.dat || ! -f Runtime/xray/geosite.dat || ! -f Runtime/xray/LICENSE ]]; then
    fetch 'https://github.com/XTLS/Xray-core/releases/download/v26.3.27/Xray-macos-arm64-v8a.zip' \
        .runtime-sources/xray.zip 2e93a67e8aa1936ecefb307e120830fcbd4c643ab9b1c46a2d0838d5f8409eaf
    unzip -q -o .runtime-sources/xray.zip LICENSE README.md geoip.dat geosite.dat -d Runtime/xray
fi
fetch 'https://github.com/heiher/hev-socks5-tunnel/releases/download/2.19.0/hev-socks5-tunnel-darwin-arm64' \
    Runtime/bin/hev-socks5-tunnel c72e2d99b698542105e10777a5105a60bb04f4d80bfbf95f20f3365cb77e5d47
fetch 'https://raw.githubusercontent.com/heiher/hev-socks5-tunnel/2.19.0/LICENSE' \
    Runtime/licenses/HevSocks5Tunnel-LICENSE 3cca1a91ca82e9b9c41852945ef15858f932828ceeb765b86bc1fe3f39127514
chmod 755 Runtime/bin/hev-socks5-tunnel
tar -xzf .runtime-sources/awg-go.tar.gz -C .runtime-sources
tar -xzf .runtime-sources/awg-tools.tar.gz -C .runtime-sources
bash "$ROOT_DIR/script/build_xray_compat.sh"
export GOCACHE="$ROOT_DIR/.runtime-sources/go-cache"
export GOMODCACHE="$ROOT_DIR/.runtime-sources/go-mod"
GO_BIN="$(command -v go)"
(cd .runtime-sources/amneziawg-go-3.1.20260828 && "$GO_BIN" build -trimpath -o "$ROOT_DIR/Runtime/bin/amneziawg-go" .)
make -C .runtime-sources/amneziawg-tools-3.1.20260812/src -j4
cp .runtime-sources/amneziawg-tools-3.1.20260812/src/wg Runtime/bin/awg
cp .runtime-sources/amneziawg-go-3.1.20260828/LICENSE Runtime/licenses/AmneziaWG-Go-LICENSE
cp .runtime-sources/amneziawg-tools-3.1.20260812/COPYING Runtime/licenses/AmneziaWG-Tools-COPYING
if ! command -v openconnect >/dev/null 2>&1; then brew install openconnect; fi
python3 script/runtime_manifest.py Runtime --verify-pins
python3 script/runtime_manifest.py Runtime
echo "Runtime engines are ready. Run ./script/build_and_run.sh"
