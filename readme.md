# Qemate - QEMU Virtual Machine Manager

[![Version](https://img.shields.io/badge/version-1.0.0-blue.svg)](https://github.com/dlzi/qemate)
[![License](https://img.shields.io/badge/license-BSD--3--Clause-green.svg)](https://github.com/dlzi/qemate/blob/main/LICENSE)

Qemate is a robust command-line tool for managing QEMU virtual machines. It provides an intuitive interface for creating and managing virtual machines with comprehensive support for networking, shared storage, USB devices, and more.

## Table of Contents
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage Guide](#usage-guide)
  - [VM Management](#vm-management)
  - [Network Configuration](#network-configuration)
  - [Shared Folder Management](#shared-folder-management)
  - [USB Device Management](#usb-device-management)
- [Configuration](#configuration)
- [Directory Structure](#directory-structure)
- [Security Considerations](#security-considerations)
- [Error Handling](#error-handling)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)
- [Author](#author)
- [Support](#support)

## Features

- **VM Lifecycle Management**:
  - Streamlined VM creation with optimized defaults
  - Safe startup and shutdown procedures
  - Headless operation support
  - Detailed status monitoring
  - Secure VM removal with cleanup

- **Advanced Networking**:
  - Multiple networking modes (NAT, none)
  - Comprehensive port forwarding management
  - Network interface configuration
  - Automatic network validation

- **Shared Storage Solutions**:
  - Linux sharing via virtio-9p
  - Windows sharing via QEMU's built-in SMB
  - Secure credential management
  - Flexible access control (read-only/read-write)
  - Custom UID/GID mapping for Linux shares

- **USB Device Management**:
  - Physical USB port detection
  - Hot-plug support
  - Persistent device configuration
  - Device serial tracking
  - Safe device removal

- **Security Features**:
  - Secure file permissions (600/700)
  - Protected credential storage
  - Safe cleanup procedures
  - Input validation and sanitization
  - Resource access control

- **Resource Optimization**:
  - Dynamic CPU pinning
  - Memory allocation control
  - Disk I/O optimization
  - Network performance tuning
  - Resource limit enforcement

## Prerequisites

- **QEMU Environment**:
  - QEMU/KVM 9.0.0+
  - Linux kernel with KVM support
  - Root access for privileged operations

- **Shared Storage Requirements**:
  - QEMU guest agent for Windows VMs
  - Appropriate filesystem permissions

- **System Tools**:
  - bash shell environment
  - socat for VM monitoring
  - coreutils for file operations

## Installation

1. Clone the repository:
```bash
git clone https://github.com/dlzi/qemate.git
cd qemate
```

2. Make the script executable:
```bash
chmod +x qemate.sh
```

3. Install to system path:
```bash
sudo mv qemate.sh /usr/local/bin/qemate
```

## Usage Guide

### VM Management

```bash
# Create a new VM
qemate vm create NAME [OPTIONS]
  Options:
    --memory MB     RAM in megabytes (default: 2048)
    --cores N       Number of CPU cores (default: 2)
    --disk SIZE    Disk size with suffix M/G/T (default: 20G)

# Start a VM
qemate vm start NAME [OPTIONS]
  Options:
    --iso PATH     Boot from ISO file
    --headless     Start without graphical display

# Stop a VM
qemate vm stop NAME [--force]

# Delete a VM
qemate vm remove NAME [--force]

# List VMs
qemate vm list

# Show VM status
qemate vm status NAME
```

### Network Configuration

```bash
# Set network type
qemate net set NAME --type TYPE

# Port forwarding (NAT mode)
qemate net port add NAME --host PORT --guest PORT [--proto PROTO]
qemate net port remove NAME --port PORT [--proto PROTO]
qemate net port list NAME
```

### Shared Folder Management

```bash
# Add shared folder
qemate shared add NAME [OPTIONS]
  Options:
    --path PATH      Host path to share
    --name NAME      Share name identifier
    --type TYPE      Share type (linux|windows)
    --readonly       Make share read-only
    --uid UID        User ID for Linux shares
    --gid GID        Group ID for Linux shares

# Remove shared folder
qemate shared remove NAME --name SHARE_NAME

# List shared folders
qemate shared list NAME
```

### USB Device Management

```bash
# List USB devices
qemate usb list

# Add USB device
qemate usb add NAME NUMBER [--temp]

# Remove USB device
qemate usb remove NAME NUMBER

# Query USB device
qemate usb query NUMBER
```

## Configuration

VM configurations are stored in `${HOME}/.local/share/qemate/vms/NAME/config` with secure permissions (600). Each configuration includes:

- Hardware allocation (memory, CPU, disk)
- Network settings and port forwards
- Shared folder configurations
- USB device assignments
- Performance optimizations

Example configuration file:
```ini
# VM Configuration
# Created: 2025-03-05T14:17:03+00:00
# Version: 1.0.0

NAME="ubuntu-server"
MEMORY=4096
CORES=4
DISK_SIZE="50G"
NETWORK_TYPE="nat"
MAC_ADDRESS="52:54:00:ab:cd:ef"
SHARED_FOLDERS_ENABLED=1
SHARED_FOLDER_TYPE="virtio-9p"
SHARED_FOLDER_data_PATH="/data"
SHARED_FOLDER_data_TAG="data"
SHARED_FOLDER_data_READONLY=0
USB_DEVICES="1234:abcd"
```

## Directory Structure

```
${HOME}/.local/share/qemate/
├── vms/            # VM configurations and disk images
├── logs/           # Operation logs
└── temp/           # Temporary files
```

## Security Considerations

- Secure file permissions (600/700) for all sensitive files
- Protected storage of credentials and configurations
- Input validation and sanitization
- Safe temporary file handling
- Resource access control
- Network security validation
- USB device access control

## Error Handling

The script provides comprehensive error management:
- Detailed error messages with color coding
- Operation logging with timestamps
- Safe cleanup on failures
- Resource locking for concurrent access
- Proper exit code handling

## Troubleshooting

### Debugging Tips

- Enable debug mode by setting `CONFIG[DEBUG]=1` in the script.
- Review the logs in `${HOME}/.local/share/qemate/logs` for detailed information.

## Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Implement your changes with appropriate tests
4. Commit your changes (`git commit -m 'Add some amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## License

This project is licensed under the BSD 3-Clause License - see the [LICENSE](LICENSE) file for details.

## Author

- **Daniel Zilli** - [GitHub](https://github.com/dlzi)

## Support

For assistance:
1. Check this documentation
2. Review [Issues](https://github.com/dlzi/qemate/issues)
3. Create a new issue if needed

Project Link: [https://github.com/dlzi/qemate](https://github.com/dlzi/qemate)

