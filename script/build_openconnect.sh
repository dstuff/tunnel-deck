#!/usr/bin/env bash
# Self-contained arm64 OpenConnect: only Apple system dylibs at runtime.
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
[[ "$(uname -m)" == "arm64" ]] || { echo "OpenConnect runtime requires Apple Silicon." >&2; exit 1; }
mkdir -p .runtime-sources Runtime/bin Runtime/openconnect Runtime/licenses

fetch() {
    local url="$1" file="$2" digest="$3"
    if [[ ! -f "$file" ]]; then
        curl --fail --location --silent --show-error --max-time 300 "$url" --output "$file.download"
        mv "$file.download" "$file"
    fi
    echo "$digest  $file" | shasum -a 256 -c -
}

fetch 'https://www.infradead.org/openconnect/download/openconnect-9.21.tar.gz' \
    .runtime-sources/openconnect-9.21.tar.gz 5b32369467db6e5f317aa1ed12cfcbb81ed00bdbc765450b6bfcbdc300944a58
fetch 'https://github.com/openssl/openssl/releases/download/openssl-3.6.2/openssl-3.6.2.tar.gz' \
    .runtime-sources/openssl-3.6.2.tar.gz aaf51a1fe064384f811daeaeb4ec4dce7340ec8bd893027eee676af31e83a04f
fetch 'https://gitlab.com/openconnect/vpnc-scripts/-/raw/ce9e961bd0f6b867e1c7c35f78f6fb973f6ff101/vpnc-script' \
    .runtime-sources/vpnc-script f0c4d936a382f07711263242699b5e2d85d1ace37136bb78785d352997c17742
fetch 'https://distfiles.ariadne.space/pkgconf/pkgconf-3.0.8.tar.xz' \
    .runtime-sources/pkgconf-3.0.8.tar.xz 943f0bc88bcaeceb630b00262e2a8ad5ea4fac3fba72a4267d8b9ec6b35d1194

BUILD_DIR="$(mktemp -d "$ROOT_DIR/.runtime-sources/openconnect-build.XXXXXX")"
LOG="$BUILD_DIR/build.log"
trap 'echo "OpenConnect build failed; details: $LOG" >&2; tail -60 "$LOG" >&2' ERR
tar -xzf .runtime-sources/openconnect-9.21.tar.gz -C "$BUILD_DIR"
tar -xzf .runtime-sources/openssl-3.6.2.tar.gz -C "$BUILD_DIR"
tar -xf .runtime-sources/pkgconf-3.0.8.tar.xz -C "$BUILD_DIR"

# Do not discover Homebrew headers, libraries, providers or build tools.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export CC=/usr/bin/clang
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
export SOURCE_DATE_EPOCH=0
unset CPATH LIBRARY_PATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH DYLD_LIBRARY_PATH OPENSSL_CONF OPENSSL_MODULES OPENSSL_LOCAL_CONFIG_DIR
JOBS="${TUNNELDECK_BUILD_JOBS:-8}"
echo "Building static OpenSSL 3.6.2 and OpenConnect 9.21 (log: $LOG)…"
(
    cd "$BUILD_DIR/pkgconf-3.0.8"
    ./configure --prefix="$BUILD_DIR/tools" --disable-shared
    make -j"$JOBS"
    make install
    cd "$BUILD_DIR/openssl-3.6.2"
    /usr/bin/perl ./Configure darwin64-arm64-cc no-shared no-module no-dso no-tests \
        --prefix=/usr/local/tunneldeck-openssl --openssldir=/etc/ssl \
        -mmacosx-version-min=14.0
    make -j"$JOBS" build_libs
    cd "$BUILD_DIR/openconnect-9.21"
    PKG_CONFIG="$BUILD_DIR/tools/bin/pkgconf" PKG_CONFIG_LIBDIR="$BUILD_DIR/tools/lib/pkgconfig" PKG_CONFIG_PATH= \
        LIBXML2_CFLAGS="-I$SDKROOT/usr/include/libxml2" LIBXML2_LIBS=-lxml2 \
        ZLIB_CFLAGS=' ' ZLIB_LIBS=-lz CFLAGS='-O2 -mmacosx-version-min=14.0' \
        ./configure --prefix=/usr/local/tunneldeck-openconnect \
        --with-openssl="$BUILD_DIR/openssl-3.6.2" --without-gnutls \
        --disable-shared --enable-static --disable-nls --disable-dependency-tracking \
        --without-lz4 --without-libproxy --without-stoken --without-libpcsclite \
        --without-libpskc --without-gssapi --with-builtin-json \
        --with-vpnc-script=/usr/bin/false
    make -j"$JOBS" openconnect
) >"$LOG" 2>&1

# Check before replacing the current runtime. No /opt/homebrew, /usr/local,
# @rpath or private dylibs may survive the static build.
/usr/bin/python3 "$ROOT_DIR/script/verify_openconnect.py" "$BUILD_DIR/openconnect-9.21/openconnect"
cp "$BUILD_DIR/openconnect-9.21/openconnect" Runtime/bin/openconnect
cp .runtime-sources/vpnc-script Runtime/openconnect/vpnc-script
chmod 755 Runtime/bin/openconnect Runtime/openconnect/vpnc-script
cp "$BUILD_DIR/openconnect-9.21/COPYING.LGPL" Runtime/licenses/OpenConnect-COPYING.LGPL
cp "$BUILD_DIR/openssl-3.6.2/LICENSE.txt" Runtime/licenses/OpenSSL-LICENSE.txt
echo "OpenConnect runtime ready (system CA file: /etc/ssl/cert.pem)."
