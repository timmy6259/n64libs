#!/usr/bin/env bash
# Cross-build an ARM64 iOS-hosted N64 MIPS toolchain on macOS.
# This first-stage build installs binutils and the GCC compiler frontend;
# target runtime libraries (newlib/libgcc) are intentionally not built here,
# because an iOS-hosted compiler cannot be executed on the macOS CI runner.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${BUILD_DIR:-${RUNNER_TEMP:-/tmp}/n64-toolchain-build}"
STAGE_DIR="${STAGE_DIR:-${ROOT_DIR}/stage}"
SDKROOT="${SDKROOT:?Set SDKROOT to a Theos iPhoneOS SDK path}"
IOS_MIN_VERSION="${IOS_MIN_VERSION:-16.0}"
INSTALL_PREFIX="${INSTALL_PREFIX:-/var/jb/usr}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"
ABI="${ABI:-32}"
TARGET="${TARGET:-mips-elf}"
GCC_VERSION="16.1.0"
BINUTILS_VERSION="2.30"

[[ -d "$SDKROOT" ]] || { echo "SDKROOT is not a directory: $SDKROOT" >&2; exit 1; }
case "$ABI" in
  32|eabi) ;;
  *) echo "This N64/VR4300 configuration currently supports ABI=32 or eabi (got $ABI)" >&2; exit 2 ;;
esac

HOST_CC=(clang -target arm64-apple-ios"$IOS_MIN_VERSION" -isysroot "$SDKROOT" -arch arm64 -miphoneos-version-min="$IOS_MIN_VERSION")
export CC="${HOST_CC[*]}"
export CXX="clang++ -target arm64-apple-ios${IOS_MIN_VERSION} -isysroot ${SDKROOT} -arch arm64 -miphoneos-version-min=${IOS_MIN_VERSION}"
export CFLAGS="-O2 -isysroot ${SDKROOT} -arch arm64 -miphoneos-version-min=${IOS_MIN_VERSION}"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-isysroot ${SDKROOT} -arch arm64 -miphoneos-version-min=${IOS_MIN_VERSION}"

mkdir -p "$BUILD_DIR" "$STAGE_DIR"
cd "$BUILD_DIR"

fetch() {
  local name="$1" url="$2"
  [[ -f "$name" ]] || curl --fail --location --retry 3 "$url" --output "$name"
}

fetch "binutils-${BINUTILS_VERSION}.tar.xz" "https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz"
fetch "gcc-${GCC_VERSION}.tar.xz" "https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz"

if [[ ! -d "binutils-${BINUTILS_VERSION}" ]]; then
  tar -xJf "binutils-${BINUTILS_VERSION}.tar.xz"
  (
    cd "binutils-${BINUTILS_VERSION}"
    patch -p1 < "$ROOT_DIR/gas-vr4300.patch"
    patch -p1 < "$ROOT_DIR/no-fp-warn.patch"
    patch -p1 < "$ROOT_DIR/sdata_merging_bfd.patch"
    patch -p1 < "$ROOT_DIR/gcc15_fix.patch"
  )
fi
if [[ ! -d "gcc-${GCC_VERSION}" ]]; then
  tar -xJf "gcc-${GCC_VERSION}.tar.xz"
  (
    cd "gcc-${GCC_VERSION}"
    patch -p1 < "$ROOT_DIR/bb-reorder.patch"
    patch -p1 < "$ROOT_DIR/gcc-vr4300.patch"
    patch -p1 < "$ROOT_DIR/mips_floats.patch"
    patch -p1 < "$ROOT_DIR/mips_oddspreg_no_warn.patch"
    patch -p1 < "$ROOT_DIR/mips_cache.patch"
    patch -p1 < "$ROOT_DIR/mingw.patch"
    # The repository's upstream script uses BSD sed syntax; CI runs on macOS,
    # but apply the GCC 16 C23 workaround only if the expected source exists.
    if grep -q 'set_std_c23 (false' gcc/c-family/c-opts.cc; then
      sed -i '' 's/set_std_c23 (false/set_std_c17 (false/' gcc/c-family/c-opts.cc
    fi
    ./contrib/download_prerequisites
  )
fi

# Build Binutils for the iOS device host, while retaining the MIPS ELF target.
mkdir -p binutils-build && cd binutils-build
BUILD_TRIPLE="$(clang -dumpmachine)"
../"binutils-${BINUTILS_VERSION}"/configure \
  --build="$BUILD_TRIPLE" --host=aarch64-apple-darwin --target="$TARGET" \
  --prefix="$INSTALL_PREFIX" --program-prefix=mips-n64- \
  --with-cpu=mips64vr4300 --disable-werror --disable-nls \
  --disable-gdb --disable-sim --disable-gprofng --disable-plugins --disable-lto
make -j"$JOBS"
make DESTDIR="$STAGE_DIR" install
cd "$BUILD_DIR"

# Build the MIPS-targeting GCC frontend for iOS ARM64. This stage omits target
# runtime libraries because those require running the just-built iOS compiler.
mkdir -p gcc-build && cd gcc-build
"$ROOT_DIR"/gcc-"$GCC_VERSION"/configure \
  --build="$BUILD_TRIPLE" --host=aarch64-apple-darwin --target="$TARGET" \
  --prefix="$INSTALL_PREFIX" --program-prefix=mips-n64- \
  --with-arch=vr4300 --with-tune=vr4300 --with-abi="$ABI" \
  --enable-languages=c --without-headers --with-newlib \
  --disable-libssp --disable-multilib --disable-shared --disable-threads \
  --disable-nls --disable-werror --disable-win32-registry \
  --disable-bootstrap --disable-lto --disable-plugin \
  --with-gmp="$BUILD_DIR/gcc-${GCC_VERSION}/gmp" \
  --with-mpfr="$BUILD_DIR/gcc-${GCC_VERSION}/mpfr" \
  --with-mpc="$BUILD_DIR/gcc-${GCC_VERSION}/mpc"
make -j"$JOBS" all-gcc
make DESTDIR="$STAGE_DIR" install-gcc

# Confirm packaged executables are Mach-O ARM64 (not macOS host executables).
BIN_DIR="$STAGE_DIR$INSTALL_PREFIX/bin"
for tool in mips-n64-gcc mips-n64-as mips-n64-ld; do
  [[ -f "$BIN_DIR/$tool" ]] || { echo "Missing expected tool: $BIN_DIR/$tool" >&2; exit 1; }
  file "$BIN_DIR/$tool" | grep -Eq 'Mach-O 64-bit executable arm64|Mach-O 64-bit arm64'
done

echo "First-stage ARM64 iOS-hosted toolchain installed under $STAGE_DIR$INSTALL_PREFIX"
echo "Note: newlib and target libgcc are not included in this bootstrap artifact."
