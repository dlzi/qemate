# Qemate - QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and configuration, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, resize, list, and check status of VMs.
- **Security & Robustness**: 
  - **Hardened Config Parsing**: Strict regex-based configuration lexer with key whitelisting (prevents arbitrary code execution).
  - **Ownership Verification**: Enforces strict file permissions and user-ownership checks for VM configurations.
  - **Locking**: Lock/unlock VMs to prevent accidental modifications or deletion.
- **Pre-flight Validation**: Centralized dependency checking ensures all required host binaries (swtpm, virtiofsd, etc.) are present before a VM attempts to start.
- **Networking**: Configure network types (user, nat, none), network models (virtio-net-pci, e1000, rtl8139), and port forwarding with TCP/UDP support.
- **Audio Support**: Enable audio output via PipeWire (preferred), PulseAudio, or ALSA.
- **Performance**: Optimized defaults for Linux and Windows VMs, with KVM acceleration and full VirtIO support.
- **Display**: SPICE display server with clipboard integration, dynamic resolution, and USB redirect.
- **USB Passthrough**: Attach and detach host USB devices to VMs by vendor:product ID.
- **Shared Folders**: Share host directories with guests via VirtFS (9P), VirtIO-FS, or QEMU built-in SMB.
- **TPM 2.0**: Emulated TPM for Windows 11 requirements (via swtpm).
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR).

## Requirements

- **Bash**: Version 5.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (version 9.0 or higher).
- **Optional**:
  - **PipeWire, PulseAudio, or ALSA**: For audio support.
  - **swtpm**: TPM 2.0 emulation (`apt install swtpm`).
  - **virtiofsd**: High-performance VirtIO-FS shared folders (`apt install virtiofsd`).
  - **virt-viewer**: SPICE display client (`apt install virt-viewer`).
  - **realpath, ss, or netstat**: For enhanced folder and network management.
  - **lsusb and udevadm**: For USB passthrough verification.
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
   qemate --version
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

Qemate uses the syntax: `qemate <group> <command> [options]`.

### VM Commands

- `qemate vm create <name> [options]`
  Creates a VM. Available options:
  - `--os-type linux|windows` — OS preset (default: linux)
  - `--memory SIZE` — e.g. `4G`, `8G`
  - `--cores N` — CPU cores (1–64)
  - `--disk-size SIZE` — e.g. `60G`
  - `--machine TYPE` — e.g. `q35,accel=kvm`
  - `--enable-audio` / `--no-audio`
  - `--enable-tpm` / `--no-tpm` — TPM 2.0 (requires swtpm)
  - `--spice` / `--no-spice` — SPICE display (auto-enabled for Windows)
  - `--share-backend auto|virtfs|smb|virtiofs`

- `qemate vm start <name> [--headless] [--iso PATH] [--virtio-iso PATH]`
  Starts a VM, optionally in headless mode, with a primary ISO, and/or a secondary ISO (e.g. VirtIO-Win drivers).

- `qemate vm stop <name> [--force]`
  Stops a VM gracefully or forcefully.

- `qemate vm delete <name> [--force]`
  Deletes a VM, optionally skipping confirmation.

- `qemate vm resize <name> <size> [--force]`
  Resizes the VM's disk (e.g., `20G`, `100G`). VM must be stopped and unlocked unless `--force` is used.

- `qemate vm list`
  Lists all VMs with their status and lock state.

- `qemate vm status <name>`
  Displays detailed VM configuration and status.

- `qemate vm configure <name> [setting value]`
  Configures VM settings. Available settings:
  - `cores` — integer 1–64
  - `memory` — e.g. `4G`, `2048M`
  - `audio` — `on`/`off`
  - `tpm` — `on`/`off`
  - `spice` — `on`/`off`
  - `spice-port` — port number (1024–65535)
  - `video` — `virtio-vga`, `virtio-gpu`, `qxl-vga`, `qxl`, `std`, `vmware`
  - `share-backend` — `auto`, `virtfs`, `smb`, `virtiofs`

### USB Passthrough

Find device IDs with `lsusb`, then:

- `qemate usb add <name> <vendor:product>` — e.g. `usb add myvm 046d:c52b`
- `qemate usb remove <name> <vendor:product>`
- `qemate usb list <name>`

### Shared Folders

- `qemate share add <name> /host/path` — tag auto-derived from folder name
- `qemate share add <name> tag:/host/path` — explicit tag
- `qemate share remove <name> <tag>`
- `qemate share list <name>`

Backends (set via `vm configure <name> share-backend <value>`):

| Backend | Description | Guest mount |
|---|---|---|
| `auto` | Picks best available: virtiofs > virtfs (Linux) / smb (Windows) | — |
| `virtfs` | 9P filesystem, Linux guests, zero dependencies | `mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt/<tag>` |
| `smb` | QEMU built-in Samba, Windows plug-and-play, one folder only | `\\10.0.2.4\qemu` in Explorer |
| `virtiofs` | Best performance, multiple folders; requires virtiofsd | Windows: WinFSP + VirtIO-FS driver; Linux: `mount -t virtiofs <tag> /mnt/<tag>` |

### Network Commands

- `qemate net type <name> <user|nat|none>`
  Sets the network type.

- `qemate net model <name> <virtio-net-pci|e1000|rtl8139>`
  Sets the network model (virtio-net-pci requires VirtIO enabled).

- `qemate net port add <name> <host:guest[:tcp|udp]>`
  Adds a port forward (e.g. `8080:80:tcp`). Protocol defaults to `tcp` if omitted.

- `qemate net port remove <name> <host:guest[:tcp|udp]>`
  Removes a port forward.

### Security Commands

- `qemate security lock <name>` — Locks a VM to prevent modifications or deletion.
- `qemate security unlock <name>` — Unlocks a VM to allow modifications.

### Examples

Create a Linux VM with 4GB memory and 4 cores:
```bash
qemate vm create myvm --os-type linux --memory 4G --cores 4
```

Create a Windows VM with audio and TPM enabled:
```bash
qemate vm create winvm --os-type windows --enable-audio --enable-tpm
```

Start a Windows VM with OS and VirtIO driver ISOs:
```bash
qemate vm start winvm --iso /path/to/windows.iso --virtio-iso /path/to/virtio-win-0.1.285.iso
```

Start a VM in headless mode:
```bash
qemate vm start myvm --headless
```

Stop a VM forcefully:
```bash
qemate vm stop myvm --force
```

Delete a VM without confirmation:
```bash
qemate vm delete myvm --force
```

Resize a VM's disk to 100GB:
```bash
qemate vm resize myvm 100G
```

Lock/unlock a VM:
```bash
qemate security lock myvm
qemate security unlock myvm
```

Configure network type to NAT:
```bash
qemate net type myvm nat
```

Set network model to e1000:
```bash
qemate net model myvm e1000
```

Add TCP and UDP port forwards:
```bash
qemate net port add myvm 8080:80:tcp
qemate net port add myvm 53:53:udp
```

Add a shared folder:
```bash
qemate share add myvm /home/user/shared
```

Pass through a USB device:
```bash
qemate usb add myvm 046d:c52b
```

List all VMs:
```bash
qemate vm list
```

Check VM status:
```bash
qemate vm status myvm
```

## Configuration

- **VM Directory**: `${HOME}/QVMs`.
- **Configurations**: Stored in `${HOME}/QVMs/<name>/config`.
- **Disk Images**: Stored in `${HOME}/QVMs/<name>/disk.qcow2` (qcow2 format).
- **Logs**:
  - General: `${HOME}/QVMs/<name>/logs/qemate_vm.log`
  - Errors: `${HOME}/QVMs/<name>/logs/error.log`
- **Logging Verbosity**: Set via `LOG_LEVEL` environment variable (DEBUG, INFO, WARNING, ERROR; default: INFO).
- **Default Configurations**:
  - **Linux VMs**: 2 cores, 2GB RAM, 40GB disk, virtio-net-pci, virtio disk interface, VirtIO enabled, audio disabled, SPICE disabled.
  - **Windows VMs**: 4 cores, 4GB RAM, 60GB disk, virtio-net-pci, NVMe disk interface, VirtIO enabled, audio disabled, SPICE disabled (port 5930).

## Troubleshooting

### Pre-flight Failures
Qemate performs automated dependency checks during the `vm start` sequence. If a required binary (like `virtiofsd` for high-performance shares or `swtpm` for TPM support) is missing, the script will abort with a clear error message before initializing the VM.

### KVM Issues
Ensure `/dev/kvm` is accessible:
```bash
sudo usermod -a -G kvm $USER
```
Log out and back in for changes to take effect.

### Audio Issues
Ensure PipeWire (preferred), PulseAudio, or ALSA is installed and running. Check logs for audio errors.

### SPICE Display
Connect with `remote-viewer` after starting the VM:
```bash
remote-viewer spice://localhost:5930
```
If `remote-viewer` is not found: `apt install virt-viewer`.

### VirtIO Drivers (Windows)
Windows does not include VirtIO drivers by default. If using VirtIO disk or network interfaces, attach the VirtIO-Win ISO as a second drive during installation:
```bash
qemate vm start winvm \
  --iso /path/to/windows.iso \
  --virtio-iso /path/to/virtio-win.iso
```
Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

### TPM Issues
Ensure `swtpm` is installed: `apt install swtpm`. Check logs for TPM errors.

### Shared Folder Issues
- **virtfs**: No extra dependencies; Linux guests only.
- **virtiofs**: Requires `apt install virtiofsd`. Windows guests also need WinFSP and the VirtIO-FS driver from the VirtIO-Win ISO.
- **smb**: Built into QEMU; Windows guests only; limited to one folder.

### Shared Folder (SMB) Issues on Windows 10 LTSC 2021

QEMU's built-in SMB share uses SMB 1.0, which is disabled by default on Windows 10. Follow these steps to enable it:

1. **Enable SMB 1.0 feature**:
   `Control Panel → Programs → Programs and Features → Turn Windows features on or off → SMB 1.0/CIFS File Sharing Support` → check and confirm.

2. **Enable network discovery and file sharing**:
   `Control Panel → Network and Sharing Center → Change advanced sharing settings` → turn on **Network discovery** and **File and Printer Sharing**.

3. **Allow insecure guest logons via Group Policy**:
   Run `gpedit.msc` → `Computer Configuration → Administrative Templates → Network → Lanman Workstation` → open **Enable insecure guest logons** → set to **Enabled**.

4. **Reboot** the Windows VM.

After rebooting, the share should be accessible at `\\10.0.2.4\qemu` in File Explorer.

> **Note**: SMB 1.0 has known security vulnerabilities. This configuration is acceptable for isolated local VMs but should not be used in exposed or production environments.

### Port Forwarding Issues
Ensure host ports are not already in use:
```bash
ss -tuln | grep :PORT
# or
netstat -tuln | grep :PORT
```
Privileged ports (≤1024) may require root privileges.

### Security Violations
If a configuration file is owned by another user or has insecure global write permissions, Qemate will abort or automatically harden the permissions to `600` to ensure the integrity of the VM environment.

### Errors
Check logs at:
- `${HOME}/QVMs/<name>/logs/qemate_vm.log` — General VM logs
- `${HOME}/QVMs/<name>/logs/error.log` — QEMU errors

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