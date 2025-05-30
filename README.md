# Qemate - QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and configuration, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, delete, resize, list, and check status of VMs.
- **Security**: Lock/unlock VMs to prevent modifications or deletion.
- **Networking**: Configure network types (user, nat, none), network models (virtio-net-pci, e1000, rtl8139), and port forwarding.
- **Folder Sharing**: Share one host folder with Linux guests (via VirtIO 9P filesystem) or Windows guests (via Samba/SMB).
- **Audio Support**: Enable audio output via PipeWire (preferred), PulseAudio, or ALSA.
- **Performance**: Optimized defaults for Linux and Windows VMs, with KVM acceleration and VirtIO support.
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR).
- **ISO Management**: Boot VMs from ISO files for installation.

## Requirements

- **Bash**: Version 5.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (version 9.0 or higher).
- **Optional**:
  - PipeWire, PulseAudio, or ALSA: For audio support with `--enable-audio`.
  - Samba: For Windows guest folder sharing.
  - `realpath`, `ss`, or `netstat`: For enhanced folder and network management.
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
  Adds a port forward (e.g., `8080:80:tcp`).
- `qemate net port remove <name> <host:guest[:tcp|udp]>`
  Removes a port forward.

### Shared Folder Commands

- `qemate shared add <name> <folder_path> [mount_tag] [security_model]`
  Adds a single shared folder (e.g., `~/Documents mydocs mapped-xattr`). Only one shared folder is supported per VM.
- `qemate shared remove <name> <folder_path_or_mount_tag>`
  Removes the shared folder by path or mount tag.
- `qemate shared list <name>`
  Lists the configured shared folder.

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

- Add a port forward (host 8080 to guest 80):
  ```bash
  qemate net port add myvm 8080:80:tcp
  ```

- Add a shared folder:
  ```bash
  qemate shared add myvm ~/Documents mydocs mapped-xattr
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
- **Logging Verbosity**: Set via `LOG_LEVEL` environment variable (DEBUG, INFO, WARNING, ERROR; default: INFO).
- **Default Configurations**:
  - **Linux VMs**: 2 cores, 2GB RAM, 20GB disk, virtio-net-pci, virtio disk interface, VirtIO enabled, audio disabled.
  - **Windows VMs**: 2 cores, 4GB RAM, 60GB disk, e1000 network model, ide-hd disk interface, VirtIO disabled, audio enabled.

## Troubleshooting

- **KVM Issues**: Ensure `/dev/kvm` is accessible:
  ```bash
  sudo usermod -a -G kvm $USER
  ```
  Check acceleration status with `qemate vm status <name>`.

- **Audio Issues**: Ensure PipeWire (preferred), PulseAudio, or ALSA is installed and running for `--enable-audio`. Check logs for audio errors. PipeWire is prioritized over PulseAudio and ALSA.

- **Folder Sharing (Linux Guests)**:
  Only one shared folder is supported per VM. Mount shared folders in the guest:
  ```bash
  sudo mkdir -p /mnt/<mount_tag>
  sudo mount -t 9p -o trans=virtio <mount_tag> /mnt/<mount_tag>
  ```
  For persistence, add to `/etc/fstab`:
  ```bash
  <mount_tag> /mnt/<mount_tag> 9p trans=virtio,version=9p2000.L 0 0
  ```
  **Workaround for Multiple Folders**: To share multiple folders despite the single-folder limitation, use a common parent folder with symbolic links:
  ```bash
  mkdir -p ~/Shared
  ln -s ~/Downloads ~/Shared/Downloads
  ln -s ~/Applications ~/Shared/Applications
  ```
  Share `~/Shared` via VirtIO 9P in Qemate:
  ```bash
  qemate shared add myvm ~/Shared shared_folder mapped-xattr
  ```
  In the Linux guest, mount the shared folder as above, and access `Downloads` and `Applications` under `/mnt/shared_folder`.

- **Folder Sharing (Windows Guests)**:
  Ensure Samba is installed on the host and the network type is `user` or `nat`. Map the network drive in Windows:
  ```
  \\<host_ip>\<mount_tag>
  ```
  Example:
  ```
  \\10.0.2.4\qemu
  ```
  **Workaround for Multiple Folders**: To share multiple folders, use a common parent folder with symbolic links on the Linux host:
  ```bash
  mkdir -p ~/Shared
  ln -s ~/Downloads ~/Shared/Downloads
  ln -s ~/Applications ~/Shared/Applications
  ```
  Share `~/Shared` via SMB in Qemate:
  ```bash
  qemate shared add myvm ~/Shared share0
  ```
  In Windows, navigate to `\\10.0.2.4\share0`. You will see:
  - Downloads
  - Applications
  
  If access fails:
  1. **Enable "Insecure guest logons"** (Windows 10+):
     - Run `gpedit.msc`, navigate to `Computer Configuration -> Administrative Templates -> Network -> Lanman Workstation`.
     - Enable "Enable insecure guest logons".
     - Reboot the VM.
  2. **Registry Fix (Windows Home)**:
     - Run `regedit`, navigate to `HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters`.
     - Set DWORD `AllowInsecureGuestAuth` to `1`.
     - Reboot the VM.
  3. **Enable SMB 1.0/CIFS Client**:
     - Control Panel -> Programs -> Turn Windows features on or off.
     - Enable "SMB 1.0/CIFS File Sharing Support" -> "SMB 1.0/CIFS Client".
     - Reboot the VM.
  4. **Network/Firewall**:
     - Set VM network to "Private".
     - Temporarily disable Windows Defender Firewall to test connectivity.

- **Port Forwarding Issues**:
  Ensure host ports are not in use (`ss -tuln` or `netstat -tuln`). Privileged ports (≤1024) may require root privileges.

- **Errors**: Check logs at `${HOME}/QVMs/<name>/logs/qemate_vm.log` or `${HOME}/QVMs/<name>/logs/error.log`.

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