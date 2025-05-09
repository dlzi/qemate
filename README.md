# Qemate - QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and networking, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, list, edit, and check status of VMs.
- **Interactive Wizard**: Guided VM creation with `qemate vm wizard`.
- **Locking Mechanism**: Lock/unlock VMs to prevent accidental deletion.
- **Networking**: Configure port forwarding, network types (nat, user, none), and network models (e1000, virtio-net-pci).
- **Audio Support**: Enable audio output via PipeWire.
- **Performance**: Optimized for KVM acceleration with sensible defaults.
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR).
- **Bash Completion**: Tab completion for commands and options.

## Requirements

- **Bash**: Version 4.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (any recent version).
- **Optional**:
  - `bash-completion`: For tab completion.
  - PipeWire: For audio support with `--enable-audio`.
- **Recommended**: KVM support for hardware acceleration (`/dev/kvm` accessible).

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/dlzi/qemate.git
   cd qemate
   ```

2. Install using the provided script:
   ```bash
   sudo ./install.sh
   ```

   This installs to `/usr/local` by default. Customize paths with:
   ```bash
   sudo ./install.sh PREFIX=/custom/path BINDIR=/custom/bin MANDIR=/custom/man DOCDIR=/custom/doc
   ```

3. Verify installation:
   ```bash
   qemate version
   ```

### Arch Linux

Build and install using `PKGBUILD`:
```bash
makepkg -si
```

### Uninstallation

Remove Qemate:
```bash
sudo ./uninstall.sh
```

## Usage

Qemate uses the syntax: `qemate COMMAND [SUBCOMMAND] [OPTIONS]`.

### Commands

- **VM Management**:
  - `qemate vm create NAME [--memory VALUE] [--cores VALUE] [--disk-size VALUE] [--machine VALUE] [--iso PATH] [--os-type VALUE] [--enable-audio]`: Create a VM.
  - `qemate vm start NAME [--iso PATH] [--headless] [--extra-args "QEMU_OPTIONS"]`: Start a VM.
  - `qemate vm stop NAME [--force]`: Stop a VM.
  - `qemate vm delete NAME [--force]`: Delete a VM.
  - `qemate vm list`: List all VMs.
  - `qemate vm status NAME`: Check VM status.
  - `qemate vm edit NAME`: Edit VM configuration.
  - `qemate vm wizard`: Interactively create a VM.
  - `qemate vm lock NAME`: Lock a VM.
  - `qemate vm unlock NAME`: Unlock a VM.

- **Networking**:
  - `qemate net port add NAME --host PORT --guest PORT [--proto PROTO]`: Add port forward (default proto: tcp).
  - `qemate net port remove NAME PORT[:PROTO]`: Remove port forward.
  - `qemate net port list NAME`: List port forwards.
  - `qemate net set NAME {nat|user|none}`: Set network type (default: user).
  - `qemate net model NAME [{e1000|virtio-net-pci}]`: Set/display network model (default: virtio-net-pci).

- **Other**:
  - `qemate help`: Display help.
  - `qemate version`: Show version (2.0.0).

### Examples

- Create a VM with 4GB memory and 4 cores:
  ```bash
  qemate vm create myvm --memory 4G --cores 4
  ```

- Start a VM with an ISO in headless mode:
  ```bash
  qemate vm start myvm --iso /path/to/install.iso --headless
  ```

- Stop a VM forcefully:
  ```bash
  qemate vm stop myvm --force
  ```

- Delete a VM without confirmation:
  ```bash
  qemate vm delete myvm --force
  ```

- Lock/unlock a VM:
  ```bash
  qemate vm lock myvm
  qemate vm unlock myvm
  ```

- Add a TCP port forward:
  ```bash
  qemate net port add myvm --host 8080 --guest 80 --proto tcp
  ```

- Remove a port forward:
  ```bash
  qemate net port remove myvm 8080:tcp
  ```

- Set network type to NAT:
  ```bash
  qemate net set myvm nat
  ```

- Set network model to virtio-net-pci:
  ```bash
  qemate net model myvm virtio-net-pci
  ```

- List VMs:
  ```bash
  qemate vm list
  ```

- Check VM status:
  ```bash
  qemate vm status myvm
  ```

For detailed help:
```bash
qemate help
qemate vm help
qemate net help
```

## Configuration

- **VM Directory**: `${HOME}/QVMs` (customize with `QEMATE_VM_DIR`).
- **Configurations**: `${HOME}/QVMs/VM_NAME/config`.
- **Disk Images**: `${HOME}/QVMs/VM_NAME/disk.qcow2` (qcow2 format).
- **Logs**:
  - Qemate logs: `${HOME}/QVMs/VM_NAME/logs/error.log`.
  - QEMU output: `${HOME}/QVMs/VM_NAME/qemu.log`.
- **Logging Verbosity**: Set `LOG_LEVEL` (DEBUG, INFO, WARNING, ERROR; default: ERROR).

## Troubleshooting

- **KVM Issues**: Ensure `/dev/kvm` is accessible:
  ```bash
  sudo usermod -a -G kvm $USER
  ```
- **Audio Issues**: Verify PipeWire is installed and running for `--enable-audio`.
- **Errors**: Check logs at `${HOME}/QVMs/VM_NAME/logs/error.log` or `${HOME}/QVMs/VM_NAME/qemu.log`.

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for details. Key guidelines:
- Follow the Google Shell Style Guide.
- Use 4-space indentation.
- Update `README.md`, `CHANGELOG.md`, and `VERSION` for changes.
- Submit pull requests with clear descriptions.

## License

Qemate is released under the [MIT License](LICENSE).

## Author

Developed by Daniel Zilli.

## Links

- [GitHub Repository](https://github.com/dlzi/qemate)
- [Issue Tracker](https://github.com/dlzi/qemate/issues)