# Changelog

All notable changes to qemate are documented in this file.

## [6.0.0] - 2026-10-09

QEMU 11 baseline and performance/stability modernization.

### Changed
- QEMU 11.0 is now the minimum supported release for `qemu-system-x86_64` and `qemu-img`.
- New VMs use the pinned `pc-q35-11.0` machine ABI. Legacy `q35` configs execute as `pc-q35-11.0` and are normalized on their next config save; explicit custom machine types remain unchanged.
- New macOS VMs default to a 256G virtual disk for development workloads.
- Linux and Windows VirtIO block/network devices advertise negotiated packed and in-order virtqueues.
- Performance-profile VirtIO block queues are distributed across up to four IOThreads.
- Multiqueue VirtIO TAP networking advertises RSS; hash reporting is enabled only on QEMU's userspace RSS path because the vhost-net eBPF path does not support it.
- `doctor` reports the effective machine type, QEMU machine availability, io_uring state, VirtIO features, and IOThread count.
- Completed macOS installs configure a private OpenCore image for a 1920x1080 boot screen, a five-second picker, and normal APFS scanning without raw EFI entries; recovery restores permissive scanning.
- Added stopped-VM `macos-boot`, `macos-vmhide`, and `macos-efi-restore` commands. VMHide is opt-in and experimental, installs verified release archives with Lilu ordered first, and creates a bootable OpenCore backup before every managed EFI change.

### Compatibility
- The macOS OpenCore/SATA, VMware SVGA, Apple SMC, and version-specific CPU layout is unchanged.
- Existing VM disks and explicitly configured non-q35 machine types require no migration.

### Requirements
- QEMU 11.0+
- Bash 5+
- macOS EFI management: mtools and Python 3; VMHide installation additionally needs curl, unzip, file, and sha256sum.

---

## [5.1.1] - 2026-09-05

Correctness and documentation follow-up to 5.1.0.

### Fixed
- `host_port_in_use` matched IPv4 octets (e.g. `10.0.0.80:22` looked like port 80). It now compares only the port on the `ss` local-address column.
- `find_ovmf` missed current Debian/Ubuntu (`OVMF_CODE_4M.fd`) and Fedora (`/usr/share/edk2/ovmf`) firmware layouts.
- `configure` held `qemu.pid.lock` for the whole `$EDITOR` session, so `list` reported `starting` and start/resize were blocked until the editor exited.
- `macos-eject` and `macos-recovery` updated install-media state without the stopped-VM lifecycle lock.
- `lock` did not block `start` or `resize`.
- `--enable-audio` without `AUDIO_PASSTHROUGH_PCI` logged a warning and attached no sound device. It now adds emulated Intel HDA (`-audio driver=default,model=intel-hda`).
- `start --detach` with no `DISPLAY`/`WAYLAND_DISPLAY` tried `-display default` and often failed. Detached start now implies `--headless` in that case.
- Performance-profile memory used hugepages whenever the mount was writable, including an empty pool (QEMU then failed after helpers were already up). VirtIO-FS also skipped hugepages because `MEMORY_SHARE` took a separate memfd branch. Hugepages are used only when the pool has enough free pages, with `share=on` so VirtIO-FS can use them; otherwise qemate falls back to memfd/RAM.

### Changed
- New Windows VMs enable TPM by default (`--no-tpm` to opt out).
- Linked `clone` warns that deleting or shrinking the source disk breaks the clone. TPM state is copied when present.
- SPICE start logs a `remote-viewer spice://127.0.0.1:PORT` connection hint.
- README and `qemate(1)` updated for the above.

### Requirements
- Unchanged from 5.1.0 (QEMU 10.0+, Bash 5+).
- New Windows VMs need `swtpm` and `swtpm_setup` unless created with `--no-tpm`.

---

## [5.1.0] - 2026-09-04

Incremental release focused on reliability, automation commands, and host-side efficiency.

### Added
- Commands: `restart`, `wait`, `console`, `logs`, `clone`.
  - `restart` coordinates stop → teardown wait → start.
  - `wait` blocks until QMP is ready or the VM is stopped.
  - `console` opens an interactive QMP session on the Unix control socket.
  - `logs` tails `qemate` / QEMU / supervisor logs (`-f`, `-n`, selector flags).
  - `clone` creates a linked qcow2 clone by default, or a full copy with `--full`.
- Shared OSX-KVM host cache (`$QEMATE_VM_DIR/.cache/OSX-KVM`, override `QEMATE_OSX_KVM_CACHE`) with per-VM worktrees (local shared clone fallback).
- Log rotation on start: age (`QEMATE_LOG_RETENTION_DAYS`, default 14), file-count cap (`QEMATE_LOG_MAX_FILES`, default 20), truncate oversized `qemate.log`.
- Disk-space preflight before `qemu-img create`.
- Memlock / available-RAM validation when creating a performance-profile VM.
- Host-port conflict check at `port-add` time (still re-checked at start).
- `doctor` reports port-forward conflicts against ports already bound on the host.
- qcow2 creation options: `lazy_refcounts=on`, `preallocation=metadata` (plus `cluster_size=2M` for the performance profile).
- VirtIO-FS daemon tuning: `--cache=always` / optional `--writeback` on the performance profile; `--cache=auto` otherwise.
- Performance memory backend prefers hugepages when `/dev/hugepages` or `/dev/hugepages-1G` is writable.

### Changed
- Memoized host probes: QEMU major version, OVMF paths, virtiofsd availability, and `nc -U` support.
- `list` uses a lightweight config field reader instead of a full locked validate per VM.
- `resize` records exact GiB when the virtual size is divisible by 1 GiB; otherwise stores MiB.
- `configure` resolves `$EDITOR`, then `nano` / `vim` / `vi`, and fails cleanly if none are present.
- `macos-refresh` updates the shared OSX-KVM cache first, then the per-VM checkout.
- README updated for the new commands, shared cache, log rotation, and audio/detached constraints.

### Fixed
- Detached starts with PCIe audio passthrough: no TTY for `sudo -v`; qemate now requires passwordless sudo (or a valid timestamp) and refuses to start rather than leaving the device on `vfio-pci`.
- Interactive audio sessions refresh the sudo timestamp while the VM runs so long-lived guests can still restore host drivers.
- VFIO driver restore uses non-interactive sudo, surfaces clear errors on credential expiry, and keeps `driver_state` when rebind fails so a later interactive attempt can finish restoration.

### Requirements
- Unchanged from 5.0.0 (QEMU 10.0+, Bash 5+).
- Detached VFIO audio still needs passwordless sudo for the relevant sysfs operations.

---

## [5.0.0] - 2026-09-04

Major release focused on a complete, production-ready macOS virtualization workflow.

### macOS
- Full lifecycle via kholia/OSX-KVM: isolated per-VM checkout, recovery preparation, install-media state, and normal disk boot after eject.
- Commands: `macos-install`, `macos-eject`, `macos-recovery`, `macos-refresh`, `macos-doctor`.
- Default memory raised to 8G (Sonoma and newer); older releases can still override with `--memory`.
- `macos-eject` removes the temporary OSX-KVM git checkout and recovery download artefacts, keeping only permanent OpenCore + 4 MiB OVMF assets under `macos/assets/`.
- `macos-recovery` re-prepares media automatically if it was cleaned up by eject.
- Version-specific CPU models (Haswell-noTSX for Sonoma, Skylake-Client for Sequoia/Tahoe).
- KVM `ignore_msrs` and required QEMU device checks before launch.
- ISA-serial guest-agent transport (`MACOS_GUEST_AGENT=1`) for mac-guest-agent.
- Post-install guidance for mac-guest-agent and VMHide.
- Removed the `macos-tools` command (information lives in the README).

### Fixed
- Recovery media launch failure caused by attaching `BaseSystem.img` as a read-only block node while `ide-hd` expects a writable backend.
- File-descriptor lifecycle locking on macOS commands (pass nameref to `release_flock`).
- Clearer diagnostics when `kvm` is already loaded and `modprobe ignore_msrs=1` is a no-op.

### Requirements
- QEMU 10.0+
- Bash 5+
- macOS installer path also needs `git`, Python 3, and `dmg2img`

---

## [4.6.x] series (summarised)

- 4.6.2: BaseSystem.img writable-backend fix.
- 4.6.1: flock nameref fix, ignore_msrs diagnostics, dmg2img documentation.
- 4.6.0: Initial complete macOS lifecycle.

## [4.5.x] series (summarised)

- macOS preset, OpenCore/recovery workflow, High Sierra–Tahoe support, CPU model guidance, KVM/CPU prerequisite checks.

## [4.4.0] - 2026-07-19

- `start --detach` with independent supervisor, QMP readiness, and clean cancellation.
- `--headless` remains display-only and can be combined with `--detach`.

## [4.3.0] - 2026-07-17

- Require QEMU 10.0+; audited generated command line against removed/deprecated features.
- Orderly ACPI shutdown via private QMP socket; `--force` is the only hard power-off path.
- Lifecycle lock acquired before TAP/TPM/VirtIO-FS/VFIO setup.
- Balanced / performance profiles, `doctor`, and `start --dry-run`.

## [4.2.x] series (summarised)

- Flat top-level CLI, physical disk passthrough, UEFI create flags, multi-share VirtIO-FS.
- Hardened config parser, PCIe audio passthrough, dependency pre-flight, QGA socket.

## [4.1.0] – [4.0.0]

- Audio passthrough, dependency pre-flight, mandatory field validation.
- Reaper/foreground QEMU execution model.

## Earlier releases (3.x – 1.x)

- Shared folders, headless start, network types/models, locking, Bash 5 requirement, initial public releases.
