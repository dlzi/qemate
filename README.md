# Qemate — QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and configuration, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, resize, list, and check status of VMs.
- **Security & Robustness**:
  - **Hardened Config Parsing**: Strict regex-based configuration lexer with key whitelisting (prevents arbitrary code execution).
  - **Ownership Verification**: Enforces strict file permissions and user-ownership checks for VM configurations.
  - **Locking**: Lock/unlock VMs to prevent accidental modifications or deletion.
- **Pre-flight Validation**: Centralized dependency checking ensures all required host binaries (`swtpm`, `virtiofsd`, etc.) are present before a VM attempts to start.
- **Networking**: Configure network types (`user`, `passt`, `tap`, `none`), network models (`virtio-net-pci`, `e1000`), and port forwarding with TCP/UDP support.
- **Audio Support**: Enable PCIe passthrough to expose a host audio device directly to the guest via VFIO.
- **Performance**: Optimized defaults for Linux and Windows VMs, with KVM acceleration and full VirtIO support.
- **Display**: SPICE display server with clipboard integration, dynamic resolution, and USB redirect.
- **USB Passthrough**: Attach and detach host USB devices to VMs by vendor:product ID.
- **Shared Folders**: Share host directories with guests via VirtFS (9P), VirtIO-FS (multi-share), or QEMU built-in SMB.
- **TPM 2.0**: Emulated TPM for Windows 11 requirements (via swtpm).
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR).

## Requirements

- **Bash**: Version 5.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (version 9.0 or higher).
- **Optional**:
  - **swtpm** and **swtpm-tools**: TPM 2.0 emulation.
  - **virtiofsd**: High-performance VirtIO-FS shared folders.
  - **virt-viewer**: SPICE display client (`remote-viewer`).
  - **passt**: Unprivileged network backend.
  - **samba** (`smbd`): Required for SMB shared folders.
  - **vfio-pci kernel module**: Required for PCIe audio passthrough. IOMMU must be enabled in BIOS/UEFI and via kernel parameters (`intel_iommu=on` or `amd_iommu=on`).
  - **edk2-ovmf**: UEFI firmware (Arch: `sudo pacman -S edk2-ovmf`).
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
   qemate --help
   ```

### Arch Linux

Build and install using `PKGBUILD`:
```bash
makepkg -si
```

### Uninstallation

```bash
sudo ./uninstall.sh
```

## Usage

Qemate uses the syntax: `qemate <command> [vm] [options]`.

### VM Commands

- `qemate create <n> [options]`
  Creates a new VM. Available options:
  - `--os-type linux|windows` — OS preset (default: linux)
  - `--memory SIZE` — e.g. `4G`, `8G`
  - `--cores N` — CPU cores (1–64)
  - `--disk-size SIZE` — e.g. `60G` (creates a qcow2 image; default)
  - `--disk-dev PATH` — e.g. `/dev/sdb` (raw physical block device; mutually exclusive with `--disk-size`)
  - `--machine TYPE[,accel=kvm|tcg]` — e.g. `q35,accel=kvm`
  - `--enable-audio` / `--no-audio`
  - `--enable-tpm` / `--no-tpm` — TPM 2.0 (requires swtpm)
  - `--uefi` / `--no-uefi` — UEFI firmware (default: on for Windows, off for Linux)
  - `--spice` / `--no-spice` — SPICE display
  - `--share-backend auto|virtfs|smb|virtiofs`

- `qemate start <n> [--headless] [--iso PATH] [--virtio-iso PATH] [--debug]`
  Starts a VM, optionally in headless mode, with a primary ISO, and/or a secondary ISO (e.g. VirtIO-Win drivers). `--debug` prints the full QEMU command before launch.

- `qemate stop <n> [--force]`
  Stops a VM gracefully (SIGTERM + 30s timeout) or forcefully (SIGKILL).

- `qemate delete <n> [--force]`
  Deletes a VM and all its data. Prompts for confirmation unless `--force` is used. Locked VMs require `--force`.

- `qemate resize <n> <SIZE|+SIZE> [--force]`
  Resizes the VM's disk image (e.g. `80G`, `+20G`). VM must be stopped unless `--force` is used (requires guest-side online resize support). Not supported for physical device VMs (`--disk-dev`).

- `qemate list`
  Lists all VMs with seven columns: `NAME`, `STATUS`, `LOCKED`, `OS`, `AUDIO`, `TPM`, `SPICE`.

- `qemate status <n>`
  Displays detailed VM configuration and runtime status, including CPU, memory, disk, network, UEFI state, share backend, port forwards, USB passthrough, and shared folders.

- `qemate configure <n>`
  Opens the VM config file directly in `$EDITOR`. After editing, the config is validated against the Qemate schema; if validation fails, the previous config is automatically restored. The VM must be stopped before configuring.

  The config file uses a simple `KEY="value"` format. Recognized keys:

  | Key                    | Description                                             | Example                  |
  |------------------------|---------------------------------------------------------|--------------------------|
  | `CORES`                | vCPU count                                              | `4`                      |
  | `MEMORY`               | RAM allocation                                          | `4G`                     |
  | `CPU_TYPE`             | QEMU CPU model                                          | `host`                   |
  | `MACHINE_TYPE`         | Machine type                                            | `q35`                    |
  | `MACHINE_OPTIONS`      | Machine options                                         | `accel=kvm`              |
  | `NETWORK_TYPE`         | Network backend (`user`, `passt`, `tap`, `none`)        | `user`                   |
  | `NETWORK_MODEL`        | NIC model (`virtio-net-pci`, `e1000`)                   | `virtio-net-pci`         |
  | `BRIDGE_NAME`          | Host bridge interface (tap mode only)                   | `br0`                    |
  | `PORT_FORWARDING_ENABLED` | Enable port forwarding (`0`/`1`)                    | `1`                      |
  | `PORT_FORWARDS`        | Comma-separated forward specs                           | `8080:80:tcp,53:53:udp`  |
  | `VIDEO_TYPE`           | Video device                                            | `qxl-vga`, `virtio-vga` |
  | `VRAM_SIZE_MB`         | VRAM in MiB                                             | `64`                     |
  | `DISK_INTERFACE`       | Disk interface (`virtio`, `nvme`, `ide`, `sata`)        | `virtio`                 |
  | `DISK_SIZE`            | Reported disk size                                      | `60G`                    |
  | `DISK_DEV`             | Physical block device path (if used)                    | `/dev/sdb`               |
  | `DISK_CACHE`           | Disk cache mode                                         | `writeback`              |
  | `DISK_IO`              | Disk I/O mode                                           | `io_uring`               |
  | `DISK_DISCARD`         | Discard/TRIM mode                                       | `unmap`                  |
  | `ENABLE_VIRTIO`        | Enable VirtIO stack (`0`/`1`)                           | `1`                      |
  | `MEMORY_PREALLOC`      | Pre-allocate memory (`0`/`1`)                           | `0`                      |
  | `MEMORY_SHARE`         | Shared memory backend for VirtIO-FS (`0`/`1`)           | `0`                      |
  | `ENABLE_AUDIO`         | Enable audio (`0`/`1`)                                  | `1`                      |
  | `AUDIO_PASSTHROUGH_PCI`| PCI address for PCIe audio passthrough                  | `01:00.1`                |
  | `USB_DEVICES`          | Comma-separated vendor:product IDs                      | `046d:c52b`              |
  | `SHARED_FOLDERS`       | Comma-separated tag:path pairs                          | `shared:/home/user/share`|
  | `SHARE_BACKEND`        | Share backend (`auto`, `virtfs`, `smb`, `virtiofs`)     | `auto`                   |
  | `ENABLE_TPM`           | Enable TPM 2.0 (`0`/`1`)                               | `1`                      |
  | `SPICE_ENABLED`        | Enable SPICE display (`0`/`1`)                          | `0`                      |
  | `SPICE_PORT`           | SPICE port (default: 5930)                              | `5930`                   |
  | `ENABLE_UEFI`          | Enable UEFI firmware (`0`/`1`)                          | `1`                      |
  | `LOCKED`               | VM lock state (`0`/`1`)                                 | `0`                      |

### PCIe Audio Passthrough

Qemate supports passing a host PCIe audio device directly to the guest via VFIO, bypassing the software audio stack entirely. Configure it by editing the VM config:

```bash
qemate configure myvm
```

Set the following fields:

```ini
ENABLE_AUDIO="1"
AUDIO_PASSTHROUGH_PCI="01:00.1"   # PCI address from lspci, e.g. 0000:01:00.1
```

**Requirements:**
- IOMMU enabled in BIOS/UEFI and kernel (`intel_iommu=on` or `amd_iommu=on`).
- `vfio-pci` kernel module available.
- The device's IOMMU group must not contain devices still needed by the host (check with `lspci` and `/sys/kernel/iommu_groups/`).

Qemate handles driver unbinding, VFIO binding, and full driver restoration automatically when the VM stops. If the PCI device is in a group with other devices, all devices in the group are moved to VFIO together (as required by the IOMMU isolation model).

> **Note**: PCIe passthrough takes exclusive control of the device while the VM is running. The host will lose access to that audio device until the VM is stopped.

### USB Passthrough

Find device IDs with `lsusb`, then:

- `qemate usb-add <n> <vendor:product>` — e.g. `qemate usb-add myvm 046d:c52b`
- `qemate usb-remove <n> <vendor:product>`
- `qemate usb-list <n>`

### Shared Folders

- `qemate share-add <n> /host/path` — tag auto-derived from folder name
- `qemate share-add <n> tag:/host/path` — explicit tag
- `qemate share-remove <n> <tag>`
- `qemate share-list <n>`

Set the backend via `qemate configure <n>` (edit `SHARE_BACKEND`):

| Backend    | Description                                                   | Guest mount                                                           |
|------------|---------------------------------------------------------------|-----------------------------------------------------------------------|
| `auto`     | Picks best available: virtiofs > virtfs (Linux) / smb (Windows) | —                                                                  |
| `virtfs`   | 9P filesystem, Linux guests, no extra dependencies            | `mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt/<tag>`      |
| `smb`      | QEMU built-in Samba, Windows plug-and-play, one folder only   | `\\10.0.2.4\qemu` in Explorer                                         |
| `virtiofs` | Best performance, multiple folders; requires virtiofsd        | Windows: WinFSP + VirtIO-FS driver; Linux: `mount -t virtiofs <tag> /mnt/<tag>` |

### Network Commands

Port forwarding:

- `qemate port-add <n> <[ip:]host:guest[:tcp|udp]>`
  Adds a port forward. Protocol defaults to `tcp` if omitted.

- `qemate port-remove <n> <[ip:]host:guest[:tcp|udp]>`
  Removes a port forward.

Network type, model, and bridge are configured via `qemate configure <n>` (edit `NETWORK_TYPE`, `NETWORK_MODEL`, `BRIDGE_NAME`).

**Network backends:**

| Type    | Description                                           |
|---------|-------------------------------------------------------|
| `user`  | SLiRP userspace NAT — default, no setup required      |
| `passt` | Unprivileged, uses host network stack directly         |
| `tap`   | Kernel-accelerated with vhost-net, requires host bridge |
| `none`  | No network interface                                  |

### Security Commands

- `qemate lock <n>` — Locks a VM to prevent modifications or deletion.
- `qemate unlock <n>` — Unlocks a VM.

### Examples

Create a Linux VM with 4GB memory and 4 cores:
```bash
qemate create myvm --os-type linux --memory 4G --cores 4
```

Create a Windows VM with TPM and UEFI enabled:
```bash
qemate create winvm --os-type windows --enable-tpm --uefi
```

Create a VM using a physical disk instead of a qcow2 image:
```bash
qemate create rawvm --os-type linux --disk-dev /dev/sdb
```

Start a Windows VM with OS and VirtIO driver ISOs:
```bash
qemate start winvm --iso /path/to/windows.iso --virtio-iso /path/to/virtio-win.iso
```

Start a VM in headless mode:
```bash
qemate start myvm --headless
```

Stop a VM forcefully:
```bash
qemate stop myvm --force
```

Delete a VM without confirmation:
```bash
qemate delete myvm --force
```

Resize a VM's disk to 100GB:
```bash
qemate resize myvm 100G
```

Lock/unlock a VM:
```bash
qemate lock myvm
qemate unlock myvm
```

Add TCP and UDP port forwards:
```bash
qemate port-add myvm 8080:80:tcp
qemate port-add myvm 53:53:udp
```

Add a shared folder:
```bash
qemate share-add myvm /home/user/shared
```

Pass through a USB device:
```bash
qemate usb-add myvm 046d:c52b
```

List all VMs:
```bash
qemate list
```

Check VM status:
```bash
qemate status myvm
```

## Configuration

- **VM Directory**: `${HOME}/QVMs` (override with `QEMATE_VM_DIR` env var).
- **Config file**: `${HOME}/QVMs/<n>/config` (permissions: `600`).
- **Disk Images**: `${HOME}/QVMs/<n>/disk.qcow2` (qcow2 format; absent when `--disk-dev` is used).
- **Logs**:
  - General: `${HOME}/QVMs/<n>/logs/qemate.log`
  - QEMU errors: `${HOME}/QVMs/<n>/logs/error.log`
  - virtiofsd (per share): `${HOME}/QVMs/<n>/logs/virtiofsd_<tag>.log`
- **Logging Verbosity**: Set via `LOG_LEVEL` environment variable (DEBUG, INFO, WARNING, ERROR; default: INFO).
- **Default Configurations**:
  - **Linux VMs**: 2 cores, 2GB RAM, 40GB disk, VirtIO disk, `virtio-net-pci`, UEFI off, audio off, SPICE off.
  - **Windows VMs**: 4 cores, 4GB RAM, 60GB disk, NVMe disk, `virtio-net-pci`, UEFI on, Hyper-V enlightenments, audio off, SPICE off (port 5930).

## Troubleshooting

### Pre-flight Failures
Qemate performs automated dependency checks during `start`. If a required binary (like `virtiofsd` for high-performance shares or `swtpm` for TPM support) is missing, the script will abort with a clear error message before initializing the VM.

### KVM Issues
Ensure `/dev/kvm` is accessible:
```bash
sudo usermod -aG kvm $USER
```
Log out and back in for changes to take effect.

### PCIe Audio Passthrough Issues

**IOMMU not found**: Ensure IOMMU is enabled in BIOS/UEFI (AMD-Vi / Intel VT-d) and that the kernel is booted with `amd_iommu=on` or `intel_iommu=on`. Verify with:
```bash
dmesg | grep -i iommu
ls /sys/kernel/iommu_groups/
```

**vfio-pci bind fails**: Check `dmesg` immediately after the failure. Common causes are the device sharing an IOMMU group with a host-active device, or the `vfio-pci` module not being loaded. Load it manually with:
```bash
sudo modprobe vfio vfio-pci
```

**Host audio lost after VM crash**: If the VM crashes without a clean shutdown, the audio device may remain bound to `vfio-pci`. Run `qemate stop <n>` — Qemate will detect the stale state and restore the original drivers. Or rebind manually:
```bash
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/vfio-pci/unbind
echo "snd_hda_intel" | sudo tee /sys/bus/pci/devices/0000:01:00.1/driver_override
echo "0000:01:00.1" | sudo tee /sys/bus/pci/drivers/snd_hda_intel/bind
```

### SPICE Display
Connect with `remote-viewer` after starting the VM:
```bash
remote-viewer spice://localhost:5930
```
If `remote-viewer` is not found, install `virt-viewer`.

### VirtIO Drivers (Windows)
Windows does not include VirtIO drivers by default. If using VirtIO disk or network interfaces, attach the VirtIO-Win ISO as a second drive during installation:
```bash
qemate start winvm \
  --iso /path/to/windows.iso \
  --virtio-iso /path/to/virtio-win.iso
```
Download from: https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/

### TPM Issues
Ensure both `swtpm` and `swtpm_setup` (from `swtpm-tools`) are installed. Check VM logs for TPM errors.

### Shared Folder Issues
- **virtfs**: No extra dependencies; Linux guests only.
- **virtiofs**: Requires `virtiofsd`. Windows guests also need WinFSP and the VirtIO-FS driver from the VirtIO-Win ISO.
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
```
Privileged ports (≤1024) may require root privileges.

### Security Violations
If a configuration file is owned by another user or has insecure global write permissions, Qemate will abort or automatically harden the permissions to `600`.

### Errors
Check logs at:
- `${HOME}/QVMs/<n>/logs/qemate.log` — General VM logs
- `${HOME}/QVMs/<n>/logs/error.log` — QEMU errors

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