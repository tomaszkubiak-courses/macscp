#!/bin/bash
set -euo pipefail

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBSSH_VERSION=0.12.2
LIBSSH_SHA256=49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f
CURL_VERSION=8.23.0
CURL_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
MIN_MACOS=14.0
ARCHS=(arm64 x86_64)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$ROOT/build/cssh
OUT=$ROOT/Frameworks/CSSH.xcframework
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS

fetch() {
  [ -f "$3" ] || curl -fsSL "$1" -o "$3"
  echo "$2  $3" | { command -v sha256sum >/dev/null && sha256sum -c - || shasum -a 256 -c -; } >/dev/null || { echo "checksum mismatch: $3" >&2; rm -f "$3"; exit 1; }
}

CURL_OPTIONS=(
  -DCMAKE_BUILD_TYPE=Release -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF
  -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DCURL_USE_PKGCONFIG=OFF
  -DCURL_USE_OPENSSL=ON -DCURL_USE_LIBPSL=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF
  -DUSE_NGHTTP2=OFF -DUSE_LIBIDN2=OFF -DUSE_APPLE_IDN=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DCURL_ZLIB=OFF
  -DCURL_DISABLE_HTTP=ON -DCURL_DISABLE_DICT=ON -DCURL_DISABLE_FILE=ON -DCURL_DISABLE_GOPHER=ON
  -DCURL_DISABLE_IMAP=ON -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DCURL_DISABLE_MQTT=ON
  -DCURL_DISABLE_POP3=ON -DCURL_DISABLE_RTSP=ON -DCURL_DISABLE_SMTP=ON
  -DCURL_DISABLE_TELNET=ON -DCURL_DISABLE_TFTP=ON -DCURL_DISABLE_IPFS=ON -DCURL_DISABLE_WEBSOCKETS=ON
)

mkdir -p "$WORK/src"
cd "$WORK/src"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" $OPENSSL_SHA256 openssl.tar.gz
fetch "https://www.libssh.org/files/${LIBSSH_VERSION%.*}/libssh-$LIBSSH_VERSION.tar.xz" $LIBSSH_SHA256 libssh.tar.xz
fetch "https://curl.se/download/curl-$CURL_VERSION.tar.xz" $CURL_SHA256 curl.tar.xz

if [ "$(uname)" = Linux ]; then
  PREFIX=/opt/cssh
  rm -rf "$WORK/build-linux" "$PREFIX" && mkdir -p "$WORK/build-linux" && cd "$WORK/build-linux"
  STATIC=(-DCMAKE_INSTALL_PREFIX=$PREFIX -DCMAKE_INSTALL_LIBDIR=lib -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
  tar xJf "$WORK/src/libssh.tar.xz"
  cmake -S libssh-$LIBSSH_VERSION -B libssh-build -G Ninja -DCMAKE_BUILD_TYPE=Release "${STATIC[@]}" \
    -DWITH_EXAMPLES=OFF -DUNIT_TESTING=OFF -DCLIENT_TESTING=OFF -DWITH_SERVER=OFF -DWITH_GSSAPI=OFF >/dev/null
  cmake --build libssh-build >/dev/null && cmake --install libssh-build >/dev/null
  tar xJf "$WORK/src/curl.tar.xz"
  cmake -S curl-$CURL_VERSION -B curl-build -G Ninja "${CURL_OPTIONS[@]}" "${STATIC[@]}" -DBUILD_STATIC_LIBS=ON >/dev/null
  cmake --build curl-build >/dev/null && cmake --install curl-build >/dev/null
  mkdir -p /usr/lib/pkgconfig
  cat > /usr/lib/pkgconfig/cssh.pc <<EOF
Name: cssh
Description: libssh and libcurl for MacSCP
Version: $LIBSSH_VERSION
Cflags: -I$PREFIX/include
Libs: -L$PREFIX/lib -lssh -lcurl -lssl -lcrypto -lz -lpthread
EOF
  echo "Installed static libssh $LIBSSH_VERSION and libcurl $CURL_VERSION to $PREFIX"
  exit 0
fi

for arch in "${ARCHS[@]}"; do
  prefix=$WORK/$arch
  [ -f "$prefix/lib/libcssh.a" ] && continue
  rm -rf "$WORK/build-$arch" && mkdir -p "$WORK/build-$arch" && cd "$WORK/build-$arch"

  tar xzf "$WORK/src/openssl.tar.gz"
  (cd openssl-$OPENSSL_VERSION &&
    ./Configure darwin64-$arch-cc no-shared no-tests no-docs no-apps no-engine no-module \
      --prefix="$prefix" --libdir=lib -mmacosx-version-min=$MIN_MACOS &&
    make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)

  tar xJf "$WORK/src/libssh.tar.xz"
  cmake -S libssh-$LIBSSH_VERSION -B libssh-build -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF -DWITH_EXAMPLES=OFF -DUNIT_TESTING=OFF -DCLIENT_TESTING=OFF \
    -DWITH_SERVER=OFF -DWITH_GSSAPI=ON -DWITH_ZLIB=ON >/dev/null
  cmake --build libssh-build >/dev/null && cmake --install libssh-build >/dev/null

  tar xJf "$WORK/src/curl.tar.xz"
  cmake -S curl-$CURL_VERSION -B curl-build -G Ninja "${CURL_OPTIONS[@]}" \
    -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DOPENSSL_ROOT_DIR="$prefix" -DOPENSSL_USE_STATIC_LIBS=ON \
    -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON >/dev/null
  cmake --build curl-build >/dev/null && cmake --install curl-build >/dev/null

  libtool -static -no_warning_for_no_symbols -o "$prefix/lib/libcssh.a" \
    "$prefix/lib/libssh.a" "$prefix/lib/libcurl.a" "$prefix/lib/libssl.a" "$prefix/lib/libcrypto.a"
done

STAGE=$WORK/universal
rm -rf "$STAGE" "$OUT" && mkdir -p "$STAGE/Headers"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/$a/lib/libcssh.a"; done) -output "$STAGE/libcssh.a"
cp -R "$WORK/${ARCHS[0]}"/include/{libssh,curl,openssl} "$STAGE/Headers/"
cp "$ROOT/Sources/CSSHLinux/cssh.h" "$STAGE/Headers/"
cat > "$STAGE/Headers/module.modulemap" <<'EOF'
module CSSH {
  header "cssh.h"
  link "z"
  link "gssapi_krb5"
  link framework "CoreFoundation"
  link framework "SystemConfiguration"
  link framework "CoreServices"
  export *
}
EOF
xcodebuild -create-xcframework -library "$STAGE/libcssh.a" -headers "$STAGE/Headers" -output "$OUT" >/dev/null
echo "Built $OUT"
lipo -info "$OUT"/*/libcssh.a
