# Changelog

All notable changes to Qemate will be documented in this file.

## [4.3.0] - 2026-07-17
### QEMU compatibility
- Require QEMU 10.0 or newer in runtime checks, installation checks, package metadata, and documentation.
- Audit generated commands against QEMU 10.0 removed and deprecated interfaces; use supported machine properties, explicit booleans, complete CPU topology, QMP commands, and PCI VFIO devices.

### Stability and lifecycle
- Request orderly guest shutdown through a private QMP socket; a timed-out guest is left running unless `--force` is explicit.
- Acquire the lifecycle lock before preparing TAP, TPM, VirtIO-FS, or VFIO resources.
- Preserve timestamped QEMU stderr logs and keep `error.log` as the latest-run link.
- Keep Rust virtiofsd compatible by using its supported request queue with a bounded worker thread pool instead of unsupported multi-request-queue negotiation.
- Map the `sata` disk setting to q35's supported AHCI/IDE frontend instead of the rejected legacy `-drive if=sata` spelling.
- Replace the deprecated NVMe `num_queues` property with its QEMU 10-supported `max_ioqpairs` replacement.

### Performance and UX
- Add balanced/performance profiles, host diagnostics, and a side-effect-free `start --dry-run` command preview.
- Honor memory preallocation when VirtIO-FS also requires shared memfd memory, with locked memory in the performance profile.
- Use explicit CPU topology, conditional AMD AVIC, bounded VirtIO queues, and a parallel VirtIO-FS daemon thread pool.
- Add effective runtime details to `status` and avoid requiring QEMU tools for unrelated inspection commands.

## [4.2.3] - 2026-07-15
### Security and reliability
- Validate VM names before installing lifecycle traps or constructing cleanup paths.
- Keep flock lock inodes stable instead of unlinking lock files during release.
- Centralize start cleanup and verify QEMU/helper process identity before signaling.
- Parse lock state through the validated configuration loader and harden VM directory modes.
- Fail closed when requested TPM or VirtIO-FS resources cannot be initialized.
- Validate additional QEMU option fields and preserve passt host bind addresses.

## [4.2.2] - 2026-05-24
### Changed
- **`PORT_FORWARDING_ENABLED` config key removed**: This derived flag is no longer stored in VM config files. Port forwarding is now controlled exclusively by the presence of entries in `PORT_FORWARDS`. Existing config files that still contain this key will log a one-time warning on load and continue to work; the key is silently dropped on the next save.
- **`ENABLE_AUDIO` now warns when unconfigured**: Setting `ENABLE_AUDIO="1"` without a corresponding `AUDIO_PASSTHROUGH_PCI` address now logs a `[WARNING]` at VM start instead of silently doing nothing.
- **Distro-agnostic error messages**: Runtime error messages for missing OVMF firmware and `passt` no longer reference Arch Linux's `pacman` specifically.
- **`--help` / bare invocation**: `qemate` with no arguments now exits 0 instead of 1. `resize --force` remains accepted for CLI compatibility, but live qcow2 resizing is refused until QMP-based online resize support is implemented.

### Fixed
- **Startup check now verifies `flock`**: `flock` (from `util-linux`) is required for all config and state operations and is now checked alongside `qemu-system-x86_64` and `qemu-img` at startup.
- **Windows no-share startup**: Windows VMs no longer require `smbd` when no shared folders are configured.
- **Safe config editing rollback**: `configure` now restores the previous config if the editor exits with an error.
- **Odd-core Windows topology**: Windows CPU topology now remains valid for odd vCPU counts and single-core VMs.
- **Installer/package layout tolerance**: `install.sh`, `Makefile`, and `PKGBUILD` now support both root-level and `src/` / `docs/man/` layouts, and skip absent optional docs instead of failing.
- **Config validation**: Loaded configs now validate enum values, booleans, sizes, port rules, USB IDs, and share tags before use.

### Internal
- OS defaults refactored: the duplicate `LINUX_DEFAULTS` and `WINDOWS_DEFAULTS` arrays are replaced by a shared `_BASE_DEFAULTS` table with per-OS override maps, eliminating duplicated key definitions.
- Log level rank table moved from a `local -A` declaration rebuilt on every `log_message` call to a single `declare -rA` global (`_LOG_RANK`).
- `VERSION` constant introduced as `readonly VERSION="4.2.2"` — the single source of truth referenced by `--help` output.
- Removed unused `vm_name` parameter from `configure_cpu`, `configure_memory`, and `configure_display`.

## [4.2.1] - 2026-04-18
### Changed
- **Bash-native Parsing**: Replaced `awk` with pure-Bash logic for memory validation (`/proc/meminfo`) and disk size extraction (`qemu-img info --output=json`), eliminating external dependencies.
- **OVMF Firmware Discovery**: `find_ovmf` now also searches for the `.4m.fd` firmware variant used by Arch Linux's `edk2-ovmf` package.

### Added
- **QEMU Guest Agent Socket**: The start sequence now provisions a `virtserialport` and Unix socket (`sockets/qga.sock`) for QEMU Guest Agent communication on every VM.
- **TPM Directory Pre-creation**: The `tpm/` subdirectory is now created at `vm create` time along with `logs/` and `sockets/`, preventing race conditions on first `swtpm_setup` run.
- **Interrupt Cleanup Trap**: A `cleanup_on_signal` handler for `INT`/`TERM` signals tears down virtiofsd daemons, the TPM, and the TAP interface if the VM is interrupted during the startup phase.
- **VFIO Exit Trap**: The `start` command registers an `EXIT` trap to restore original host PCI drivers when the process exits, ensuring the host audio device is always reclaimed after the VM stops.

### Fixed
- Log file name corrected from `qemate_vm.log` to `qemate.log` in all VM log directories.

## [4.2.0] - 2026-04-01
### Changed
- **Flat Command Interface**: Removed the previous subgroup hierarchy (`vm`, `net`, `share`, `usb`, `security`). All commands are now top-level with hyphenated names. See the table below.

  | Old                          | New                  |
  |------------------------------|----------------------|
  | `qemate vm create`           | `qemate create`      |
  | `qemate vm start`            | `qemate start`       |
  | `qemate vm stop`             | `qemate stop`        |
  | `qemate vm delete`           | `qemate delete`      |
  | `qemate vm resize`           | `qemate resize`      |
  | `qemate vm list`             | `qemate list`        |
  | `qemate vm status`           | `qemate status`      |
  | `qemate vm configure`        | `qemate configure`   |
  | `qemate net port add`        | `qemate port-add`    |
  | `qemate net port remove`     | `qemate port-remove` |
  | `qemate usb add`             | `qemate usb-add`     |
  | `qemate usb remove`          | `qemate usb-remove`  |
  | `qemate usb list`            | `qemate usb-list`    |
  | `qemate share add`           | `qemate share-add`   |
  | `qemate share remove`        | `qemate share-remove`|
  | `qemate share list`          | `qemate share-list`  |
  | `qemate security lock`       | `qemate lock`        |
  | `qemate security unlock`     | `qemate unlock`      |

- **`configure` Redesign**: The `configure` command no longer accepts `setting value` arguments. It opens the VM config file directly in `$EDITOR`, validates syntax after editing, and automatically restores the previous config if validation fails. The `--raw` flag has been removed (all editing is now raw).

- **Expanded `list` Output**: `vm list` now displays seven columns: `NAME`, `STATUS`, `LOCKED`, `OS`, `AUDIO`, `TPM`, and `SPICE`.

### Added
- **Physical Disk Passthrough** (`--disk-dev`): The `create` command now accepts `--disk-dev PATH` (e.g. `/dev/sdb`) to use a raw physical block device instead of a qcow2 image. `--disk-size` is ignored when `--disk-dev` is set. Resize is blocked on physical-device VMs.
- **UEFI Flags on Create**: `--uefi` / `--no-uefi` flags added to `create`, allowing explicit UEFI firmware selection at creation time (default: on for Windows, off for Linux).
- **Multi-share VirtIO-FS**: `virtiofs` backend now supports multiple simultaneous shared folders, each backed by its own `virtiofsd` daemon and socket.
- **`resize --force`**: Added as a reserved CLI-compatible flag. Live resize is intentionally refused until QMP-based online resize support is available.

## [4.1.0] - 2026-03-30
### Added
- **Audio passthrough**: PCIe Audio Passthrough to expose a host audio device directly to the guest via VFIO.
- **Centralized Dependency Pre-flighting**: Implemented `check_vm_dependencies` to validate all required host binaries (`swtpm`, `virtiofsd`, `smbd`) before VM initialization, preventing partial starts and orphaned processes.
- **Mandatory Field Validation**: The configuration loader now verifies that critical settings (Cores, Memory, Networking, etc.) are present and valid before execution.

### Changed
- **Hardened Config Serialization**: Replaced the legacy configuration parser with a strict, regex-based lexer. This eliminates the use of `source` for config loading, effectively preventing arbitrary code execution from modified config files.
- **Key Whitelisting**: Implemented an internal `_ALLOWED_KEYS` map to ensure only recognized parameters are processed during the configuration load.

### Security
- **Ownership Enforcement**: Added strict checks to ensure VM configuration files are owned by the current user.
- **Permission Hardening**: The script now detects and automatically corrects insecure file permissions on configuration files (forcing `600`).
- **Improved Concurrency**: Integrated robust file locking (`flock`) within the configuration load sequence to prevent race conditions during simultaneous CLI operations.

## [4.0.0] - 2026-03-10
### Added
- **Reaper Execution Block**: Refactored the start sequence to run QEMU in the foreground with a dedicated cleanup trap, improving reliability over legacy `-daemonize` flags.
- **Advanced Networking**: Added support for complex port-forwarding rules using Bash associative arrays.

## [3.4.0] - 2025-12-29
### Added
- **Enhanced Host Memory Validation**: The `create` command now checks `MemAvailable` instead of `MemTotal` to ensure the host can safely support the VM's memory footprint.
- **Disk Resize Safeguards**: Added validation to `vm resize` to prevent accidental disk shrinking and verify size formatting before execution.

### Changed
- **Robust Port Management**: Rewrote `manage_network_ports` using Bash arrays to replace brittle string manipulation, preventing accidental corruption of configuration files.
- **Increased Requirements**: Updated minimum Bash version requirement to 5.0+ to support advanced array handling.

### Fixed
- Fixed a potential bug where port forwarding strings (e.g., "80:80") could be partially matched and incorrectly removed if they were substrings of other rules.

## [3.3.0] - 2025-06-15
### Fixed
- Fixed argument parsing to correctly handle flags (--memory, --force, etc.).
- Applied strict umask (0077) for security.
- Hardened config loading with ownership checks.

## [3.0.1] - 2025-05-25
### Added
- Audio backend prioritization: PipeWire (preferred), PulseAudio, ALSA for `--enable-audio`.
- Limited shared folders to one per VM for both Linux (VirtIO 9P) and Windows (Samba/SMB).
- Enhanced logging with `LOG_LEVEL` (DEBUG, INFO, WARNING, ERROR; default: INFO).

### Changed
- Completely rewritten from the ground up.
- Breaking changes — not compatible with previous versions.
- Improved network configuration with explicit TCP/UDP port forwarding support.

### Fixed
- Improved error handling for port conflicts and shared folder validation.
- Fixed race conditions in PID file management using file locking.

## [2.1.0] - 2025-05-12
- Added shared folder functionality.

## [2.0.1] - 2025-05-09
- Fixed vm start error.
- Fixed vm start --headless issue.

## [2.0.0] - 2025-04-29
- Added audio support (requires PipeWire installed and running; audio is disabled if PipeWire is unavailable).
- Updated the man page, completion.

## [1.1.1] - 2025-04-05
- First public release.

### Added
- **VM Locking**: Added `vm lock` and `vm unlock` subcommands to prevent accidental deletion of VMs. Locked VMs cannot be deleted until explicitly unlocked.
- **Locked Status Display**: Updated `vm list` to show whether each VM is locked in a new "LOCKED" column.

### Changed
- Removed the use of ID for handling commands.

## [1.1.0] - 2025-03-31
### Added
- **Networking Enhancements**:
  - Support for `nat`, `user`, and `none` network types (`net set` command).
  - Network model configuration (`net model` command) with options `e1000` and `virtio-net-pci`.
  - Port forwarding management (`net port add`, `remove`, `list`) with TCP/UDP support.
- **VM Management**:
  - Added `--headless` option for starting VMs without a graphical console.
  - Improved VM status display with detailed information (memory, cores, disk usage).
- **Bash Completion**: Enhanced autocompletion for commands, subcommands, and VM names.

### Changed
- Updated minimum QEMU requirement to 9.0.0 for better compatibility.
- Improved error handling and logging across all commands.
- Default network model changed to `virtio-net-pci` for better performance.

### Fixed
- Graceful shutdown timeout handling in `vm stop`.
- Lock management to prevent race conditions during VM operations.

## [1.0.0] - 2025-03-25
### Added
- Initial private release with full VM management and networking.

## [0.1.0] - 2025-03-19
### Added
- Initial project structure.
- Basic VM management functionality (start, stop, status).
- Basic network configuration.
- Command-line interface with subcommands.
