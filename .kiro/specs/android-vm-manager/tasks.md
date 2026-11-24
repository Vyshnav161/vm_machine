# Implementation Plan: Android VM Manager

## Overview

The plan builds the app bottom-up. Pure Dart logic (domain, validation, state machine, serializer, policies, builders) comes first, with property tests next to each unit. Kotlin platform services (QEMU supervision, QMP, RFB display, host probing, storage, signals) come next, followed by the Dart service layer and the `VmManagerController` that joins them. The UI and final wiring come last. Language: Dart (Flutter) for app code, Kotlin for the Android layer, as specified in the design. Property tests use `glados` with at least 100 runs, and each test carries the comment `// Feature: android-vm-manager, Property N: <text>`.

## Tasks

- [x] 1. Set up project structure and test tooling
  - Create the Flutter project `vm_machine` (Android only) in the workspace root if it does not exist
  - Add dependencies: `flutter_riverpod`, `path_provider`, `path`, `uuid`; dev dependencies: `glados`, `flutter_test`
  - Create directories `lib/domain/`, `lib/data/`, `lib/services/`, `lib/controller/`, `lib/ui/`, `test/properties/`, `test/unit/`, `test/widget/`, `test/fakes/`
  - Configure `android/app/build.gradle` for `abiFilters "arm64-v8a"` and `useLegacyPackaging = true` for native libraries
  - _Requirements: 5.1, 7.1_

- [x] 2. Implement domain models and compatibility evaluation
  - [x] 2.1 Create core domain types and models
    - Implement enums `GuestOs`, `GuestArch`, `AccelerationMode`, `VmState`, `NetworkMode`, `MediaStatus`, and `Detected<T>` (`Known`, `Unknown`)
    - Implement `HostCapabilities`, `VmProfile`, `DiskRef`, `MediaRef`, `NetworkConfig`, `PortForward`, `SharedFolder`, `SnapshotInfo`, with `copyWith` and value equality
    - Pure Dart only: no Flutter, `dart:io`, or channel imports in `lib/domain/`
    - _Requirements: 1.7, 3.1, 10.1_

  - [x] 2.2 Implement `CompatibilityEvaluator`, `EngineCatalog`, and `RecommendedDefaults`
    - One entry per `(GuestOs, GuestArch)` pair with mode, warnings, and `blockedReason`
    - ARM64 guest on known ARM64 host uses hardware virtualization only when `Known(true)`; every other runnable entry uses software emulation
    - Add `reducedPerformance` warning for x86_64 guest on non-x86_64 host, and `notRecommendedLowRam` for Windows and macOS below 4 GiB
    - Keep `Unknown` values in the report and never block on them
    - Defaults: Linux 2 vCPU/2048 MiB/16 GiB; Windows and macOS 4 vCPU/4096 MiB/64 GiB
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.7, 2.7, 3.2_

  - [ ]* 2.3 Write property test for compatibility report
    - **Property 1: Compatibility report completeness and mode selection**
    - **Validates: Requirements 1.2, 1.3, 1.4**

  - [ ]* 2.4 Write property test for low-RAM warning
    - **Property 2: Low-RAM warning**
    - **Validates: Requirements 1.5**

- [x] 3. Implement profile validation and start eligibility
  - [x] 3.1 Implement `ProfileDraft`, `ValidationIssue`, `ProfileValidator`, and `StartEligibility`
    - Validate name (non-empty, unique case-insensitive), memory at most 75 percent of RAM, vCPU at most core count, disk at most free storage, at least one media entry, host ports 1024..65535, macOS license acknowledgment
    - Report the limit in each memory, CPU, and disk issue; include the "Android apps cannot bind ports below 1024" message
    - Skip rules whose host value is `Unknown`
    - `StartEligibility.check` blocks non-runnable combinations and combined running memory above 75 percent of known host RAM
    - _Requirements: 2.2, 2.5, 2.7, 3.4, 3.5, 3.6, 3.7, 3.8, 5.9, 11.3_

  - [ ]* 3.2 Write property test for unknown values
    - **Property 3: Unknown values do not block creation**
    - **Validates: Requirements 1.7**

  - [ ]* 3.3 Write property test for start eligibility
    - **Property 4: Start eligibility**
    - **Validates: Requirements 2.7, 5.9**

  - [ ]* 3.4 Write property test for validation
    - **Property 5: Validation accepts exactly the valid drafts**
    - **Validates: Requirements 2.2, 2.5, 3.4, 3.5, 3.6, 3.7, 3.8, 11.3**

  - [ ]* 3.5 Write property test for validation limits
    - **Property 6: Validation issues report the limit**
    - **Validates: Requirements 3.5, 3.6, 3.7**

  - [ ]* 3.6 Write unit tests for defaults and boundaries
    - Per-OS defaults, exact boundaries at 4 GiB RAM, 75 percent memory, 1023 and 1024 ports
    - _Requirements: 1.5, 3.2, 3.5, 11.3_

- [x] 4. Implement the VM lifecycle state machine
  - [x] 4.1 Implement `VmEvent`, `VmTransition`, and `VmStateMachine`
    - Encode the transition table from the design, including restart via `Starting` and `Running` through `engineReady`
    - Reject illegal events with `accepted: false` and an unchanged state
    - `NetworkChanged` never changes state; crash from `starting`, `running`, `paused`, or `stopping` yields `error` with the reason
    - _Requirements: 5.2, 5.3, 5.7, 5.8, 11.4_

  - [ ]* 4.2 Write property test for legal transitions
    - **Property 14: Lifecycle transitions are legal**
    - **Validates: Requirements 5.7, 11.4**

  - [ ]* 4.3 Write property test for pause and resume
    - **Property 15: Pause and resume round trip**
    - **Validates: Requirements 5.2, 5.3**

  - [ ]* 4.4 Write property test for crash handling
    - **Property 16: Crash yields Error and leaves the disk unchanged**
    - **Validates: Requirements 5.8**

- [x] 5. Implement media and storage logic
  - [x] 5.1 Implement `MediaFilter`, `StorageCheck`, `CopyProgress`, `StorageOverview`, `MediaPreflight`, and attach/detach helpers
    - `MediaFilter.accepts` handles `.iso`, `.img`, `.qcow2`, `.vhdx` case-insensitively; the rejection message lists supported formats
    - `StorageCheck.hasRoom` returns a message containing required and available bytes on failure
    - `CopyProgress.percent` returns 0..100; `StorageOverview.total` sums disks, snapshots, and copied media
    - `MediaPreflight.missing` returns missing paths; it also marks imported items `Missing`
    - Attach and detach change only the profile, never files
    - _Requirements: 4.1, 4.3, 4.4, 4.5, 4.6, 4.7, 8.7, 9.4, 10.9_

  - [ ]* 5.2 Write property test for media filter
    - **Property 9: Media format filter**
    - **Validates: Requirements 4.4**

  - [ ]* 5.3 Write property test for copy progress
    - **Property 10: Copy progress is well formed**
    - **Validates: Requirements 4.3**

  - [ ]* 5.4 Write property test for storage sufficiency
    - **Property 11: Storage sufficiency check**
    - **Validates: Requirements 4.6, 9.4**

  - [ ]* 5.5 Write property test for missing file detection
    - **Property 12: Missing file detection**
    - **Validates: Requirements 4.5, 10.9**

  - [ ]* 5.6 Write property test for attach then detach
    - **Property 13: Attach then detach round trip**
    - **Validates: Requirements 4.7**

  - [ ]* 5.7 Write property test for storage overview
    - **Property 25: Storage overview total**
    - **Validates: Requirements 8.7**

- [x] 6. Implement serialization, persistence, and library logic
  - [x] 6.1 Implement `ProfileSerializer` (Profile_Printer and parser)
    - Deterministic pretty-printed JSON with sorted keys and `schemaVersion: 1`; no disk content; `status` fields not serialized
    - `parse` returns `Success` or `Failure(ParseError)` naming the invalid field or unsupported version
    - _Requirements: 10.5, 10.6, 10.7, 10.8_

  - [x] 6.2 Implement `VmRepository`, `FileVmRepository`, `MemoryVmRepository`, `LibrarySearch`, and `CloneNamer`
    - `FileVmRepository` writes `<appDocs>/vms/<id>/profile.json` atomically (temp file, then rename)
    - `LibrarySearch.filter` is a case-insensitive contains match; an empty query returns all
    - `CloneNamer.uniqueName` yields `"<name> copy"`, `"<name> copy 2"`, and so on
    - Import assigns a fresh id when the id already exists
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.6_

  - [ ]* 6.3 Write property test for serialization round trip
    - **Property 30: Profile serialization round trip**
    - **Validates: Requirements 10.5, 10.6, 10.8**

  - [ ]* 6.4 Write property test for malformed files
    - **Property 31: Malformed profile files are rejected with the offending field or version**
    - **Validates: Requirements 10.7**

  - [ ]* 6.5 Write property test for library persistence
    - **Property 8: Profile library persistence round trip**
    - **Validates: Requirements 3.3, 10.1**

  - [ ]* 6.6 Write property test for library search
    - **Property 28: Library search**
    - **Validates: Requirements 10.3**

  - [ ]* 6.7 Write property test for clone naming
    - **Property 29: Clone**
    - **Validates: Requirements 10.4**

- [x] 7. Implement launch, resource policy, input, and diagnostics logic
  - [x] 7.1 Implement `LaunchSpec` and `LaunchSpecBuilder`
    - Build QEMU argv: `-machine`, `-accel tcg|kvm`, `-smp`, `-m`, one `-drive` per disk and media item, user-mode netdev with `hostfwd=tcp::H-:G`, `-virtfs` or `smb=` shares, `-qmp unix:`, `-vnc unix:`, `-serial file:`, `-display none`
    - Select `virtio-net` or `e1000` by guest OS; use `q35` for x86_64 and `virt` with UEFI for ARM64
    - _Requirements: 5.1, 11.1, 11.2, 11.5, 12.2_

  - [ ]* 7.2 Write property test for launch spec
    - **Property 17: Launch spec reflects the profile**
    - **Validates: Requirements 5.1, 11.1, 11.2, 11.5**

  - [x] 7.3 Implement `ResourcePolicy`, `HostSignals`, `BatterySaver`, `CrossArchIndicator`, `NotificationText`, and `StatsOverlay`
    - Thermal `severe` or higher pauses all running VMs plus one notice; battery at most 15 percent and not charging with a VM running notifies; trim level 15 or higher snapshots (if supported) then pauses; free storage below 500 MB pauses and warns
    - Never target a VM that is not running
    - `BatterySaver.effectiveCpuCap` returns half the vCPU count when enabled
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.7, 8.6_

  - [ ]* 7.4 Write property test for status text
    - **Property 20: Status text contains required information**
    - **Validates: Requirements 7.1, 7.2**

  - [ ]* 7.5 Write property test for cross-architecture indicator
    - **Property 21: Cross-architecture indicator**
    - **Validates: Requirements 7.3**

  - [ ]* 7.6 Write property test for resource policy
    - **Property 22: Resource policy**
    - **Validates: Requirements 7.4, 7.5, 7.6, 8.6**

  - [ ]* 7.7 Write property test for battery saver cap
    - **Property 23: Battery saver CPU cap**
    - **Validates: Requirements 7.7**

  - [x] 7.8 Implement `GestureTranslator`, `KeyMapper`, and `SpecialKeys`
    - Tap is left click; long press or two-finger tap is right click; two-finger vertical drag is scroll; single-finger drag moves the pointer
    - Scale to guest resolution and clamp to its bounds
    - Map Android key codes to X11 keysyms, each key-down paired with a key-up; `SpecialKeys.ctrlAltDel` returns ordered down and up events; include Ctrl, Alt, Shift, Esc, Tab, Windows/Command
    - _Requirements: 6.2, 6.3, 6.6_

  - [ ]* 7.9 Write property test for gesture translation
    - **Property 18: Gesture translation**
    - **Validates: Requirements 6.2**

  - [ ]* 7.10 Write property test for key mapping
    - **Property 19: Key mapping**
    - **Validates: Requirements 6.3**

  - [x] 7.11 Implement `StartFailure`, `FailureMessage`, `VmError`, and `LogRotator`
    - `FailureMessage.format` includes step and cause, and appends the slow-boot hint only when `crossArch` is true
    - `LogRotator.rotate` keeps the last `min(total, maxBytes)` bytes; inject the 10 MiB limit
    - _Requirements: 12.1, 12.5, 12.6_

  - [ ]* 7.12 Write property test for failure messages
    - **Property 33: Failure messages**
    - **Validates: Requirements 12.1, 12.6**

  - [ ]* 7.13 Write property test for log rotation
    - **Property 34: Log rotation keeps the most recent bytes**
    - **Validates: Requirements 12.5**

- [x] 8. Implement the Kotlin platform layer
  - [x] 8.1 Declare manifest entries and native binary layout
    - Add foreground service declaration with type `specialUse` and justification, `FOREGROUND_SERVICE`, `POST_NOTIFICATIONS`, and `FOREGROUND_SERVICE_SPECIAL_USE` permissions
    - Create `android/app/src/main/jniLibs/arm64-v8a/` with a README listing the expected `libqemu-system-*.so` and `libqemu-img.so` names
    - _Requirements: 7.1, 7.8_

  - [x] 8.2 Implement `HostProbe`
    - Read `Build.SUPPORTED_ABIS`, `ActivityManager.MemoryInfo`, `StatFs`, `availableProcessors()`, `/dev/kvm` access, and AVF system feature
    - Return null for unreadable values
    - _Requirements: 1.1, 1.7_

  - [x] 8.3 Implement `QmpClient`
    - Connect to the Unix socket with a 30 s timeout; send `stop`, `cont`, `system_reset`, `system_powerdown`, `quit`, `savevm`, `loadvm`, `query-status`, `query-cpus-fast`
    - Forward `SHUTDOWN`, `RESET`, `STOP`, `RESUME` events
    - _Requirements: 5.2, 5.3, 5.4, 5.6, 9.1_

  - [x] 8.4 Implement `EngineSupervisor`
    - Spawn QEMU from `nativeLibraryDir`, pipe stderr and serial output to the log file, wait for exit, map exit code and signal to a reason
    - Force stop with `SIGKILL` and verify the process is dead within 5 s
    - Duty-cycle CPU limiter for battery saver; clean up stale sockets and mark VM `Error` after app termination
    - Run `qemu-img` for create (`qcow2`, `preallocation=off`), info, and snapshot operations; restore against a temp copy and replace the live disk only on success
    - _Requirements: 5.1, 5.5, 5.8, 7.7, 8.1, 8.2, 9.2, 9.5, 12.2_

  - [x] 8.5 Implement `VmForegroundService`
    - Persistent notification with VM name and state, continues while the app is in the background
    - _Requirements: 7.1, 7.8_

  - [x] 8.6 Implement `RfbClient` and the `vm/display` texture
    - Connect to the VNC Unix socket, decode framebuffer updates into a `SurfaceTexture`, send pointer and key events, handle desktop resize, and save PNG screenshots
    - _Requirements: 6.1, 6.2, 6.3, 6.5, 6.7_

  - [x] 8.7 Implement `HostSignalMonitor`
    - Thermal listener, battery broadcasts, `onTrimMemory`, periodic free-storage poll, and network connectivity; emit on the `vm/hostSignals` EventChannel
    - _Requirements: 7.4, 7.5, 7.6, 8.6, 11.4_

  - [x] 8.8 Implement `StorageAccess`
    - SAF file picker with extension filter, persisted URI permissions, `/proc/self/fd/N` resolution, copy with progress, free space, removable volumes via `StorageManager`, share-sheet for logs, and `ACTION_VIEW` for distribution URLs
    - _Requirements: 2.6, 4.1, 4.2, 4.3, 4.6, 8.5, 12.4_

  - [x] 8.9 Implement `DisplayMirror`
    - Present the guest texture on an external display using `DisplayManager` and `Presentation`
    - _Requirements: 6.8_

  - [x] 8.10 Register platform channels in `MainActivity`
    - Register `vm/host`, `vm/engine`, `vm/files`, `vm/display` method channels and `vm/events`, `vm/hostSignals` event channels with the payloads from the design
    - _Requirements: 1.1, 5.1, 6.1, 7.1_

  - [ ]* 8.11 Write Kotlin unit tests
    - QMP command encoding and event parsing, exit reason mapping, RFB pixel decoding on fixture frames
    - _Requirements: 5.4, 5.6, 5.8, 6.1_

- [x] 9. Implement the Dart service layer and `VmManagerController`
  - [x] 9.1 Define service interfaces, channel implementations, and fakes
    - Abstract `HostProbeService`, `EngineService`, `FileService`, `DisplayService`, `HostSignalService`
    - Method and event channel implementations matching the channel contract
    - Fakes in `test/fakes/`: `FakeHostProbe`, `FakeEngineService` (records QMP commands, fails on demand), `FakeFileSystem`
    - Riverpod providers for each service
    - _Requirements: 1.1, 5.1, 6.1, 7.1_

  - [x] 9.2 Implement controller start and lifecycle operations
    - Start sequence: `StartEligibility`, `MediaPreflight`, `LaunchSpecBuilder`, then `EngineService.start`; failures become `StartFailure` and a `FailureMessage`
    - Pause, resume, shutdown (`system_powerdown`), force stop (after confirmation), restart (`system_reset`), and `VmStateMachine` event handling for engine events
    - On unexpected exit set `Error` with the exit reason and write nothing to disk images
    - _Requirements: 2.7, 4.5, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 12.1, 12.6_

  - [x] 9.3 Implement controller library and media operations
    - Create (validate, save profile, create qcow2 disk, removable storage option), edit (powered off only, same validation), delete (profile, disks, snapshots, copied media; keep referenced media), clone, search, export and import
    - Attach and detach media, copy with progress and storage pre-check, remove shared folder without touching files
    - Compatibility detection on first start and refresh
    - _Requirements: 1.1, 1.6, 3.3, 3.8, 3.9, 4.2, 4.3, 4.6, 4.7, 8.1, 8.3, 8.4, 8.5, 10.1, 10.4, 10.5, 10.6, 10.7, 10.9, 11.6_

  - [x] 9.4 Implement controller snapshots, host-signal handling, and diagnostics
    - Snapshot create (with `StorageCheck`), restore (powered off, after confirmation), delete; name and timestamp stored in `snapshots.json`
    - Apply `ResourcePolicy` actions from `HostSignalService` (pause, snapshot, notify); mark guest network disconnected without changing VM state
    - Log viewing and sharing, and the stats stream
    - _Requirements: 7.2, 7.4, 7.5, 7.6, 8.6, 9.1, 9.2, 9.3, 9.4, 9.5, 11.4, 12.2, 12.3, 12.4_

  - [ ]* 9.5 Write property test for edit rejection
    - **Property 7: Running VMs reject edits**
    - **Validates: Requirements 3.9**

  - [ ]* 9.6 Write property test for VM deletion
    - **Property 24: Delete removes VM data and keeps referenced media**
    - **Validates: Requirements 8.3, 8.4**

  - [ ]* 9.7 Write property test for snapshot add and delete
    - **Property 26: Snapshot add and delete**
    - **Validates: Requirements 9.1, 9.3**

  - [ ]* 9.8 Write property test for failed restore
    - **Property 27: Failed restore leaves the disk unchanged**
    - **Validates: Requirements 9.5**

  - [ ]* 9.9 Write property test for shared folder removal
    - **Property 32: Shared folder removal keeps files**
    - **Validates: Requirements 11.6**

  - [ ]* 9.10 Write unit tests for controller commands
    - Shutdown sends `system_powerdown`, restart sends `system_reset`, force stop sends no QMP and kills the process
    - `qemu-img create` arguments use `qcow2` and `preallocation=off`; `qemu-img info` fixture parsing; media attach in place versus copy; removable storage option only when a volume exists
    - _Requirements: 4.2, 5.4, 5.5, 5.6, 8.1, 8.2, 8.5_

- [x] 10. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 11. Implement the user interface
  - [x] 11.1 Create app shell, routing, theme, and Riverpod providers
    - `MaterialApp` with routes for library, compatibility report, create/edit form, VM details, console, storage overview, logs
    - Providers exposing controller state and VM states
    - _Requirements: 10.2_

  - [x] 11.2 Implement the compatibility report screen
    - Show host values (with `Unknown`), entries with modes and warnings, and a refresh action
    - _Requirements: 1.2, 1.3, 1.4, 1.5, 1.6, 1.7_

  - [x] 11.3 Implement the VM library screen
    - List name, guest OS, architecture, and state; search field; start, clone, delete (with confirmation), export and import actions
    - _Requirements: 5.7, 8.3, 10.2, 10.3, 10.4, 10.5, 10.6_

  - [x] 11.4 Implement the create and edit VM form
    - Fields for name, OS, architecture, vCPU, memory, disk size, storage location, media, network and port forwards, shared folders, battery saver
    - Pre-fill defaults on OS change; show validation issues with limits; Windows license notice; macOS experimental notice with required acknowledgment gating the save button; Linux distribution list that opens official `https` download pages
    - Disable fields while the VM is running
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.1, 3.2, 3.4, 3.5, 3.6, 3.7, 3.9, 11.2, 11.3_

  - [x] 11.5 Implement media attach and storage overview screens
    - File picker with copy option and progress, unsupported format message, detach action
    - Per-VM virtual and actual disk size, and the total across VMs, snapshots, and copied media
    - _Requirements: 4.1, 4.3, 4.4, 4.6, 4.7, 8.1, 8.7_

  - [x] 11.6 Implement the VM console
    - `Texture` display, gesture and keyboard input, special keys sheet, external keyboard and mouse forwarding, orientation resize without restart, screenshot action, external display toggle
    - Stats overlay with CPU, memory, and mode; cross-architecture indicator; pause, resume, shutdown, restart, and force stop controls
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 6.8, 7.2, 7.3_

  - [x] 11.7 Implement the snapshots and logs screens
    - Snapshot list with create, restore, and delete using confirmations and error display
    - Log viewer and share action; startup error dialog with step, cause, and hint
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 12.1, 12.3, 12.4_

  - [ ]* 11.8 Write widget tests
    - Creation form fields and pre-fill, macOS acknowledgment gate, library rows and search, compatibility report with warnings, orientation change without engine start or stop, logs viewer
    - _Requirements: 1.2, 2.5, 3.1, 3.2, 6.5, 10.2, 10.3, 12.3_

- [x] 12. Wire the application together
  - [x] 12.1 Wire `main.dart` and the dependency graph
    - Provide the channel-backed services, `FileVmRepository`, and controller through Riverpod overrides in `main`
    - Run capability detection on first launch, show the compatibility report, then the library
    - Reconcile stale VM runtime state after app restart
    - _Requirements: 1.1, 1.2, 5.8, 10.1, 10.2_

  - [ ]* 12.2 Write smoke tests
    - Verify the manifest declares the foreground service type and permissions, native libraries exist only under `arm64-v8a`, and no Windows or macOS media is bundled in assets
    - Verify the Linux distribution catalog contains only official `https` URLs
    - _Requirements: 2.2, 2.6, 7.1_

- [x] 13. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [x] 14. Post-release fixes and QEMU engine packaging
  - [x] 14.1 Fix media display name and the "in place" label
    - Make `StorageAccess.onPickResult` return `OpenableColumns.DISPLAY_NAME` (queried from the `ContentResolver`) as the display name, falling back to the last URI path segment only when the query fails
    - Keep the `content://` URI as the media path; store the display name separately in `MediaRef` and show it in the create form chip and in the profile, so the chip no longer shows ids such as `msf:1000254595`
    - Make the chip label reflect the current "Copy into app storage" toggle (copy versus in place), updating when the toggle changes, so it never says "in place" while the toggle is on
    - Add unit and widget tests using fakes: display name returned from the pick result, URI kept as path, chip label for toggle on and off
    - _Requirements: 4.1, 4.2, 4.3_

  - [x] 14.2 Add friendly engine-missing error and engine status check
    - In `EngineSupervisor` and `MainActivity`, detect missing `libqemu-img.so` and `libqemu-system-*.so` in `nativeLibraryDir` and return a distinct error code `engine_missing` (with the missing library names as data) instead of a raw path error
    - Add an `engineStatus` method on the `vm/engine` channel (or `vm/host` probe) that reports whether `qemu-img` and each `qemu-system-*` binary are installed
    - Extend `EngineService` and its channel implementation with `engineStatus`; map `engine_missing` to a typed `StartFailure` in Dart, and have `FailureMessage` produce a "QEMU engine not installed" message with short setup steps (point to `tools/README.md`, install libraries into `jniLibs/arm64-v8a`, rebuild) in place of the raw path
    - Show engine installed or not installed on the Host/compatibility screen and in the startup error dialog
    - Add unit tests using `FakeEngineService`: `engine_missing` mapping, message content, engine status for installed, partially installed, and missing cases; add a widget test for the compatibility screen status row
    - _Requirements: 1.1, 1.2, 5.1, 12.1_

  - [x] 14.3 Add QEMU Android build tooling and documentation
    - Create `tools/build-qemu-android.sh`: cross-compile `qemu-system-aarch64`, `qemu-system-x86_64`, and `qemu-img` for `arm64-v8a` with the Android NDK (take the NDK path, API level, and QEMU version from environment variables with documented defaults)
    - Build required dependencies in the script (zlib, libffi, pcre2, glib, pixman, and libslirp as needed), static where possible, with a cross file for meson and a pkg-config path to the dependency prefix
    - Configure QEMU with unneeded features disabled (gtk, sdl, opengl, audio, and other UI backends) and `--enable-vnc`, `--enable-slirp`, and qcow2 support enabled
    - Name the outputs `libqemu-system-aarch64.so`, `libqemu-system-x86_64.so`, and `libqemu-img.so`, and copy them to `android/app/src/main/jniLibs/arm64-v8a/`
    - Create `tools/README.md` documenting prerequisites, usage, and environment variables; UEFI firmware notes (`QEMU_EFI.fd` for aarch64 and OVMF for x86_64: where to fetch and where to place them); how to install the result and rebuild the app; the GPL license obligations (GPLv2 for QEMU, plus dependency licenses: provide corresponding source, keep notices, and include the license text and build scripts with distributed binaries); and a clear statement that the script was not run in CI and is untested
    - _Requirements: 5.1, 12.2_

- [x] 15. Build the QEMU engine for Android
  - [x] 15.1 Run and debug tools/build-qemu-android.sh on this Mac
    - Install `meson` and `pkg-config` with Homebrew (`brew install meson pkg-config`), plus any other host tools the script reports as missing
    - Run `tools/build-qemu-android.sh` with `ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/27.1.12297006`
    - Diagnose and fix script errors iteratively (dependency builds, meson cross file, pkg-config paths, QEMU configure flags, linking, output naming), re-running until `libqemu-img.so`, `libqemu-system-aarch64.so`, and `libqemu-system-x86_64.so` are present in `android/app/src/main/jniLibs/arm64-v8a/`
    - Only about 9 GB of disk is free on this Mac: keep the script work directory (sources, build trees, dependency prefix) on a disk with enough space, check free space with `df -h` before and during each stage, and delete intermediates (build trees, source tarballs, object files) once a stage completes
    - Update `tools/README.md` to record the fixes made, the work directory setting, and that the script has now been run on this Mac
    - Rebuild the debug APK (`flutter build apk --debug`) and confirm the build succeeds and the APK contains the three libraries under `lib/arm64-v8a/`
    - _Requirements: 5.1, 12.2_

- [x] 16. Device boot fixes
  - [x] 16.1 In-place media via All-files access
    - Device test showed QEMU (a child process) fails with "Could not open '/proc/self/fd/247'": `/proc/self/fd` paths resolved in the app process do not exist in the QEMU process
    - Declare `MANAGE_EXTERNAL_STORAGE` in `AndroidManifest.xml`
    - Add Kotlin methods on `vm/files` to check and request All-files access (`Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`), and extend `FileService` and its channel implementation
    - In `StorageAccess`, when media is picked "in place", resolve the `content://` URI to a real filesystem path (`DocumentsContract` for primary external storage and downloads, with a `MediaStore` `_data` fallback) and store that path in `MediaRef`
    - At start, pass the real path to QEMU; remove the `/proc/self/fd` resolution and launch path entirely
    - If the permission is not granted or the path cannot be resolved, show a clear message in the form and media screens and offer copying into app storage instead
    - Update the create/edit form and media screens: All-files access status, grant action, and the copy fallback offer
    - Write unit and widget tests with `FakeFileSystem` and fakes: permission granted, denied, and unresolvable path; the launch spec uses the real path and never `/proc/self/fd`; copy fallback offer
    - _Requirements: 4.1, 4.2, 4.3, 4.5, 5.1_

  - [x] 16.2 UEFI firmware and QEMU share directory
    - ARM64 guests need `QEMU_EFI.fd` (edk2 aarch64); x86_64 guests use QEMU's bundled SeaBIOS and ROMs through `-L`
    - Extend `tools/build-qemu-android.sh` to fetch the edk2 aarch64 firmware (for example from the Debian `qemu-efi-aarch64` package, extracting `QEMU_EFI.fd`) and to stage the QEMU share directory (`bios`, `roms`, `keymaps`) into `android/app/src/main/assets/qemu/`; keep the work directory and cleanup rules from task 15.1; update `tools/README.md`
    - At app start, copy `assets/qemu` to the app files directory once, keyed by a version marker so that a new version recopies; add the Kotlin or Dart service and wire it into startup
    - Make `LaunchSpecBuilder` pass `-L <dir>` for all guests and `-bios <dir>/QEMU_EFI.fd` for aarch64 guests
    - Write unit tests: `LaunchSpecBuilder` arguments per architecture, and the versioned copy-once logic with fakes
    - Rebuild the debug APK (`flutter build apk --debug`) and confirm the assets are included
    - _Requirements: 5.1, 11.1, 11.2, 12.2_

  - [x] 16.3 Architecture mismatch hint
    - Add a pure Dart `ArchMismatchDetector` that reads the attached ISO filename and recognizes `amd64`, `x86_64`, `x64` versus `arm64`, `aarch64` as clear indicators; return no hint when the name is ambiguous or matches the VM architecture
    - Show a warning in the create/edit form when the detected architecture differs from the VM architecture
    - Append the same hint to the start failure message in `FailureMessage`
    - Write unit tests for filename detection (case, separators, ambiguous names, both directions), the form warning, and the failure message text
    - _Requirements: 2.1, 4.1, 12.1_

  - [x] 16.4 Checkpoint: analysis, tests, builds, and device install
    - Run `flutter analyze`, `flutter test`, a Kotlin compile (`./gradlew :app:compileDebugKotlin` in `android/`), and `flutter build apk --debug`
    - If a device is attached (`adb devices`), install the debug APK with `adb install -r`; otherwise report that no device was attached
    - Ensure all tests pass, ask the user if questions arise.
    - _Requirements: 5.1, 12.1_

- [x] 17. Fix QEMU SIGILL crash on Android
  - [x] 17.1 Fix the coroutine/longjmp crash in the QEMU build
    - Device crash: on a real phone (MediaTek MT6985, Android 16, arm64 with PAC/BTI/SVE2 and shadow call stack, `pac_enabled_keys` set) `qemu-system-aarch64 -accel tcg` dies with SIGILL `ILL_ILLOPN` in bionic libc `longjmp+456`, called from QEMU's coroutine code shortly after the UEFI firmware starts
    - Investigate which QEMU coroutine backend is chosen for bionic (`sigaltstack` versus `ucontext`) in `tools/build-qemu-android.sh` and the QEMU configure/meson output; find the cause (bionic `longjmp` validating shadow call stack or PAC state on a stack that QEMU switched manually)
    - Reference how Termux's qemu packages patch this (Termux packages repo, qemu build recipe and patches) and reuse the approach where it applies
    - Apply a fix in `tools/build-qemu-android.sh`: a configure option (for example `--with-coroutine=ucontext`), a patch file under `tools/patches/` applied by the script, or a minimal ucontext/asm stack switch that avoids bionic `longjmp` on switched stacks
    - Also evaluate adding `-fno-sanitize=shadow-call-stack` and branch-protection flags (`-mbranch-protection=none`) to the C flags for QEMU and its dependencies, and keep only the flags that are needed
    - Rebuild only what is necessary (`WORK_DIR=/tmp/qemu-android-build`, reuse the existing dependency prefix), check free space with `df -h`, and delete intermediates afterwards
    - Re-copy `libqemu-system-aarch64.so`, `libqemu-system-x86_64.so`, and `libqemu-img.so` to `android/app/src/main/jniLibs/arm64-v8a/`
    - Update `tools/README.md` with the crash description, the chosen fix, the patch or flags, and rebuild instructions
    - _Requirements: 5.1, 5.8, 12.2_

  - [x] 17.2 Device verification
    - Build the debug APK (`flutter build apk --debug`) and install it with `adb install -r` so app data and the existing VM are kept
    - Run the existing VM's exact QEMU command line (take it from the VM log or the launch spec) through `adb shell run-as com.vmmachine.vm_machine` for about 30 s, or start the VM through the app, and confirm that QEMU does not die with SIGILL
    - Check `adb logcat -b crash -d` filtered to `libqemu` and `qemu-system` for new crash entries, and record the result
    - Only access this app's own directories (`run-as com.vmmachine.vm_machine`); do not read or modify other apps or shared storage beyond what the VM profile already references
    - If no device is attached, report that and leave the task incomplete
    - _Requirements: 5.1, 5.8_

- [x] 18. Fix the VM console display
  - [x] 18.1 Fix the rfb-connect threading bug and verify on the device
    - The console shows "Can't create handler inside thread Thread[rfb-connect,5,main] that has not called Looper.prepare()" because `DisplayChannel.createTexture` (`RfbClient.kt`) calls `textures.createSurfaceTexture()` and `result.success`/`result.error` on a background thread
    - Create the `SurfaceTexture` entry on the main thread, do the blocking RFB connect on a background thread, and post `result.success`/`result.error` and every Flutter or texture call (`setDefaultBufferSize`, `release`, `onClosed` dispose) back to the main thread
    - Check `RfbClient` frame drawing and `DisplayMirror` for the same threading issue and fix any occurrences
    - Check that the Dart console handles the display connecting while the guest is still booting: retry or wait for the VNC socket, with a visible "waiting for display" state instead of an error
    - Run the Kotlin compile (`./gradlew :app:compileDebugKotlin` in `android/`) and `flutter build apk --debug`, then install with `adb install -r` to the attached phone (keeps app data)
    - Verify via `adb logcat` that the display connects and the threading error no longer appears; if no device is attached, report that and leave the task incomplete
    - _Requirements: 6.1, 6.2, 6.5, 6.8_

- [x] 19. Faster installation media
  - [x] 19.1 Attach ISO media as a virtio-scsi CD-ROM instead of usb-storage
    - In `LaunchSpecBuilder`, add `-device virtio-scsi-pci,id=scsi0` once when there is at least one ISO
    - Attach each ISO as `-drive file=...,format=raw,id=mediaN,media=cdrom,readonly=on,if=none -device scsi-cd,drive=mediaN,bus=scsi0.0` for ARM64 and x86_64 guests
    - For Windows x86_64 guests, which lack virtio drivers at install time, use `-device ide-cd,drive=mediaN` on the q35 AHCI bus instead of virtio-scsi
    - Give the CD a boot order ahead of the empty disk (`bootindex`) so firmware tries it first
    - Keep `.img`, `.qcow2`, and `.vhdx` media attached as before
    - Update the launch spec unit tests to cover the virtio-scsi, ide-cd, bootindex, and unchanged non-ISO cases
    - Run `flutter analyze` and `flutter test`, then `flutter build apk --debug`
    - Install with `adb install -r` to the attached phone (serial 10BE9D2LYZ000UT, keeps app data); if a VM is running, the install stops it, and that must be reported
    - Confirm on the device that the generated QEMU command line contains `scsi-cd` (for example via `adb logcat` or a crash-free start of the app, without tapping UI if possible); if the device is not attached, report that and leave the task incomplete
    - _Requirements: 5.1, 12.2_

- [x] 20. Console key bar
  - [x] 20.1 Replace the console's bottom control panel with a key bar and a controls popup
    - In `lib/ui/screens/vm_console_screen.dart`, show a compact bottom bar (portfolio-style glass pill, same design system) with Esc, Up, Down, Left, Right, and Enter keys; lay the arrows out compactly in a row (← ↑ ↓ →)
    - Each key sends a key-down then key-up to the guest through the existing `KeyMapper` and X11 keysyms (Escape 0xff1b, Return 0xff0d, Left 0xff51, Up 0xff52, Right 0xff53, Down 0xff54)
    - Support press-and-hold auto-repeat for the arrow keys and give haptic feedback on tap
    - Add a "more" / menu button to the bar that opens a popup (bottom sheet in the glass style) containing all existing controls: Start, Pause/Resume, Shut down, Restart, Force stop (with confirmation), Keyboard, Keys (special keys), Screenshot, External display, with the same enable/disable rules by VM state
    - Give the display more vertical space now that the control panel is gone
    - Add widget tests using a fake display service: the key bar sends the right keysyms (down and up), arrow hold repeats, and the popup shows the controls with state-based enablement
    - Run `flutter analyze` and `flutter test`, then `flutter build apk --debug`
    - Install with `adb install -r` to the attached phone (serial 10BE9D2LYZ000UT, keeps app data); if a VM is running, the install stops it, and that must be reported
    - _Requirements: 6.1, 6.2, 6.5_

- [x] 21. Console trackpad mode
  - [x] 21.1 Add a trackpad that toggles with the arrow-key set
    - In `lib/ui/screens/vm_console_screen.dart`, add a toggle button to the bottom key bar (glass pill style) that switches the bar between "keys" mode (Esc, arrows, Enter from task 20.1) and "trackpad" mode
    - In trackpad mode show a touchpad surface (glass panel, taller than the key bar, about 160-200 dp) plus Left and Right click buttons below or beside it
    - Relative pointer movement: a finger drag moves the guest cursor by the drag delta multiplied by a sensitivity/acceleration factor
    - Tap sends a left click; two-finger tap sends a right click; two-finger vertical drag sends scroll wheel events; long-press then drag performs a drag with the left button held
    - Track the guest cursor position locally, clamp it to the guest framebuffer size from `textureSize`, and send absolute coordinates through the existing `DisplayService.sendPointer` (QEMU usb-tablet is absolute)
    - Remember the last-chosen mode (keys or trackpad) per session
    - In trackpad mode, Esc and Enter stay reachable only through the "more" popup or by toggling back to keys mode
    - Give haptic feedback on clicks
    - Add widget tests using the fake display service: the toggle switches modes; a drag moves the pointer by the scaled delta and clamps at the framebuffer edges; a tap sends left button down and up; the right-click button sends the right button mask
    - Run `flutter analyze` and `flutter test`, then `flutter build apk --debug`
    - Device install: only if phone 10BE9D2LYZ000UT is connected AND no libqemu process is running (check with `adb shell run-as com.vmmachine.vm_machine pidof libqemu-system-aarch64.so libqemu-system-x86_64.so`), run `adb install -r` (never uninstall); otherwise report that the APK is ready and do not install
    - _Requirements: 6.1, 6.2, 6.5_

- [x] 22. Fullscreen landscape console
  - [x] 22.1 Add a fullscreen landscape mode to the VM console
    - In `lib/ui/screens/vm_console_screen.dart`, add a fullscreen button to the key bar (glass pill style)
    - Tapping it locks orientation to landscape (`SystemChrome.setPreferredOrientations` with landscapeLeft and landscapeRight) and hides system bars (`SystemUiMode.immersiveSticky`)
    - In fullscreen the guest display fills the left area keeping its aspect ratio; a vertical side panel on the right holds the same controls: the keys/trackpad mode toggle; in keys mode the Esc, arrow, and Enter keys laid out vertically and compactly; in trackpad mode the trackpad surface plus Left and Right click buttons; and the "more" button and an exit-fullscreen button
    - Hide the app bar and stats chip in fullscreen (stats may show as a small overlay)
    - Exiting (exit button or system back) restores the portrait-up orientation preference and `SystemUiMode.edgeToEdge`; also restore both in `dispose`
    - Keep the keys/trackpad mode state shared between the portrait and fullscreen layouts and reuse the existing key and trackpad widgets instead of duplicating logic
    - The display must re-read `textureSize` after rotation
    - Add widget tests (mock the `SystemChrome` platform channel): entering fullscreen calls SystemChrome with landscape orientations; the side panel shows the keys and the toggle; the trackpad works in the side panel; exiting restores portrait
    - Run `flutter analyze` and `flutter test`, then `flutter build apk --debug`
    - Device install: only if phone 10BE9D2LYZ000UT is connected AND no libqemu process is running (check with `adb shell run-as com.vmmachine.vm_machine pidof libqemu-system-aarch64.so libqemu-system-x86_64.so`), run `adb install -r` (never uninstall); otherwise report that the APK is ready and do not install
    - _Requirements: 6.1, 6.2, 6.5_
## Notes

- Tasks marked with `*` are optional and can be skipped for a faster MVP
- Each task references specific requirements for traceability
- Property tests validate the universal properties from the design; each of Properties 1 to 34 is its own sub-task
- QEMU cross-compilation is outside this plan (see the design's risks). Tasks 8.4 and 9.x assume the binaries are placed in `jniLibs/arm64-v8a`; the `Fake*` services allow all Dart logic to be tested without them
- Device-only checks (display, external input, thermal behavior, real boot) remain manual, per the design's testing strategy

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1"] },
    { "id": 1, "tasks": ["2.1", "8.1"] },
    { "id": 2, "tasks": ["2.2", "4.1", "5.1", "6.1", "7.1", "7.3", "7.8", "7.11", "8.2", "8.3", "8.6", "8.7", "8.8"] },
    { "id": 3, "tasks": ["2.3", "2.4", "3.1", "4.2", "4.3", "4.4", "5.2", "5.3", "5.4", "5.5", "5.6", "5.7", "6.2", "6.3", "6.4", "7.2", "7.4", "7.5", "7.6", "7.7", "7.9", "7.10", "7.12", "7.13", "8.4", "8.5", "8.9"] },
    { "id": 4, "tasks": ["3.2", "3.3", "3.4", "3.5", "3.6", "6.5", "6.6", "6.7", "8.10", "9.1"] },
    { "id": 5, "tasks": ["8.11", "9.2"] },
    { "id": 6, "tasks": ["9.3"] },
    { "id": 7, "tasks": ["9.4", "9.5", "9.6", "9.9"] },
    { "id": 8, "tasks": ["9.7", "9.8", "9.10"] },
    { "id": 9, "tasks": ["10"] },
    { "id": 10, "tasks": ["11.1"] },
    { "id": 11, "tasks": ["11.2", "11.3", "11.4", "11.5", "11.6", "11.7"] },
    { "id": 12, "tasks": ["11.8", "12.1"] },
    { "id": 13, "tasks": ["12.2"] },
    { "id": 14, "tasks": ["13"] },
    { "id": 15, "tasks": ["14.1", "14.3"] },
    { "id": 16, "tasks": ["14.2"] },
    { "id": 17, "tasks": ["15.1"] },
    { "id": 18, "tasks": ["16.1"] },
    { "id": 19, "tasks": ["16.2"] },
    { "id": 20, "tasks": ["16.3"] },
    { "id": 21, "tasks": ["16.4"] },
    { "id": 22, "tasks": ["17.1"] },
    { "id": 23, "tasks": ["17.2"] },
    { "id": 24, "tasks": ["18.1"] },
    { "id": 25, "tasks": ["19.1"] },
    { "id": 26, "tasks": ["20.1"] },
    { "id": 27, "tasks": ["21.1"] },
    { "id": 28, "tasks": ["22.1"] }
  ]
}
```
