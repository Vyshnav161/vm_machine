# Requirements Document

## Introduction

The Android VM Manager is a Flutter application for Android devices. It lets a user create, configure, run, and manage virtual machines (VMs) that represent different PC builds. Target guest operating systems are Windows, Linux, and macOS (macOS only where legally and technically permitted).

Running full PC guests on a phone or tablet has hard constraints, which these requirements account for:

- **CPU architecture.** Most Android devices use ARM64 CPUs. Most Windows, Linux, and macOS desktop images target x86_64. An x86_64 guest on an ARM64 host needs full software emulation, which is much slower than native execution. ARM64 guests can run on an ARM64 host with hardware acceleration only when the device exposes it.
- **Hardware virtualization.** Android does not give regular apps access to the Linux KVM interface. A few devices and Android versions expose virtualization through the Android Virtualization Framework (AVF), but this is not available on most devices. The app therefore has to work without hardware acceleration and has to detect acceleration when it exists.
- **Performance.** Emulated guests use a lot of CPU, memory, battery, and heat. The app has to keep the Android device usable.
- **Storage.** Disk images are large (often 10 GB to more than 60 GB), and Android restricts app storage access.
- **macOS licensing.** The Apple macOS license permits macOS to run only on Apple-branded hardware. The app cannot bundle or download macOS images, and it cannot promise that macOS guests work.

The first release is scoped to a VM manager with an embedded emulation backend. The feature covers VM lifecycle, guest operating system image handling, display and input, resource limits, storage, and compatibility reporting. It does not cover cloud-hosted VMs or remote desktop clients.

## Glossary

- **VM_Manager**: The Flutter Android application that provides the user interface and coordinates all VM operations.
- **VM**: A virtual machine defined by a name, a guest operating system, a CPU architecture, resource limits, and one or more disk images.
- **VM_Profile**: The saved configuration of a VM, including guest operating system, architecture, virtual CPU count, memory size, disk images, display settings, and network mode.
- **Guest_OS**: The operating system that runs inside a VM. Supported families are Windows, Linux, and macOS.
- **Host_Device**: The Android device on which the VM_Manager runs.
- **Emulation_Engine**: The native component bundled with the VM_Manager that executes guest code, either through software emulation or hardware acceleration.
- **Acceleration_Mode**: The method used to execute guest CPU instructions. Values are `Software_Emulation` and `Hardware_Virtualization`.
- **Capability_Detector**: The VM_Manager component that inspects the Host_Device and reports its CPU architecture, available RAM, free storage, and hardware virtualization support.
- **Compatibility_Report**: The result produced by the Capability_Detector that states which Guest_OS and architecture combinations the Host_Device can run, and which Acceleration_Mode each uses.
- **Installation_Media**: A user-provided disk image file (for example an ISO or a prebuilt disk image) used to install or boot a Guest_OS.
- **Disk_Image**: A file that holds a VM's virtual disk contents.
- **Snapshot**: A saved point-in-time state of a VM that the user can restore later.
- **VM_Console**: The screen that shows the VM's display output and accepts touch, keyboard, and mouse input for a running VM.
- **VM_Library**: The persistent collection of VM_Profiles stored on the Host_Device.
- **Resource_Limits**: The maximum virtual CPU count and memory a VM may use, as configured in its VM_Profile.
- **VM_Profile_File**: A JSON file that serializes a VM_Profile for export and import.
- **Profile_Serializer**: The VM_Manager component that converts a VM_Profile to and from a VM_Profile_File.
- **Profile_Printer**: The part of the Profile_Serializer that writes a VM_Profile as a VM_Profile_File.

## Requirements

### Requirement 1: Host Capability Detection

**User Story:** As a user, I want the app to tell me what my device can run, so that I can choose VMs that will work and avoid wasting time on unsupported setups.

#### Acceptance Criteria

1. WHEN the VM_Manager starts for the first time, THE Capability_Detector SHALL determine the Host_Device CPU architecture, total RAM, free internal storage, and Hardware_Virtualization availability.
2. WHEN the Capability_Detector completes detection, THE VM_Manager SHALL display a Compatibility_Report that lists each supported Guest_OS and architecture combination with its Acceleration_Mode.
3. WHERE the Host_Device CPU architecture is ARM64 and Hardware_Virtualization is unavailable, THE Compatibility_Report SHALL mark ARM64 guests as `Software_Emulation` and x86_64 guests as `Software_Emulation` with a warning that performance is substantially reduced.
4. WHERE the Host_Device exposes Hardware_Virtualization for ARM64 guests, THE Compatibility_Report SHALL mark ARM64 guests as `Hardware_Virtualization`.
5. IF the Host_Device has less than 4 GB of total RAM, THEN THE VM_Manager SHALL display a warning in the Compatibility_Report that Windows and macOS guests are not recommended.
6. WHEN the user selects the refresh action on the Compatibility_Report, THE Capability_Detector SHALL repeat detection and update the Compatibility_Report within 5 seconds.
7. IF the Capability_Detector cannot determine one of the detected values, THEN THE VM_Manager SHALL mark that value as `Unknown` in the Compatibility_Report and continue to allow VM creation.

### Requirement 2: Guest Operating System Support and Legal Limits

**User Story:** As a user, I want to know which guest operating systems are supported and under what conditions, so that I stay within licensing rules and have realistic expectations.

#### Acceptance Criteria

1. THE VM_Manager SHALL offer Linux, Windows, and macOS as selectable Guest_OS families when the user creates a VM.
2. THE VM_Manager SHALL require the user to supply Installation_Media for every VM, and THE VM_Manager SHALL NOT bundle or download Windows or macOS Installation_Media.
3. WHEN the user selects Windows as the Guest_OS, THE VM_Manager SHALL display a notice that the user is responsible for holding a valid Windows license.
4. WHEN the user selects macOS as the Guest_OS, THE VM_Manager SHALL display a notice that Apple's license permits macOS to run only on Apple-branded hardware and that macOS support is provided as experimental and unsupported.
5. WHEN the user selects macOS as the Guest_OS, THE VM_Manager SHALL require the user to confirm the licensing notice before the VM_Profile is saved.
6. WHEN the user selects Linux as the Guest_OS, THE VM_Manager SHALL display a list of suggested distributions that publish ARM64 or x86_64 images and open the distribution's official download page in the Android browser when the user selects one.
7. IF the Compatibility_Report states that a Guest_OS and architecture combination is not runnable on the Host_Device, THEN THE VM_Manager SHALL display the reason and prevent the user from starting a VM of that combination.

### Requirement 3: VM Creation and Configuration

**User Story:** As a user, I want to create a VM with a chosen operating system and hardware settings, so that I can match the PC build I want to run.

#### Acceptance Criteria

1. WHEN the user selects the create VM action, THE VM_Manager SHALL present a form that collects VM name, Guest_OS family, guest CPU architecture, virtual CPU count, memory size, Disk_Image size, and Installation_Media.
2. WHEN the user selects a Guest_OS family, THE VM_Manager SHALL pre-fill virtual CPU count, memory size, and Disk_Image size with the recommended minimum values for that family.
3. WHEN the user submits the creation form with valid values, THE VM_Manager SHALL save a VM_Profile to the VM_Library and create an empty Disk_Image of the requested size.
4. IF the VM name is empty or duplicates the name of an existing VM_Profile, THEN THE VM_Manager SHALL reject the submission and display the reason.
5. IF the requested memory size exceeds 75 percent of the Host_Device total RAM, THEN THE VM_Manager SHALL reject the submission and display the maximum allowed value.
6. IF the requested virtual CPU count exceeds the number of Host_Device CPU cores, THEN THE VM_Manager SHALL reject the submission and display the maximum allowed value.
7. IF the requested Disk_Image size exceeds the free storage on the Host_Device, THEN THE VM_Manager SHALL reject the submission and display the available free storage.
8. WHEN the user edits the VM_Profile of a VM that is powered off, THE VM_Manager SHALL apply the same validation rules as creation and save the changes.
9. WHILE a VM is running, THE VM_Manager SHALL prevent edits to the VM_Profile of that VM.

### Requirement 4: Installation Media Import

**User Story:** As a user, I want to attach my own ISO or disk image to a VM, so that I can install or boot an operating system of my choice.

#### Acceptance Criteria

1. WHEN the user selects the attach media action, THE VM_Manager SHALL open the Android system file picker and accept files with the extensions `.iso`, `.img`, `.qcow2`, and `.vhdx`.
2. WHEN the user selects a file, THE VM_Manager SHALL reference the file in place without copying it, unless the user chooses the copy option.
3. WHERE the user chooses the copy option, THE VM_Manager SHALL copy the file into the app storage and display progress as a percentage while copying.
4. IF the selected file has an unsupported format, THEN THE VM_Manager SHALL reject the file and display the list of supported formats.
5. IF the selected file can no longer be read when the VM starts, THEN THE VM_Manager SHALL display an error that names the missing file and keep the VM powered off.
6. IF the free storage on the Host_Device is smaller than the size of the file when the user chooses the copy option, THEN THE VM_Manager SHALL cancel the copy and display the required and available storage amounts.
7. WHEN the user detaches Installation_Media from a powered-off VM, THE VM_Manager SHALL remove the reference from the VM_Profile and leave the file on the Host_Device unchanged.

### Requirement 5: VM Lifecycle Control

**User Story:** As a user, I want to start, pause, resume, restart, and stop my VMs, so that I can control them like a physical PC.

#### Acceptance Criteria

1. WHEN the user selects the start action for a powered-off VM, THE VM_Manager SHALL start the Emulation_Engine with the settings from the VM_Profile and show the VM_Console.
2. WHEN the user selects the pause action for a running VM, THE Emulation_Engine SHALL suspend guest execution and THE VM_Manager SHALL show the VM state as `Paused`.
3. WHEN the user selects the resume action for a paused VM, THE Emulation_Engine SHALL continue guest execution and THE VM_Manager SHALL show the VM state as `Running`.
4. WHEN the user selects the shutdown action for a running VM, THE Emulation_Engine SHALL send an ACPI power-off request to the guest.
5. WHEN the user selects the force stop action for a running VM and confirms the confirmation prompt, THE Emulation_Engine SHALL terminate the VM within 5 seconds.
6. WHEN the user selects the restart action for a running VM, THE Emulation_Engine SHALL send a reset to the guest.
7. THE VM_Manager SHALL display the current state of each VM in the VM_Library as one of `Powered Off`, `Starting`, `Running`, `Paused`, `Stopping`, or `Error`.
8. IF the Emulation_Engine terminates unexpectedly, THEN THE VM_Manager SHALL set the VM state to `Error`, display the engine's exit reason, and keep the Disk_Image unchanged.
9. IF the user starts a VM while another VM is running and the combined configured memory of both VMs exceeds 75 percent of the Host_Device total RAM, THEN THE VM_Manager SHALL refuse to start the second VM and display the reason.

### Requirement 6: Display and Input

**User Story:** As a user, I want to see and control the guest desktop on my phone or tablet, so that I can use the guest operating system.

#### Acceptance Criteria

1. WHILE a VM is running, THE VM_Console SHALL display the guest video output.
2. WHILE a VM is running, THE VM_Console SHALL translate touch gestures into mouse pointer movement, left click, right click, and scroll events in the guest.
3. WHILE a VM is running and an Android hardware or on-screen keyboard is active, THE VM_Console SHALL send key presses to the guest.
4. WHERE an external USB or Bluetooth keyboard or mouse is connected to the Host_Device, THE VM_Console SHALL forward the input events from that device to the guest.
5. WHEN the Host_Device screen orientation changes, THE VM_Console SHALL resize the display area without restarting the VM.
6. WHEN the user selects the special keys action, THE VM_Console SHALL provide the keys Ctrl, Alt, Shift, Esc, Tab, Windows or Command, and the Ctrl+Alt+Del combination for sending to the guest.
7. WHEN the user selects the screenshot action, THE VM_Console SHALL save the current guest display as a PNG file in the app's screenshot folder.
8. IF the Host_Device has an external display connected, THEN THE VM_Console SHALL allow the user to show the guest display on the external display.

### Requirement 7: Performance and Resource Protection

**User Story:** As a user, I want the app to keep my device usable while a VM runs, so that emulation does not freeze Android or drain the battery unexpectedly.

#### Acceptance Criteria

1. WHILE a VM is running, THE VM_Manager SHALL run the Emulation_Engine in an Android foreground service with a persistent notification that shows the VM name and state.
2. WHILE a VM is running, THE VM_Manager SHALL display the current guest CPU usage, memory usage, and Acceleration_Mode in the VM_Console.
3. WHILE a VM is running using `Software_Emulation` for a guest architecture that differs from the Host_Device architecture, THE VM_Console SHALL display an indicator that cross-architecture emulation is active.
4. WHEN the Android system reports a thermal status of `SEVERE` or higher, THE VM_Manager SHALL pause the running VMs and display a notification that explains the pause.
5. WHEN the Host_Device battery level falls to 15 percent or lower while the device is not charging, THE VM_Manager SHALL display a notification that offers to pause or shut down the running VMs.
6. WHEN the Android system issues a low-memory signal of level `TRIM_MEMORY_RUNNING_CRITICAL` or higher, THE VM_Manager SHALL save a Snapshot of each running VM, if Snapshots are supported for that VM, and pause the VM.
7. WHERE the user enables the battery saver option in a VM_Profile, THE Emulation_Engine SHALL cap the virtual CPU usage of that VM to 50 percent of the configured virtual CPU count.
8. WHEN the VM_Manager moves to the background while a VM is running, THE Emulation_Engine SHALL continue running the VM for as long as the foreground service is active.

### Requirement 8: Storage Management

**User Story:** As a user, I want to see and manage how much space my VMs use, so that large disk images do not fill my device.

#### Acceptance Criteria

1. THE VM_Manager SHALL display, for each VM, the Disk_Image virtual size and the actual size used on the Host_Device.
2. THE VM_Manager SHALL create Disk_Images in a sparse format that allocates storage on demand.
3. WHEN the user selects the delete VM action and confirms the confirmation prompt, THE VM_Manager SHALL remove the VM_Profile, its Disk_Images, and its Snapshots from the Host_Device.
4. WHEN the user selects the delete VM action and confirms the confirmation prompt, THE VM_Manager SHALL leave user-referenced Installation_Media files unchanged.
5. WHERE the Host_Device has removable storage available, THE VM_Manager SHALL allow the user to choose removable storage as the location for the Disk_Image when creating a VM.
6. WHILE a VM is running and the free storage on the Host_Device falls below 500 MB, THE VM_Manager SHALL pause the VM and display a low-storage warning.
7. WHEN the user selects the storage overview, THE VM_Manager SHALL display the total space used by all VMs, Snapshots, and copied Installation_Media.

### Requirement 9: Snapshots

**User Story:** As a user, I want to save and restore the state of a VM, so that I can experiment safely and resume quickly.

#### Acceptance Criteria

1. WHEN the user selects the create Snapshot action for a running or paused VM, THE Emulation_Engine SHALL save the VM state and THE VM_Manager SHALL add the Snapshot with a user-provided name and a creation timestamp to the VM.
2. WHEN the user selects the restore Snapshot action for a powered-off VM and confirms the confirmation prompt, THE Emulation_Engine SHALL restore the Disk_Image and VM state to the Snapshot.
3. WHEN the user selects the delete Snapshot action and confirms the confirmation prompt, THE VM_Manager SHALL remove the Snapshot and release its storage.
4. IF the free storage on the Host_Device is smaller than the estimated Snapshot size, THEN THE VM_Manager SHALL reject the Snapshot request and display the required and available storage amounts.
5. IF restoring a Snapshot fails, THEN THE VM_Manager SHALL leave the current Disk_Image unchanged and display the failure reason.

### Requirement 10: VM Library and Profile Export

**User Story:** As a user, I want to see all my VMs in one place and move their configurations between devices, so that I can reuse setups.

#### Acceptance Criteria

1. THE VM_Library SHALL persist all VM_Profiles across app restarts.
2. WHEN the user opens the VM_Manager, THE VM_Manager SHALL display the VM_Library with each VM's name, Guest_OS family, architecture, and state.
3. WHEN the user enters text in the search field, THE VM_Manager SHALL filter the VM_Library to VMs whose names contain the text, ignoring letter case.
4. WHEN the user selects the clone action for a powered-off VM, THE VM_Manager SHALL create a new VM_Profile with a unique name and a copy of the source Disk_Image.
5. WHEN the user selects the export profile action, THE Profile_Printer SHALL write the VM_Profile as a VM_Profile_File in JSON format without Disk_Image content.
6. WHEN the user selects the import profile action and chooses a VM_Profile_File, THE Profile_Serializer SHALL parse the file and add the VM_Profile to the VM_Library.
7. IF the selected VM_Profile_File is malformed or has an unsupported schema version, THEN THE Profile_Serializer SHALL reject the file and return an error that identifies the invalid field or version.
8. FOR ALL valid VM_Profiles, parsing the output of the Profile_Printer and then printing the result SHALL produce a VM_Profile_File equivalent to the original (round-trip property).
9. IF an imported VM_Profile references a Disk_Image or Installation_Media that is not present on the Host_Device, THEN THE VM_Manager SHALL import the profile with the missing items marked `Missing`.

### Requirement 11: Networking and File Sharing

**User Story:** As a user, I want my VMs to reach the network and exchange files with Android, so that I can install software and move data.

#### Acceptance Criteria

1. THE VM_Manager SHALL provide user-mode network address translation as the default network mode for each VM.
2. WHERE the user enables port forwarding in a VM_Profile, THE Emulation_Engine SHALL forward the configured Host_Device TCP ports to the configured guest ports.
3. IF the user configures a port forward on a Host_Device port below 1024, THEN THE VM_Manager SHALL reject the configuration and display that Android apps cannot bind ports below 1024.
4. IF the Host_Device has no network connection, THEN THE VM_Manager SHALL keep the VM running and show the guest network as disconnected.
5. WHERE the user selects a shared folder in a VM_Profile, THE Emulation_Engine SHALL expose that Android folder to the guest as a network or virtual file system share.
6. WHEN the user removes a shared folder from a powered-off VM_Profile, THE VM_Manager SHALL remove the share without deleting files in the folder.

### Requirement 12: Error Reporting and Diagnostics

**User Story:** As a user, I want clear error messages and logs, so that I can understand why a VM does not boot or run well.

#### Acceptance Criteria

1. WHEN a VM fails to start, THE VM_Manager SHALL display an error message that states the failing step and the cause.
2. WHILE a VM is running, THE Emulation_Engine SHALL write guest serial console and engine log output to a log file for that VM.
3. WHEN the user selects the view logs action, THE VM_Manager SHALL display the log file of the selected VM.
4. WHEN the user selects the share logs action, THE VM_Manager SHALL open the Android share sheet with the log file attached.
5. IF the log file of a VM exceeds 10 MB, THEN THE VM_Manager SHALL rotate the log file and keep the most recent 10 MB.
6. WHEN the VM_Manager displays a boot failure for a cross-architecture VM, THE VM_Manager SHALL include a hint that Software_Emulation may cause the boot time to exceed several minutes.
