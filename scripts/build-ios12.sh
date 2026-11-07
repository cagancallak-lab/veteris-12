#!/bin/bash
# Build Veteris for arm64 / iOS 12 on macOS.
#
#   ./scripts/build-ios12.sh              # deps (if missing) + app + .deb
#   SKIP_DEPS=1 ./scripts/build-ios12.sh  # reuse libs/arm64
#
# Requires: Xcode (full install), scons, ldid; dpkg for the .deb step.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH="arm64"
MIN_IOS="${MIN_IOS:-12.0}"
JOBS="$(sysctl -n hw.ncpu)"
DEPS="$ROOT/build/deps"
PREFIX="$DEPS/prefix"
SRC="$DEPS/src"
OPENSSL_VER="1.1.1w"
CURL_VER="7.77.0"

say()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }

say "Checking toolchain"
xcode-select -p >/dev/null 2>&1 || die "Xcode is not selected. Install Xcode, then: sudo xcode-select -s /Applications/Xcode.app"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" || die "No iPhoneOS SDK. Open Xcode once, install the iOS platform, and retry."
[ -d "$SDK" ] || die "iPhoneOS SDK path does not exist: $SDK"
command -v scons >/dev/null 2>&1 || die "scons missing: brew install scons"
command -v ldid  >/dev/null 2>&1 || die "ldid missing: brew install ldid"
if ! command -v dpkg-deb >/dev/null 2>&1; then
    warn "dpkg-deb missing: brew install dpkg (skipping .deb packaging)"
fi
echo "SDK: $SDK"
echo "Xcode: $(xcodebuild -version 2>/dev/null | head -1 || echo unknown)"

build_openssl() {
    if [ -f "$PREFIX/lib/libssl.a" ] && [ -f "$PREFIX/lib/libcrypto.a" ]; then
        say "OpenSSL already built"
        return
    fi
    say "Building OpenSSL $OPENSSL_VER for arm64"
    mkdir -p "$SRC" "$PREFIX"
    cd "$SRC"
    if [ ! -f "openssl-$OPENSSL_VER.tar.gz" ]; then
        curl -fL --retry 3 -o "openssl-$OPENSSL_VER.tar.gz" \
            "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz"
    fi
    [ -d "openssl-$OPENSSL_VER" ] || tar xzf "openssl-$OPENSSL_VER.tar.gz"
    cd "openssl-$OPENSSL_VER"

    export CROSS_TOP="$(xcode-select -p)/Platforms/iPhoneOS.platform/Developer"
    export CROSS_SDK="iPhoneOS.sdk"
    ./Configure ios64-cross no-shared no-tests no-async \
        --prefix="$PREFIX" --openssldir="$PREFIX/ssl"
    make -j"$JOBS" build_libs
    make install_sw
    cd "$ROOT"
}

build_curl() {
    if [ -f "$PREFIX/lib/libcurl.a" ]; then
        say "libcurl already built"
        return
    fi
    say "Building libcurl $CURL_VER for arm64"
    mkdir -p "$SRC"
    cd "$SRC"
    if [ ! -f "curl-$CURL_VER.tar.gz" ]; then
        curl -fL --retry 3 -o "curl-$CURL_VER.tar.gz" \
            "https://github.com/curl/curl/releases/download/curl-7_77_0/curl-$CURL_VER.tar.gz"
    fi
    [ -d "curl-$CURL_VER" ] || tar xzf "curl-$CURL_VER.tar.gz"
    cd "curl-$CURL_VER"

    export CC="$(xcrun -f clang) -arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
    export CFLAGS="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS -O2"
    export LDFLAGS="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
    export AR="$(xcrun -f ar)"
    export RANLIB="$(xcrun -f ranlib)"
    export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
    ./configure --host=arm-apple-darwin --prefix="$PREFIX" \
        --with-ssl="$PREFIX" --with-zlib="$SDK/usr" \
        --disable-shared --enable-static \
        --disable-ldap --disable-ldaps --disable-manual --disable-debug \
        --without-libidn2 --without-librtmp --without-libpsl
    make -j"$JOBS"
    make install
    cd "$ROOT"
}

if [ "${SKIP_DEPS:-0}" != "1" ]; then
    build_openssl
    build_curl
fi

[ -f "$PREFIX/lib/libssl.a" ] && [ -f "$PREFIX/lib/libcrypto.a" ] && [ -f "$PREFIX/lib/libcurl.a" ] \
    || die "static libraries missing under $PREFIX/lib"

say "Installing arm64 static libraries into libs/arm64"
mkdir -p libs/arm64
cp -f "$PREFIX/lib/libssl.a" "$PREFIX/lib/libcrypto.a" "$PREFIX/lib/libcurl.a" libs/arm64/

say "Building Veteris (arm64, iOS $MIN_IOS)"
# Release build: no download-debug logging, no debug strings.
export FINALPACKAGE=1
# The tree still carries VERSION = "2.1.1" in SConstruct; pin the release the
# port is based on so Info.plist and the .deb name are not stale.
export VETERIS_MARKETING_VERSION="${VETERIS_MARKETING_VERSION:-4.0.3}"
export VETERIS_BUILD_VERSION="${VETERIS_BUILD_VERSION:-4.0.3}"
export VETERIS_PACKAGE_VERSION="${VETERIS_PACKAGE_VERSION:-4.0.3}"
scons -j"$JOBS" arch="$ARCH" min_version="$MIN_IOS" SDKROOT="$SDK" app

APP="xcbuild/Veteris.app"
BIN="$APP/Veteris"
[ -f "$BIN" ] || die "build did not produce $BIN"

say "Result"
lipo -info "$BIN" || true
otool -l "$BIN" | awk '/LC_VERSION_MIN_IPHONEOS/{f=1} f&&/version/{print "  minimum iOS:", $2; exit}' || true
echo "  binary: $BIN"
du -h "$BIN" | awk '{print "  size:  ", $1}'

if command -v dpkg-deb >/dev/null 2>&1; then
    say "Packaging .deb"
    scons -j"$JOBS" arch="$ARCH" min_version="$MIN_IOS" SDKROOT="$SDK" deb
    DEB="$(ls -t xcbuild/*.deb 2>/dev/null | head -1 || true)"
    [ -n "$DEB" ] && echo "  package: $DEB"
fi

cat <<'EOF'

Next steps on the device (jailbroken, OpenSSH installed):
  scp -r xcbuild/Veteris.app root@<device-ip>:/Applications/
  ssh root@<device-ip> 'uicache -a; killall -9 Veteris || true'

Or install the .deb with:  dpkg -i --force-depends xcbuild/Veteris-v*.deb
(--force-depends is for the separate com.victorlobe.veterishelper package.)
EOF
