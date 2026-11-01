#!/bin/bash
set -euo pipefail

OPENSSL_VERSION=3.5.9
OPENSSL_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
LIBSSH_VERSION=0.12.2
LIBSSH_SHA256=49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f
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

mkdir -p "$WORK/src"
cd "$WORK/src"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" $OPENSSL_SHA256 openssl.tar.gz
fetch "https://www.libssh.org/files/${LIBSSH_VERSION%.*}/libssh-$LIBSSH_VERSION.tar.xz" $LIBSSH_SHA256 libssh.tar.xz

if [ "$(uname)" = Linux ]; then
  rm -rf "$WORK/build-linux" && mkdir -p "$WORK/build-linux" && cd "$WORK/build-linux"
  tar xJf "$WORK/src/libssh.tar.xz"
  cmake -S libssh-$LIBSSH_VERSION -B libssh-build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
    -DWITH_EXAMPLES=OFF -DUNIT_TESTING=OFF -DCLIENT_TESTING=OFF -DWITH_SERVER=OFF -DWITH_GSSAPI=OFF >/dev/null
  cmake --build libssh-build >/dev/null && cmake --install libssh-build >/dev/null
  ldconfig
  echo "Installed libssh $LIBSSH_VERSION to /usr"
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

  libtool -static -no_warning_for_no_symbols -o "$prefix/lib/libcssh.a" "$prefix/lib/libssh.a" "$prefix/lib/libcrypto.a"
done

STAGE=$WORK/universal
rm -rf "$STAGE" "$OUT" && mkdir -p "$STAGE/Headers"
lipo -create $(for a in "${ARCHS[@]}"; do echo "$WORK/$a/lib/libcssh.a"; done) -output "$STAGE/libcssh.a"
cp -R "$WORK/${ARCHS[0]}/include/libssh" "$STAGE/Headers/"
cat > "$STAGE/Headers/cssh.h" <<'EOF'
#include "libssh/libssh.h"
#include "libssh/sftp.h"
#include "libssh/callbacks.h"
EOF
cat > "$STAGE/Headers/module.modulemap" <<'EOF'
module CSSH {
  header "cssh.h"
  link "z"
  link "gssapi_krb5"
  export *
}
EOF
xcodebuild -create-xcframework -library "$STAGE/libcssh.a" -headers "$STAGE/Headers" -output "$OUT" >/dev/null
echo "Built $OUT"
lipo -info "$OUT"/*/libcssh.a
