# Native QEMU binaries (arm64-v8a only)
Place QEMU executables here, named as shared libraries so Android extracts
them to `nativeLibraryDir` (`useLegacyPackaging = true`). They are executed as
processes, not loaded with `System.loadLibrary`. Executables must be renamed to
`libqemu-*.so`.
Expected files:
- `libqemu-system-aarch64.so`  (ARM64 guests)
- `libqemu-system-x86_64.so`   (x86_64 guests)
- `libqemu-img.so`             (qcow2 create, info, snapshots)
Any additional `libqemu-system-*.so` follows the same naming. Binaries must be
built for arm64-v8a. No other ABI directory is allowed.

Build them with `tools/build-qemu-android.sh` (see `tools/README.md`). That
script has not been run end-to-end and is untested. QEMU also needs its data
and firmware directory passed with `-L`, and UEFI firmware (`QEMU_EFI.fd`,
OVMF) bundled in app assets; the tools README explains where to get them.
