# Changelog

All notable changes to Qemate will be documented in this file.


## [2.0.0] - 29/04/2025
- Added audio support(requires PipeWire installed and running; audio is disabled if PipeWire is unavailable).
- Updated the man page, completion.

## [1.1.1] - 05/04/2025
- First public release.

### Added
- **VM Locking**: Added `vm lock` and `vm unlock` subcommands to prevent accidental deletion of VMs. Locked VMs cannot be deleted until explicitly unlocked.
- **Locked Status Display**: Updated `vm list` to show whether each VM is locked in a new "LOCKED" column.

### Changed
- Removed the use of ID for handling commands.

## [1.1.0] - 31/03/2025
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

## [1.0.0] - 25/03/2025

### Added
- Initial private release with full VM management and networking.

### Changed
- N/A

### Fixed
- N/A

## [0.1.0] - 19/03/2025

### Added
- Initial project structure
- Basic VM management functionality (start, stop, status)
- Basic network configuration
- Command-line interface with subcommands

### Changed
- N/A (initial release)

### Fixed
- N/A (initial release)