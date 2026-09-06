# qemate — QEMU Virtual Machine Manager

Qemate is a streamlined command-line utility for managing QEMU virtual machines (VMs). It simplifies VM creation, control, and configuration, leveraging QEMU with KVM acceleration for enhanced performance when supported by the host system.

## Features

- **VM Management**: Create, start, stop, restart, wait, delete, resize, list, status, clone, and inspect logs of VMs.
- **Security & Robustness**:
  - **Hardened Config Parsing**: Strict regex-based configuration lexer with key whitelisting (prevents arbitrary code execution).
  - **Ownership Verification**: Enforces strict file permissions and user-ownership checks for VM configurations.
  - **Locking**: Lock/unlock VMs to prevent start, resize, configuration edits, and accidental deletion.
- **Pre-flight Validation**: Dependency checks plus disk-space and memlock validation at create/start time so failures surface early.
- **macOS via QEMU/KVM**: Optional macOS VM creation and installer preparation using OpenCore and the recovery workflow from [OSX-KVM](https://github.com/kholia/OSX-KVM), with a shared host cache for multi-VM installs.
- **Safe Lifecycle Control**: Per-VM lifecycle locking and QMP-based ACPI shutdown prevent overlapping starts and surprise hard power-offs.
- **Detached Operation**: `start --detach` returns after QEMU is ready while a private supervisor preserves lifecycle cleanup.
- **Automation Helpers**: `wait` blocks until QMP reports ready or the VM is stopped; `console` opens an interactive QMP session; `restart` coordinates stop + start.
- **Performance Profiles**: Portable balanced defaults plus an opt-in performance profile with preallocated/locked memory (hugepages when available), tuned VirtIO queues, and optimized qcow2 creation options.
- **Diagnostics**: `doctor` and `start --dry-run` expose host readiness, port-forward conflicts, and the effective QEMU command without launching a VM.
- **Networking**: Configure network types (`user`, `passt`, `tap`, `none`), network models (`virtio-net-pci`, `e1000`), and port forwarding with TCP/UDP support (host port checked at `port-add` time).
- **Audio Support**: Emulated Intel HDA via QEMU's default host backend, or optional PCIe passthrough of a host audio device via VFIO (passwordless sudo required for detached VFIO starts).
- **Performance**: Optimized defaults for Linux and Windows VMs, with KVM acceleration and full VirtIO support; host probes (QEMU version, OVMF, virtiofsd, netcat) are memoized.
- **Display**: SPICE display server with clipboard integration and dynamic resolution.
- **USB Passthrough**: Attach and detach host USB devices to VMs by vendor:product ID.
- **Shared Folders**: Share host directories with guests via VirtFS (9P), VirtIO-FS (multi-share, with performance-oriented daemon flags), or QEMU user-mode SMB.
- **TPM 2.0**: Emulated TPM for Windows 11 requirements (via swtpm).
- **Logging**: Detailed logs with configurable verbosity (`LOG_LEVEL`: DEBUG, INFO, WARNING, ERROR), automatic rotation, and a `logs` command to tail them.

## Requirements

- **Bash**: Version 5.0 or higher.
- **QEMU**: `qemu-system-x86_64` and `qemu-img` (version 10.0 or higher).
- **util-linux**: `flock` for lifecycle locking and `setsid` for detached starts.
- **OpenBSD netcat**: `nc` with Unix-socket support (`nc -U`) for QMP lifecycle control.
- **Optional**:
  - **swtpm** and **swtpm-tools**: TPM 2.0 emulation.
  - **virtiofsd**: High-performance VirtIO-FS shared folders.
  - **virt-viewer**: SPICE display client (`remote-viewer`).
  - **passt**: Unprivileged network backend.
  - **samba** (`smbd`): Required for SMB shared folders.
  - **vfio-pci kernel module**: Required for PCIe audio passthrough. IOMMU must be enabled in BIOS/UEFI and via kernel parameters (`intel_iommu=on` or `amd_iommu=on`).
  - **edk2-ovmf / ovmf**: UEFI firmware (Arch: `sudo pacman -S edk2-ovmf`; Debian/Ubuntu: `sudo apt install ovmf`; Fedora: `sudo dnf install edk2-ovmf`).
  - **macOS installer prerequisites**: `git`, Python 3, and **dmg2img** (Arch: `sudo pacman -S git python dmg2img`).
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

### macOS on QEMU/KVM

macOS VMs require KVM acceleration and `ignore_msrs=1`. Check the current value with:
```bash
cat /sys/module/kvm/parameters/ignore_msrs
```

If KVM is already loaded and the value is `N`, `sudo modprobe kvm ignore_msrs=1` can be a no-op. Enable the parameter directly:
```bash
sudo sh -c 'echo 1 > /sys/module/kvm/parameters/ignore_msrs'
```

For persistent configuration on Arch, create `/etc/modprobe.d/kvm.conf` with:
```text
options kvm ignore_msrs=1
options kvm report_ignored_msrs=0
```
Then reboot (or unload/reload the KVM modules when safe). Qemate refuses to start a macOS VM until `ignore_msrs` is enabled.

The macOS recovery workflow also requires `dmg2img` to convert Apple's `BaseSystem.dmg` into the raw image used by QEMU.
Qemate intentionally attaches `BaseSystem.img` as a writable raw `-drive` backend when the installer media is connected. This matches the upstream OSX-KVM QEMU layout; making the block backend read-only while attaching it with `ide-hd` causes QEMU to fail with `Block node is read-only`.

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
  - `--os-type linux|windows|macos` — OS preset (default: linux)
  - `--memory SIZE` — e.g. `4G`, `8G`
  - `--cores N` — CPU cores (1–64)
  - `--disk-size SIZE` — e.g. `60G` (creates a qcow2 image; default)
  - `--disk-dev PATH` — e.g. `/dev/sdb` (raw physical block device; mutually exclusive with `--disk-size`). These VMs cannot be resized or cloned; the disk is the host device itself.
  - `--machine TYPE[,accel=kvm|tcg]` — e.g. `q35,accel=kvm`
  - `--enable-audio` / `--no-audio` — emulated Intel HDA; set `AUDIO_PASSTHROUGH_PCI` for VFIO passthrough
  - `--enable-tpm` / `--no-tpm` — TPM 2.0 (requires swtpm; default on for Windows)
  - `--uefi` / `--no-uefi` — UEFI firmware (default: on for Windows, off for Linux)
  - `--spice` / `--no-spice` — SPICE display
  - `--share-backend auto|virtfs|smb|virtiofs`
  - `--profile balanced|performance` — defaults to `balanced`; performance favors low latency and throughput. Creating with `--profile performance` validates available RAM and the process memlock limit up front.

- `qemate start <n> [--headless] [--detach] [--iso PATH] [--virtio-iso PATH] [--debug] [--dry-run]`
  Starts a VM, optionally without a graphical console (`--headless`) or under a detached lifecycle supervisor (`--detach`), with a primary ISO and/or a secondary ISO (e.g. VirtIO-Win drivers). `--debug` prints the shell-escaped QEMU command before a foreground launch and relays it before a detached caller returns; `--dry-run` prints it without binding devices or starting helpers. Log rotation runs automatically on each start. If `--detach` is used with neither `DISPLAY` nor `WAYLAND_DISPLAY` set, qemate implies `--headless` so QEMU does not fail opening a GUI. Locked VMs cannot be started.

- `qemate stop <n> [--timeout SECONDS] [--force]`
  Requests an orderly ACPI shutdown through QMP and waits 60 seconds by default. A guest that ignores the request is left running; `--force` is the explicit hard-power-off path.

- `qemate restart <n> [stop/start options]`
  Stops the VM (if running), waits until lifecycle teardown completes, then starts it again. Accepts the same stop options (`--force`, `--timeout`) and start options (`--headless`, `--detach`, `--iso`, `--virtio-iso`, `--debug`, `--dry-run`).

- `qemate wait <n> [--timeout SECONDS] [--state running|ready|stopped]`
  Blocks until the VM reaches the requested state. Default state is `running`/`ready` (QEMU live and QMP responsive). Useful for scripts that need a reliable barrier after `start --detach`.

- `qemate console <n> [--qmp]`
  Opens an interactive QMP session on the VM's Unix control socket (`sockets/qmp.sock`). Requires the VM to be running and OpenBSD netcat with `nc -U`.

- `qemate logs <n> [-f|--follow] [-n|--lines N] [--qemate|--qemu|--supervisor]`
  Shows recent log lines for the VM. Defaults to `qemate.log`; use `--qemu` or `--supervisor` for the latest QEMU or detached-supervisor log. `-f` follows like `tail -f`.

- `qemate clone <src> <dst> [--full]`
  Duplicates a stopped VM that uses a **qcow2** disk image. Copies the config, assigns a new MAC address, and either:
  - **linked** (default): new qcow2 whose backing file is the source disk (fast; shares unchanged clusters). Deleting or shrinking the source disk breaks the clone.
  - **`--full`**: standalone full copy of the disk.

  UEFI NVRAM and TPM state are copied when present. VMs that use a **host block device** (`DISK_DEV` / `--disk-dev`) cannot be cloned. There is no private image file to copy, and two VMs must not share the same physical disk. Create another VM with its own `--disk-dev` path if you need a second physical-disk guest.

- `qemate delete <n> [--force]`
  Deletes a VM and all its data. Prompts for confirmation unless `--force` is used. Locked VMs require `--force`.

- `qemate resize <n> <SIZE|+SIZE> [--force]`
  Resizes the VM's disk image (e.g. `80G`, `+20G`). The VM must be stopped and unlocked; `--force` is reserved for CLI compatibility and does not allow live qcow2 resizing. Not supported for physical device VMs (`--disk-dev`). The recorded size keeps exact GiB when divisible, otherwise stores MiB.

- `qemate list`
  Lists all VMs with seven columns: `NAME`, `STATUS`, `LOCKED`, `OS`, `AUDIO`, `TPM`, `SPICE`. Uses a lightweight config read path (no full validation lock per row).

- `qemate status <n>`
  Displays detailed VM configuration and runtime status, including CPU, memory, disk, network, UEFI state, share backend, port forwards, USB passthrough, and shared folders.

- `qemate tune <n> balanced|performance`
  Changes only the runtime performance profile (`PERFORMANCE_PROFILE`) without replacing custom disk, network, passthrough, or share settings. The VM must be stopped. For multi-field edits, use `configure`.

- `qemate doctor [<n>]`
  Reports host KVM/QMP/AVIC/vhost/memlock readiness and, when a VM is supplied, its effective storage, memory, share choices, and whether configured port forwards conflict with ports already bound on the host.

- `qemate configure <n>`
  Opens the VM config file in `$EDITOR` (falls back to `nano`, `vim`, or `vi`). After editing, the config is validated against the qemate schema; if validation fails, the previous config is automatically restored. The VM may be running; changes then apply on the next start. The VM must not be locked.

  The config file uses a simple `KEY="value"` format. Recognized keys:

  | Key                    | Description                                             | Example                  |
  |------------------------|---------------------------------------------------------|--------------------------|
  | `CORES`                | vCPU count                                              | `4`                      |
  | `MEMORY`               | RAM allocation                                          | `8G` (macOS) / `4G` (Windows) / `2G` (Linux) |
  | `CPU_TYPE`             | QEMU CPU model                                          | `host`                   |
  | `MACHINE_TYPE`         | Machine type                                            | `q35`                    |
  | `MACHINE_OPTIONS`      | Machine options                                         | `accel=kvm`              |
  | `NETWORK_TYPE`         | Network backend (`user`, `passt`, `tap`, `none`)        | `user`                   |
  | `NETWORK_MODEL`        | NIC model (`virtio-net-pci`, `e1000`)                   | `virtio-net-pci`         |
  | `BRIDGE_NAME`          | Host bridge interface (tap mode only)                   | `br0`                    |
  | `PORT_FORWARDS`        | Comma-separated forward specs                           | `8080:80:tcp,53:53:udp`  |
  | `VIDEO_TYPE`           | Video device                                            | `qxl-vga`, `virtio-vga`  |
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
  | `ENABLE_AUDIO`         | Enable emulated HDA (`0`/`1`); VFIO if PCI set          | `1`                      |
  | `AUDIO_PASSTHROUGH_PCI`| PCI address for PCIe audio passthrough                  | `01:00.1`                |
  | `USB_DEVICES`          | Comma-separated vendor:product IDs                      | `046d:c52b`              |
  | `SHARED_FOLDERS`       | Comma-separated tag:path pairs                          | `shared:/home/user/share`|
  | `SHARE_BACKEND`        | Share backend (`auto`, `virtfs`, `smb`, `virtiofs`)     | `auto`                   |
  | `ENABLE_TPM`           | Enable TPM 2.0 (`0`/`1`)                                | `1`                      |
  | `SPICE_ENABLED`        | Enable SPICE display (`0`/`1`)                          | `0`                      |
  | `SPICE_PORT`           | SPICE port (default: 5930)                              | `5930`                   |
  | `ENABLE_UEFI`          | Enable UEFI firmware (`0`/`1`)                          | `1`                      |
  | `MACOS_VERSION`        | macOS recovery version for macOS VMs                    | `sonoma`                 |
  | `MACOS_INSTALL_MEDIA`  | Recovery/installer media attached (`0`/`1`)             | `0`                      |
  | `MACOS_GUEST_AGENT`    | ISA-serial macOS guest agent transport (`0`/`1`)        | `1`                      |
  | `PERFORMANCE_PROFILE`  | Runtime policy (`balanced`, `performance`)              | `balanced`               |
  | `HIDE_KVM`             | Hide KVM signature for legacy compatibility (`0`/`1`)   | `0`                      |
  | `CPU_AFFINITY`         | Optional Linux CPU list for the whole QEMU process      | empty                    |
  | `LOCKED`               | VM lock state (`0`/`1`)                                 | `0`                      |

### macOS Commands

- `qemate macos-install <n> [--version VERSION] [--no-start] [--refresh]`
  Prepares an Apple recovery installer via [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM) and starts the VM by default. See [macOS](#macos) below for details.

- `qemate macos-eject <n>`
  Detaches installer/recovery media after installation; subsequent boots use the installed disk through OpenCore. Also removes the temporary OSX-KVM git checkout and recovery download artifacts, keeping permanent OpenCore/OVMF assets under `macos/assets/`.

- `qemate macos-recovery <n>`
  Re-attaches recovery media for maintenance or reinstallation (re-prepares via `macos-install` if the media was cleaned up by eject).

- `qemate macos-refresh <n>`
  Updates the shared OSX-KVM cache and the VM's checkout (worktree or local clone).

- `qemate macos-doctor <n>`
  Validates OpenCore/OVMF/recovery assets, the KVM `ignore_msrs` requirement, and required QEMU macOS devices.

### Performance Profiles

`balanced` is the portable default. It preserves demand-allocated memory unless `MEMORY_PREALLOC=1` is set and keeps compatibility-oriented device choices.

`performance` is opt-in. It preallocates and locks guest memory. When the hugepage pool has enough free pages, qemate uses a hugepage-backed memory object with `share=on` (so VirtIO-FS can use it too). If the pool is empty or too small, it falls back to memfd or anonymous RAM instead of failing at QEMU start. It also enables AMD AVIC for Windows when the host confirms support, bounds VirtIO block queues to eight, and gives VirtIO-FS a larger request queue with a daemon thread pool of up to four workers plus `--cache=always` / `--writeback` when supported. New qcow2 images created under this profile use metadata preallocation and a larger cluster size. New Windows VMs created with this profile use VirtIO block and therefore need the VirtIO storage driver during installation. Existing VMs never have their disk interface changed by `tune`.

Run `qemate doctor <n>` before tuning. `CPU_AFFINITY` is deliberately empty by default because reserving host cores is workload- and host-specific.

### QEMU compatibility

Qemate 5.1.x requires QEMU 10.0 or newer and enforces that floor before image creation, resizing, or VM launch. Its generated x86 command line was audited against QEMU 10.0's [deprecated features](https://qemu.readthedocs.io/en/v10.0.3/about/deprecated.html) and [removed features](https://qemu.readthedocs.io/en/v10.0.3/about/removed-features.html). Qemate does not emit an option or device listed there; existing VM configs continue to use non-versioned `q35` so they follow the installed QEMU's current machine model.

### Audio

`--enable-audio` attaches emulated Intel HDA using QEMU's default host backend (PipeWire, PulseAudio, or ALSA). That is enough for guest sound without VFIO.

To pass a host PCIe audio device to the guest instead, set both fields in the VM config:

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

Foreground starts cache sudo credentials and refresh the sudo timestamp while the VM runs so long sessions can still restore host drivers. **Detached starts** (`start --detach`) have no controlling TTY, so audio passthrough requires passwordless sudo for the VFIO sysfs operations (or an already-valid sudo timestamp). Without that, qemate refuses to start rather than leave the device stuck on `vfio-pci`.

If restore fails (expired credentials, killed supervisor), `driver_state` is kept under the VM directory so a later interactive attempt can finish rebinding.

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
| `smb`      | QEMU user-mode SMB, Windows plug-and-play, one folder only; requires host `smbd` and `NETWORK_TYPE=user`/`nat` | `\\10.0.2.4\qemu` in Explorer |
| `virtiofs` | Best performance, multiple folders; requires virtiofsd        | Windows: WinFSP + VirtIO-FS driver; Linux: `mount -t virtiofs <tag> /mnt/<tag>` |

### Network Commands

Port forwarding:

- `qemate port-add <n> <[ip:]host:guest[:tcp|udp]>`
  Adds a port forward. Protocol defaults to `tcp` if omitted. The host port is checked for conflicts at add time (and again at start).

- `qemate port-remove <n> <[ip:]host:guest[:tcp|udp]>`
  Removes a port forward.

Network type, model, and bridge are configured via `qemate configure <n>` (edit `NETWORK_TYPE`, `NETWORK_MODEL`, `BRIDGE_NAME`).

**Network backends:**

| Type    | Description                                           |
|---------|-------------------------------------------------------|
| `user`  | SLiRP userspace NAT — default, no setup required      |
| `passt` | Unprivileged, uses host network stack directly         |
| `tap`   | Kernel-accelerated with vhost-net, optionally bridges to a host bridge |
| `none`  | No network interface                                  |

### Security Commands

- `qemate lock <n>` — Blocks start, resize, configuration edits, and delete (unless `delete --force`). Stop and status still work.
- `qemate unlock <n>` — Unlocks a VM.

### Examples

Create a Linux VM with 4GB memory and 4 cores:
```bash
qemate create myvm --os-type linux --memory 4G --cores 4
```

Create a Windows VM (UEFI and TPM are on by default):
```bash
qemate create winvm --os-type windows
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

Start a VM without keeping the terminal occupied:
```bash
qemate start myvm --detach
```

Detached and headless operation can be combined. If `--detach` is used with no `DISPLAY` or `WAYLAND_DISPLAY`, qemate implies `--headless`:
```bash
qemate start myvm --headless --detach
```

Detached VMs remain managed through `qemate status` and `qemate stop`. They cannot be returned to the original shell with `fg`; reconnect to a configured SPICE display when graphical access is needed.

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

Restart a VM (stop, wait for teardown, start):
```bash
qemate restart myvm --headless
```

Wait until a detached VM is QMP-ready:
```bash
qemate start myvm --detach --headless
qemate wait myvm --timeout 60
```

Tail logs:
```bash
qemate logs myvm -n 100
qemate logs myvm --qemu -f
```

Clone a qcow2-based VM (linked disk by default; use `--full` for a standalone copy). Physical-disk VMs (`--disk-dev`) are not supported by clone:
```bash
qemate clone myvm myvm-copy
qemate clone myvm myvm-full --full
```

Interactive QMP console:
```bash
qemate console myvm
```

## Configuration

- **VM Directory**: `${HOME}/QVMs` (override with `QEMATE_VM_DIR` env var).
- **Config file**: `${HOME}/QVMs/<n>/config` (permissions: `600`).
- **Disk Images**: `${HOME}/QVMs/<n>/disk.qcow2` (qcow2 format; absent when `--disk-dev` is used). New images are created with metadata preallocation and `lazy_refcounts=on`.
- **Logs**:
  - General: `${HOME}/QVMs/<n>/logs/qemate.log`
  - QEMU stderr: `${HOME}/QVMs/<n>/logs/qemu-YYYYMMDD-HHMMSS.log`
  - Latest QEMU stderr: `${HOME}/QVMs/<n>/logs/error.log` (symlink)
  - Detached supervisor: `${HOME}/QVMs/<n>/logs/supervisor-YYYYMMDD-HHMMSS.log`
  - virtiofsd (per share): `${HOME}/QVMs/<n>/logs/virtiofsd_<tag>.log`
  - Rotation: on each start, aged files older than `QEMATE_LOG_RETENTION_DAYS` (default `14`) are removed and per-pattern file counts are capped by `QEMATE_LOG_MAX_FILES` (default `20`). Oversized `qemate.log` is truncated.
- **Logging Verbosity**: Set via `LOG_LEVEL` environment variable (DEBUG, INFO, WARNING, ERROR; default: INFO).
- **Shared OSX-KVM cache**: `${QEMATE_VM_DIR:-$HOME/QVMs}/.cache/OSX-KVM` (override with `QEMATE_OSX_KVM_CACHE`). Per-VM checkouts are worktrees (or local shared clones) of this cache.
- **Default Configurations**:
  - **Linux VMs**: 2 cores, 2GB RAM, 40GB disk, VirtIO disk, `virtio-net-pci`, UEFI off, audio off, SPICE off.
  - **Windows VMs**: 4 cores, 4GB RAM, 60GB disk, NVMe disk, `virtio-net-pci`, UEFI on, TPM on, Hyper-V enlightenments, audio off, SPICE off (port 5930).
  - **macOS VMs**: 4 cores, 8GB RAM, 80GB disk, SATA disk, `virtio-net-pci`, UEFI on, OpenCore, Apple SMC, audio on the QEMU software path, SPICE off. (Sonoma and newer; older releases can still override with `--memory`.)

## macOS

Qemate can prepare and launch a macOS guest using the OpenCore/recovery approach from [kholia/OSX-KVM](https://github.com/kholia/OSX-KVM). The project currently supports recovery downloads for High Sierra through Tahoe. Qemate follows its current QEMU boot model, including Skylake-Client for Sequoia/Tahoe and Haswell-noTSX for Sonoma, with the High Sierra vmxnet3 networking exception documented upstream.

Create the VM, then prepare the installer:

```bash
qemate create macvm --os-type macos
qemate macos-install macvm --version sonoma
```

Supported versions: `high-sierra`, `mojave`, `catalina`, `big-sur`, `monterey`, `ventura`, `sonoma`, `sequoia`, `tahoe`.

`macos-install` uses a **shared host cache** of the upstream OSX-KVM repository (`$QEMATE_VM_DIR/.cache/OSX-KVM`, overridable via `QEMATE_OSX_KVM_CACHE`) and creates a per-VM worktree (or local shared clone) so multiple macOS VMs do not each download the full tree. It downloads and verifies the Apple recovery image through OSX-KVM's `fetch-macOS-v2.py` workflow, converts it to `BaseSystem.img`, and prepares the VM with the upstream OpenCore image and 4 MiB OVMF layout. The qemate-managed qcow2 disk is the install target.

The installer media is tracked explicitly: `MACOS_INSTALL_MEDIA=1` while recovery is needed, then `qemate macos-eject <n>` detaches it so subsequent boots use the installed disk through OpenCore. Eject also removes the temporary OSX-KVM checkout and recovery download artifacts (BaseSystem.img/.dmg, chunklists), keeping only the permanent OpenCore and 4 MiB OVMF assets under `macos/assets/`. `qemate macos-recovery <n>` re-prepares recovery media if it was cleaned up. Use `qemate macos-refresh <n>` to update the shared cache and the per-VM checkout, and `qemate macos-doctor <n>` to validate the boot assets, KVM requirement and QEMU devices.

Typical lifecycle:

```bash
qemate create macvm --os-type macos
qemate macos-install macvm --version sonoma --no-start
qemate start macvm
# Complete installation from macOS Recovery / Installer UI.
qemate stop macvm
qemate macos-eject macvm
qemate start macvm
```

For current modern macOS releases, Qemate follows OSX-KVM's version-specific CPU guidance: Haswell-noTSX for Sonoma and Skylake-Client with HLE/RTM disabled for Sequoia/Tahoe. OSX-KVM also documents `ignore_msrs=1` as required, while its current KVM module examples set `report_ignored_msrs=0`. Qemate validates `ignore_msrs` before launching a macOS guest when the kernel exposes the parameter.

### Feature compatibility on macOS guests

Not every qemate feature maps onto the OpenCore/QEMU device set. The start path keeps the OSX-KVM layout (SATA + OpenCore + `isa-applesmc` + `vmware-svga` + ICH9 HDA) and only layers host features that that layout can actually use.

| Feature | Works with macOS? | Notes |
|---------|-------------------|-------|
| Network (`user`/`nat`, `passt`, `tap`, `none`) | Yes | Same `configure_network` path as Linux/Windows. Default NIC is `virtio-net-pci`; High Sierra is forced to `vmxnet3`. Port forwards work on `user`/`passt`. |
| Port forwarding | Yes | `qemate port-add` / `port-remove`. Guest must have a working NIC. |
| USB passthrough | Yes | `qemate usb-add <n> vendor:product` attaches `usb-host` to the existing `qemu-xhci` (`xhci.0`). Permission to claim the host device is still required. |
| Shared folders | Partial | There is no supported macOS guest driver for VirtIO-FS or 9p. `SHARE_BACKEND=auto` therefore selects QEMU user-mode SMB. That backend needs `NETWORK_TYPE=user` or `nat` and host `smbd`, and QEMU slirp SMB is SMB 1.0 — modern macOS often refuses it. Prefer TAP + a host Samba/NFS share, or copy files over SSH after the guest agent is installed. |
| Software audio | Yes | `ich9-intel-hda` + `hda-duplex` is always attached on the macOS path. |
| PCIe audio passthrough (VFIO) | No | Skipped so the OSX-KVM HDA device stays the audio path. |
| SPICE | No | Display is `vmware-svga` + the default GTK/SDL window (or `--headless`). |
| TPM (`swtpm`) | No | Not part of the OpenCore boot model qemate emits. |
| `--iso` / installer CD | No | Recovery media is `BaseSystem.img` via `macos-install` / `macos-recovery`, not a generic ISO. `--virtio-iso` is still accepted if you need a second raw CD. |
| Guest agent transport | Yes (host side) | `MACOS_GUEST_AGENT=1` (default) adds an ISA serial socket at `${HOME}/QVMs/<n>/sockets/mac-guest-agent.sock`. The guest-side daemon is installed after first boot; see below. |
| `start --detach`, QMP stop, lock, resize, tune | Yes | Lifecycle commands are OS-agnostic. Graceful `stop` is ACPI via QMP; install [mac-guest-agent](https://github.com/mav2287/mac-guest-agent) if you want QGA `guest-shutdown` / fsfreeze as well. |

### Post-install recommended actions

After macOS is installed and you have run `qemate macos-eject <n>` (which also removes the temporary OSX-KVM checkout and recovery download artifacts), two guest-side tools are recommended:

#### 1. mac-guest-agent

Install [mav2287/mac-guest-agent](https://github.com/mav2287/mac-guest-agent) inside the guest. It is a native QEMU Guest Agent that talks over **ISA serial** (not VirtIO), covers OS X 10.4 Tiger through macOS Tahoe, and adds shutdown, exec, file transfer, and real filesystem freeze — the pieces that make a QEMU macOS VM usable day to day.

Qemate already creates the host transport when `MACOS_GUEST_AGENT=1`:

```text
-chardev socket,id=macagent,path=${HOME}/QVMs/<n>/sockets/mac-guest-agent.sock,server=on,wait=off
-device isa-serial,chardev=macagent
```

Inside the running guest (Terminal.app, as an admin user):

```bash
curl -fL -o /tmp/mac-guest-agent \
  https://github.com/mav2287/mac-guest-agent/releases/latest/download/mac-guest-agent
chmod +x /tmp/mac-guest-agent
sudo /tmp/mac-guest-agent --install
rm -f /tmp/mac-guest-agent
sudo mac-guest-agent --self-test
```

The installer drops a native slice under `/usr/local/bin/mac-guest-agent` and a launchd job (`com.macos.guest-agent`). The agent uses Apple's built-in `Apple16X50Serial.kext` (`/dev/cu.serial1`); no extra kext, no SIP change, no code signing.

From the Linux host, once the VM is up and the agent is running:

```bash
echo '{"execute":"guest-ping"}' \
  | socat - UNIX-CONNECT:${HOME}/QVMs/macvm/sockets/mac-guest-agent.sock

# or, if qemu-ga-client is installed:
qemu-ga-client --address=${HOME}/QVMs/macvm/sockets/mac-guest-agent.sock ping
```

`qemate macos-doctor <n>` reports whether the ISA serial device exists in QEMU and whether the socket is present while the VM is running. Set `MACOS_GUEST_AGENT=0` in the VM config to omit the serial device.

#### 2. VMHide

Install [Carnations-Botanica/VMHide](https://github.com/Carnations-Botanica/VMHide) inside the guest as a Lilu plug-in (requires Lilu 1.7.0+). It selectively hides VMM presence from the guest and is configured through the macOS guest's OpenCore Kexts/config.plist. Qemate does not inject or modify the guest EFI automatically; add the kext yourself after first boot for the best compatibility with modern macOS releases.

OC4VM is used as a reference for OpenCore guest configuration, boot-argument management, diagnostics and modern macOS support, but its current project is VMware-focused and explicitly removed QEMU support because it was considered problematic/unstable. Qemate therefore does not copy VMware VMX/VMDK settings into its QEMU backend.

Important limitations:

- macOS guests require x86_64 KVM acceleration and suitable CPU virtualization features.
- Qemate does not provide Apple hardware emulation; this is a virtual Hackintosh workflow.
- Graphics acceleration and some USB/device functionality remain limited by the underlying QEMU/macOS stack.
- Review Apple's current software license terms before using macOS virtualization.

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

**Host audio lost after VM crash**: If the VM crashes without a clean shutdown, the audio device may remain bound to `vfio-pci`. Use `qemate stop <n>` so the guest receives an orderly shutdown request and the supervisor can restore the device. Do not signal the supervisor directly except as a last resort.

If sudo credentials expired during a long session, qemate keeps `${HOME}/QVMs/<n>/driver_state` and reports the failure instead of silently giving up. Re-run stop/start from an interactive shell (or configure NOPASSWD for the VFIO sysfs paths) so restore can complete.

**Detached start rejects audio passthrough**: `start --detach` has no TTY for `sudo -v`. Configure passwordless sudo for the needed VFIO operations, or start without `--detach`.

If the supervisor was killed with SIGKILL, rebind manually:
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
Windows VMs enable TPM by default, so `start` fails unless both `swtpm` and `swtpm_setup` (from `swtpm-tools`) are installed. Create with `--no-tpm` if you do not need it. Check VM logs for TPM errors.

### Shared Folder Issues
- **virtfs**: No extra dependencies; Linux guests only.
- **virtiofs**: Requires `virtiofsd`. Windows guests also need WinFSP and the VirtIO-FS driver from the VirtIO-Win ISO.
- **smb**: Built into QEMU slirp (`NETWORK_TYPE=user`/`nat`); limited to one folder. Default for Windows and macOS VMs. QEMU's user-mode SMB is SMB 1.0, which modern macOS often rejects; a host Samba/NFS export on TAP is more reliable for macOS.

### Shared Folder (SMB) Issues on Windows 10 LTSC 2021

QEMU's user-mode SMB share uses SMB 1.0, which is disabled by default on Windows 10. Follow these steps to enable it:

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
If a configuration file is owned by another user or has insecure global write permissions, qemate will abort or automatically harden the permissions to `600`.

### Errors
Use `qemate logs <n>` (or inspect the files under the VM log directory):
- `${HOME}/QVMs/<n>/logs/qemate.log` — General VM logs
- `${HOME}/QVMs/<n>/logs/error.log` — Latest QEMU stderr log (symlink)
- `${HOME}/QVMs/<n>/logs/qemu-YYYYMMDD-HHMMSS.log` — Per-run QEMU stderr history
- `${HOME}/QVMs/<n>/logs/supervisor-YYYYMMDD-HHMMSS.log` — Detached start supervisor output

## Contributing

Contributions are welcome. Key guidelines:
- Follow the Google Shell Style Guide.
- Use 4-space indentation.
- Update `README.md`, `CHANGELOG.md`, and `VERSION` for changes.
- Submit pull requests with clear descriptions.

## License

Qemate is released under the MIT License.

## Author

Developed by Daniel Zilli.

## Links

- [GitHub Repository](https://github.com/dlzi/qemate)
- [Issue Tracker](https://github.com/dlzi/qemate/issues)

### Related OpenCore projects

Qemate uses **OSX-KVM** as the QEMU/KVM boot and recovery reference. After installation, **[mac-guest-agent](https://github.com/mav2287/mac-guest-agent)** is the recommended guest-side QEMU Guest Agent (ISA serial; Tiger through Tahoe). **OC4VM** is currently a VMware-focused project; its maintainer removed QEMU support in 1.1.0, so Qemate does not copy its VMware VMX/VMDK machinery. Its current releases are still useful as a reference for OpenCore configuration, guest tools, boot-argument management, and troubleshooting workflows. **VMHide** is a guest-side Lilu plug-in for selectively hiding VMM presence, not a QEMU host configuration feature. It is therefore intentionally not enabled or embedded by default in Qemate.
