# Qemate - QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and configuration, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, resize, list, and check status of VMs.
- **Security**: Lock/unlock VMs to prevent modifications or deletion.
- **Networking**: Configure network types (user, nat, none), network models (virtio-net-pci, e1000, rtl8139), and port forwarding with TCP/UDP protocol support.
- **Folder Sharing**: Share host folders with guests using VirtioFS (recommended for Linux), 9p (Linux), or SMB (Windows).
- **USB Passthrough**: Pass USB devices directly to VMs by vendor:product ID.
- **Audio Support**: Enable audio output via PipeWire (preferred), PulseAudio, or ALSA.
- **Performance**: Optimized defaults for Linux and Windows VMs, with KVM acceleration and VirtIO support.
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR).
- **ISO Management**: Boot VMs from ISO files for installation.

## Requirements

- **Bash**: Version 5.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (version 9.0 or higher).
- **Optional**:
  - **virtiofsd**: For VirtioFS shared folders (recommended for Linux guests).
  - **PipeWire, PulseAudio, or ALSA**: For audio support with `--enable-audio`.
  - **Samba**: For Windows guest folder sharing.
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

- `qemate vm create <name> [--os-type linux|windows] [--memory SIZE] [--cores N] [--disk-size SIZE] [--machine TYPE] [--enable-audio]`
  Creates a VM with specified parameters (e.g., `myvm --os-type linux --memory 4G --cores 4`).
- `qemate vm start <name> [--headless] [--iso PATH]`
  Starts a VM, optionally in headless mode or with an ISO file.
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
- `qemate vm configure <name> [cores|memory|audio] [value]`
  Configures VM settings (e.g., `cores 4`, `memory 2G`, `audio on`). Without arguments, opens the config file in an editor (e.g., nano or vi).

### Network Commands

- `qemate net type <name> [user|nat|none]`
  Sets or displays the network type.
- `qemate net model <name> [virtio-net-pci|e1000|rtl8139]`
  Sets or displays the network model (virtio-net-pci requires VirtIO enabled).
- `qemate net port add <name> <host:guest[:tcp|udp]>`
  Adds a port forward (e.g., `8080:80:tcp` or `8080:80:udp`). Protocol defaults to tcp if not specified.
- `qemate net port remove <name> <host:guest[:tcp|udp]>`
  Removes a port forward.

### Shared Folder Commands

- `qemate shared add <name> <folder_path> [mount_tag] [type]`
  Adds a shared folder. Types: `virtiofs` (default for Linux, requires virtiofsd), `9p` (Linux alternative), `smb` (Windows only). Mount tag is auto-generated if not provided.
- `qemate shared remove <name> <folder_path_or_mount_tag>`
  Removes the shared folder by path or mount tag.
- `qemate shared list <name>`
  Lists configured shared folders with mounting instructions.

### USB Commands

- `qemate usb add <name> <vendor_id:product_id>`
  Adds a USB device for passthrough (e.g., `1d6b:0002`). Use `lsusb` to find device IDs.
- `qemate usb remove <name> <vendor_id:product_id>`
  Removes a USB device from passthrough configuration.
- `qemate usb list <name>`
  Lists configured USB passthrough devices.

### Security Commands

- `qemate security lock <name>`
  Locks a VM to prevent modifications or deletion.
- `qemate security unlock <name>`
  Unlocks a VM to allow modifications.

### Other

- `qemate help`
  Displays detailed help information.
- `qemate version`
  Displays the program version (3.0.1).

### Examples

- Create a Linux VM with 4GB memory and 4 cores:
  ```bash
  qemate vm create myvm --os-type linux --memory 4G --cores 4
  ```

- Create a Windows VM with audio enabled:
  ```bash
  qemate vm create winvm --os-type windows --enable-audio
  ```

- Start a VM in headless mode with an ISO:
  ```bash
  qemate vm start myvm --headless --iso /path/to/ubuntu.iso
  ```

- Stop a VM forcefully:
  ```bash
  qemate vm stop myvm --force
  ```

- Delete a VM without confirmation:
  ```bash
  qemate vm delete myvm --force
  ```

- Resize a VM's disk to 100GB:
  ```bash
  qemate vm resize myvm 100G
  ```

- Lock/unlock a VM:
  ```bash
  qemate security lock myvm
  qemate security unlock myvm
  ```

- Configure network type to NAT:
  ```bash
  qemate net type myvm nat
  ```

- Set network model to e1000:
  ```bash
  qemate net model myvm e1000
  ```

- Add TCP and UDP port forwards:
  ```bash
  qemate net port add myvm 8080:80:tcp
  qemate net port add myvm 53:53:udp
  ```

- Add a VirtioFS shared folder (Linux):
  ```bash
  qemate shared add myvm ~/Documents mydocs virtiofs
  ```

- Add a 9p shared folder (Linux):
  ```bash
  qemate shared add myvm ~/Downloads downloads 9p
  ```

- Add an SMB shared folder (Windows):
  ```bash
  qemate shared add myvm ~/Shared winshare smb
  ```

- Add USB device for passthrough:
  ```bash
  qemate usb add myvm 046d:c52b
  ```

- List all VMs:
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
```

## Configuration

- **VM Directory**: `${HOME}/QVMs` (customizable via `QEMATE_VM_DIR` environment variable).
- **Configurations**: Stored in `${HOME}/QVMs/<name>/config`.
- **Disk Images**: Stored in `${HOME}/QVMs/<name>/disk.qcow2` (qcow2 format).
- **Logs**:
  - General: `${HOME}/QVMs/<name>/logs/qemate_vm.log`.
  - Errors: `${HOME}/QVMs/<name>/logs/error.log`.
  - VirtioFS: `${HOME}/QVMs/<name>/logs/virtiofsd_<tag>.log`.
- **Logging Verbosity**: Set via `LOG_LEVEL` environment variable (DEBUG, INFO, WARNING, ERROR; default: INFO).
- **Default Configurations**:
  - **Linux VMs**: 2 cores, 2GB RAM, 40GB disk, virtio-net-pci, virtio disk interface, VirtIO enabled, audio disabled.
  - **Windows VMs**: 2 cores, 4GB RAM, 60GB disk, e1000 network model, ide-hd disk interface, VirtIO disabled, audio enabled.

## Troubleshooting

### KVM Issues
Ensure `/dev/kvm` is accessible:
```bash
sudo usermod -a -G kvm $USER
```
Log out and back in for changes to take effect. Check acceleration status with `qemate vm status <name>`.

### Audio Issues
Ensure PipeWire (preferred), PulseAudio, or ALSA is installed and running for `--enable-audio`. Check logs for audio errors. PipeWire is prioritized over PulseAudio and ALSA.

### Folder Sharing

#### Linux Guests (VirtioFS - Recommended)

VirtioFS provides the best performance for Linux guests:

1. Install virtiofsd on the host:
   ```bash
   # Arch Linux
   sudo pacman -S virtiofsd
   
   # Ubuntu/Debian
   sudo apt install virtiofsd
   ```

2. Add the shared folder:
   ```bash
   qemate shared add myvm ~/Documents mydocs virtiofs
   ```

3. Mount in the guest:
   ```bash
   sudo mkdir -p /mnt/mydocs
   sudo mount -t virtiofs mydocs /mnt/mydocs
   ```

4. For automatic mounting, add to `/etc/fstab`:
   ```
   mydocs /mnt/mydocs virtiofs defaults 0 0
   ```

#### Linux Guests (9p Alternative)

If virtiofsd is not available, use 9p:

1. Add the shared folder:
   ```bash
   qemate shared add myvm ~/Documents mydocs 9p
   ```

2. Mount in the guest:
   ```bash
   sudo mkdir -p /mnt/mydocs
   sudo mount -t 9p -o trans=virtio,version=9p2000.L mydocs /mnt/mydocs
   ```

3. For automatic mounting, add to `/etc/fstab`:
   ```
   mydocs /mnt/mydocs 9p trans=virtio,version=9p2000.L 0 0
   ```

#### Windows Guests (SMB)

1. Ensure Samba is installed on the host and network type is `user` or `nat`.

2. Add the shared folder:
   ```bash
   qemate shared add myvm ~/Shared winshare smb
   ```

3. In Windows, access via File Explorer:
   ```
   \\10.0.2.4\qemu
   ```

4. If access fails, enable "Insecure guest logons":
   - **Windows Pro/Enterprise**: Run `gpedit.msc`, navigate to `Computer Configuration -> Administrative Templates -> Network -> Lanman Workstation`. Enable "Enable insecure guest logons". Reboot.
   - **Windows Home**: Run `regedit`, navigate to `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters`. Set DWORD `AllowInsecureGuestAuth` to `1`. Reboot.

5. Enable SMB 1.0/CIFS Client if needed:
   - Control Panel -> Programs -> Turn Windows features on or off
   - Enable "SMB 1.0/CIFS File Sharing Support" -> "SMB 1.0/CIFS Client"
   - Reboot

6. Network/Firewall:
   - Set VM network to "Private"
   - Temporarily disable Windows Defender Firewall to test connectivity

### USB Passthrough

USB passthrough requires proper permissions:

1. Find your device ID:
   ```bash
   lsusb
   # Example output: Bus 001 Device 005: ID 046d:c52b Logitech, Inc.
   ```

2. Add the device:
   ```bash
   qemate usb add myvm 046d:c52b
   ```

3. If you get permission errors, create a udev rule:
   ```bash
   # Create /etc/udev/rules.d/99-qemu-usb.rules
   SUBSYSTEM=="usb", ATTR{idVendor}=="046d", ATTR{idProduct}=="c52b", MODE="0666"
   ```

4. Reload udev rules:
   ```bash
   sudo udevadm control --reload-rules
   sudo udevadm trigger
   ```

5. Alternatively, add your user to the appropriate group (varies by distribution):
   ```bash
   sudo usermod -a -G plugdev $USER
   ```

6. Quick workaround - Run qemate with sudo while preserving environment variables:
   ```bash
   sudo -E qemate vm start myvm
   ```
   Note: The `-E` flag preserves your environment variables (including `$HOME`) so the VM is still managed in your user directory.

Note: Some USB devices (especially input devices) may need to be unbound from the host before passthrough works properly.

### Port Forwarding Issues

Ensure host ports are not in use:
```bash
ss -tuln | grep :PORT
# or
netstat -tuln | grep :PORT
```

Privileged ports (≤1024) may require root privileges. The script checks for port conflicts with both system services and other VMs.

### Errors

Check logs at:
- `${HOME}/QVMs/<name>/logs/qemate_vm.log` - General VM logs
- `${HOME}/QVMs/<name>/logs/error.log` - QEMU errors
- `${HOME}/QVMs/<name>/logs/virtiofsd_<tag>.log` - VirtioFS daemon logs

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