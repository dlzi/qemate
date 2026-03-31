# Changelog

All notable changes to Qemate will be documented in this file.

## [4.1.0] - 2026-03-30
### Added
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