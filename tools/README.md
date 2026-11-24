# QEMU for Android build tooling

`build-qemu-android.sh` cross-compiles `qemu-system-aarch64`,
`qemu-system-x86_64` and `qemu-img` for `arm64-v8a` with the Android NDK and
installs them as `libqemu-*.so` in `android/app/src/main/jniLibs/arm64-v8a/`.

> **Status: run end-to-end on macOS (Apple Silicon), NDK 27.1.12297006.**
> The script produced `libqemu-img.so` (3.1 MB), `libqemu-system-aarch64.so`
> (33.7 MB) and `libqemu-system-x86_64.so` (28.0 MB), all stripped
> `ELF 64-bit ... ARM aarch64` PIE executables linked only against
> `libc.so`, `libm.so` and `libdl.so`. `flutter build apk --debug` packages all
> three under `lib/arm64-v8a/`. The binaries have **not** been booted on a
> device or emulator yet (a macOS host cannot execute them); treat runtime
> behavior as unverified.

### Fixes made on the first real run
- **zlib:** its `configure` detected the macOS host and picked Apple `libtool`
  as `AR`, producing an empty `libz.a`. Now passes `CHOST=aarch64-linux-android`.
- **glib:** removed the nonexistent `-Dintrospection` option; added
  `-Dwrap_mode=default` for glib only so it can fetch its tiny `proxy-libintl`
  wrap (bionic has no libintl). Default bumped 2.78.6 to 2.80.5 because 2.78
  imports `distutils`, which is gone in new Pythons.
- **Python:** the script now creates a venv in `$WORK_DIR/venv` (Homebrew Python
  is externally managed) with `packaging`, `setuptools`, `distlib` and `meson`,
  and puts it first on `PATH`. glib needs `packaging` visible to meson, and QEMU's
  configure fails on Python 3.15, so the venv prefers python3.12/3.13/3.11
  (override with `VENV_PYTHON`).
- **pixman:** removed the nonexistent `-Ddemos` option; default bumped 0.42.2 to
  0.43.4 because 0.42.2's aarch64 NEON assembly (`.endfunc`) does not assemble
  with the NDK's clang.
- **QEMU:** added `--disable-dbus-display`. Homebrew's newer `gdbus-codegen`
  emits code that needs glib 2.84 headers, which break against the 2.80 target glib.

### SIGILL crash in coroutines on real devices (fixed)
- **Symptom:** on a phone with PAC/BTI/shadow call stack (vivo, MediaTek MT6985,
  Android 16) `qemu-system-aarch64 -accel tcg` died about 3 s after the UEFI
  firmware started, with `SIGILL (ILL_ILLOPN)` in bionic `libc.so longjmp+456`,
  called from a chain of frames in QEMU's coroutine code (`0x117e3ac`, `0x117e740`, ...).
- **Cause:** QEMU's only portable backend for bionic, `--with-coroutine=sigaltstack`,
  switches coroutine stacks with `sigsetjmp()`/`siglongjmp()` (after a one-time
  `sigaltstack` signal trick to enter the new stack). Modern bionic `longjmp`
  checks the jmp_buf cookie and the shadow call stack/PAC state of the stack it
  jumps to. Jumping between hand-made stacks trips that check and executes an
  invalid instruction. bionic has no `makecontext`/`swapcontext`, so the
  `ucontext` backend is unavailable.
- **Fix:** `tools/patches/coroutine-android-arm64.c` is a small arm64 backend with
  an inline-assembly stack switch (saves x19-x30 and d8-d15, swaps `sp`, never
  calls libc, leaves x18 alone). `build_qemu` copies it over
  `util/coroutine-sigaltstack.c` in the QEMU source and still passes
  `--with-coroutine=sigaltstack`, so meson compiles the replacement. The
  remaining `sigsetjmp`/`siglongjmp` uses (TCG `cpu_exec` and similar) stay on one
  stack, which bionic accepts. Extra flags such as `-mbranch-protection=none` or
  `-fno-sanitize=shadow-call-stack` were not added: the cause was the stack
  switch, and the NDK does not enable these by default.
- **Rebuild:** `WORK_DIR=/tmp/qemu-android-build ANDROID_NDK_HOME=... tools/build-qemu-android.sh`
  (dependencies in `$WORK_DIR/prefix` are reused; the QEMU rebuild takes about 3 minutes).
  Verify with `llvm-objdump -d --disassemble-symbols=coroutine_asm_switch` on the
  unstripped `$WORK_DIR/build/qemu/qemu-system-aarch64`.
- **Status:** built and checked in the disassembly, not yet run on a device (task 17.2).

### Environment used
`brew install meson pkg-config` (Homebrew also pulled in Python 3.15 as a
dependency), `ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/27.1.12297006`, and
`WORK_DIR=/tmp/qemu-android-build` to keep the build off the repo. The full build took only a
few minutes with all cores. Peak work-dir use was about 1.5 GB (sources, build
trees, prefix); after cleaning, only `out/qemu-share` (about 3 MB) remains.
Set `WORK_DIR` to a disk with at least 2 GB free.

## What the script does

1. Downloads and builds static dependencies into `$WORK_DIR/prefix`:
   zlib, libffi, pcre2, glib (meson), pixman (meson), libslirp (meson).
   Meson builds use a generated cross file (`android-arm64.cross`) that points
   at the NDK clang and a `pkg-config` wrapper limited to the prefix and run
   with `--static`.
2. Rewrites glib's `.pc` helper variables (`glib-mkenums`, ...) to host tools,
   because the target-built ones cannot run on the build machine.
3. Configures QEMU with `--cross-prefix` (symlinks to the NDK `llvm-*` tools are
   created for this), targets `aarch64-softmmu,x86_64-softmmu`, TCG only, VNC
   and slirp enabled, and GTK/SDL/OpenGL/audio/USB/curses and other optional
   features disabled. qcow2 is always built in.
4. Copies the three binaries, stripped, into `jniLibs/arm64-v8a` as
   `libqemu-system-aarch64.so`, `libqemu-system-x86_64.so`, `libqemu-img.so`.
   These are ordinary executables with a `.so` name so Android extracts them
   to `nativeLibraryDir` (the app sets `useLegacyPackaging = true`); they are run
   as processes, not loaded.
5. Stages QEMU's runtime data (BIOS, VGA BIOS, option ROMs, keymaps) in
   `$WORK_DIR/out/qemu-share`, then copies it into the app assets
   (`android/app/src/main/assets/qemu/`) together with the edk2 aarch64
   firmware `QEMU_EFI.fd` (see "Firmware and share assets").

## Prerequisites

- Android NDK r26 or newer (set `ANDROID_NDK_HOME`).
- Host tools: `bash`, `curl`, `tar`, `xz`, `make`, `python3` with `venv`,
  `meson`, `ninja`, `pkg-config`, and a host C compiler.
- Host glib tools (`glib-mkenums`, `glib-genmarshal`; package
  `libglib2.0-dev-bin` on Debian/Ubuntu, `glib` on Homebrew).
- Network access to zlib.net, github.com, download.gnome.org,
  cairographics.org, gitlab.freedesktop.org and download.qemu.org.
- Roughly 2 GB of disk for the work directory (delete `src`, `build`, `downloads`, `prefix` and `venv` afterwards; keep `out/`).

## Usage

```sh
export ANDROID_NDK_HOME=$HOME/Library/Android/sdk/ndk/27.1.12297006
./tools/build-qemu-android.sh
flutter build apk      # or flutter run, to repackage with the new binaries
```

Completed dependency steps are recorded in `$WORK_DIR/build/.done-*`; delete
that file (or `$WORK_DIR`) to rebuild a step.

## Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `ANDROID_NDK_HOME` (or `ANDROID_NDK_ROOT`) | none, required | NDK path |
| `ANDROID_API` | `29` | Toolchain API level (keep 28 or higher for bionic iconv) |
| `QEMU_VERSION` | `9.0.2` | QEMU release tarball to download |
| `WORK_DIR` | `tools/.build-qemu-android` | Downloads, builds, dependency prefix |
| `JOBS` | CPU count | Parallel jobs |
| `JNILIBS_DIR` | `android/app/src/main/jniLibs/arm64-v8a` | Install destination |
| `FIRMWARE_OUT_DIR` | `$WORK_DIR/out/qemu-share` | Staged QEMU runtime data |
| `ASSETS_DIR` | `android/app/src/main/assets/qemu` | App asset destination |
| `EDK2_DEB_VERSION`, `EDK2_DEB_SHA256`, `EDK2_DEB_URL` | Debian 13 `2025.02-8+deb13u1` | edk2 aarch64 package to fetch |
| `HOST_CC` | `cc` | Host compiler passed to QEMU |
| `VENV_PYTHON` | python3.12, 3.13, 3.11, then python3 | Python used for the build venv |
| `ZLIB_VERSION`, `LIBFFI_VERSION`, `PCRE2_VERSION`, `GLIB_VERSION`, `PIXMAN_VERSION`, `LIBSLIRP_VERSION` | see script | Dependency versions |

## Firmware and share assets
`stage_assets` (runs at the end of a full build, or alone with `--firmware-only`)
rebuilds `android/app/src/main/assets/qemu/` from scratch:

- the QEMU share files from `$FIRMWARE_OUT_DIR` (BIOS, VGA ROMs, option ROMs, keymaps);
- `QEMU_EFI.fd` (3 MiB edk2 aarch64 firmware) and its `QEMU_EFI.copyright`, taken from
  the Debian `qemu-efi-aarch64` package. The `.deb` is downloaded to
  `$WORK_DIR/downloads`, checked against `EDK2_DEB_SHA256`, and unpacked with
  `ar` and `tar` (works on macOS, no `dpkg`). The image is used as is with
  `-bios`; padding to 64 MiB is only needed for a pflash drive;
- a `VERSION` file (`qemu=<ver> edk2=<ver>`). The app copies the assets to
  `<documents>/qemu` on start and recopies only when this marker changes.

`--firmware-only` skips the QEMU build and needs no NDK, only `curl`, `tar`, `ar`,
`xz` and `shasum`/`sha256sum`. It reuses the share files already in `$FIRMWARE_OUT_DIR`:

```sh
WORK_DIR=/tmp/qemu-android-build ./tools/build-qemu-android.sh --firmware-only
```

The work directory and cleanup rules are unchanged: only `out/` needs to survive;
`downloads/` and `build/` may be deleted. The assets add about 6 MB to the source tree
and about 15 KB to the debug APK (the zero-filled firmware compresses well; the share
files were already counted). The app passes `-L <documents>/qemu` for all guests
and `-bios <documents>/qemu/QEMU_EFI.fd` for aarch64 guests. Debian's pool drops
superseded versions, so if the pinned `.deb` URL 404s, set `EDK2_DEB_VERSION` and
`EDK2_DEB_SHA256` together.

## Firmware and data paths

QEMU finds its data files (BIOS, ROMs, keymaps) relative to a compiled-in
prefix, which does not exist on Android. The app must pass the directory
explicitly with `-L <dir>`, using a directory the app can read (for example
files copied from assets into the app's files directory).

- **x86_64 (legacy BIOS):** copy the contents of `$WORK_DIR/out/qemu-share`
  (`bios-256k.bin`, `vgabios-*.bin`, `efi-*.rom`, `kvmvapic.bin`, `linuxboot*.bin`,
  `keymaps/`, ...) into that directory and use `-L`.
- **x86_64 (UEFI):** get OVMF (`OVMF_CODE.fd` / `OVMF_VARS.fd`) from a distro
  package such as Debian `ovmf` (`/usr/share/OVMF/`) or the edk2 nightly builds
  at <https://retrage.github.io/edk2-nightly/>. Pass it with
  `-drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd` and a writable
  copy of `OVMF_VARS.fd`.
- **aarch64 (UEFI):** get `QEMU_EFI.fd` from Debian `qemu-efi-aarch64`
  (`/usr/share/qemu-efi-aarch64/QEMU_EFI.fd`) or the edk2 nightly builds. Use it
  with `-bios QEMU_EFI.fd` or as a pflash drive (pad it to 64 MiB for pflash).
- Bundle the firmware in the app assets (for example `assets/firmware/`) and copy
  it to the app files directory on first run, then reference it by absolute path.
  Do not commit firmware blobs here; check their licenses (OVMF/edk2 is
  BSD-2-Clause-Patent) before shipping.

## Installing the result

The script already copies the binaries to `jniLibs/arm64-v8a`. Only that ABI
directory is allowed. Rebuild the app afterwards so Gradle packages them. Run
`file android/app/src/main/jniLibs/arm64-v8a/*.so` and confirm each reports
`ELF 64-bit ... ARM aarch64`.

## License obligations

If you distribute an APK that contains these binaries you must comply with the
licenses of everything in them:

- **QEMU:** GPLv2 (some parts under other licenses). Provide the corresponding
  source for the exact version built (the QEMU tarball plus any patches), keep
  copyright notices, and ship the GPLv2 text.
- **Dependencies:** glib (LGPL-2.1+), libslirp (BSD-3-Clause), pixman (MIT),
  libffi (MIT), pcre2 (BSD-3-Clause with a PCRE2 exemption), zlib (zlib
  license). Keep each license notice and provide source or a written offer
  as each license requires. LGPL glib is linked statically here, so recipients
  must be able to relink; providing the build script and dependency sources
  covers this.
- Include the license texts and this build script (and the exact versions used)
  with distributed binaries, for example in an in-app "Open source licenses"
  screen and in your repository or release notes.
- Firmware (OVMF/edk2, QEMU_EFI) has its own licenses; check them separately.

This is a summary, not legal advice.
