#!/usr/bin/env bash
#
# Build OpenAL Soft binaries (win-x64 + linux-x64) for the
# Rombadil.OpenAL.Soft.Native NuGet package.
#
# Designed to be run on a *fresh Ubuntu EC2 instance* (24.04 or 26.04).
# It installs all required toolchains, fetches the OpenAL Soft source,
# cross-compiles the Windows DLL with MinGW-w64, builds the Linux .so
# natively, and stages both artifacts under ~/build-artifacts/runtimes/.
#
# Usage:
#   bash build.sh
#   OPENAL_VERSION=1.25.1 bash build.sh   # override the upstream version
#
# Suggested instance: t3.medium or larger, 20 GB root disk.
# Wall time on a t3.medium: roughly 5 minutes.
#
# After the script finishes, copy the artifacts into the package repo:
#   scp -r <ec2-host>:~/build-artifacts/runtimes ./
#
set -euo pipefail

# ---- Config ----
OPENAL_VERSION="${OPENAL_VERSION:-1.25.1}"
TARBALL_URL="https://github.com/kcat/openal-soft/archive/refs/tags/${OPENAL_VERSION}.tar.gz"
WORK_DIR="$HOME/openal-build"
OUT_DIR="$HOME/build-artifacts/runtimes"
SRC_DIR="$WORK_DIR/openal-soft-${OPENAL_VERSION}"

# ---- Pretty output ----
B=$'\033[1m'; G=$'\033[32m'; C=$'\033[36m'; Y=$'\033[33m'; D=$'\033[2m'; R=$'\033[0m'
step()  { printf "\n${B}${C}[%s]${R} ${B}%s${R}\n" "$1" "$2"; }
note()  { printf "  ${D}%s${R}\n" "$1"; }
ok()    { printf "  ${G}✓${R} %s\n" "$1"; }
fail()  { printf "  ${Y}!${R} %s\n" "$1"; exit 1; }

printf "\n${B}OpenAL Soft ${OPENAL_VERSION} — building win-x64 + linux-x64${R}\n"
note "Source:   $TARBALL_URL"
note "Workdir:  $WORK_DIR"
note "Output:   $OUT_DIR"

# =========================================================================
step "1/7" "Install toolchains"
# =========================================================================
note "C/C++ compilers + CMake + Ninja for both targets."
note "MinGW-w64 cross compiler for the Windows target."
note "ALSA / PulseAudio / PipeWire dev headers so the Linux build picks up"
note "those backends at configure time."

sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential cmake ninja-build curl ca-certificates \
    mingw-w64 \
    libasound2-dev libpulse-dev libpipewire-0.3-dev

note "OpenAL Soft is C++17 and uses std::thread / std::mutex, which require"
note "MinGW's POSIX thread model. On modern Ubuntu POSIX is the default;"
note "the update-alternatives calls below are no-ops in that case."
sudo update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix 2>/dev/null || true
sudo update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix 2>/dev/null || true

note "Active MinGW C++ compiler:"
note "  $(readlink -f "$(command -v x86_64-w64-mingw32-g++)")"
x86_64-w64-mingw32-g++ -v 2>&1 | grep -i "thread model" | sed 's/^/  /'
ok "Toolchains installed."

# =========================================================================
step "2/7" "Fetch OpenAL Soft ${OPENAL_VERSION} source"
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
step "3/7" "Write MinGW-w64 CMake toolchain file"
# =========================================================================
note "Tells CMake to use the x86_64-w64-mingw32 compilers and to look up"
note "libraries/headers in /usr/x86_64-w64-mingw32 (the cross sysroot)"
note "instead of the host Linux system."

cat > "$WORK_DIR/mingw-w64-x86_64.cmake" <<'EOF'
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER   x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER  x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
ok "Toolchain file written."

# =========================================================================
step "4/7" "Build win-x64 (MinGW-w64 cross compile, static C/C++ runtime)"
# =========================================================================
note "Release build of OpenAL32.dll with libgcc, libstdc++, and winpthread"
note "statically linked, so the DLL has zero MinGW runtime dependencies."
note "Unix-only audio backends are explicitly disabled to keep host"
note "pkg-config from leaking Linux headers into the cross build."
note ""
note "Note: --whole-archive on libwinpthread causes a benign 'duplicate"
note "VERSION resource' warning during link. ld.bfd keeps openal-soft's"
note "version info and discards winpthread's; without --whole-archive,"
note "winpthread isn't actually statically linked (libstdc++ pulls in a"
note "dynamic dependency on libwinpthread-1.dll, which then fails at"
note "load time on machines that don't have it on PATH)."

cd "$SRC_DIR"
rm -rf build-win64
env -u PKG_CONFIG_PATH PKG_CONFIG_LIBDIR= \
cmake -S . -B build-win64 -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$WORK_DIR/mingw-w64-x86_64.cmake" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBTYPE=SHARED \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_INSTALL=OFF \
    -DALSOFT_INSTALL_CONFIG=OFF \
    -DALSOFT_INSTALL_HRTF_DATA=OFF \
    -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF \
    -DALSOFT_INSTALL_UTILS=OFF \
    -DALSOFT_BACKEND_PIPEWIRE=OFF \
    -DALSOFT_BACKEND_PULSEAUDIO=OFF \
    -DALSOFT_BACKEND_JACK=OFF \
    -DALSOFT_BACKEND_PORTAUDIO=OFF \
    -DCMAKE_SHARED_LINKER_FLAGS="-static-libgcc -static-libstdc++ -Wl,-Bstatic,--whole-archive -lwinpthread -Wl,--no-whole-archive,-Bdynamic" \
    > "$WORK_DIR/configure-win.log"

cmake --build build-win64 -j

note "Stripping debug symbols. A stripped release DLL is roughly 1 MB."
x86_64-w64-mingw32-strip build-win64/OpenAL32.dll

WIN_OUT="$OUT_DIR/win-x64/native"
mkdir -p "$WIN_OUT"
cp build-win64/OpenAL32.dll "$WIN_OUT/"
ok "OpenAL32.dll → $WIN_OUT  ($(du -h "$WIN_OUT/OpenAL32.dll" | cut -f1))"

# =========================================================================
step "5/7" "Build linux-x64 (native, dynamic-linked to system libstdc++)"
# =========================================================================
note "Release build of libopenal.so.1 with ALSA / PulseAudio / PipeWire"
note "backends auto-detected from the dev headers installed in step 1."
note "libstdc++ is dynamic-linked, matching upstream's own Linux release"
note "convention; every glibc distro ships a compatible libstdc++."

cd "$SRC_DIR"
rm -rf build-linux64
cmake -S . -B build-linux64 -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLIBTYPE=SHARED \
    -DALSOFT_UTILS=OFF \
    -DALSOFT_EXAMPLES=OFF \
    -DALSOFT_INSTALL=OFF \
    -DALSOFT_INSTALL_CONFIG=OFF \
    -DALSOFT_INSTALL_HRTF_DATA=OFF \
    -DALSOFT_INSTALL_AMBDEC_PRESETS=OFF \
    -DALSOFT_INSTALL_EXAMPLES=OFF \
    -DALSOFT_INSTALL_UTILS=OFF \
    > "$WORK_DIR/configure-linux.log"

cmake --build build-linux64 -j

note "openal-soft builds libopenal.so.1.X.Y plus a libopenal.so.1 symlink."
note "We ship the resolved real file under the SONAME the loader looks for."
strip build-linux64/libopenal.so.1*

LINUX_OUT="$OUT_DIR/linux-x64/native"
mkdir -p "$LINUX_OUT"
cp "$(readlink -f build-linux64/libopenal.so.1)" "$LINUX_OUT/libopenal.so.1"
ok "libopenal.so.1 → $LINUX_OUT  ($(du -h "$LINUX_OUT/libopenal.so.1" | cut -f1))"

# =========================================================================
step "6/7" "Verify artifacts"
# =========================================================================

printf "\n${B}win-x64/native/OpenAL32.dll — imported DLLs${R}\n"
note "Should be only Windows system DLLs (KERNEL32, USER32, OLE32, WINMM,"
note "AVRT, SHELL32) and the api-ms-win-crt-* api-set."
note "Must NOT contain libgcc_s_seh-1, libstdc++-6, libwinpthread-1."
echo
x86_64-w64-mingw32-objdump -p "$WIN_OUT/OpenAL32.dll" | grep -i "DLL Name" | sort -u

if x86_64-w64-mingw32-objdump -p "$WIN_OUT/OpenAL32.dll" \
    | grep -qiE "libgcc|libstdc\\+\\+|libwinpthread"; then
    fail "Windows DLL still imports MinGW runtime — static-link flags didn't take."
fi
ok "Windows DLL is self-contained."

printf "\n${B}linux-x64/native/libopenal.so.1 — dependencies${R}\n"
note "Expected: libc, libm, libpthread, libdl, libstdc++, plus the audio"
note "backend libs (libasound, libpulse, libpipewire-0.3)."
echo
ldd "$LINUX_OUT/libopenal.so.1"
ok "Linux artifact OK."

# =========================================================================
step "7/7" "Done"
# =========================================================================
printf "\nArtifacts:\n"
printf "  ${G}%s${R}\n" "$WIN_OUT/OpenAL32.dll"
printf "  ${G}%s${R}\n" "$LINUX_OUT/libopenal.so.1"
printf "\nCopy them into the package's runtimes/ folder from your local machine:\n"
printf "  ${B}scp -r <ec2-host>:%s ./${R}\n\n" "$OUT_DIR"
