#!/usr/bin/env bash
#
# Build OpenAL Soft osx-arm64 binary for the Rombadil.OpenAL.Soft.Native
# NuGet package.
#
# Designed to be run on a *fresh Apple Silicon Mac* (macOS 11 Big Sur or
# newer). An AWS mac2.metal or mac2-m2.metal EC2 instance works, as does a
# regular M-series Mac. The script bootstraps Homebrew if missing, then
# installs CMake + Ninja from it; the Apple toolchain (clang, the
# frameworks) comes from Xcode Command Line Tools.
#
# Usage:
#   bash build-osx-arm64.sh
#   OPENAL_VERSION=1.25.1 bash build-osx-arm64.sh
#
# Wall time: ~3 minutes on M1/M2.
#
# After the script finishes, copy the artifact into the package repo:
#   scp -r <mac-host>:~/build-artifacts/runtimes/osx-arm64 ./runtimes/
#
set -euo pipefail

# ---- Config ----
OPENAL_VERSION="${OPENAL_VERSION:-1.25.1}"
TARBALL_URL="https://github.com/kcat/openal-soft/archive/refs/tags/${OPENAL_VERSION}.tar.gz"
WORK_DIR="$HOME/openal-build"
OUT_DIR="$HOME/build-artifacts/runtimes"
SRC_DIR="$WORK_DIR/openal-soft-${OPENAL_VERSION}"
OSX_ARCH="arm64"
OSX_DEPLOYMENT_TARGET="11.0"  # First arm64-supporting macOS

# ---- Pretty output ----
B=$'\033[1m'; G=$'\033[32m'; C=$'\033[36m'; Y=$'\033[33m'; D=$'\033[2m'; R=$'\033[0m'
step()  { printf "\n${B}${C}[%s]${R} ${B}%s${R}\n" "$1" "$2"; }
note()  { printf "  ${D}%s${R}\n" "$1"; }
ok()    { printf "  ${G}✓${R} %s\n" "$1"; }
fail()  { printf "  ${Y}!${R} %s\n" "$1"; exit 1; }

printf "\n${B}OpenAL Soft ${OPENAL_VERSION} — building osx-arm64${R}\n"
note "Source:   $TARBALL_URL"
note "Workdir:  $WORK_DIR"
note "Output:   $OUT_DIR"
note "Arch:     $OSX_ARCH (deployment target: macOS $OSX_DEPLOYMENT_TARGET)"

# =========================================================================
step "1/5" "Bootstrap toolchain"
# =========================================================================
note "Apple's toolchain (clang, the SDK frameworks) lives in Xcode Command"
note "Line Tools. CMake and Ninja come from Homebrew."

if ! xcode-select -p >/dev/null 2>&1; then
    note "Xcode Command Line Tools not found — triggering installer..."
    xcode-select --install || true
    fail "An interactive installer window should have appeared. Re-run this script after it finishes."
fi

if ! command -v brew >/dev/null 2>&1; then
    note "Installing Homebrew (non-interactive)..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # brew lives at /opt/homebrew on Apple Silicon, /usr/local on Intel.
    if [[ -x /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -x /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

brew install --quiet cmake ninja

note "Active compiler:"
note "  $(xcrun --find clang)"
clang --version | head -1 | sed 's/^/  /'
ok "Toolchain ready."

# =========================================================================
step "2/5" "Fetch OpenAL Soft ${OPENAL_VERSION} source"
# =========================================================================
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
if [[ -d "$SRC_DIR" ]]; then
    note "Source tree already present at $SRC_DIR — reusing."
else
    curl -fsSL -o "openal-soft-${OPENAL_VERSION}.tar.gz" "$TARBALL_URL"
    tar xf "openal-soft-${OPENAL_VERSION}.tar.gz"
    note "Extracted to $SRC_DIR"
fi
ok "Source ready."

# =========================================================================
step "3/5" "Build osx-arm64 (native, CoreAudio backend)"
# =========================================================================
note "Release build of libopenal.dylib targeting arm64, with macOS"
note "${OSX_DEPLOYMENT_TARGET} as the minimum deployment target. CoreAudio is auto-detected"
note "from the bundled Apple frameworks. No static linking is needed:"
note "every Mac ships libc++ and the audio frameworks at known paths."

cd "$SRC_DIR"
rm -rf build-osx-arm64
cmake -S . -B build-osx-arm64 -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBTYPE=SHARED \
    -DCMAKE_OSX_ARCHITECTURES="$OSX_ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$OSX_DEPLOYMENT_TARGET" \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_INSTALL=OFF \
    -DALSOFT_INSTALL_CONFIG=OFF \
    -DALSOFT_INSTALL_HRTF_DATA=OFF \
    -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF \
    -DALSOFT_INSTALL_UTILS=OFF \
    > "$WORK_DIR/configure-osx-arm64.log"

cmake --build build-osx-arm64 -j

note "openal-soft builds libopenal.X.Y.Z.dylib plus libopenal.1.dylib and"
note "libopenal.dylib symlinks. We ship the resolved real file under the"
note "name the loader looks for."
strip -x build-osx-arm64/libopenal.1.dylib 2>/dev/null || true

OSX_OUT="$OUT_DIR/osx-arm64/native"
mkdir -p "$OSX_OUT"
# Resolve the symlink chain to the real file and ship it as libopenal.1.dylib.
REAL_PATH=$(cd "$SRC_DIR/build-osx-arm64" && readlink libopenal.1.dylib 2>/dev/null || true)
if [[ -n "$REAL_PATH" ]]; then
    cp "$SRC_DIR/build-osx-arm64/$REAL_PATH" "$OSX_OUT/libopenal.1.dylib"
else
    cp "$SRC_DIR/build-osx-arm64/libopenal.1.dylib" "$OSX_OUT/libopenal.1.dylib"
fi
ok "libopenal.1.dylib → $OSX_OUT  ($(du -h "$OSX_OUT/libopenal.1.dylib" | cut -f1))"

# =========================================================================
step "4/5" "Verify artifact"
# =========================================================================

printf "\n${B}osx-arm64/native/libopenal.1.dylib — architecture${R}\n"
file "$OSX_OUT/libopenal.1.dylib"

printf "\n${B}osx-arm64/native/libopenal.1.dylib — linked dependencies${R}\n"
note "Expected: only Apple system libraries — libc++, libSystem, and the"
note "CoreAudio / AudioToolbox / AudioUnit / CoreFoundation frameworks."
echo
otool -L "$OSX_OUT/libopenal.1.dylib"

if ! file "$OSX_OUT/libopenal.1.dylib" | grep -qi "arm64"; then
    fail "Architecture is not arm64 — check CMAKE_OSX_ARCHITECTURES."
fi
ok "macOS dylib verified."

# =========================================================================
step "5/5" "Done"
# =========================================================================
printf "\nArtifact:\n"
printf "  ${G}%s${R}\n" "$OSX_OUT/libopenal.1.dylib"
printf "\nCopy it into the package's runtimes/ folder from your local machine:\n"
printf "  ${B}scp -r <mac-host>:%s/osx-arm64 ./${R}\n\n" "$OUT_DIR"
