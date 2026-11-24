#!/usr/bin/env bash
#
# Cross-compile QEMU (qemu-system-aarch64, qemu-system-x86_64, qemu-img) for
# Android arm64-v8a with the Android NDK, and install the results as
# libqemu-*.so into android/app/src/main/jniLibs/arm64-v8a/.
#
# STATUS: run end-to-end on macOS arm64 with NDK 27.1.12297006 (see tools/README.md).
# The resulting binaries have not yet been booted on a device.
#
# Environment variables (all optional except an NDK location):
#   ANDROID_NDK_HOME   Path to the NDK (r26+ recommended). Also tries ANDROID_NDK_ROOT.
#   ANDROID_API        Android API level for the toolchain.   Default: 29
#                      (keep >= 28: glib relies on bionic's iconv)
#   QEMU_VERSION       QEMU release to download.               Default: 9.0.2
#   WORK_DIR           Download/build/prefix directory.        Default: tools/.build-qemu-android
#   JOBS               Parallel jobs.                          Default: detected CPU count
#   JNILIBS_DIR        Install destination.                    Default: <repo>/android/app/src/main/jniLibs/arm64-v8a
#   FIRMWARE_OUT_DIR   Where QEMU's runtime data (pc-bios) is staged.
#                                                              Default: $WORK_DIR/out/qemu-share
#   Dependency versions: ZLIB_VERSION, LIBFFI_VERSION, PCRE2_VERSION,
#                        GLIB_VERSION, PIXMAN_VERSION, LIBSLIRP_VERSION
#
# Host requirements: bash, curl, tar, xz, make, python3 (+pip/venv), meson,
# ninja, pkg-config, and a host C compiler (glib/QEMU build helpers).

#
# Usage: build-qemu-android.sh [--firmware-only]
#   --firmware-only  Skip the QEMU build. Only fetch the edk2 aarch64 firmware and
#                    stage the QEMU share directory (already built into
#                    FIRMWARE_OUT_DIR) into the app assets. Needs only curl, tar, ar,
#                    xz and shasum; no NDK.
#
# Firmware / share staging (both modes) writes to:
#   ASSETS_DIR         Destination in the app.   Default: <repo>/android/app/src/main/assets/qemu
#   EDK2_DEB_VERSION   Debian qemu-efi-aarch64 package version.   Default: 2025.02-8+deb13u1
#   EDK2_DEB_SHA256    Expected SHA-256 of that .deb (change both together).
#   EDK2_DEB_URL       Override the download URL.
set -euo pipefail
FIRMWARE_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --firmware-only) FIRMWARE_ONLY=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d'; exit 0 ;;
    *) printf 'error: unknown argument: %s\n' "$arg" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------- settings --
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ANDROID_API="${ANDROID_API:-29}"
QEMU_VERSION="${QEMU_VERSION:-9.0.2}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.4.6}"
PCRE2_VERSION="${PCRE2_VERSION:-10.42}"
GLIB_VERSION="${GLIB_VERSION:-2.80.5}"
PIXMAN_VERSION="${PIXMAN_VERSION:-0.43.4}"
LIBSLIRP_VERSION="${LIBSLIRP_VERSION:-4.7.0}"

WORK_DIR="${WORK_DIR:-$SCRIPT_DIR/.build-qemu-android}"
JNILIBS_DIR="${JNILIBS_DIR:-$REPO_ROOT/android/app/src/main/jniLibs/arm64-v8a}"
FIRMWARE_OUT_DIR="${FIRMWARE_OUT_DIR:-$WORK_DIR/out/qemu-share}"
ASSETS_DIR="${ASSETS_DIR:-$REPO_ROOT/android/app/src/main/assets/qemu}"
EDK2_DEB_VERSION="${EDK2_DEB_VERSION:-2025.02-8+deb13u1}"
EDK2_DEB_SHA256="${EDK2_DEB_SHA256:-a00b2411a79c8aeafd95a7c868ac3cd1aab592f1af9fff965f02d81a625276ed}"
EDK2_DEB_URL="${EDK2_DEB_URL:-https://deb.debian.org/debian/pool/main/e/edk2/qemu-efi-aarch64_${EDK2_DEB_VERSION}_all.deb}"

if [[ -z "${JOBS:-}" ]]; then
  JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
fi

NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
TRIPLE="aarch64-linux-android"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------- firmware and share staging -
sha256_of() { # sha256_of <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
# Downloads the Debian qemu-efi-aarch64 package, unpacks QEMU_EFI.fd with ar+tar
# (no dpkg needed, works on macOS) and installs it into $ASSETS_DIR. The 3 MiB
# image is used directly with `-bios` on the "virt" machine; no padding is needed
# (padding to 64 MiB is only required for a pflash drive).
fetch_edk2() {
  local deb="$DL_DIR/qemu-efi-aarch64_${EDK2_DEB_VERSION}_all.deb"
  local tmp="$WORK_DIR/build/edk2"
  for tool in curl tar ar xz; do
    command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
  done
  if [[ ! -f "$deb" ]]; then
    log "Downloading qemu-efi-aarch64 $EDK2_DEB_VERSION"
    curl -fL --retry 3 -o "$deb.part" "$EDK2_DEB_URL"
    mv "$deb.part" "$deb"
  fi
  [[ "$(sha256_of "$deb")" == "$EDK2_DEB_SHA256" ]] || { rm -f "$deb"; die "checksum mismatch for $deb (removed)"; }
  log "Extracting QEMU_EFI.fd"
  rm -rf "$tmp"; mkdir -p "$tmp" "$ASSETS_DIR"
  ( cd "$tmp"
    ar x "$deb"
    local data
    data="$(ls data.tar.* | head -n 1)"
    tar -xf "$data" ./usr/share/qemu-efi-aarch64/QEMU_EFI.fd ./usr/share/doc/qemu-efi-aarch64/copyright )
  cp "$tmp/usr/share/qemu-efi-aarch64/QEMU_EFI.fd" "$ASSETS_DIR/QEMU_EFI.fd"
  cp "$tmp/usr/share/doc/qemu-efi-aarch64/copyright" "$ASSETS_DIR/QEMU_EFI.copyright"
  rm -rf "$tmp"
}
# Copies the staged QEMU share files into $ASSETS_DIR, adds the edk2 firmware and
# writes the VERSION marker the app uses to decide whether to recopy.
stage_assets() {
  [[ -d "$FIRMWARE_OUT_DIR" && -n "$(ls -A "$FIRMWARE_OUT_DIR" 2>/dev/null)" ]] || \
    die "no QEMU share files in $FIRMWARE_OUT_DIR; run a full build first or set FIRMWARE_OUT_DIR"
  log "Staging assets into $ASSETS_DIR"
  rm -rf "$ASSETS_DIR"; mkdir -p "$ASSETS_DIR"
  cp -R "$FIRMWARE_OUT_DIR"/. "$ASSETS_DIR/"
  fetch_edk2
  # Changing any component changes the marker, so installed apps recopy.
  printf 'qemu=%s edk2=%s\n' "$QEMU_VERSION" "$EDK2_DEB_VERSION" > "$ASSETS_DIR/VERSION"
  echo "  assets: $ASSETS_DIR ($(du -sh "$ASSETS_DIR" | cut -f1))"
}
if [[ "$FIRMWARE_ONLY" == 1 ]]; then
  DL_DIR="$WORK_DIR/downloads"
  mkdir -p "$DL_DIR" "$WORK_DIR/build"
  stage_assets
  log "Done (firmware only). Rebuild the app (flutter build apk) to package the assets."
  exit 0
fi
# ------------------------------------------------------------ preflight -----
[[ -n "$NDK" && -d "$NDK" ]] || die "set ANDROID_NDK_HOME to your NDK directory"
for tool in curl tar xz make python3 meson ninja pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || die "missing host tool: $tool"
done

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;   # NDK ships a universal/x86_64 toolchain dir on macOS
  Linux)  HOST_TAG="linux-x86_64" ;;
  *) die "unsupported host OS: $(uname -s)" ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
[[ -d "$TOOLCHAIN" ]] || die "NDK toolchain not found: $TOOLCHAIN"
CC_BIN="$TOOLCHAIN/bin/${TRIPLE}${ANDROID_API}-clang"
CXX_BIN="$TOOLCHAIN/bin/${TRIPLE}${ANDROID_API}-clang++"
[[ -x "$CC_BIN" ]] || die "compiler not found: $CC_BIN (check ANDROID_API)"

SRC_DIR="$WORK_DIR/src"
BLD_DIR="$WORK_DIR/build"
DL_DIR="$WORK_DIR/downloads"
PREFIX="$WORK_DIR/prefix"          # dependency install prefix
BIN_DIR="$WORK_DIR/bin"            # tool wrappers (cross-prefixed names, pkg-config)
OUT_DIR="$WORK_DIR/out"
mkdir -p "$SRC_DIR" "$BLD_DIR" "$DL_DIR" "$PREFIX/lib/pkgconfig" "$BIN_DIR" "$OUT_DIR"

# Android 15 devices may use 16 KB pages; align segments accordingly.
COMMON_CFLAGS="-fPIC -O2 -I$PREFIX/include"
COMMON_LDFLAGS="-L$PREFIX/lib -Wl,-z,max-page-size=16384"

# ------------------------------------------------------- toolchain wrappers --
# QEMU's configure derives tool names from --cross-prefix. The NDK ships
# llvm-* tools without the triple prefix, so provide prefixed symlinks.
for t in ar ranlib nm strip objcopy objdump; do
  ln -sf "$TOOLCHAIN/bin/llvm-$t" "$BIN_DIR/${TRIPLE}-$t"
done
ln -sf "$TOOLCHAIN/bin/ld.lld" "$BIN_DIR/${TRIPLE}-ld"
ln -sf "$CC_BIN" "$BIN_DIR/${TRIPLE}-gcc"
ln -sf "$CXX_BIN" "$BIN_DIR/${TRIPLE}-g++"

# pkg-config for the target: only look in our prefix and always use --static,
# because the dependencies are static archives whose private deps must be linked.
cat > "$BIN_DIR/${TRIPLE}-pkg-config" <<EOF
#!/usr/bin/env bash
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH
exec pkg-config --static "\$@"
EOF
chmod +x "$BIN_DIR/${TRIPLE}-pkg-config"

# Build-time python modules (glib needs 'packaging', and meson must run from this venv to see it; Homebrew python is
# "externally managed", so use a venv inside the work dir).
if [[ ! -x "$WORK_DIR/venv/bin/python3" ]]; then
  # Very new Pythons (3.15) break QEMU's configure; prefer 3.11-3.13. Override with VENV_PYTHON.
  VENV_PYTHON="${VENV_PYTHON:-}"
  if [[ -z "$VENV_PYTHON" ]]; then
    for c in python3.12 python3.13 python3.11 python3; do
      command -v "$c" >/dev/null 2>&1 && { VENV_PYTHON="$(command -v "$c")"; break; }
    done
  fi
  "$VENV_PYTHON" -m venv "$WORK_DIR/venv"
  "$WORK_DIR/venv/bin/pip" install --quiet packaging setuptools distlib meson
fi

export PATH="$WORK_DIR/venv/bin:$BIN_DIR:$TOOLCHAIN/bin:$PATH"

# ------------------------------------------------------------ meson cross ---
CROSS_FILE="$WORK_DIR/android-arm64.cross"
cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CC_BIN'
cpp = '$CXX_BIN'
ar = '$TOOLCHAIN/bin/llvm-ar'
ranlib = '$TOOLCHAIN/bin/llvm-ranlib'
strip = '$TOOLCHAIN/bin/llvm-strip'
nm = '$TOOLCHAIN/bin/llvm-nm'
pkg-config = '$BIN_DIR/${TRIPLE}-pkg-config'

[built-in options]
c_args = ['-fPIC', '-I$PREFIX/include']
cpp_args = ['-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib', '-Wl,-z,max-page-size=16384']
cpp_link_args = ['-L$PREFIX/lib', '-Wl,-z,max-page-size=16384']

[host_machine]
system = 'android'
subsystem = 'android'
kernel = 'linux'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF

# ---------------------------------------------------------------- helpers ---
fetch() { # fetch <url> <filename>
  local url="$1" name="$2"
  [[ -f "$DL_DIR/$name" ]] || { log "Downloading $name"; curl -fL --retry 3 -o "$DL_DIR/$name.part" "$url"; mv "$DL_DIR/$name.part" "$DL_DIR/$name"; }
}
unpack() { # unpack <filename> <dirname>
  [[ -d "$SRC_DIR/$2" ]] || { log "Unpacking $1"; tar -C "$SRC_DIR" -xf "$DL_DIR/$1"; }
  [[ -d "$SRC_DIR/$2" ]] || die "expected directory $SRC_DIR/$2 after unpacking $1"
}
stamp() { echo "$BLD_DIR/.done-$1"; }
is_done() { [[ -f "$(stamp "$1")" ]]; }
mark_done() { touch "$(stamp "$1")"; }

meson_dep() { # meson_dep <name> <srcdir> [meson args...]
  local name="$1" src="$2"; shift 2
  rm -rf "$BLD_DIR/$name"
  meson setup "$BLD_DIR/$name" "$src" \
    --cross-file "$CROSS_FILE" \
    --prefix "$PREFIX" --libdir lib \
    --buildtype release --default-library static \
    -Dwrap_mode=nodownload \
    "$@"
  ninja -C "$BLD_DIR/$name" -j "$JOBS"
  ninja -C "$BLD_DIR/$name" install
}

autotools_dep() { # autotools_dep <name> <srcdir> [configure args...]
  local name="$1" src="$2"; shift 2
  rm -rf "$BLD_DIR/$name"; mkdir -p "$BLD_DIR/$name"
  ( cd "$BLD_DIR/$name"
    CC="$CC_BIN" CXX="$CXX_BIN" AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib" \
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
    "$src/configure" --host="$TRIPLE" --prefix="$PREFIX" --enable-static --disable-shared "$@"
    make -j "$JOBS"
    make install )
}

# ------------------------------------------------------------- dependencies -
build_zlib() {
  is_done zlib && return 0
  fetch "https://zlib.net/fossils/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION.tar.gz"
  unpack "zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION"
  log "Building zlib"
  rm -rf "$BLD_DIR/zlib"; cp -R "$SRC_DIR/zlib-$ZLIB_VERSION" "$BLD_DIR/zlib"   # zlib builds in-tree
  ( cd "$BLD_DIR/zlib"
    # CHOST stops zlib's configure from detecting the macOS host (it would
    # pick Apple libtool as AR, which cannot archive ELF objects).
    CHOST="$TRIPLE" CC="$CC_BIN" AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib" \
    CFLAGS="$COMMON_CFLAGS" LDFLAGS="$COMMON_LDFLAGS" \
    ./configure --prefix="$PREFIX" --static
    make -j "$JOBS"
    make install )
  mark_done zlib
}

build_libffi() {
  is_done libffi && return 0
  fetch "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz" "libffi-$LIBFFI_VERSION.tar.gz"
  unpack "libffi-$LIBFFI_VERSION.tar.gz" "libffi-$LIBFFI_VERSION"
  log "Building libffi"
  autotools_dep libffi "$SRC_DIR/libffi-$LIBFFI_VERSION" --disable-docs
  mark_done libffi
}

build_pcre2() {
  is_done pcre2 && return 0
  fetch "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "pcre2-$PCRE2_VERSION.tar.gz"
  unpack "pcre2-$PCRE2_VERSION.tar.gz" "pcre2-$PCRE2_VERSION"
  log "Building pcre2"
  autotools_dep pcre2 "$SRC_DIR/pcre2-$PCRE2_VERSION" --disable-pcre2grep-libz --disable-pcre2grep-libbz2
  mark_done pcre2
}

build_glib() {
  is_done glib && return 0
  local series="${GLIB_VERSION%.*}"
  fetch "https://download.gnome.org/sources/glib/$series/glib-$GLIB_VERSION.tar.xz" "glib-$GLIB_VERSION.tar.xz"
  unpack "glib-$GLIB_VERSION.tar.xz" "glib-$GLIB_VERSION"
  log "Building glib"
  # PKG_CONFIG_LIBDIR lets glib's meson find our libffi/pcre2/zlib via the cross pkg-config wrapper.
  meson_dep glib "$SRC_DIR/glib-$GLIB_VERSION" \
    -Dtests=false -Dnls=disabled -Dlibmount=disabled -Dselinux=disabled \
    -Dxattr=false -Dglib_debug=disabled -Dinstalled_tests=false \
    -Dlibelf=disabled -Dsysprof=disabled \
    -Dwrap_mode=default   # bionic has no libintl; glib falls back to its proxy-libintl wrap (small git download)
  mark_done glib
}

# glib's .pc files point helper variables (glib-mkenums, glib-genmarshal, ...)
# at target binaries that cannot run on the build host. Redirect them to host
# tools, which QEMU's build invokes.
fix_glib_pc_tools() {
  local pc="$PREFIX/lib/pkgconfig/glib-2.0.pc" gpc="$PREFIX/lib/pkgconfig/gio-2.0.pc"
  local v tool
  for f in "$pc" "$gpc"; do
    [[ -f "$f" ]] || continue
    for pair in glib_genmarshal:glib-genmarshal glib_mkenums:glib-mkenums gdbus_codegen:gdbus-codegen \
                glib_compile_resources:glib-compile-resources glib_compile_schemas:glib-compile-schemas \
                gobject_query:gobject-query; do
      v="${pair%%:*}"; tool="${pair##*:}"
      if command -v "$tool" >/dev/null 2>&1; then
        sed -i.bak "s|^$v=.*|$v=$(command -v "$tool")|" "$f"
      fi
    done
    rm -f "$f.bak"
  done
  command -v glib-mkenums >/dev/null 2>&1 || \
    echo "warning: host glib tools (glib-mkenums, glib-genmarshal) not found; install libglib2.0-dev-bin / glib via your package manager if the QEMU configure step fails." >&2
}

build_pixman() {
  is_done pixman && return 0
  fetch "https://cairographics.org/releases/pixman-$PIXMAN_VERSION.tar.gz" "pixman-$PIXMAN_VERSION.tar.gz"
  unpack "pixman-$PIXMAN_VERSION.tar.gz" "pixman-$PIXMAN_VERSION"
  log "Building pixman"
  meson_dep pixman "$SRC_DIR/pixman-$PIXMAN_VERSION" -Dtests=disabled -Dgtk=disabled -Dlibpng=disabled
  mark_done pixman
}

build_libslirp() {
  is_done libslirp && return 0
  fetch "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v$LIBSLIRP_VERSION/libslirp-v$LIBSLIRP_VERSION.tar.gz" "libslirp-$LIBSLIRP_VERSION.tar.gz"
  unpack "libslirp-$LIBSLIRP_VERSION.tar.gz" "libslirp-v$LIBSLIRP_VERSION"
  log "Building libslirp"
  meson_dep libslirp "$SRC_DIR/libslirp-v$LIBSLIRP_VERSION"
  mark_done libslirp
}

# --------------------------------------------------------------------- QEMU -
build_qemu() {
  fetch "https://download.qemu.org/qemu-$QEMU_VERSION.tar.xz" "qemu-$QEMU_VERSION.tar.xz"
  unpack "qemu-$QEMU_VERSION.tar.xz" "qemu-$QEMU_VERSION"
  # Replace the sigsetjmp/siglongjmp coroutine backend with an assembly stack
  # switch that never calls bionic's longjmp (which SIGILLs on Android devices
  # with PAC/shadow call stack; see tools/README.md). configure still gets
  # --with-coroutine=sigaltstack, which makes meson compile this file.
  local co_patch="$SCRIPT_DIR/patches/coroutine-android-arm64.c"
  [[ -f "$co_patch" ]] || die "missing $co_patch"
  cp "$co_patch" "$SRC_DIR/qemu-$QEMU_VERSION/util/coroutine-sigaltstack.c"

  log "Configuring QEMU $QEMU_VERSION"

  local qb="$BLD_DIR/qemu"
  rm -rf "$qb"; mkdir -p "$qb"

  # The pkg-config used by QEMU is "${cross-prefix}pkg-config" from BIN_DIR.
  export PKG_CONFIG="$BIN_DIR/${TRIPLE}-pkg-config"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

  ( cd "$qb"
    "$SRC_DIR/qemu-$QEMU_VERSION/configure" \
      --cross-prefix="${TRIPLE}-" \
      --cc="$CC_BIN" --cxx="$CXX_BIN" --objcc="$CC_BIN" \
      --host-cc="${HOST_CC:-cc}" \
      --prefix=/qemu \
      --target-list=aarch64-softmmu,x86_64-softmmu \
      --extra-cflags="$COMMON_CFLAGS" \
      --extra-ldflags="$COMMON_LDFLAGS" \
      --with-coroutine=sigaltstack \
      --enable-tcg --enable-vnc --enable-slirp --enable-tools \
      --disable-kvm --disable-xen --disable-whpx --disable-hvf \
      --disable-docs --disable-guest-agent --disable-werror --disable-debug-info \
      --disable-gtk --disable-sdl --disable-sdl-image --disable-opengl --disable-virglrenderer \
      --disable-curses --disable-cocoa --disable-vte --disable-spice --disable-spice-protocol \
      --disable-vnc-sasl --disable-vnc-jpeg --disable-png --disable-dbus-display \
      --disable-libusb --disable-usb-redir --disable-smartcard --disable-u2f --disable-canokey \
      --disable-linux-aio --disable-linux-io-uring --disable-libnfs --disable-libssh \
      --disable-rbd --disable-glusterfs --disable-curl --disable-bzip2 --disable-lzo --disable-snappy \
      --disable-zstd --disable-capstone --enable-fdt=internal --disable-brlapi --disable-rdma \
      --disable-vhost-user --disable-vhost-net --disable-vhost-kernel --disable-vhost-vdpa \
      --disable-seccomp --disable-libudev --disable-attr --disable-cap-ng \
      --disable-pa --disable-alsa --disable-oss --disable-jack --disable-pipewire --disable-sndio \
      --disable-gnutls --disable-nettle --disable-gcrypt --disable-libpmem --disable-numa \
      --disable-user --disable-linux-user --disable-bsd-user \
      --audio-drv-list=
  )
  # libfdt is required by the aarch64 target; it is built from QEMU's bundled dtc.
  # qcow2 needs no flag: the block-qcow2 driver is always built in.

  log "Building QEMU"
  make -C "$qb" -j "$JOBS" qemu-system-aarch64 qemu-system-x86_64 qemu-img
}

install_outputs() {
  local qb="$BLD_DIR/qemu"
  log "Installing outputs into $JNILIBS_DIR"
  mkdir -p "$JNILIBS_DIR" "$FIRMWARE_OUT_DIR"
  for pair in qemu-system-aarch64:libqemu-system-aarch64.so \
              qemu-system-x86_64:libqemu-system-x86_64.so \
              qemu-img:libqemu-img.so; do
    local src="$qb/${pair%%:*}" dst="$JNILIBS_DIR/${pair##*:}"
    [[ -x "$src" ]] || die "build output missing: $src"
    cp "$src" "$dst"
    "$TOOLCHAIN/bin/llvm-strip" --strip-unneeded "$dst"
    chmod 755 "$dst"
    echo "  $dst"
  done

  # Runtime data (BIOS, VGA ROMs, option ROMs, keymaps). The edk2 firmware is
  # added by stage_assets, which copies everything into the app assets.
  local pcbios="$SRC_DIR/qemu-$QEMU_VERSION/pc-bios"
  shopt -s nullglob
  for f in "$pcbios"/bios*.bin "$pcbios"/vgabios*.bin "$pcbios"/efi-*.rom "$pcbios"/kvmvapic.bin \
           "$pcbios"/linuxboot*.bin "$pcbios"/multiboot*.bin "$pcbios"/pvh.bin; do
    cp "$f" "$FIRMWARE_OUT_DIR/"
  done
  shopt -u nullglob
  [[ -d "$pcbios/keymaps" ]] && cp -R "$pcbios/keymaps" "$FIRMWARE_OUT_DIR/"
  echo "  runtime data: $FIRMWARE_OUT_DIR"
}

verify_outputs() {
  log "Verifying outputs"
  if command -v file >/dev/null 2>&1; then
    file "$JNILIBS_DIR"/libqemu-*.so
  fi
  "$TOOLCHAIN/bin/llvm-readelf" -h "$JNILIBS_DIR/libqemu-img.so" | grep -E 'Machine|Type' || true
}

# ------------------------------------------------------------------- main ---
log "NDK=$NDK API=$ANDROID_API QEMU=$QEMU_VERSION WORK_DIR=$WORK_DIR JOBS=$JOBS"
build_zlib
build_libffi
build_pcre2
build_glib
fix_glib_pc_tools
build_pixman
build_libslirp
build_qemu
install_outputs
stage_assets
verify_outputs
log "Done. Rebuild the app (flutter build apk) so the binaries are packaged."
