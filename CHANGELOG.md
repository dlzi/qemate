# Changelog

All notable changes to Qemate will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2025-03-31
### Added
- **Networking Enhancements**:
  - Support for `nat`, `user`, and `none` network types (`net set` command).
  - Network model configuration (`net model` command) with options `e1000` and `virtio-net-pci`.
  - Port forwarding management (`net port add`, `remove`, `list`) with TCP/UDP support.
- **VM Management**:
  - Added `--headless` option for starting VMs without a graphical console.
  - Improved VM status display with detailed information (memory, cores, disk usage).
- **Testing**: Added BATS test suite for core functionality (`tests/qemate_tests.bats`).
- **Bash Completion**: Enhanced autocompletion for commands, subcommands, and VM names.

### Changed
- Updated minimum QEMU requirement to 8.0.0 for better compatibility.
- Improved error handling and logging across all commands.
- Default network model changed to `virtio-net-pci` for better performance.

### Fixed
- Graceful shutdown timeout handling in `vm stop`.
- Lock management to prevent race conditions during VM operations.

## [1.0.0] - 2025-03-25

### Added
- Initial stable release with full VM management, networking, shared folders, and USB support.

### Changed
- N/A

### Fixed
- N/A

## [0.1.0] - 2025-03-19

### Added
- Initial project structure
- Basic VM management functionality (start, stop, status)
- Basic network configuration
- Shared folder mounting capabilities
- USB device management
- Command-line interface with subcommands

### Changed
- N/A (initial release)

### Fixed
- N/A (initial release)