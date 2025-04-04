# Qemate - QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility designed to simplify the management of QEMU virtual machines (VMs). It provides an intuitive interface for creating, starting, stopping, and deleting VMs, as well as configuring their networking. Leveraging QEMU with KVM acceleration, Qemate ensures enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, and list virtual machines with ease. There is also an easy to use wizard mode!
- **Networking**: Configure port forwarding, network types (NAT, user, none), and network models (e1000, virtio-net-pci).
- **Performance**: Optimized for KVM acceleration with sensible defaults.
- **Extensible**: Modular Bash script design for easy customization.

## Requirements

- **QEMU**: Version 9.0.0 or higher, installed and configured.
- **KVM**: Optional, for hardware acceleration (recommended).
- **Bash**: Version 4.0 or higher.
- **Linux**: Tested on common distributions.

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/dlzi/qemate.git
   cd qemate
   ```

2. Install using `make`:
   ```bash
   sudo make install
   ```

   This installs Qemate to the default prefix `/usr/local`. To specify a custom prefix:
   ```bash
   sudo make install PREFIX=/custom/path
   ```

3. Verify installation:
   ```bash
   qemate version
   ```

### Manual Installation

Run the provided `install.sh` script:
```bash
sudo ./install.sh
```

### Uninstallation

To remove Qemate:
```bash
sudo ./uninstall.sh
```

Or, if installed via `make`:
```bash
sudo make uninstall
```

## Usage

Qemate operates via a simple command structure: `qemate COMMAND [SUBCOMMAND] [OPTIONS]`.

### Examples

#### Create a VM
Create a VM named `myvm` with 4GB memory and 4 CPU cores:
```bash
qemate vm create myvm --memory 4G --cores 4
```

#### Start a VM with an ISO
Start `myvm` using an installation ISO:
```bash
qemate vm start myvm --iso /path/to/install.iso
```

#### Stop a VM
Stop `myvm` gracefully:
```bash
qemate vm stop myvm
```

#### Delete a VM
Delete `myvm` and its files (requires confirmation unless `--force` is used):
```bash
qemate vm delete myvm
```
#### Add a Port Forward
Forward host port 8080 to guest port 80:
```bash
qemate net port add myvm --host 8080 --guest 80
```

#### Set Network Type
Set the network type to NAT:
```bash
qemate net set myvm nat
```

#### Set Network Model
Set the network model to e1000 (defaults to e1000 if not specified):
```bash
qemate net model myvm e1000
```

Or use virtio-net-pci:
```
qemate net model myvm virtio-net-pci
```

For detailed help:
```bash
qemate help
qemate vm help
```

## Configuration

VM configurations are stored in `${HOME}/QVMs`. Logs are written to `${HOME}/QVMs/logs/qemate.log`.

## Testing

Run the included BATS tests:
```bash
make test
```

Tests are located in `tests/qemate_tests.bats` and use mock implementations for QEMU and system commands.

## Contributing

Contributions are welcome! Please:
1. Fork the repository.
2. Create a feature branch.
3. Submit a pull request with clear descriptions and test coverage.

## License

Qemate is released under the [BSD 3-Clause License](LICENSE).

## Author

Developed by Daniel Zilli.

## Version

Current version: 1.1.1 (April 2025)
