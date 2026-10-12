#!/bin/bash
# =============================================================================
# qemate — Streamlined QEMU Virtual Machine Management Utility
#
# VERSION:  6.0.0
# LICENSE:  MIT
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: qemate must be run with bash, not sh." >&2
    echo "  Use: bash $0 $*" >&2
    exit 1
fi

[[ "${BASH_VERSION%%.*}" -ge 5 ]] || { echo "Error: Bash 5+ required"; exit 1; }

set -euo pipefail
umask 0077

# =============================================================================
# CONSTANTS & DEFAULTS
# =============================================================================

readonly VERSION="6.0.0"
readonly MIN_QEMU_MAJOR=11
readonly MIN_QEMU_VERSION="11.0"
readonly DEFAULT_MACHINE_TYPE="pc-q35-11.0"
readonly VM_DIR="${QEMATE_VM_DIR:-$HOME/QVMs}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"
readonly DEFAULT_STOP_TIMEOUT=60
readonly DETACH_START_TIMEOUT=30
readonly MACOS_KVM_REPO="https://github.com/kholia/OSX-KVM.git"
readonly VMHIDE_RELEASE_API="https://api.github.com/repos/Carnations-Botanica/VMHide/releases/latest"
readonly LILU_RELEASE_API="https://api.github.com/repos/acidanthera/Lilu/releases/latest"
readonly MACOS_DEFAULT_RESOLUTION="1920x1080"
readonly MACOS_DEFAULT_BOOT_TIMEOUT=5

# Shared defaults for all OS types.
declare -A _BASE_DEFAULTS=(
    [CORES]=2
    [MEMORY]="2G"
    [DISK_SIZE]=40G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=virtio-net-pci
    [DISK_INTERFACE]=virtio
    [ENABLE_AUDIO]=0
    [AUDIO_PASSTHROUGH_PCI]=0
    [CPU_TYPE]=host
    [MACHINE_TYPE]="$DEFAULT_MACHINE_TYPE"
    [VIDEO_TYPE]="qxl-vga"
    [VRAM_SIZE_MB]=64
    [DISK_CACHE]=writeback
    [DISK_IO]=io_uring
    [DISK_DISCARD]=unmap
    [ENABLE_VIRTIO]=1
    [MEMORY_PREALLOC]=0
    [MEMORY_SHARE]=0
    [ENABLE_TPM]=0
    [SPICE_ENABLED]=0
    [SPICE_PORT]=5930
    [SHARE_BACKEND]=auto
    [ENABLE_UEFI]=0
    [PERFORMANCE_PROFILE]=balanced
    [HIDE_KVM]=0
    [CPU_AFFINITY]=""
    [MACOS_INSTALL_MEDIA]=0
)

# Per-OS overrides — only keys that differ from _BASE_DEFAULTS.
# Linux: no overrides (virtio disk, UEFI off).
declare -A _OS_OVERRIDES_linux=()
# macOS: OpenCore + Apple SMC, UEFI, SATA disk, VMware SVGA-compatible display.
# Defaults of 8G RAM and a 256G disk suit development workloads on Sonoma and newer;
# older releases can still override them with --memory and --disk-size.
declare -A _OS_OVERRIDES_macos=(
    [CORES]=4
    [MEMORY]="8G"
    [DISK_SIZE]=256G
    [DISK_INTERFACE]=sata
    [NETWORK_MODEL]=virtio-net-pci
    [VIDEO_TYPE]="vmware"
    [ENABLE_UEFI]=1
    [ENABLE_VIRTIO]=1
    [MACOS_GUEST_AGENT]=1
)
# Windows: NVMe disk, larger defaults, UEFI on, Hyper-V enlightenments via SMB shares.
declare -A _OS_OVERRIDES_windows=(
    [CORES]=4
    [MEMORY]="4G"
    [DISK_SIZE]=60G
    [DISK_INTERFACE]=nvme
    [ENABLE_UEFI]=1
    [ENABLE_TPM]=1
)
# =============================================================================

declare -g QEMATE_ACTIVE_VM=""
declare -g QEMATE_PHASE=""
declare -g QEMATE_CLEANUP_DONE=0
declare -g QEMATE_LOCK_FD=""
declare -g QEMATE_LOCK_FILE=""
declare -g QEMATE_SUPPRESS_FILE_LOG=0
declare -g QEMATE_DETACH_STATUS_FILE=""
declare -g QEMATE_DETACH_READY=0
declare -g QEMATE_QEMU_JOB_PID=""
declare -g QEMATE_DETACH_LAUNCH_STATUS_FILE=""
declare -g QEMATE_DETACH_SUPERVISOR_PID=""

# Memoization caches for repeated host probes (cleared only on process exit).
declare -gA _CACHE_QEMU_MAJOR=()
declare -g _CACHE_OVMF_CODE=""
declare -g _CACHE_OVMF_VARS=""
declare -g _CACHE_OVMF_DONE=0
declare -g _CACHE_VIRTIOFSD=""
declare -g _CACHE_VIRTIOFSD_DONE=0
declare -g _CACHE_UNIX_NC=""
declare -g _CACHE_UNIX_NC_DONE=0

readonly OSX_KVM_CACHE_DIR="${QEMATE_OSX_KVM_CACHE:-$VM_DIR/.cache/OSX-KVM}"
readonly LOG_RETENTION_DAYS="${QEMATE_LOG_RETENTION_DAYS:-14}"
readonly LOG_MAX_FILES_PER_VM="${QEMATE_LOG_MAX_FILES:-20}"

write_detach_status() {
    [[ -n "$QEMATE_DETACH_STATUS_FILE" ]] || return 0
    local state="$1" value="${2:-}" tmp="${QEMATE_DETACH_STATUS_FILE}.tmp.${BASHPID}"
    printf '%s\t%s\n' "$state" "$value" > "$tmp"
    mv -f "$tmp" "$QEMATE_DETACH_STATUS_FILE"
}

vm_pid_matches() {
    local vm_name="$1" pid="$2"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1

    local -a args=()
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
    local i
    for (( i = 0; i + 1 < ${#args[@]}; i++ )); do
        if [[ "${args[i]}" == "-name" && "${args[i + 1]}" == "${vm_name},process=${vm_name}" ]]; then
            return 0
        fi
    done
    return 1
}

pid_cmdline_contains() {
    local pid="$1" needle="$2"
    [[ "$pid" =~ ^[0-9]+$ && -r "/proc/$pid/cmdline" ]] || return 1
    local -a args=()
    mapfile -d '' -t args < "/proc/$pid/cmdline" 2>/dev/null || return 1
    local arg
    for arg in "${args[@]}"; do
        [[ "$arg" == *"$needle"* ]] && return 0
    done
    return 1
}

cleanup_active_vm() {
    if [[ "$QEMATE_CLEANUP_DONE" -eq 0 && -n "$QEMATE_ACTIVE_VM" && "$QEMATE_PHASE" =~ ^(starting|running)$ ]]; then
        QEMATE_CLEANUP_DONE=1

        log_message "DEBUG" "Cleaning up: $QEMATE_ACTIVE_VM"
        local pidfile="$VM_DIR/$QEMATE_ACTIVE_VM/qemu.pid" pid="" tracked_pid=""
        if [[ -n "$QEMATE_QEMU_JOB_PID" ]] && vm_pid_matches "$QEMATE_ACTIVE_VM" "$QEMATE_QEMU_JOB_PID"; then
            tracked_pid="$QEMATE_QEMU_JOB_PID"
            kill "$tracked_pid" 2>/dev/null || true
        fi
        if [[ -f "$pidfile" ]]; then
            read -r pid < "$pidfile" || true
            if [[ "$pid" != "$tracked_pid" ]] && vm_pid_matches "$QEMATE_ACTIVE_VM" "$pid"; then
                kill "$pid" 2>/dev/null || true
            fi
            [[ "$(< "$pidfile")" == "$pid" ]] && rm -f "$pidfile"
        fi
        stop_virtiofsd_daemons "$QEMATE_ACTIVE_VM" 2>/dev/null || true
        stop_tpm               "$QEMATE_ACTIVE_VM" 2>/dev/null || true
        teardown_tap_interface "$QEMATE_ACTIVE_VM" 2>/dev/null || true
        restore_group_drivers  "$QEMATE_ACTIVE_VM" 2>/dev/null || true
    fi

    if [[ -n "$QEMATE_LOCK_FD" ]]; then
        flock -u "$QEMATE_LOCK_FD" 2>/dev/null || true
        exec {QEMATE_LOCK_FD}>&-
        QEMATE_LOCK_FD=""
        QEMATE_LOCK_FILE=""
    fi
}

cleanup_start_exit() {
    local exit_code=$?
    if [[ -n "$QEMATE_DETACH_STATUS_FILE" && "$QEMATE_DETACH_READY" -eq 0 ]]; then
        write_detach_status "FAILED" "$exit_code" 2>/dev/null || true
    fi
    cleanup_active_vm
}

# Clean up orphaned daemons and lock files when interrupted during launch.
cleanup_on_signal() {
    local exit_code="$1"
    cleanup_active_vm
    exit "$exit_code"
}

trap 'cleanup_on_signal 130' INT
trap 'cleanup_on_signal 143' TERM

terminate_detached_supervisor() {
    local pid="$QEMATE_DETACH_SUPERVISOR_PID" status_file="$QEMATE_DETACH_LAUNCH_STATUS_FILE" i
    if [[ -z "$pid" && -n "$status_file" ]]; then
        local state="" value=""
        for (( i=0; i<20; i++ )); do
            if IFS=$'\t' read -r state value < "$status_file" 2>/dev/null && [[ "$state" == "STARTING" ]]; then
                pid="$value"
                QEMATE_DETACH_SUPERVISOR_PID="$pid"
                break
            fi
            sleep 0.05
        done
    fi
    if [[ -n "$pid" && -n "$status_file" ]] && pid_cmdline_contains "$pid" "$status_file"; then
        kill "$pid" 2>/dev/null || true
        for (( i=0; i<50; i++ )); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
    fi
}

cancel_detached_launch() {
    local exit_code="$1" status_file="$QEMATE_DETACH_LAUNCH_STATUS_FILE"
    terminate_detached_supervisor
    [[ -z "$status_file" ]] || rm -f "$status_file"
    exit "$exit_code"
}

# =============================================================================
# LOGGING
# =============================================================================

# Log level rank table — declared once here instead of inside log_message on every call.
declare -rA _LOG_RANK=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# log_message LEVEL MESSAGE [VM_NAME]
# Levels: DEBUG < INFO < WARNING < ERROR (default LOG_LEVEL=INFO)
# Set LOG_LEVEL=DEBUG to see all output; ERROR to see only errors.
log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local vm_name="${3:-}"

    local msg_rank="${_LOG_RANK[$level]:-1}"
    local min_rank="${_LOG_RANK[${LOG_LEVEL:-INFO}]:-1}"

    if (( msg_rank >= min_rank )); then
        echo "[${level}] ${message}"
        if [[ "$QEMATE_SUPPRESS_FILE_LOG" != "1" && -n "$vm_name" && -d "$VM_DIR/$vm_name/logs" ]]; then
            local timestamp
            printf -v timestamp '%(%Y-%m-%d %H:%M:%S)T' -1
            echo "${timestamp} [${level}] ${message}" >> "$VM_DIR/$vm_name/logs/qemate.log"
        fi
    fi

    [[ "$level" == "ERROR" ]] && return 1
    return 0
}

# =============================================================================
# BASE UTILITIES & LOCKING
# =============================================================================

vm_exists() { [[ -d "$VM_DIR/$1" ]]; }

# vm_is_running VM_NAME — returns 0 if QEMU is live and owns the PID file.
vm_is_running() {
    local vm_name="$1" pidfile="$VM_DIR/$1/qemu.pid"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    [[ -f "$pidfile" ]] || return 1

    local pid
    read -r pid < "$pidfile"
    kill -0 "$pid" 2>/dev/null && vm_pid_matches "$vm_name" "$pid" && return 0

    local lockfile="$pidfile.lock" _fd
    if acquire_flock "$lockfile" _fd; then
        log_message "WARNING" "Removing stale PID file for VM: $vm_name" "$vm_name"
        rm -f "$pidfile"
        release_flock _fd "$lockfile"
    fi
    return 1
}

vm_is_locked() {
    validate_vm_name "$1" >/dev/null 2>&1 || return 1
    local -A VM=()
    load_vm_config "$1" VM >/dev/null 2>&1 && [[ "${VM[LOCKED]:-0}" == "1" ]]
}

validate_vm_name() {
    [[ -z "$1" ]]          && { log_message "ERROR" "VM name cannot be empty";                      return 1; }
    [[ "${#1}" -gt 40 ]]   && { log_message "ERROR" "VM name too long (max 40 chars)";              return 1; }
    [[ ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]] && \
                              { log_message "ERROR" "VM name: letters, numbers, hyphens, underscores only"; return 1; }
    return 0
}

# Generate a deterministic MAC derived from the VM name.
generate_mac_address() {
    local hash
    read -r hash _ < <(echo -n "$1" | md5sum)
    local h="${hash:0:6}"
    printf "52:54:00:%s:%s:%s" "${h:0:2}" "${h:2:2}" "${h:4:2}"
}

# require_vm VM_NAME FLAG... — validates name and checks state flags.
require_vm() {
    local vm_name="$1"; shift
    validate_vm_name "$vm_name" || return 1
    local flag
    for flag in "$@"; do
        case "$flag" in
            exists)              vm_exists "$vm_name"     || { log_message "ERROR" "VM not found: $vm_name"; return 1; } ;;
            running)             vm_is_running "$vm_name" || { log_message "ERROR" "VM is not running";      return 1; } ;;
            not-running|stopped) vm_is_running "$vm_name" && { log_message "ERROR" "VM is already running";  return 1; } || true ;;
            unlocked)            vm_is_locked "$vm_name"  && { log_message "ERROR" "VM is locked";           return 1; } || true ;;
        esac
    done
}

acquire_flock() {
    local lockfile="$1"
    local -n _af_fd="$2"
    exec {_af_fd}>"$lockfile"
    flock -n "$_af_fd" || { exec {_af_fd}>&-; return 1; }
}

acquire_stopped_vm_lock() {
    local vm_name="$1"
    local -n _asvl_fd="$2"
    local lockfile="$VM_DIR/$vm_name/qemu.pid.lock"
    acquire_flock "$lockfile" _asvl_fd || {
        log_message "ERROR" "VM lifecycle is busy (starting or running): $vm_name" "$vm_name"
        return 1
    }
    if vm_is_running "$vm_name"; then
        release_flock _asvl_fd "$lockfile"
        log_message "ERROR" "VM is already running" "$vm_name"
        return 1
    fi
}

vm_lifecycle_busy() {
    local vm_name="$1" _fd
    local lockfile="$VM_DIR/$vm_name/qemu.pid.lock"
    if acquire_flock "$lockfile" _fd; then
        release_flock _fd "$lockfile"
        return 1
    fi
    return 0
}

release_flock() {
    local -n _rf_fd="$1"
    # Second argument (lockfile path) is accepted for call-site uniformity but unused;
    # the lock is held by the open file descriptor.
    flock -u "$_rf_fd"
    exec {_rf_fd}>&-
}

# split_list RAW_CSV OUTPUT_ARRAY_NAMEREF — splits a comma-separated string.
split_list() {
    local raw="$1"
    local -n _sl_out="$2"
    _sl_out=()
    [[ -z "$raw" ]] && return 0
    IFS=',' read -ra _sl_out <<< "$raw"
    # Remove empty elements efficiently
    local i
    for i in "${!_sl_out[@]}"; do
        [[ -z "${_sl_out[i]}" ]] && unset '_sl_out[i]'
    done
    _sl_out=("${_sl_out[@]}") # Re-index
}

require_commands() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Required command(s) not found: ${missing[*]}"
        return 1
    fi
}

qemu_major_version() {
    local command_name="$1" version_output
    if [[ -n "${_CACHE_QEMU_MAJOR[$command_name]+x}" ]]; then
        [[ -n "${_CACHE_QEMU_MAJOR[$command_name]}" ]] || return 1
        printf '%s' "${_CACHE_QEMU_MAJOR[$command_name]}"
        return 0
    fi
    version_output=$("$command_name" --version 2>/dev/null) || {
        _CACHE_QEMU_MAJOR[$command_name]=""
        return 1
    }
    if [[ "$version_output" =~ version[[:space:]]+([0-9]+)(\.[0-9]+)? ]]; then
        _CACHE_QEMU_MAJOR[$command_name]="${BASH_REMATCH[1]}"
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    _CACHE_QEMU_MAJOR[$command_name]=""
    return 1
}

require_qemu_version() {
    local command_name="$1" major
    require_commands "$command_name" || return 1
    major=$(qemu_major_version "$command_name") || {
        log_message "ERROR" "Could not determine the $command_name version; QEMU ${MIN_QEMU_VERSION}+ is required"
        return 1
    }
    if (( major < MIN_QEMU_MAJOR )); then
        log_message "ERROR" "$command_name $major is unsupported; QEMU ${MIN_QEMU_VERSION}+ is required"
        return 1
    fi
}

require_qemu_toolchain() {
    require_qemu_version qemu-system-x86_64 || return 1
    require_qemu_version qemu-img || return 1
}

# Preserve q35 as a legacy config alias while pinning its effective ABI to the
# QEMU 11.0 machine revision. Explicit custom/versioned machine types are kept.
effective_machine_type() {
    local configured="${1:-$DEFAULT_MACHINE_TYPE}"
    if [[ "$configured" == "q35" ]]; then
        printf '%s' "$DEFAULT_MACHINE_TYPE"
    else
        printf '%s' "$configured"
    fi
}

size_to_mib() {
    local size="$1"
    local value="${size%[GMgm]}" unit="${size: -1}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    if [[ "${unit^^}" == "G" ]]; then printf '%s' "$(( value * 1024 ))"
    else printf '%s' "$value"
    fi
}

size_to_bytes() {
    local size="$1"
    local value="${size%[GMgm]}" unit="${size: -1}"
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    if [[ "${unit^^}" == "G" ]]; then printf '%s' "$(( value * 1024 * 1024 * 1024 ))"
    else printf '%s' "$(( value * 1024 * 1024 ))"
    fi
}

# Ensure $VM_DIR has enough free space for a new qcow2 of the requested size
# (sparse images need far less initially, but we require headroom for growth).
check_disk_space_for_create() {
    local vm_name="$1" disk_size="$2" needed_bytes avail_kb avail_bytes
    needed_bytes=$(size_to_bytes "$disk_size") || return 1
    # Require at least 10% of the virtual size free, minimum 1 GiB.
    local min_free=$(( needed_bytes / 10 ))
    (( min_free < 1073741824 )) && min_free=1073741824
    mkdir -p "$VM_DIR" 2>/dev/null || true
    avail_kb=$(df -Pk "$VM_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || {
        log_message "WARNING" "Could not determine free space on $VM_DIR; skipping disk-space preflight" "$vm_name"
        return 0
    }
    avail_bytes=$(( avail_kb * 1024 ))
    if (( avail_bytes < min_free )); then
        log_message "ERROR" "Insufficient free space on $VM_DIR for disk $disk_size (need ~$(( min_free / 1073741824 ))G free, have $(( avail_bytes / 1073741824 ))G)" "$vm_name"
        return 1
    fi
    return 0
}

# Return 0 if disk_dev is already claimed by another VM (excluding exclude_vm).
disk_dev_in_use_by_other() {
    local disk_dev="$1" exclude_vm="${2:-}" other cfg other_dev
    [[ -n "$disk_dev" ]] || return 1
    for other in "$VM_DIR"/*/; do
        [[ -d "$other" ]] || continue
        other="${other%/}"
        other="${other##*/}"
        [[ "$other" == .* || "$other" == "$exclude_vm" ]] && continue
        cfg="$VM_DIR/$other/config"
        [[ -f "$cfg" ]] || continue
        other_dev=$(_list_config_field "$cfg" DISK_DEV "")
        [[ -n "$other_dev" && "$other_dev" == "$disk_dev" ]] && return 0
    done
    return 1
}

rotate_vm_logs() {
    local vm_name="$1"
    local log_dir="$VM_DIR/$vm_name/logs"
    [[ -d "$log_dir" ]] || return 0
    # Age-based cleanup
    find "$log_dir" -type f \( -name 'qemu-*.log' -o -name 'supervisor-*.log' -o -name 'virtiofsd_*.log' \) \
        -mtime "+${LOG_RETENTION_DAYS}" -delete 2>/dev/null || true
    # Cap file count per pattern (newest kept)
    local pattern f count
    for pattern in 'qemu-*.log' 'supervisor-*.log'; do
        count=0
        while IFS= read -r f; do
            (( ++count > LOG_MAX_FILES_PER_VM )) && rm -f "$f"
        done < <(ls -1t "$log_dir"/$pattern 2>/dev/null || true)
    done
    # Truncate qemate.log if it grows beyond ~8 MiB
    if [[ -f "$log_dir/qemate.log" ]]; then
        local sz
        sz=$(stat -c%s "$log_dir/qemate.log" 2>/dev/null || echo 0)
        if [[ "$sz" =~ ^[0-9]+$ && "$sz" -gt 8388608 ]]; then
            tail -c 4194304 "$log_dir/qemate.log" > "$log_dir/qemate.log.tmp" 2>/dev/null && \
                mv -f "$log_dir/qemate.log.tmp" "$log_dir/qemate.log"
        fi
    fi
}

validate_performance_memory() {
    local vm_name="$1" memory="$2" requested_mib available_mib=0 lock_kib
    requested_mib=$(size_to_mib "$memory") || return 1
    if [[ -r /proc/meminfo ]]; then
        local key value _
        while IFS=': ' read -r key value _; do
            if [[ "$key" == "MemAvailable" ]]; then
                available_mib=$(( value / 1024 ))
                break
            fi
        done < /proc/meminfo
    fi
    if (( available_mib > 0 && requested_mib > available_mib * 90 / 100 )); then
        log_message "ERROR" "Performance profile needs ${requested_mib} MiB locked RAM, but only ${available_mib} MiB is available" "$vm_name"
        return 1
    fi

    lock_kib=$(ulimit -l)
    if [[ "$lock_kib" != "unlimited" && "$lock_kib" =~ ^[0-9]+$ && "$lock_kib" -lt $(( requested_mib * 1024 )) ]]; then
        log_message "ERROR" "memlock limit (${lock_kib} KiB) is below VM memory; raise ulimit -l or use the balanced profile" "$vm_name"
        return 1
    fi
}

have_unix_nc() {
    if [[ "$_CACHE_UNIX_NC_DONE" -eq 1 ]]; then
        [[ "$_CACHE_UNIX_NC" == "1" ]]
        return $?
    fi
    _CACHE_UNIX_NC_DONE=1
    if command -v nc >/dev/null 2>&1 && nc -h 2>&1 | grep -q -- '-U'; then
        _CACHE_UNIX_NC=1
        return 0
    fi
    _CACHE_UNIX_NC=0
    return 1
}

qmp_is_ready() {
    local vm_name="$1" socket="$VM_DIR/$1/sockets/qmp.sock"
    [[ -S "$socket" ]] && have_unix_nc || return 1

    local response compact
    response=$(
        {
            printf '%s\n' '{"execute":"qmp_capabilities","id":"capabilities"}'
            printf '%s\n' '{"execute":"query-status","id":"ready"}'
            sleep 0.05
        } | timeout 1 nc -U -N "$socket" 2>/dev/null
    ) || return 1
    compact="${response//[[:space:]]/}"
    [[ "$compact" != *'"error"'* &&
       "$compact" == *'"id":"capabilities"'* &&
       "$compact" == *'"id":"ready"'* &&
       "$compact" == *'"status":'* ]]
}

qmp_command() {
    local vm_name="$1" command="$2"
    local socket="$VM_DIR/$vm_name/sockets/qmp.sock"
    [[ -S "$socket" ]] || {
        log_message "ERROR" "QMP control socket is unavailable for: $vm_name" "$vm_name"
        return 1
    }
    have_unix_nc || {
        log_message "ERROR" "OpenBSD netcat with Unix-socket support (nc -U) is required for VM control" "$vm_name"
        return 1
    }

    local response
    response=$(
        {
            printf '%s\n' '{"execute":"qmp_capabilities","id":"capabilities"}'
            printf '{"execute":"%s","id":"command"}\n' "$command"
            sleep 0.1
        } | timeout 3 nc -U -N "$socket" 2>/dev/null
    ) || {
        log_message "ERROR" "QMP command failed: $command" "$vm_name"
        return 1
    }
    [[ "$response" == *'"error"'* ]] && {
        log_message "ERROR" "QMP rejected command '$command': $response" "$vm_name"
        return 1
    }
    return 0
}

apply_os_defaults() {
    local os_type="$1"
    local -n _vm="$2"
    local key
    for key in "${!_BASE_DEFAULTS[@]}"; do
        _vm[$key]="${_BASE_DEFAULTS[$key]}"
    done
    local -n _os_over="_OS_OVERRIDES_${os_type}"
    for key in "${!_os_over[@]}"; do
        _vm[$key]="${_os_over[$key]}"
    done
}

# =============================================================================
# CONFIGURATION I/O
# =============================================================================

readonly -a CONFIG_KEYS=(
    NAME OS_TYPE MACHINE_TYPE MACHINE_OPTIONS
    CORES MEMORY CPU_TYPE
    NETWORK_TYPE NETWORK_MODEL BRIDGE_NAME MAC_ADDRESS
    PORT_FORWARDS
    VIDEO_TYPE VRAM_SIZE_MB
    DISK_INTERFACE DISK_CACHE DISK_IO DISK_DISCARD DISK_SIZE DISK_DEV
    ENABLE_VIRTIO MEMORY_PREALLOC MEMORY_SHARE
    ENABLE_AUDIO AUDIO_PASSTHROUGH_PCI
    USB_DEVICES SHARED_FOLDERS SHARE_BACKEND
    ENABLE_TPM SPICE_ENABLED SPICE_PORT ENABLE_UEFI
    PERFORMANCE_PROFILE HIDE_KVM CPU_AFFINITY
    MACOS_VERSION MACOS_INSTALL_MEDIA MACOS_GUEST_AGENT
    LOCKED
)


quote_config_value() {
    local value="${1-}"
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
        return 1
    fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

unquote_config_value() {
    local value="$1"
    local out="" char next i
    for (( i=0; i<${#value}; i++ )); do
        char="${value:i:1}"
        if [[ "$char" == "\\" && $(( i + 1 )) -lt ${#value} ]]; then
            next="${value:i+1:1}"
            case "$next" in
                '\\'|'"') out+="$next"; (( i++ )) ;;
                *) out+="$char" ;;
            esac
        else
            out+="$char"
        fi
    done
    printf '%s' "$out"
}

validate_vm_config_values() {
    local vm_name="$1"
    local -n _vcv_vm="$2"
    local key value base_video

    validate_vm_name "${_vcv_vm[NAME]:-}" || return 1
    [[ "${_vcv_vm[NAME]}" == "$vm_name" ]] || {
        log_message "ERROR" "Config NAME '${_vcv_vm[NAME]}' does not match VM directory '$vm_name'" "$vm_name"
        return 1
    }

    case "${_vcv_vm[OS_TYPE]:-}" in
        linux|windows|macos) ;;
        *) log_message "ERROR" "Invalid OS_TYPE: '${_vcv_vm[OS_TYPE]:-}'" "$vm_name"; return 1 ;;
    esac

    [[ "${_vcv_vm[CORES]:-}" =~ ^[0-9]+$ && "${_vcv_vm[CORES]}" -ge 1 && "${_vcv_vm[CORES]}" -le 64 ]] || {
        log_message "ERROR" "Invalid CORES: '${_vcv_vm[CORES]:-}' (must be 1-64)" "$vm_name"; return 1; }
    [[ "${_vcv_vm[MEMORY]:-}" =~ ^[0-9]+[GMgm]$ ]] || {
        log_message "ERROR" "Invalid MEMORY: '${_vcv_vm[MEMORY]:-}' (use e.g. 4G or 2048M)" "$vm_name"; return 1; }

    case "${_vcv_vm[NETWORK_TYPE]:-}" in
        user|nat|passt|tap|none) ;;
        *) log_message "ERROR" "Invalid NETWORK_TYPE: '${_vcv_vm[NETWORK_TYPE]:-}'" "$vm_name"; return 1 ;;
    esac
    case "${_vcv_vm[NETWORK_MODEL]:-}" in
        virtio-net-pci|e1000|vmxnet3) ;;
        *) log_message "ERROR" "Invalid NETWORK_MODEL: '${_vcv_vm[NETWORK_MODEL]:-}'" "$vm_name"; return 1 ;;
    esac
    case "${_vcv_vm[DISK_INTERFACE]:-}" in
        virtio|nvme|ide|sata) ;;
        *) log_message "ERROR" "Invalid DISK_INTERFACE: '${_vcv_vm[DISK_INTERFACE]:-}'" "$vm_name"; return 1 ;;
    esac
    case "${_vcv_vm[DISK_CACHE]:-}" in
        none|writeback|writethrough|directsync|unsafe) ;;
        *) log_message "ERROR" "Invalid DISK_CACHE: '${_vcv_vm[DISK_CACHE]:-}'" "$vm_name"; return 1 ;;
    esac
    case "${_vcv_vm[DISK_IO]:-}" in
        threads|native|io_uring) ;;
        *) log_message "ERROR" "Invalid DISK_IO: '${_vcv_vm[DISK_IO]:-}'" "$vm_name"; return 1 ;;
    esac
    case "${_vcv_vm[DISK_DISCARD]:-}" in
        ignore|unmap) ;;
        *) log_message "ERROR" "Invalid DISK_DISCARD: '${_vcv_vm[DISK_DISCARD]:-}'" "$vm_name"; return 1 ;;
    esac

    [[ "${_vcv_vm[CPU_TYPE]:-}" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
        log_message "ERROR" "Invalid CPU_TYPE: '${_vcv_vm[CPU_TYPE]:-}'" "$vm_name"; return 1; }
    [[ "${_vcv_vm[MACHINE_TYPE]:-}" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
        log_message "ERROR" "Invalid MACHINE_TYPE: '${_vcv_vm[MACHINE_TYPE]:-}'" "$vm_name"; return 1; }
    [[ "${_vcv_vm[MACHINE_OPTIONS]:-}" =~ ^accel=(kvm|tcg)$ ]] || {
        log_message "ERROR" "Invalid MACHINE_OPTIONS: '${_vcv_vm[MACHINE_OPTIONS]:-}'" "$vm_name"; return 1; }
    [[ "${_vcv_vm[MAC_ADDRESS]:-}" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]] || {
        log_message "ERROR" "Invalid MAC_ADDRESS: '${_vcv_vm[MAC_ADDRESS]:-}'" "$vm_name"; return 1; }
    if [[ -n "${_vcv_vm[BRIDGE_NAME]:-}" ]]; then
        [[ "${_vcv_vm[BRIDGE_NAME]}" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || {
            log_message "ERROR" "Invalid BRIDGE_NAME: '${_vcv_vm[BRIDGE_NAME]}'" "$vm_name"; return 1; }
    fi

    if [[ -n "${_vcv_vm[DISK_DEV]:-}" ]]; then
        [[ "${_vcv_vm[DISK_DEV]}" =~ ^/dev/[A-Za-z0-9_./@+-]+$ ]] || {
            log_message "ERROR" "Invalid DISK_DEV: '${_vcv_vm[DISK_DEV]}'" "$vm_name"; return 1; }
    else
        [[ "${_vcv_vm[DISK_SIZE]:-}" =~ ^[0-9]+[GMgm]$ ]] || {
            log_message "ERROR" "Invalid DISK_SIZE: '${_vcv_vm[DISK_SIZE]:-}'" "$vm_name"; return 1; }
    fi

    for key in ENABLE_VIRTIO MEMORY_PREALLOC MEMORY_SHARE ENABLE_AUDIO ENABLE_TPM SPICE_ENABLED ENABLE_UEFI HIDE_KVM LOCKED; do
        value="${_vcv_vm[$key]:-}"
        [[ "$value" =~ ^[01]$ ]] || {
            log_message "ERROR" "Invalid $key: '$value' (must be 0 or 1)" "$vm_name"; return 1; }
    done

    case "${_vcv_vm[PERFORMANCE_PROFILE]:-balanced}" in
        balanced|performance) ;;
        *) log_message "ERROR" "Invalid PERFORMANCE_PROFILE: '${_vcv_vm[PERFORMANCE_PROFILE]:-}'" "$vm_name"; return 1 ;;
    esac

    if [[ -n "${_vcv_vm[CPU_AFFINITY]:-}" ]]; then
        [[ "${_vcv_vm[CPU_AFFINITY]}" =~ ^[0-9,-]+$ ]] || {
            log_message "ERROR" "Invalid CPU_AFFINITY: '${_vcv_vm[CPU_AFFINITY]}'" "$vm_name"; return 1; }
        command -v taskset >/dev/null 2>&1 && taskset -c "${_vcv_vm[CPU_AFFINITY]}" true >/dev/null 2>&1 || {
            log_message "ERROR" "CPU_AFFINITY selects unavailable CPUs: '${_vcv_vm[CPU_AFFINITY]}'" "$vm_name"; return 1; }
    fi

    if [[ "${_vcv_vm[OS_TYPE]:-linux}" == "macos" ]]; then
        [[ "${_vcv_vm[MACOS_VERSION]:-}" =~ ^(high-sierra|mojave|catalina|big-sur|monterey|ventura|sonoma|sequoia|tahoe)$ ]] || {
            log_message "ERROR" "Invalid MACOS_VERSION: '${_vcv_vm[MACOS_VERSION]:-}'" "$vm_name"; return 1; }
    fi
    if [[ "${_vcv_vm[OS_TYPE]:-linux}" == "macos" ]]; then
        key="MACOS_INSTALL_MEDIA"
        value="${_vcv_vm[$key]:-0}"
        [[ "$value" =~ ^[01]$ ]] || {
            log_message "ERROR" "Invalid $key: '$value' (must be 0 or 1)" "$vm_name"; return 1; }

        value="${_vcv_vm[MACOS_GUEST_AGENT]:-1}"
        [[ "$value" =~ ^[01]$ ]] || {
            log_message "ERROR" "Invalid MACOS_GUEST_AGENT: '$value' (must be 0 or 1)" "$vm_name"
            return 1
        }
    fi

    [[ "${_vcv_vm[VRAM_SIZE_MB]:-}" =~ ^[0-9]+$ && "${_vcv_vm[VRAM_SIZE_MB]}" -ge 16 && "${_vcv_vm[VRAM_SIZE_MB]}" -le 512 ]] || {
        log_message "ERROR" "Invalid VRAM_SIZE_MB: '${_vcv_vm[VRAM_SIZE_MB]:-}' (must be 16-512)" "$vm_name"; return 1; }
    [[ "${_vcv_vm[SPICE_PORT]:-}" =~ ^[0-9]+$ && "${_vcv_vm[SPICE_PORT]}" -ge 1 && "${_vcv_vm[SPICE_PORT]}" -le 65535 ]] || {
        log_message "ERROR" "Invalid SPICE_PORT: '${_vcv_vm[SPICE_PORT]:-}'" "$vm_name"; return 1; }

    case "${_vcv_vm[SHARE_BACKEND]:-auto}" in
        auto|virtfs|smb|virtiofs) ;;
        *) log_message "ERROR" "Invalid SHARE_BACKEND: '${_vcv_vm[SHARE_BACKEND]:-}'" "$vm_name"; return 1 ;;
    esac

    base_video="${_vcv_vm[VIDEO_TYPE]%%,*}"
    case "$base_video" in
        qxl|qxl-vga|virtio-vga|virtio-gpu|std|vmware) ;;
        *) log_message "ERROR" "Invalid VIDEO_TYPE: '${_vcv_vm[VIDEO_TYPE]:-}'" "$vm_name"; return 1 ;;
    esac

    if [[ -n "${_vcv_vm[AUDIO_PASSTHROUGH_PCI]:-}" && "${_vcv_vm[AUDIO_PASSTHROUGH_PCI]}" != "0" ]]; then
        [[ "${_vcv_vm[AUDIO_PASSTHROUGH_PCI]}" =~ ^([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]$ ]] || {
            log_message "ERROR" "Invalid AUDIO_PASSTHROUGH_PCI: '${_vcv_vm[AUDIO_PASSTHROUGH_PCI]}'" "$vm_name"; return 1; }
    fi

    if [[ -n "${_vcv_vm[PORT_FORWARDS]:-}" ]]; then
        local ports=() port normalized
        split_list "${_vcv_vm[PORT_FORWARDS]}" ports
        for port in "${ports[@]}"; do
            parse_port_spec "$port" "$vm_name" normalized >/dev/null || return 1
        done
    fi

    if [[ -n "${_vcv_vm[USB_DEVICES]:-}" ]]; then
        local usbs=() usb
        split_list "${_vcv_vm[USB_DEVICES]}" usbs
        for usb in "${usbs[@]}"; do
            [[ "$usb" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]] || {
                log_message "ERROR" "Invalid USB_DEVICES entry: '$usb'" "$vm_name"; return 1; }
        done
    fi

    if [[ -n "${_vcv_vm[SHARED_FOLDERS]:-}" ]]; then
        local shares=() share tag path
        split_list "${_vcv_vm[SHARED_FOLDERS]}" shares
        for share in "${shares[@]}"; do
            [[ "$share" == *:* ]] || { log_message "ERROR" "Invalid SHARED_FOLDERS entry: '$share'" "$vm_name"; return 1; }
            tag="${share%%:*}"; path="${share#*:}"
            [[ "$tag" =~ ^[A-Za-z0-9_.-]+$ && "$path" =~ ^/[^,[:cntrl:]]+$ ]] || {
                log_message "ERROR" "Invalid shared folder entry: '$share'" "$vm_name"; return 1; }
        done
    fi

    return 0
}

load_vm_config() {
    local vm_name="$1"
    local -n _lvc_vm="$2"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    local config_file="$VM_DIR/$vm_name/config"

    [[ ! -f "$config_file" ]] && {
        log_message "ERROR" "Config not found for: $vm_name" "$vm_name"; return 1; }

    # Security check using pure stat format
    local owner perms
    read -r owner perms < <(stat -c "%U %a" "$config_file")
    [[ "$owner" != "$USER" ]] && {
        log_message "ERROR" "Security: config not owned by $USER" "$vm_name"; return 1; }
    if [[ "$perms" != "600" ]]; then
        log_message "WARNING" "Config permissions are $perms. Hardening to 600." "$vm_name"
        chmod 600 "$config_file"
    fi

    local -A allowed=()
    local k; for k in "${CONFIG_KEYS[@]}"; do allowed[$k]=1; done

    local _fd
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

    local line line_num=0 _key _val
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( ++line_num ))
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            _key="${BASH_REMATCH[1]}"
            _val="${BASH_REMATCH[2]}"
            if [[ "$_val" =~ ^\"(.*)\"$ ]]; then
                _val=$(unquote_config_value "${BASH_REMATCH[1]}")
            elif [[ "$_val" =~ ^\'(.*)\'$ ]]; then
                _val="${BASH_REMATCH[1]}"
            fi
            if [[ -n "${allowed[$_key]:-}" ]]; then
                _lvc_vm[$_key]="$_val"
            else
                log_message "WARNING" "Config line $line_num: unknown key '$_key' ignored." "$vm_name"
            fi
        else
            log_message "ERROR" "Config line $line_num: syntax error → '$line'" "$vm_name"
            release_flock _fd "$config_file.lock"
            return 1
        fi
    done < "$config_file"

    local var
    for var in NAME CORES MEMORY NETWORK_TYPE NETWORK_MODEL DISK_INTERFACE VIDEO_TYPE; do
        if [[ -z "${_lvc_vm[$var]:-}" ]]; then
            log_message "ERROR" "Config missing required field: $var" "$vm_name"
            release_flock _fd "$config_file.lock"
            return 1
        fi
    done

    _lvc_vm[PERFORMANCE_PROFILE]="${_lvc_vm[PERFORMANCE_PROFILE]:-balanced}"
    _lvc_vm[MACOS_VERSION]="${_lvc_vm[MACOS_VERSION]:-}"
    _lvc_vm[HIDE_KVM]="${_lvc_vm[HIDE_KVM]:-0}"
    _lvc_vm[CPU_AFFINITY]="${_lvc_vm[CPU_AFFINITY]:-}"
    [[ "${_lvc_vm[OS_TYPE]:-linux}" == "macos" ]] &&         _lvc_vm[MACOS_GUEST_AGENT]="${_lvc_vm[MACOS_GUEST_AGENT]:-1}"

    validate_vm_config_values "$vm_name" _lvc_vm || {
        release_flock _fd "$config_file.lock"
        return 1
    }

    release_flock _fd "$config_file.lock"
}

save_vm_config() {
    local vm_name="$1"
    local -n _svc_vm="$2"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    local config_file="$VM_DIR/$vm_name/config"

    local _fd
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

    if [[ "${_svc_vm[MACHINE_TYPE]:-}" == "q35" ]]; then
        _svc_vm[MACHINE_TYPE]="$DEFAULT_MACHINE_TYPE"
    fi

    validate_vm_config_values "$vm_name" _svc_vm || {
        release_flock _fd "$config_file.lock"
        return 1
    }

    local tmp
    tmp="$(mktemp "$config_file.XXXXXX")"
    local key value quoted
    for key in "${CONFIG_KEYS[@]}"; do
        case "$key" in
            MAC_ADDRESS) value="${_svc_vm[$key]:-$(generate_mac_address "$vm_name")}" ;;
            MACHINE_OPTIONS) value="${_svc_vm[$key]:-accel=kvm}" ;;
            *) value="${_svc_vm[$key]:-}" ;;
        esac
        quoted=$(quote_config_value "$value") || {
            rm -f "$tmp"
            release_flock _fd "$config_file.lock"
            log_message "ERROR" "Cannot serialize config value containing a newline: $key" "$vm_name"
            return 1
        }
        printf '%s=%s\n' "$key" "$quoted"
    done > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$config_file"

    log_message "DEBUG" "Config saved for: $vm_name" "$vm_name"
    release_flock _fd "$config_file.lock"
}

check_vm_dependencies() {
    local vm_name="$1"
    local -n _deps_vm="$2"
    local missing=()

    if [[ "${_deps_vm[ENABLE_UEFI]:-0}" == "1" && "${_deps_vm[OS_TYPE]:-linux}" != "macos" ]]; then
        local _c="" _v=""
        find_ovmf _c _v || missing+=("edk2-ovmf (OVMF firmware not found; install the edk2-ovmf package for your distribution)")
    fi

    if [[ "${_deps_vm[ENABLE_TPM]:-0}" == "1" ]]; then
        command -v swtpm       >/dev/null || missing+=("swtpm")
        command -v swtpm_setup >/dev/null || missing+=("swtpm_setup (swtpm-tools)")
    fi

    local shares=()
    split_list "${_deps_vm[SHARED_FOLDERS]:-}" shares
    local backend
    backend=$(resolve_share_backend _deps_vm)
    if [[ ${#shares[@]} -gt 0 && "$backend" == "virtiofs" ]]; then
        have_virtiofsd || missing+=("virtiofsd")
    elif [[ ${#shares[@]} -gt 0 && "$backend" == "smb" ]]; then
        case "${_deps_vm[NETWORK_TYPE]:-user}" in
            user|nat) ;;
            *) log_message "ERROR" "SMB shares require NETWORK_TYPE=user or nat." "$vm_name"; return 1 ;;
        esac
        command -v smbd >/dev/null || missing+=("smbd (samba)")
    fi

    if [[ "${_deps_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        qemu-system-x86_64 -display help 2>/dev/null | grep -q "spice" || \
            log_message "WARNING" "QEMU may not be compiled with SPICE support." "$vm_name"
    fi

    if [[ "${_deps_vm[OS_TYPE]:-linux}" == "macos" ]]; then
        if [[ -r /sys/module/kvm/parameters/ignore_msrs ]]; then
            local ignore_msrs
            ignore_msrs=$(< /sys/module/kvm/parameters/ignore_msrs)
            if [[ "$ignore_msrs" != "Y" && "$ignore_msrs" != "1" ]]; then
                log_message "ERROR" "KVM ignore_msrs is disabled. The kvm module is already loaded, so 'sudo modprobe kvm ignore_msrs=1' may be a no-op. Enable it with: sudo sh -c 'echo 1 > /sys/module/kvm/parameters/ignore_msrs' (or unload/reload KVM with ignore_msrs=1)." "$vm_name"
                return 1
            fi
        else
            log_message "ERROR" "Cannot verify KVM ignore_msrs on this host. macOS requires KVM ignore_msrs=1 per OSX-KVM. Check /sys/module/kvm/parameters/ignore_msrs or your KVM module configuration." "$vm_name"
            return 1
        fi
        local cpu_flags=""
        if command -v lscpu >/dev/null 2>&1; then
            cpu_flags=$(lscpu 2>/dev/null | awk -F: '/^Flags/ {gsub(/^[[:space:]]+/,"",$2); print $2}')
            local flag
            for flag in avx avx2 f16c rdrand; do
                [[ " $cpu_flags " == *"$flag"* ]] || log_message "WARNING" "Host CPU is missing $flag; modern macOS virtualization may not work reliably." "$vm_name"
            done
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Pre-flight failed. Missing: ${missing[*]}" "$vm_name"
        return 1
    fi
}

# =============================================================================
# NETWORK UTILS
# =============================================================================

tap_interface_name() {
    local vm_name="$1" tap_hash
    read -r tap_hash _ < <(echo -n "$vm_name" | md5sum)
    printf 'qtap-%s-%s' "${vm_name:0:6}" "${tap_hash:0:5}"
}

setup_tap_interface() {
    local vm_name="$1"
    local -n _sti_vm="$2"
    local tap_name
    tap_name=$(tap_interface_name "$vm_name")
    local bridge="${_sti_vm[BRIDGE_NAME]:-}"

    if [[ ! -r /dev/net/tun || ! -w /dev/net/tun ]]; then
        log_message "ERROR" \
            "/dev/net/tun not accessible. Run: sudo usermod -aG netdev $USER" "$vm_name"
        return 1
    fi

    if ip link show "$tap_name" &>/dev/null; then
        ip link set "$tap_name" down  2>/dev/null || true
        ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true
    fi

    ip tuntap add dev "$tap_name" mode tap user "$USER" 2>/dev/null || {
        log_message "ERROR" "Failed to create tap '$tap_name'." "$vm_name"; return 1; }

    if [[ -n "$bridge" ]]; then
        ip link show "$bridge" &>/dev/null || {
            log_message "ERROR" "Bridge '$bridge' does not exist." "$vm_name"
            ip tuntap del dev "$tap_name" mode tap 2>/dev/null; return 1
        }
        ip link set "$tap_name" master "$bridge" 2>/dev/null || {
            log_message "ERROR" "Failed to attach '$tap_name' to bridge '$bridge'." "$vm_name"
            ip tuntap del dev "$tap_name" mode tap 2>/dev/null; return 1
        }
    fi

    ip link set "$tap_name" up 2>/dev/null
    echo "$tap_name"
}

teardown_tap_interface() {
    local vm_name="$1"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    local tap_name
    tap_name=$(tap_interface_name "$vm_name")
    if ip link show "$tap_name" &>/dev/null; then
        ip link set "$tap_name" down       2>/dev/null || true
        ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true
        log_message "INFO" "TAP '$tap_name' removed." "$vm_name"
    fi
}

valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.' octets=() octet
    read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ && "$octet" -ge 0 && "$octet" -le 255 ]] || return 1
    done
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ && "$1" -ge 1 && "$1" -le 65535 ]]
}

host_port_in_use() {
    local host_port="$1" proto="$2" _st _rq _sq local_addr _peer local_port
    command -v ss >/dev/null 2>&1 || return 1
    [[ "$host_port" =~ ^[0-9]+$ ]] || return 1

    # Compare against the port of ss column 4 (Local Address:Port) only.
    # A substring match on the whole line false-positives on IPv4 octets
    # (10.0.0.80:22 looks like port 80).
    while read -r _st _rq _sq local_addr _peer; do
        [[ -n "$local_addr" ]] || continue
        local_port="${local_addr##*:}"
        [[ "$local_port" == "$host_port" ]] && return 0
    done < <(ss -H -l${proto:0:1}n 2>/dev/null || true)
    return 1
}

parse_port_spec() {
    local port_spec="$1" vm_name="$2"
    local output_var="$3"
    if [[ "$port_spec" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+)(:(tcp|udp))?$ ]]; then
        local ip="${BASH_REMATCH[2]:-}"
        local host_port="${BASH_REMATCH[3]}"
        local guest_port="${BASH_REMATCH[4]}"
        local proto="${BASH_REMATCH[6]:-tcp}"
        if [[ -n "$ip" ]] && ! valid_ipv4 "$ip"; then
            log_message "ERROR" "Invalid host IP in port rule: '$port_spec'" "$vm_name"
            return 1
        fi
        valid_port "$host_port" || {
            log_message "ERROR" "Invalid host port in port rule: '$port_spec'" "$vm_name"; return 1; }
        valid_port "$guest_port" || {
            log_message "ERROR" "Invalid guest port in port rule: '$port_spec'" "$vm_name"; return 1; }
        if [[ -n "$ip" ]]; then printf -v "$output_var" '%s' "${ip}:${host_port}:${guest_port}:${proto}"
        else                    printf -v "$output_var" '%s' "${host_port}:${guest_port}:${proto}"
        fi
        return 0
    fi
    log_message "ERROR" "Invalid port format: '$port_spec'. Use [IP:]HOST:GUEST[:PROTO]" "$vm_name"
    return 1
}

manage_network_ports() {
    local vm_name="$1" action="$2" port_spec="${3:-}"
    require_vm "$vm_name" exists unlocked || return 1
    local operation_fd
    acquire_stopped_vm_lock "$vm_name" operation_fd || return 1

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1

    local normalized; parse_port_spec "$port_spec" "$vm_name" normalized || return 1
    local port_array=(); split_list "${VM[PORT_FORWARDS]:-}" port_array
    local new_array=() found=0 p

    case "$action" in
        add)
            for p in "${port_array[@]}"; do
                [[ "$p" == "$normalized" ]] && {
                    log_message "WARNING" "Port rule already exists: $normalized" "$vm_name"; return 0; }
                new_array+=("$p")
            done
            # Validate host port is free now so the error is not deferred until start.
            if [[ "$normalized" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                local check_hport="${BASH_REMATCH[3]}" check_proto="${BASH_REMATCH[5]}"
                if host_port_in_use "$check_hport" "$check_proto"; then
                    log_message "ERROR" "Host port already in use: ${check_hport}/${check_proto}" "$vm_name"
                    release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
                    return 1
                fi
            fi
            new_array+=("$normalized")
            log_message "INFO" "Added port forwarding: $normalized" "$vm_name" ;;
        remove)
            for p in "${port_array[@]}"; do
                [[ "$p" != "$normalized" ]] && new_array+=("$p") || found=1
            done
            [[ $found -eq 0 ]] && {
                log_message "WARNING" "Port rule not found: $normalized" "$vm_name"; return 1; }
            log_message "INFO" "Removed port forwarding: $normalized" "$vm_name" ;;
    esac

    VM[PORT_FORWARDS]=$(IFS=,; echo "${new_array[*]:-}")
    save_vm_config "$vm_name" VM
    release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
}

# =============================================================================
# IOMMU / VFIO — AUDIO PASSTHROUGH UTILS
# =============================================================================

get_iommu_group() {
    local pci_dev="$1"
    [[ "$pci_dev" != 0000:* ]] && pci_dev="0000:${pci_dev#0000:}"
    local group_link="/sys/bus/pci/devices/$pci_dev/iommu_group"
    if [[ -L "$group_link" ]]; then
        local link; link=$(readlink "$group_link")
        echo "${link##*/}"
    else
        return 1
    fi
}

get_group_devices() {
    local group_id="$1"
    local devs=() d
    shopt -s nullglob
    for d in /sys/kernel/iommu_groups/"$group_id"/devices/*; do
        devs+=("${d##*/}")
    done
    shopt -u nullglob
    echo "${devs[@]}"
}

save_original_drivers() {
    local vm_name="$1" pci_id="$2"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    # Store in the VM directory rather than /tmp to prevent symlink/TOCTOU attacks
    # on a world-writable directory.
    local state_file="$VM_DIR/$vm_name/driver_state"
    grep -q "^$pci_id " "$state_file" 2>/dev/null && return 0

    local dev_path="/sys/bus/pci/devices/$pci_id"
    if [[ -L "$dev_path/driver" ]]; then
        local link driver vendor_id device_id vendor device
        link=$(readlink "$dev_path/driver")
        driver="${link##*/}"
        
        if [[ "$driver" != "vfio-pci" ]]; then
            read -r vendor < "$dev_path/vendor"; vendor_id="${vendor#0x}"
            read -r device < "$dev_path/device"; device_id="${device#0x}"
            echo "$pci_id $driver $vendor_id $device_id" >> "$state_file"
            log_message "DEBUG" "Saved driver $driver for $pci_id (${vendor_id}:${device_id})" "$vm_name"
        fi
    fi
}

restore_group_drivers() {
    local vm_name="$1"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    local state_file="$VM_DIR/$vm_name/driver_state"
    [[ ! -f "$state_file" ]] && return 0

    log_message "INFO" "Restoring original host drivers..." "$vm_name"

    # Prefer non-interactive sudo. If credentials expired, surface a clear error
    # instead of silently leaving devices on vfio-pci.
    if ! sudo -n true 2>/dev/null; then
        log_message "ERROR" "Cannot restore host drivers: sudo credentials expired or unavailable. Devices may remain bound to vfio-pci. Re-run with an interactive shell or configure NOPASSWD for VFIO sysfs paths." "$vm_name"
        # Keep state_file so a later interactive attempt can still restore.
        return 1
    fi

    local pci_id driver vendor_id device_id restore_failed=0

    while read -r pci_id driver vendor_id device_id; do
        [[ -z "$pci_id" || -z "$driver" ]] && continue
        local dev_path="/sys/bus/pci/devices/$pci_id"

        if [[ -L "$dev_path/driver" ]]; then
            local link current
            link=$(readlink "$dev_path/driver")
            current="${link##*/}"
            if [[ "$current" != "$driver" ]]; then
                if ! echo "$pci_id" | sudo -n tee "/sys/bus/pci/drivers/$current/unbind" >/dev/null 2>&1; then
                    log_message "WARNING" "Failed to unbind $pci_id from $current" "$vm_name"
                fi
            fi
        fi

        echo "" | sudo -n tee "$dev_path/driver_override" >/dev/null 2>&1 || true

        if [[ -n "${vendor_id:-}" && -n "${device_id:-}" ]]; then
            echo "${vendor_id} ${device_id}" | \
                sudo -n tee /sys/bus/pci/drivers/vfio-pci/remove_id >/dev/null 2>&1 || true
        fi

        log_message "INFO" "Rebinding $pci_id to $driver..." "$vm_name"
        if ! echo "$pci_id" | sudo -n tee "/sys/bus/pci/drivers/$driver/bind" >/dev/null 2>&1; then
            log_message "WARNING" "Bind failed. Triggering PCI rescan for $pci_id..." "$vm_name"
            echo 1 | sudo -n tee "/sys/bus/pci/devices/$pci_id/remove" >/dev/null 2>&1 || true
            sleep 0.5
            echo 1 | sudo -n tee "/sys/bus/pci/rescan" >/dev/null 2>&1 || true

            if [[ -L "$dev_path/driver" ]]; then
                log_message "INFO"  "✅ $pci_id recovered via rescan." "$vm_name"
            else
                log_message "ERROR" "❌ Failed to restore $pci_id even after rescan." "$vm_name"
                restore_failed=1
            fi
        else
            log_message "INFO" "✅ $pci_id restored to $driver." "$vm_name"
        fi
    done < "$state_file"

    if [[ "$restore_failed" -eq 0 ]]; then
        rm -f "$state_file"
    else
        log_message "WARNING" "Kept driver_state for retry; some devices were not restored." "$vm_name"
    fi
    return "$restore_failed"
}

# =============================================================================
# USB UTILITIES
# =============================================================================

parse_usb_id() {
    if [[ ! "$1" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        log_message "ERROR" "Invalid USB ID: '$1'. Use vendor:product hex (e.g. 046d:c52b)"
        return 1
    fi
}

manage_usb() {
    local vm_name="$1" action="$2" usb_id="${3:-}"
    require_vm "$vm_name" exists unlocked || return 1
    local operation_fd=""
    if [[ "$action" != "list" ]]; then
        acquire_stopped_vm_lock "$vm_name" operation_fd || return 1
    fi

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    local usb_array=(); split_list "${VM[USB_DEVICES]:-}" usb_array

    case "$action" in
        list)
            if [[ ${#usb_array[@]} -eq 0 ]]; then
                echo "No USB devices configured for VM: $vm_name"
            else
                echo "USB devices for VM: $vm_name"
                local dev desc
                for dev in "${usb_array[@]}"; do
                    desc=$(lsusb 2>/dev/null | grep -i "ID ${dev}" | sed 's/.*ID [^ ]* //' | head -1) || true
                    printf "  %-12s  %s\n" "$dev" "${desc:-(not currently connected)}"
                done
            fi
            return 0 ;;
        add)
            parse_usb_id "$usb_id" || return 1
            local u
            for u in "${usb_array[@]}"; do
                [[ "$u" == "$usb_id" ]] && {
                    log_message "WARNING" "USB device already added: $usb_id" "$vm_name"; return 0; }
            done
            usb_array+=("$usb_id")
            log_message "INFO" "USB device added: $usb_id" "$vm_name" ;;
        remove)
            parse_usb_id "$usb_id" || return 1
            local new_array=() found=0 u
            for u in "${usb_array[@]}"; do
                [[ "$u" != "$usb_id" ]] && new_array+=("$u") || found=1
            done
            [[ $found -eq 0 ]] && {
                log_message "ERROR" "USB device not found: $usb_id" "$vm_name"; return 1; }
            usb_array=("${new_array[@]:-}")
            log_message "INFO" "USB device removed: $usb_id" "$vm_name" ;;
    esac

    VM[USB_DEVICES]=$(IFS=,; echo "${usb_array[*]:-}")
    save_vm_config "$vm_name" VM
    [[ -z "$operation_fd" ]] || release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
}

# =============================================================================
# SHARE UTILS
# =============================================================================

have_virtiofsd() {
    if [[ "$_CACHE_VIRTIOFSD_DONE" -eq 1 ]]; then
        [[ -n "$_CACHE_VIRTIOFSD" ]]
        return $?
    fi
    _CACHE_VIRTIOFSD_DONE=1
    local bin
    bin=$(command -v virtiofsd 2>/dev/null || { [[ -x /usr/lib/virtiofsd ]] && echo /usr/lib/virtiofsd; } || true)
    if [[ -n "$bin" ]] && "$bin" --version &>/dev/null; then
        _CACHE_VIRTIOFSD="$bin"
        return 0
    fi
    _CACHE_VIRTIOFSD=""
    return 1
}

# Return cached virtiofsd binary path (empty if unavailable).
virtiofsd_bin() {
    have_virtiofsd >/dev/null 2>&1
    printf '%s' "$_CACHE_VIRTIOFSD"
}

resolve_share_backend() {
    local -n _rsb_vm="$1"
    local backend="${_rsb_vm[SHARE_BACKEND]:-auto}"
    local shares=()
    split_list "${_rsb_vm[SHARED_FOLDERS]:-}" shares
    local share_count="${#shares[@]}"

    [[ "$share_count" -eq 0 ]] && { echo "none"; return; }

    if [[ "$backend" != "auto" ]]; then
        if [[ "$backend" == "smb" && "$share_count" -gt 1 ]]; then
            log_message "WARNING" "SMB does not support multiple shares. Falling back to virtiofs." "${_rsb_vm[NAME]:-unknown}"
            echo "virtiofs"; return
        fi
        echo "$backend"; return
    fi

    if [[ "$share_count" -gt 1 ]]; then
        if have_virtiofsd; then echo "virtiofs"
        else
            log_message "WARNING" "Multiple shares requested but virtiofsd not available. Falling back to SMB." "${_rsb_vm[NAME]:-unknown}"
            echo "smb"
        fi
    elif [[ "${_rsb_vm[OS_TYPE]:-linux}" == "windows" ]]; then
        echo "smb"
    elif [[ "${_rsb_vm[OS_TYPE]:-linux}" == "macos" ]]; then
        # macOS has no supported 9p/virtiofs guest driver in this stack.
        # QEMU user-mode SMB is the only qemate-managed share path.
        echo "smb"
    elif have_virtiofsd; then
        echo "virtiofs"
    else
        echo "virtfs"
    fi
}

parse_share_spec() {
    local spec="$1"
    if [[ "$spec" =~ ^([^/:][^:]*):(.+)$ ]]; then
        local tag="${BASH_REMATCH[1]}" path="${BASH_REMATCH[2]}"
        [[ "$tag" == *","* || "$path" == *","* ]] && {
            log_message "ERROR" "Share tag/path must not contain commas: '$spec'"; return 1; }
        echo "${tag}:${path}"
    elif [[ -d "$spec" ]]; then
        local derived="${spec##*/}"
        [[ "$derived" == *","* || "$spec" == *","* ]] && {
            log_message "ERROR" "Share tag/path must not contain commas: '$spec'"; return 1; }
        echo "${derived}:${spec}"
    else
        log_message "ERROR" "Invalid share spec: '$spec'. Use /host/path or tag:/host/path"
        return 1
    fi
}

get_smb_share_path() {
    local vm_name="$1"
    local -n _gsp_vm="$2"
    [[ -z "${_gsp_vm[SHARED_FOLDERS]:-}" ]] && return 0

    local backend; backend=$(resolve_share_backend _gsp_vm)
    [[ "$backend" != "smb" ]] && return 0

    local shares=(); split_list "${_gsp_vm[SHARED_FOLDERS]}" shares
    [[ "${#shares[@]}" -eq 0 ]] && return 0
    [[ "${#shares[@]}" -gt 1 ]] && log_message "WARNING" "SMB supports only one share. Using first: ${shares[0]}" "$vm_name"

    local path="${shares[0]#*:}"
    if [[ ! -d "$path" ]]; then
        log_message "ERROR" "SMB share path not found: $path" "$vm_name"; return 1
    fi
    echo "$path"
}

manage_shares() {
    local vm_name="$1" action="$2" spec="${3:-}"
    require_vm "$vm_name" exists unlocked || return 1
    local operation_fd=""
    if [[ "$action" != "list" ]]; then
        acquire_stopped_vm_lock "$vm_name" operation_fd || return 1
    fi

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    local share_array=(); split_list "${VM[SHARED_FOLDERS]:-}" share_array

    case "$action" in
        list)
            if [[ ${#share_array[@]} -eq 0 ]]; then
                echo "No shared folders configured for VM: $vm_name"
            else
                echo "Shared folders for VM: $vm_name  (backend: ${VM[SHARE_BACKEND]:-auto})"
                local s
                for s in "${share_array[@]}"; do
                    printf "  %-15s → %s\n" "${s%%:*}" "${s#*:}"
                done
            fi
            return 0 ;;
        add)
            local resolved; resolved=$(parse_share_spec "$spec") || return 1
            local new_tag="${resolved%%:*}" new_path
            new_path=$(realpath -m "${resolved#*:}")
            [[ ! -d "$new_path" ]] && { log_message "ERROR" "Host path does not exist: $new_path"; return 1; }
            local s
            for s in "${share_array[@]:-}"; do
                [[ "${s%%:*}" == "$new_tag" ]] && { log_message "ERROR" "Share tag '$new_tag' already exists."; return 1; }
            done
            share_array+=("${new_tag}:${new_path}")
            log_message "INFO" "Share added: $new_tag → $new_path" "$vm_name" ;;
        remove)
            local new_array=() found=0 s
            for s in "${share_array[@]:-}"; do
                [[ "${s%%:*}" != "$spec" ]] && new_array+=("$s") || found=1
            done
            [[ $found -eq 0 ]] && { log_message "ERROR" "Share tag not found: $spec" "$vm_name"; return 1; }
            share_array=("${new_array[@]:-}")
            log_message "INFO" "Share removed: $spec" "$vm_name" ;;
    esac

    VM[SHARED_FOLDERS]=$(IFS=,; echo "${share_array[*]:-}")
    save_vm_config "$vm_name" VM
    [[ -z "$operation_fd" ]] || release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
}

start_virtiofsd_daemons() {
    local vm_name="$1"
    local -n _svd_vm="$2"
    local socket_dir="$VM_DIR/$vm_name/sockets"

    local shares=(); split_list "${_svd_vm[SHARED_FOLDERS]:-}" shares

    local virtiofsd_bin
    virtiofsd_bin=$(virtiofsd_bin)
    [[ -z "$virtiofsd_bin" ]] && { log_message "ERROR" "virtiofsd not found" "$vm_name"; return 1; }

    local -A seen_tags=()
    local s tag path sock pidf
    for s in "${shares[@]}"; do
        tag="${s%%:*}"; path="${s#*:}"

        [[ -n "${seen_tags[$tag]:-}" ]] && {
            log_message "ERROR" "Duplicate share tag: $tag" "$vm_name"
            stop_virtiofsd_daemons "$vm_name"; return 1
        }
        seen_tags[$tag]=1
        if [[ ! -d "$path" ]]; then
            log_message "WARNING" "Share path not found, skipping: $path" "$vm_name"
            continue
        fi

        sock="$socket_dir/virtiofsd_${tag}.sock"
        pidf="$VM_DIR/$vm_name/virtiofsd_${tag}.pid"

        local -a perf_opts=(--announce-submounts --sandbox=namespace)
        if [[ "${_svd_vm[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
            local queues="${_svd_vm[CORES]}"
            (( queues > 4 )) && queues=4
            perf_opts+=("--thread-pool-size=$queues" "--cache=always")
            # Prefer writeback when the host and guest can tolerate it.
            # Guests should still mount with: -o cache=always,writeback,noatime when supported.
            if "$virtiofsd_bin" --help 2>&1 | grep -q -- '--writeback'; then
                perf_opts+=("--writeback")
            fi
        else
            perf_opts+=("--cache=auto")
        fi

        "$virtiofsd_bin" --socket-path="$sock" --shared-dir="$path" "${perf_opts[@]}" \
            &> "$VM_DIR/$vm_name/logs/virtiofsd_${tag}.log" &
        echo "$!" > "$pidf"

        if ! timeout 4 bash -c "until [[ -S '$sock' ]]; do sleep 0.1; done"; then
            log_message "ERROR" "virtiofsd failed to start for: $tag" "$vm_name"
            stop_virtiofsd_daemons "$vm_name"; return 1
        fi
        log_message "INFO" "virtiofsd ready: $tag" "$vm_name"
    done
}

stop_virtiofsd_daemons() {
    local vm_name="$1" pid_file pid
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1

    for pid_file in "$VM_DIR/$vm_name"/virtiofsd_*.pid; do
        [[ -e "$pid_file" ]] || continue
        read -r pid < "$pid_file"
        local tag="${pid_file##*/virtiofsd_}"
        tag="${tag%.pid}"
        local socket="$VM_DIR/$vm_name/sockets/virtiofsd_${tag}.sock"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && pid_cmdline_contains "$pid" "--socket-path=$socket"; then
            kill "$pid" 2>/dev/null
            sleep 0.5
            kill -0 "$pid" 2>/dev/null && pid_cmdline_contains "$pid" "--socket-path=$socket" && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    done
    rm -f "$VM_DIR/$vm_name/sockets"/virtiofsd_*.sock* 2>/dev/null
}

# =============================================================================
# UEFI / OVMF UTILS
# =============================================================================

# Returns the OVMF CODE and VARS paths, or empty strings if not found.
# Results are memoized for the lifetime of the process.
find_ovmf() {
    local -n _code_ref="$1"
    local -n _vars_ref="$2"
    if [[ "$_CACHE_OVMF_DONE" -eq 1 ]]; then
        if [[ -n "$_CACHE_OVMF_CODE" && -n "$_CACHE_OVMF_VARS" ]]; then
            _code_ref="$_CACHE_OVMF_CODE"
            _vars_ref="$_CACHE_OVMF_VARS"
            return 0
        fi
        return 1
    fi
    _CACHE_OVMF_DONE=1
    local search_dirs=(
        /usr/share/edk2/x64
        /usr/share/edk2-ovmf/x64
        /usr/share/edk2/ovmf
        /usr/share/edk2-ovmf
        /usr/share/OVMF
        /usr/share/ovmf/x64
        /usr/share/ovmf
        /usr/share/qemu
    )
    # Distro filenames differ: Arch uses OVMF_CODE.4m.fd, Debian/Ubuntu
    # OVMF_CODE_4M.fd, Fedora OVMF_CODE.fd under edk2/ovmf.
    local d suffix code vars
    for d in "${search_dirs[@]}"; do
        for suffix in "" ".4m" "_4M" ".4M" "_4m"; do
            code="$d/OVMF_CODE${suffix}.fd"
            vars="$d/OVMF_VARS${suffix}.fd"
            if [[ -f "$code" && -f "$vars" ]]; then
                _CACHE_OVMF_CODE="$code"
                _CACHE_OVMF_VARS="$vars"
                _code_ref="$code"
                _vars_ref="$vars"
                return 0
            fi
        done
    done
    _CACHE_OVMF_CODE=""
    _CACHE_OVMF_VARS=""
    return 1
}

configure_uefi() {
    local vm_name="$1"
    local -n _uefi_vm="$2"
    local -n _uefi_cmd="$3"
    local dry_run="${4:-0}"

    [[ "${_uefi_vm[ENABLE_UEFI]:-0}" != "1" ]] && return 0

    local ovmf_code="" ovmf_vars_tmpl=""
    if ! find_ovmf ovmf_code ovmf_vars_tmpl; then
        log_message "ERROR" "OVMF firmware not found. Install the edk2-ovmf package for your distribution." "$vm_name"
        return 1
    fi

    # Each VM gets its own writable NVRAM copy so UEFI variables persist.
    local vm_vars="$VM_DIR/$vm_name/OVMF_VARS.fd"
    if [[ ! -f "$vm_vars" && "$dry_run" != "1" ]]; then
        cp "$ovmf_vars_tmpl" "$vm_vars" && chmod 600 "$vm_vars" || {
            log_message "ERROR" "Failed to create VM UEFI vars file: $vm_vars" "$vm_name"; return 1; }
        log_message "INFO" "UEFI NVRAM initialised for $vm_name" "$vm_name"
    fi

    _uefi_cmd+=(
        "-drive" "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
        "-drive" "if=pflash,format=raw,file=${vm_vars}"
    )
    log_message "INFO" "UEFI firmware: $ovmf_code" "$vm_name"
}

# =============================================================================
# macOS / OSX-KVM UTILS
# =============================================================================

macos_version_supported() {
    [[ "$1" =~ ^(high-sierra|mojave|catalina|big-sur|monterey|ventura|sonoma|sequoia|tahoe)$ ]]
}

macos_choose_version() {
    local -n _selected_version="$1"
    local -a versions=(
        tahoe
        sequoia
        sonoma
        ventura
        monterey
        big-sur
        catalina
        mojave
        high-sierra
    )
    local -a labels=(
        "macOS Tahoe"
        "macOS Sequoia"
        "macOS Sonoma"
        "macOS Ventura"
        "macOS Monterey"
        "macOS Big Sur"
        "macOS Catalina"
        "macOS Mojave"
        "macOS High Sierra"
    )
    local choice index

    [[ -t 0 ]] || {
        log_message "ERROR" "No macOS version was provided and input is not interactive. Use --version VERSION."
        return 1
    }

    printf 'Select a macOS version:\n' >&2
    for index in "${!versions[@]}"; do
        printf '  %d) %s (%s)\n' "$((index + 1))" "${labels[index]}" "${versions[index]}" >&2
    done

    while true; do
        printf 'Enter selection [1-%d]: ' "${#versions[@]}" >&2
        if ! IFS= read -r choice; then
            printf '\n' >&2
            log_message "ERROR" "No macOS version selected."
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            index=$((10#$choice - 1))
            if (( index >= 0 && index < ${#versions[@]} )); then
                _selected_version="${versions[index]}"
                return 0
            fi
        fi
        printf 'Invalid selection. Enter a number from 1 to %d.\n' "${#versions[@]}" >&2
    done
}

macos_download_recovery() {
    local repo="$1" version="$2"
    (
        cd "$repo" || return 1
        # OSX-KVM currently prints its full numbered product menu even when a
        # valid --shortname already selected the product. Hide only those
        # duplicate menu rows while retaining progress and error output.
        PYTHONUNBUFFERED=1 python3 ./fetch-macOS-v2.py --shortname="$version" |
            sed -E '/^[0-9]+\. (High Sierra|Mojave|Catalina|Big Sur|Monterey|Ventura|Sonoma|Sequoia|Tahoe)( \(|$)/d'
    )
}

macos_cpu_model() {
    # Follow OSX-KVM: Penryn for older releases, Haswell-noTSX for Sonoma,
    # Skylake-Client (HLE/RTM off) for Sequoia/Tahoe.
    case "$1" in
        sequoia|tahoe)
            echo "Skylake-Client,-hle,-rtm,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
        sonoma)
            echo "Haswell-noTSX,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
        *)
            echo "Penryn,kvm=on,vendor=GenuineIntel,+invtsc,vmware-cpuid-freq=on,+ssse3,+sse4.2,+popcnt,+avx,+aes,+xsave,+xsaveopt,check" ;;
    esac
}

macos_ensure_shared_cache() {
    require_commands git || return 1
    mkdir -p "$(dirname "$OSX_KVM_CACHE_DIR")"
    if [[ ! -f "$OSX_KVM_CACHE_DIR/.git/HEAD" ]]; then
        log_message "INFO" "Cloning shared OSX-KVM cache into $OSX_KVM_CACHE_DIR..."
        rm -rf "$OSX_KVM_CACHE_DIR"
        git clone --depth 1 --recursive "$MACOS_KVM_REPO" "$OSX_KVM_CACHE_DIR" || {
            log_message "ERROR" "Failed to clone OSX-KVM from $MACOS_KVM_REPO"; return 1; }
    fi
    [[ -f "$OSX_KVM_CACHE_DIR/fetch-macOS-v2.py" && -f "$OSX_KVM_CACHE_DIR/OpenCore/OpenCore.qcow2" ]] || {
        log_message "ERROR" "Shared OSX-KVM cache is incomplete: $OSX_KVM_CACHE_DIR"; return 1; }
}

macos_prepare_repo() {
    local vm_name="$1"
    local macos_dir="$VM_DIR/$vm_name/macos"
    require_commands git || return 1
    mkdir -p "$macos_dir"
    chmod 700 "$macos_dir"
    macos_ensure_shared_cache || return 1

    # Prefer a local worktree (or lightweight local clone) linked to the shared cache
    # so multiple macOS VMs do not each download the full repository.
    if [[ ! -f "$macos_dir/OSX-KVM/.git/HEAD" && ! -f "$macos_dir/OSX-KVM/.git" ]]; then
        log_message "INFO" "Creating per-VM OSX-KVM worktree from shared cache..." "$vm_name"
        rm -rf "$macos_dir/OSX-KVM"
        if git -C "$OSX_KVM_CACHE_DIR" worktree add --detach "$macos_dir/OSX-KVM" HEAD 2>/dev/null; then
            :
        else
            # Fallback for older git: local clone reuses objects via hardlinks when possible.
            git clone --local --shared --depth 1 "$OSX_KVM_CACHE_DIR" "$macos_dir/OSX-KVM" || {
                log_message "ERROR" "Failed to create per-VM OSX-KVM checkout from shared cache" "$vm_name"
                return 1
            }
        fi
    fi
    local repo="$macos_dir/OSX-KVM"
    [[ -f "$repo/fetch-macOS-v2.py" && -f "$repo/OpenCore/OpenCore.qcow2" ]] || {
        log_message "ERROR" "OSX-KVM checkout is incomplete" "$vm_name"; return 1; }
}

macos_repo_info() {
    local vm_name="$1"
    local repo="$VM_DIR/$vm_name/macos/OSX-KVM"
    [[ -d "$repo/.git" ]] || return 1
    local commit remote
    commit=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)
    remote=$(git -C "$repo" remote get-url origin 2>/dev/null || true)
    printf 'repository=%s\ncommit=%s\nremote=%s\n' "$repo" "$commit" "$remote"
}

macos_refresh_repo() {
    local vm_name="$1"
    require_vm "$vm_name" exists unlocked not-running || return 1
    require_commands git || return 1
    local fd
    acquire_stopped_vm_lock "$vm_name" fd || return 1

    # Always refresh the shared cache first so all VMs benefit.
    if [[ -d "$OSX_KVM_CACHE_DIR/.git" ]]; then
        git -C "$OSX_KVM_CACHE_DIR" fetch --depth 1 --prune origin master &&             git -C "$OSX_KVM_CACHE_DIR" reset --hard FETCH_HEAD || {
            log_message "WARNING" "Failed to update shared OSX-KVM cache; continuing with local checkout" "$vm_name"
        }
    else
        macos_ensure_shared_cache || {
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    fi

    local repo="$VM_DIR/$vm_name/macos/OSX-KVM"
    if [[ ! -e "$repo/.git" && ! -d "$repo/.git" ]]; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        macos_prepare_repo "$vm_name"
        return $?
    fi
    # For worktrees, reset to the shared cache HEAD; for local clones, fetch from origin/cache.
    if git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$repo" fetch --depth 1 "$OSX_KVM_CACHE_DIR" HEAD 2>/dev/null || true
        git -C "$repo" reset --hard FETCH_HEAD 2>/dev/null ||             git -C "$repo" reset --hard "$(git -C "$OSX_KVM_CACHE_DIR" rev-parse HEAD)" || {
            log_message "ERROR" "Failed to update local OSX-KVM checkout" "$vm_name"
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    else
        git -C "$repo" fetch --depth 1 --prune origin master || {
            log_message "ERROR" "Failed to update OSX-KVM repository" "$vm_name"
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
        git -C "$repo" reset --hard FETCH_HEAD || {
            log_message "ERROR" "Failed to update local OSX-KVM checkout" "$vm_name"
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    fi
    log_message "INFO" "OSX-KVM assets updated to $(git -C "$repo" rev-parse --short HEAD)." "$vm_name"
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
}

# Return the OpenCore image used for a VM without creating or modifying files.
macos_opencore_image() {
    local vm_name="$1"
    local -n _image_ref="$2"
    local macos_dir="$VM_DIR/$vm_name/macos"
    local asset="$macos_dir/assets/OpenCore.qcow2"
    local checkout="$macos_dir/OSX-KVM/OpenCore/OpenCore.qcow2"

    if [[ -f "$asset" ]]; then
        _image_ref="$asset"
    elif [[ -f "$checkout" ]]; then
        _image_ref="$checkout"
    else
        log_message "ERROR" "OpenCore image is missing (run macos-install or macos-refresh)" "$vm_name"
        return 1
    fi
}

# Make a per-VM, persistent OpenCore copy before changing its EFI.  The source
# checkout can be removed by macos-eject or reset by macos-refresh, so it must
# never be modified in place by managed guest tooling.
macos_private_opencore_image() {
    local vm_name="$1"
    local -n _image_ref="$2"
    local macos_dir="$VM_DIR/$vm_name/macos"
    local assets="$macos_dir/assets"
    local private_image="$assets/OpenCore.qcow2"
    local checkout="$macos_dir/OSX-KVM/OpenCore/OpenCore.qcow2"

    if [[ ! -f "$private_image" ]]; then
        [[ -f "$checkout" ]] || {
            log_message "ERROR" "OpenCore image is missing (run macos-install or macos-refresh)" "$vm_name"
            return 1
        }
        mkdir -p "$assets" || {
            log_message "ERROR" "Failed to create persistent macOS asset directory" "$vm_name"
            return 1
        }
        chmod 700 "$assets" 2>/dev/null || true
        cp "$checkout" "$private_image" || {
            log_message "ERROR" "Failed to create private OpenCore image" "$vm_name"
            return 1
        }
        chmod 600 "$private_image"
    fi
    _image_ref="$private_image"
}

macos_require_efi_tools() {
    require_commands qemu-img sfdisk mcopy mmd mdeltree mtype python3 || {
        log_message "ERROR" "macOS EFI management requires qemu-img, util-linux (sfdisk), mtools, and Python 3."
        return 1
    }
}

macos_efi_partition_offset() {
    local raw_image="$1"
    local -n _offset_ref="$2"
    local detected_offset
    detected_offset=$(sfdisk --json "$raw_image" 2>/dev/null | python3 -c '
import json
import sys

doc = json.load(sys.stdin)
table = doc.get("partitiontable", {})
sector_size = int(table.get("sectorsize", 512))
parts = table.get("partitions", [])
efi_types = {
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b",  # GPT EFI System Partition
    "ef", "uefi",
}
for part in parts:
    kind = str(part.get("type", "")).lower()
    if kind in efi_types:
        print(int(part["start"]) * sector_size)
        raise SystemExit(0)
if len(parts) == 1:
    print(int(parts[0]["start"]) * sector_size)
    raise SystemExit(0)
raise SystemExit("could not identify an EFI System Partition")
') || {
        log_message "ERROR" "Could not identify the EFI partition in OpenCore image: $raw_image"
        return 1
    }
    [[ "$detected_offset" =~ ^[0-9]+$ ]] || {
        log_message "ERROR" "Invalid EFI partition offset returned for OpenCore image"
        return 1
    }
    _offset_ref="$detected_offset"
}

macos_efi_drive() {
    printf '%s@@%s' "$1" "$2"
}

macos_backup_opencore_image() {
    local vm_name="$1" image="$2" label="$3"
    local backup_dir="$VM_DIR/$vm_name/macos/backups"
    local timestamp backup suffix=0
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$backup_dir" || return 1
    chmod 700 "$backup_dir" 2>/dev/null || true
    backup="$backup_dir/OpenCore.${label}.${timestamp}.qcow2"
    while [[ -e "$backup" ]]; do
        (( ++suffix ))
        backup="$backup_dir/OpenCore.${label}.${timestamp}.${suffix}.qcow2"
    done
    cp --reflink=auto --preserve=mode "$image" "$backup" || {
        log_message "ERROR" "Failed to create OpenCore backup: $backup" "$vm_name"
        return 1
    }
    chmod 600 "$backup"
    log_message "INFO" "OpenCore backup created: $backup" "$vm_name"
}

# Update only qemate-owned OpenCore settings.  plistlib both writes canonical
# XML and verifies the resulting plist before the EFI image is rebuilt.
macos_update_opencore_plist() {
    local plist="$1" action="$2" resolution="${3:-}" timeout="${4:-}"
    python3 - "$plist" "$action" "$resolution" "$timeout" <<'PY'
import os
import plistlib
import sys
import tempfile

path, action, resolution, timeout = sys.argv[1:]
with open(path, "rb") as handle:
    config = plistlib.load(handle)

if not isinstance(config, dict):
    raise SystemExit("OpenCore config.plist root must be a dictionary")

def mapping(parent, key):
    value = parent.get(key)
    if not isinstance(value, dict):
        value = {}
        parent[key] = value
    return value

def standard_kext(bundle, executable, comment):
    return {
        "Arch": "x86_64",
        "BundlePath": bundle,
        "Comment": comment,
        "Enabled": True,
        "ExecutablePath": executable,
        "MaxKernel": "",
        "MinKernel": "",
        "PlistPath": "Contents/Info.plist",
    }

if action in {"boot-normal", "boot-recovery"}:
    if not resolution or not timeout:
        raise SystemExit("resolution and timeout are required for boot configuration")
    uefi = mapping(config, "UEFI")
    output = mapping(uefi, "Output")
    output["Resolution"] = resolution
    misc = mapping(config, "Misc")
    boot = mapping(misc, "Boot")
    boot["ShowPicker"] = True
    boot["Timeout"] = int(timeout)
    security = mapping(misc, "Security")
    # 0xF0103 permits APFS and the normal SATA/NVMe device classes but excludes
    # EFI System Partitions.  Zero is OpenCore's permissive scan policy used
    # while recovery/install media is attached.
    security["ScanPolicy"] = 0xF0103 if action == "boot-normal" else 0

if action in {"verbose-on", "verbose-off"}:
    nvram = mapping(config, "NVRAM")
    add = mapping(nvram, "Add")
    apple_guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    add_guid = next((key for key in add
                     if isinstance(key, str) and key.upper() == apple_guid), apple_guid)
    apple_nvram = mapping(add, add_guid)
    boot_args = apple_nvram.get("boot-args", "")
    if not isinstance(boot_args, str):
        raise SystemExit("OpenCore NVRAM boot-args must be a string")
    arguments = boot_args.split()
    if action == "verbose-on":
        if "-v" not in arguments:
            arguments.append("-v")
    else:
        arguments = [argument for argument in arguments if argument != "-v"]
    apple_nvram["boot-args"] = " ".join(arguments)

    # NVRAM Add does not replace an existing firmware variable. Delete it first
    # so the configured value, with or without -v, is applied on the next boot.
    delete = mapping(nvram, "Delete")
    delete_guid = next((key for key in delete
                       if isinstance(key, str) and key.upper() == apple_guid), apple_guid)
    deleted_variables = delete.get(delete_guid, [])
    if not isinstance(deleted_variables, list) or any(not isinstance(name, str) for name in deleted_variables):
        raise SystemExit("OpenCore NVRAM Delete entry must be an array of strings")
    if "boot-args" not in deleted_variables:
        deleted_variables.append("boot-args")
    delete[delete_guid] = deleted_variables

if action in {"vmhide-install", "vmhide-remove"}:
    kernel = mapping(config, "Kernel")
    add = kernel.get("Add")
    if not isinstance(add, list):
        add = []
        kernel["Add"] = add
    vmhide_path = "VMHide.kext"
    lilu_path = "Lilu.kext"
    if action == "vmhide-install":
        positions = [i for i, item in enumerate(add)
                     if isinstance(item, dict) and item.get("BundlePath") in {lilu_path, vmhide_path}]
        insert_at = min(positions) if positions else 0
        kept = [item for item in add
                if not (isinstance(item, dict) and item.get("BundlePath") in {lilu_path, vmhide_path})]
        entries = [
            standard_kext(lilu_path, "Contents/MacOS/Lilu", "qemate: dependency for VMHide"),
            standard_kext(vmhide_path, "Contents/MacOS/VMHide", "qemate: hide VMM presence"),
        ]
        kept[insert_at:insert_at] = entries
        kernel["Add"] = kept
    else:
        kernel["Add"] = [item for item in add
                         if not (isinstance(item, dict) and item.get("BundlePath") == vmhide_path)]

directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(prefix="config.plist.", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "wb") as handle:
        plistlib.dump(config, handle, sort_keys=False)
    with open(temporary, "rb") as handle:
        plistlib.load(handle)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY
}

macos_efi_prepare_raw() {
    local vm_name="$1" image="$2" work_dir="$3"
    local -n _raw_ref="$4" _offset_ref="$5"
    local prepared_raw="$work_dir/OpenCore.raw" prepared_offset
    qemu-img check -q "$image" >/dev/null || {
        log_message "ERROR" "OpenCore image failed qemu-img validation: $image" "$vm_name"
        return 1
    }
    qemu-img convert -O raw "$image" "$prepared_raw" || {
        log_message "ERROR" "Failed to read OpenCore image" "$vm_name"
        return 1
    }
    macos_efi_partition_offset "$prepared_raw" prepared_offset || return 1
    _raw_ref="$prepared_raw"
    _offset_ref="$prepared_offset"
}

macos_efi_commit_raw() {
    local vm_name="$1" raw="$2" image="$3" work_dir="$4"
    local candidate="$work_dir/OpenCore.new.qcow2"
    qemu-img convert -O qcow2 "$raw" "$candidate" || {
        log_message "ERROR" "Failed to rebuild OpenCore image" "$vm_name"
        return 1
    }
    qemu-img check -q "$candidate" >/dev/null || {
        log_message "ERROR" "Rebuilt OpenCore image failed qemu-img validation" "$vm_name"
        return 1
    }
    chmod 600 "$candidate"
    mv -f "$candidate" "$image" || {
        log_message "ERROR" "Failed to atomically replace OpenCore image" "$vm_name"
        return 1
    }
}

# Apply an EFI change while the VM lifecycle lock is already held.  The source
# image is unchanged until the rebuilt qcow2 passes qemu-img validation.
macos_mutate_opencore_locked() {
    local vm_name="$1" action="$2" resolution="${3:-}" timeout="${4:-}" stage_dir="${5:-}"
    local image macos_dir work_dir raw offset drive plist
    macos_require_efi_tools || return 1
    macos_private_opencore_image "$vm_name" image || return 1
    macos_dir="$VM_DIR/$vm_name/macos"
    work_dir=$(mktemp -d "$macos_dir/.efi-edit.XXXXXX") || {
        log_message "ERROR" "Failed to create temporary EFI workspace" "$vm_name"
        return 1
    }
    chmod 700 "$work_dir" 2>/dev/null || true

    if ! macos_backup_opencore_image "$vm_name" "$image" "$action" ||
       ! macos_efi_prepare_raw "$vm_name" "$image" "$work_dir" raw offset; then
        rm -rf "$work_dir"
        return 1
    fi
    drive=$(macos_efi_drive "$raw" "$offset")
    plist="$work_dir/config.plist"
    if ! mcopy -o -i "$drive" ::/EFI/OC/config.plist "$plist"; then
        log_message "ERROR" "Could not read EFI/OC/config.plist from OpenCore image" "$vm_name"
        rm -rf "$work_dir"
        return 1
    fi

    case "$action" in
        boot-normal|boot-recovery)
            macos_update_opencore_plist "$plist" "$action" "$resolution" "$timeout" || {
                log_message "ERROR" "Failed to update OpenCore boot configuration" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            ;;
        verbose-on|verbose-off)
            macos_update_opencore_plist "$plist" "$action" || {
                log_message "ERROR" "Failed to update OpenCore verbose boot argument" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            ;;
        vmhide-install)
            [[ -d "$stage_dir/Lilu.kext" && -d "$stage_dir/VMHide.kext" ]] || {
                log_message "ERROR" "Validated Lilu and VMHide kexts are required" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            macos_update_opencore_plist "$plist" "$action" || {
                log_message "ERROR" "Failed to register VMHide in OpenCore" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            # mmd prompts when the directory already exists.  EFI mutations
            # run from an interactive shell, so detach stdin as well as hiding
            # the expected "already exists" diagnostic.
            mmd -i "$drive" ::/EFI/OC/Kexts </dev/null >/dev/null 2>&1 || true
            mdeltree -i "$drive" ::/EFI/OC/Kexts/VMHide.kext >/dev/null 2>&1 || true
            mdeltree -i "$drive" ::/EFI/OC/Kexts/Lilu.kext >/dev/null 2>&1 || true
            mcopy -s -o -i "$drive" "$stage_dir/Lilu.kext" ::/EFI/OC/Kexts/ &&
            mcopy -s -o -i "$drive" "$stage_dir/VMHide.kext" ::/EFI/OC/Kexts/ || {
                log_message "ERROR" "Failed to copy VMHide kexts into the EFI" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            mtype -i "$drive" ::/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist >/dev/null 2>&1 &&
            mtype -i "$drive" ::/EFI/OC/Kexts/VMHide.kext/Contents/Info.plist >/dev/null 2>&1 || {
                log_message "ERROR" "EFI validation could not find the copied Lilu and VMHide kexts" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            ;;
        vmhide-remove)
            macos_update_opencore_plist "$plist" "$action" || {
                log_message "ERROR" "Failed to remove VMHide from OpenCore" "$vm_name"
                rm -rf "$work_dir"; return 1; }
            mdeltree -i "$drive" ::/EFI/OC/Kexts/VMHide.kext >/dev/null 2>&1 || true
            if mtype -i "$drive" ::/EFI/OC/Kexts/VMHide.kext/Contents/Info.plist >/dev/null 2>&1; then
                log_message "ERROR" "EFI validation found VMHide after removal" "$vm_name"
                rm -rf "$work_dir"; return 1
            fi
            ;;
        *)
            log_message "ERROR" "Unknown OpenCore mutation: $action" "$vm_name"
            rm -rf "$work_dir"; return 1
            ;;
    esac

    if ! mcopy -o -i "$drive" "$plist" ::/EFI/OC/config.plist ||
       ! macos_efi_commit_raw "$vm_name" "$raw" "$image" "$work_dir"; then
        log_message "ERROR" "OpenCore change was not committed; the previous image remains intact" "$vm_name"
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
}

macos_validate_archive_layout() {
    local archive="$1" bundle="$2" executable="$3"
    local list entry
    list=$(unzip -Z1 "$archive") || return 1
    while IFS= read -r entry; do
        [[ -z "$entry" || "$entry" == /* || "$entry" == *"../"* || "$entry" == ".." ]] && return 1
    done <<< "$list"
    [[ "$list" == *"${bundle}/Contents/Info.plist"* && "$list" == *"${bundle}/Contents/MacOS/${executable}"* ]]
}

macos_release_asset() {
    local api="$1" prefix="$2" metadata="$3"
    local -n _url_ref="$4" _digest_ref="$5" _version_ref="$6"
    local parsed="$metadata.parsed" resolved_url resolved_digest resolved_version
    curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
        "$api" -o "$metadata" || return 1
    if ! python3 - "$metadata" "$prefix" > "$parsed" <<'PY'
import json
import sys

path, prefix = sys.argv[1:]
with open(path, encoding="utf-8") as handle:
    release = json.load(handle)
assets = release.get("assets", [])
matches = [asset for asset in assets
           if asset.get("name", "").startswith(prefix)
           and asset.get("name", "").endswith("-RELEASE.zip")]
if len(matches) != 1:
    raise SystemExit("expected exactly one release archive")
asset = matches[0]
digest = asset.get("digest", "")
if not isinstance(digest, str) or not digest.startswith("sha256:"):
    raise SystemExit("release archive does not provide a SHA-256 digest")
print(asset["browser_download_url"])
print(digest.split(":", 1)[1].lower())
print(release.get("tag_name", "unknown"))
PY
    then
        return 1
    fi
    {
        IFS= read -r resolved_url
        IFS= read -r resolved_digest
        IFS= read -r resolved_version
    } < "$parsed"
    [[ "$resolved_url" == https://* && "$resolved_digest" =~ ^[a-f0-9]{64}$ && -n "$resolved_version" ]] || return 1
    _url_ref="$resolved_url"
    _digest_ref="$resolved_digest"
    _version_ref="$resolved_version"
}

macos_download_release_archive() {
    local api="$1" prefix="$2" destination="$3" metadata_dir="$4"
    local -n _version_ref="$5"
    local metadata="$metadata_dir/${prefix}release.json" url digest version actual
    macos_release_asset "$api" "$prefix" "$metadata" url digest version || {
        log_message "ERROR" "Could not resolve a verified ${prefix} release archive"
        return 1
    }
    curl --fail --location --silent --show-error --retry 2 --proto '=https' --proto-redir '=https' \
        "$url" -o "$destination" || {
        log_message "ERROR" "Failed to download ${prefix}${version}"
        return 1
    }
    actual=$(sha256sum "$destination" | awk '{print tolower($1)}')
    [[ "$actual" == "$digest" ]] || {
        log_message "ERROR" "SHA-256 mismatch for ${prefix}${version}; refusing the archive"
        return 1
    }
    _version_ref="$version"
}

macos_extract_release_kext() {
    local archive="$1" bundle="$2" executable="$3" destination="$4"
    macos_validate_archive_layout "$archive" "$bundle" "$executable" || return 1
    unzip -qq "$archive" "${bundle}/*" -d "$destination" || return 1
    [[ -f "$destination/$bundle/Contents/MacOS/$executable" ]] || return 1
    file -b "$destination/$bundle/Contents/MacOS/$executable" | grep -qi 'x86_64'
}

macos_validate_vmhide_kext_metadata() {
    local stage_dir="$1"
    python3 - "$stage_dir/Lilu.kext/Contents/Info.plist" "$stage_dir/VMHide.kext/Contents/Info.plist" <<'PY'
import plistlib
import re
import sys

lilu_path, vmhide_path = sys.argv[1:]
with open(lilu_path, "rb") as handle:
    lilu = plistlib.load(handle)
with open(vmhide_path, "rb") as handle:
    vmhide = plistlib.load(handle)

def version_tuple(value):
    parts = re.findall(r"\d+", str(value))
    if not parts:
        raise SystemExit("invalid Lilu version")
    return tuple(int(part) for part in (parts + ["0", "0"])[:3])

if version_tuple(lilu.get("CFBundleShortVersionString", "")) < (1, 7, 0):
    raise SystemExit("VMHide requires Lilu 1.7.0 or newer")
libraries = vmhide.get("OSBundleLibraries", {})
if "as.vit9696.Lilu" not in libraries:
    raise SystemExit("VMHide kext does not declare its Lilu dependency")
PY
}

macos_boot_configure() {
    local vm_name="$1"; shift
    local resolution="$MACOS_DEFAULT_RESOLUTION" timeout="$MACOS_DEFAULT_BOOT_TIMEOUT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --resolution) [[ $# -ge 2 ]] || { log_message "ERROR" "--resolution requires WIDTHxHEIGHT"; return 1; }; resolution="$2"; shift 2 ;;
            --timeout) [[ $# -ge 2 ]] || { log_message "ERROR" "--timeout requires seconds"; return 1; }; timeout="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    [[ "$resolution" =~ ^[1-9][0-9]{2,4}x[1-9][0-9]{2,4}$ ]] || {
        log_message "ERROR" "Invalid resolution '$resolution' (use WIDTHxHEIGHT, e.g. 1920x1080)" "$vm_name"; return 1; }
    [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -le 60 ]] || {
        log_message "ERROR" "Invalid timeout '$timeout' (must be 0-60 seconds)" "$vm_name"; return 1; }
    require_vm "$vm_name" exists unlocked not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }
    [[ "${VM[MACOS_INSTALL_MEDIA]:-0}" == "0" ]] || {
        log_message "ERROR" "Detach installer media with macos-eject before configuring normal macOS boot" "$vm_name"; return 1; }
    local fd
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    local result
    if macos_mutate_opencore_locked "$vm_name" boot-normal "$resolution" "$timeout"; then
        result=0
    else
        result=$?
    fi
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
    [[ "$result" -eq 0 ]] && log_message "INFO" "macOS boot configured: ${resolution}, picker timeout ${timeout}s." "$vm_name"
    return "$result"
}

macos_verbose_configure() {
    local vm_name="${1:-}" mode="${2:-}"
    [[ $# -eq 2 && ( "$mode" == "on" || "$mode" == "off" ) ]] || {
        log_message "ERROR" "Usage: macos-verbose <name> on|off"; return 1; }
    require_vm "$vm_name" exists unlocked not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }

    local fd result
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    if macos_mutate_opencore_locked "$vm_name" "verbose-$mode"; then
        result=0
    else
        result=$?
    fi
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
    [[ "$result" -eq 0 ]] && log_message "INFO" "Verbose macOS boot ${mode}." "$vm_name"
    return "$result"
}

macos_set_recovery_boot_locked() {
    local vm_name="$1"
    macos_mutate_opencore_locked "$vm_name" boot-recovery "$MACOS_DEFAULT_RESOLUTION" "$MACOS_DEFAULT_BOOT_TIMEOUT"
}

macos_vmhide() {
    local vm_name="$1" action="${2:-}"
    [[ -n "$action" && $# -eq 2 ]] || {
        log_message "ERROR" "Usage: macos-vmhide <name> install|remove|status"; return 1; }
    require_vm "$vm_name" exists || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }

    case "$action" in
        install)
            require_vm "$vm_name" unlocked not-running || return 1
            [[ "${VM[MACOS_INSTALL_MEDIA]:-0}" == "0" ]] || {
                log_message "ERROR" "Install VMHide only after macos-eject completes" "$vm_name"; return 1; }
            require_commands curl unzip sha256sum file || return 1
            macos_require_efi_tools || return 1
            local fd workspace lilu_version vmhide_version
            acquire_stopped_vm_lock "$vm_name" fd || return 1
            workspace=$(mktemp -d "$VM_DIR/$vm_name/macos/.vmhide.XXXXXX") || {
                release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
            chmod 700 "$workspace" 2>/dev/null || true
            if ! macos_download_release_archive "$LILU_RELEASE_API" "Lilu-" "$workspace/Lilu.zip" "$workspace" lilu_version ||
               ! macos_download_release_archive "$VMHIDE_RELEASE_API" "VMHide-" "$workspace/VMHide.zip" "$workspace" vmhide_version ||
               ! macos_extract_release_kext "$workspace/Lilu.zip" "Lilu.kext" "Lilu" "$workspace/kexts" ||
               ! macos_extract_release_kext "$workspace/VMHide.zip" "VMHide.kext" "VMHide" "$workspace/kexts" ||
               ! macos_validate_vmhide_kext_metadata "$workspace/kexts" ||
               ! macos_mutate_opencore_locked "$vm_name" vmhide-install "" "" "$workspace/kexts"; then
                rm -rf "$workspace"
                release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
                return 1
            fi
            printf 'VMHIDE_VERSION=%q\nLILU_VERSION=%q\n' "$vmhide_version" "$lilu_version" > "$VM_DIR/$vm_name/macos/vmhide.env"
            chmod 600 "$VM_DIR/$vm_name/macos/vmhide.env"
            rm -rf "$workspace"
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
            log_message "INFO" "VMHide ${vmhide_version} and Lilu ${lilu_version} installed. Restart the VM to load them." "$vm_name"
            ;;
        remove)
            require_vm "$vm_name" unlocked not-running || return 1
            macos_require_efi_tools || return 1
            local fd_remove
            acquire_stopped_vm_lock "$vm_name" fd_remove || return 1
            local result
            if macos_mutate_opencore_locked "$vm_name" vmhide-remove; then
                result=0
            else
                result=$?
            fi
            if [[ "$result" -eq 0 ]]; then
                rm -f "$VM_DIR/$vm_name/macos/vmhide.env"
            fi
            release_flock fd_remove "$VM_DIR/$vm_name/qemu.pid.lock"
            [[ "$result" -eq 0 ]] && log_message "INFO" "VMHide removed. Lilu was retained; restart the VM." "$vm_name"
            return "$result"
            ;;
        status)
            macos_vmhide_status "$vm_name"
            ;;
        *) log_message "ERROR" "Unknown VMHide action: $action (use install|remove|status)" "$vm_name"; return 1 ;;
    esac
}

macos_vmhide_status() {
    local vm_name="$1" image work_dir raw offset drive plist lilu_info vmhide_info
    macos_require_efi_tools || return 1
    macos_opencore_image "$vm_name" image || return 1
    work_dir=$(mktemp -d "$VM_DIR/$vm_name/macos/.vmhide-status.XXXXXX") || return 1
    chmod 700 "$work_dir" 2>/dev/null || true
    if ! macos_efi_prepare_raw "$vm_name" "$image" "$work_dir" raw offset; then
        rm -rf "$work_dir"; return 1
    fi
    drive=$(macos_efi_drive "$raw" "$offset")
    plist="$work_dir/config.plist"
    lilu_info="$work_dir/Lilu-Info.plist"
    vmhide_info="$work_dir/VMHide-Info.plist"
    mcopy -o -i "$drive" ::/EFI/OC/config.plist "$plist" || { rm -rf "$work_dir"; return 1; }
    mcopy -o -i "$drive" ::/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist "$lilu_info" 2>/dev/null || true
    mcopy -o -i "$drive" ::/EFI/OC/Kexts/VMHide.kext/Contents/Info.plist "$vmhide_info" 2>/dev/null || true
    if ! python3 - "$plist" "$lilu_info" "$vmhide_info" <<'PY'
import os
import plistlib
import sys

config_path, lilu_path, vmhide_path = sys.argv[1:]
with open(config_path, "rb") as handle:
    config = plistlib.load(handle)
entries = config.get("Kernel", {}).get("Add", [])
paths = [entry.get("BundlePath") for entry in entries if isinstance(entry, dict) and entry.get("Enabled")]
def version(path):
    if not os.path.isfile(path):
        return "missing"
    with open(path, "rb") as handle:
        return str(plistlib.load(handle).get("CFBundleShortVersionString", "unknown"))
lilu_ok = "Lilu.kext" in paths
vmhide_ok = "VMHide.kext" in paths
order_ok = lilu_ok and vmhide_ok and paths.index("Lilu.kext") < paths.index("VMHide.kext")
print(f"Lilu: {version(lilu_path)} ({'registered' if lilu_ok else 'not registered'})")
print(f"VMHide: {version(vmhide_path)} ({'registered' if vmhide_ok else 'not registered'})")
print(f"Load order: {'Lilu before VMHide' if order_ok else 'invalid or incomplete'}")
PY
    then
        rm -rf "$work_dir"
        return 1
    fi
    rm -rf "$work_dir"
}

macos_efi_restore() {
    local vm_name="$1" backup_name="$2"
    [[ "$backup_name" =~ ^OpenCore\.[A-Za-z0-9_-]+\.[0-9]{8}T[0-9]{6}Z(\.[0-9]+)?\.qcow2$ ]] || {
        log_message "ERROR" "Backup name must be a file listed in macos/backups" "$vm_name"; return 1; }
    require_vm "$vm_name" exists unlocked not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }
    local backup="$VM_DIR/$vm_name/macos/backups/$backup_name" image fd candidate
    [[ -f "$backup" ]] || { log_message "ERROR" "OpenCore backup not found: $backup_name" "$vm_name"; return 1; }
    qemu-img check -q "$backup" >/dev/null || { log_message "ERROR" "Backup image is invalid: $backup_name" "$vm_name"; return 1; }
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    macos_private_opencore_image "$vm_name" image || { release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    candidate="$image.restore.${BASHPID}"
    cp --reflink=auto --preserve=mode "$backup" "$candidate" && mv -f "$candidate" "$image" || {
        rm -f "$candidate"
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        log_message "ERROR" "Failed to restore OpenCore backup" "$vm_name"
        return 1
    }
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
    log_message "INFO" "Restored OpenCore backup: $backup_name" "$vm_name"
}

configure_macos_guest_agent() {
    local vm_name="$1"
    local -n _mga_vm="$2"
    local -n _mga_cmd="$3"

    [[ "${_mga_vm[MACOS_GUEST_AGENT]:-1}" == "1" ]] || return 0

    local socket="$VM_DIR/$vm_name/sockets/mac-guest-agent.sock"

    _mga_cmd+=(
        "-chardev" "socket,id=macagent,path=${socket},server=on,wait=off"
        "-device" "isa-serial,chardev=macagent"
    )

    log_message "INFO"         "macOS Guest Agent: ISA serial → $socket"         "$vm_name"
}

install_macos() {
    local vm_name="$1"; shift
    local version="" no_start="0" refresh="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version) [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--version requires a value"; return 1; }; version="$2"; shift 2 ;;
            --no-start) no_start="1"; shift ;;
            --refresh) refresh="1"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ -z "$version" ]]; then
        macos_choose_version version || return 1
    fi

    macos_version_supported "$version" || {
        log_message "ERROR" "Unsupported macOS version: '$version'. Use: high-sierra, mojave, catalina, big-sur, monterey, ventura, sonoma, sequoia, tahoe"; return 1; }
    require_qemu_toolchain || return 1
    require_vm "$vm_name" exists unlocked not-running || return 1

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || {
        log_message "ERROR" "VM '$vm_name' is not a macOS VM. Create it with --os-type macos." "$vm_name"; return 1; }

    require_commands git python3 dmg2img || return 1
    local fd
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    if ! macos_prepare_repo "$vm_name"; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
    fi
    local repo="$VM_DIR/$vm_name/macos/OSX-KVM"
    if [[ "$refresh" == "1" ]]; then
        git -C "$repo" fetch --depth 1 --prune origin master && git -C "$repo" reset --hard FETCH_HEAD || {
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    fi

    local requested_image="$repo/BaseSystem.img"
    if [[ ! -f "$requested_image" || "${VM[MACOS_VERSION]:-}" != "$version" ]]; then
        log_message "INFO" "Downloading macOS $version recovery image from Apple via OSX-KVM..." "$vm_name"
        rm -f "$repo"/BaseSystem.dmg "$repo"/BaseSystem.img "$repo"/*.chunklist
        if ! (macos_download_recovery "$repo" "$version" && [[ -f "$repo/BaseSystem.dmg" ]] && dmg2img -i "$repo/BaseSystem.dmg" "$repo/BaseSystem.img"); then
            log_message "ERROR" "Failed to download or convert the macOS recovery image" "$vm_name"
            release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
        fi
        chmod 600 "$repo/BaseSystem.img" 2>/dev/null || true
    fi

    VM[MACOS_VERSION]="$version"
    VM[MACOS_INSTALL_MEDIA]=1
    VM[ENABLE_UEFI]=1
    VM[DISK_INTERFACE]="sata"
    VM[VIDEO_TYPE]="vmware"
    if [[ "$version" == "high-sierra" ]]; then
        VM[NETWORK_MODEL]="vmxnet3"
    else
        VM[NETWORK_MODEL]="virtio-net-pci"
    fi
    VM[ENABLE_VIRTIO]=1
    save_vm_config "$vm_name" VM || { release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1; }
    local commit; commit=$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)
    printf '%s\n' "$version" > "$VM_DIR/$vm_name/macos/version"
    printf '%s\n' "$commit" > "$VM_DIR/$vm_name/macos/osx-kvm-commit"
    chmod 600 "$VM_DIR/$vm_name/macos/version" "$VM_DIR/$vm_name/macos/osx-kvm-commit"
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"

    log_message "INFO" "macOS $version installer prepared (OSX-KVM $commit) for '$vm_name'." "$vm_name"
    if [[ "$no_start" == "1" ]]; then
        log_message "INFO" "Installer media attached. Start manually with: qemate start $vm_name" "$vm_name"
        return 0
    fi
    start "$vm_name"
}

macos_finalize_install() {
    local vm_name="$1"
    require_vm "$vm_name" exists unlocked not-running || return 1
    macos_require_efi_tools || return 1
    local fd
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    local -A VM=()
    if ! load_vm_config "$vm_name" VM; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
    fi
    if [[ "${VM[OS_TYPE]:-}" != "macos" ]]; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1
    fi
    if [[ "${VM[MACOS_INSTALL_MEDIA]:-0}" != "1" ]]; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        log_message "INFO" "macOS installer media is already detached." "$vm_name"; return 0
    fi
    # After a successful install the recovery image and the full OSX-KVM git
    # checkout are no longer required for normal boots. Keep only the permanent
    # OpenCore + 4 MiB OVMF assets under macos/assets/, then drop the temporary
    # clone and download artefacts. macos-recovery will re-prepare media if needed.
    local macos_dir="$VM_DIR/$vm_name/macos"
    local repo="$macos_dir/OSX-KVM"
    if [[ -d "$repo" ]]; then
        mkdir -p "$macos_dir/assets"
        [[ -f "$repo/OpenCore/OpenCore.qcow2" ]] && cp -n "$repo/OpenCore/OpenCore.qcow2" "$macos_dir/assets/OpenCore.qcow2" 2>/dev/null || true
        [[ -f "$repo/OVMF_CODE_4M.fd" ]] && cp -n "$repo/OVMF_CODE_4M.fd" "$macos_dir/assets/OVMF_CODE_4M.fd" 2>/dev/null || true
        [[ -f "$repo/OVMF_VARS-1920x1080.fd" ]] && cp -n "$repo/OVMF_VARS-1920x1080.fd" "$macos_dir/assets/OVMF_VARS-1920x1080.fd" 2>/dev/null || true
        chmod 600 "$macos_dir/assets"/* 2>/dev/null || true
    fi

    # Configure the now-private OpenCore image before detaching recovery.  This
    # keeps EFI entries out of the normal picker while preserving the recovery
    # profile that macos-recovery can restore later.
    if ! macos_mutate_opencore_locked "$vm_name" boot-normal "$MACOS_DEFAULT_RESOLUTION" "$MACOS_DEFAULT_BOOT_TIMEOUT"; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        return 1
    fi

    VM[MACOS_INSTALL_MEDIA]=0
    if ! save_vm_config "$vm_name" VM; then
        # A failed state save must not strand the still-attached installer
        # behind the normal boot scan policy.
        macos_set_recovery_boot_locked "$vm_name" || true
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
        return 1
    fi

    if [[ -d "$repo" ]]; then
        rm -rf "$repo"
        log_message "INFO" "Removed temporary OSX-KVM checkout and recovery download artifacts." "$vm_name"
    fi
    rm -f "$macos_dir"/BaseSystem.img "$macos_dir"/BaseSystem.dmg "$macos_dir"/*.chunklist 2>/dev/null || true

    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
    log_message "INFO" "macOS installer media detached. The VM will auto-boot the installed disk through OpenCore after ${MACOS_DEFAULT_BOOT_TIMEOUT}s." "$vm_name"
}

macos_recovery_attach() {
    local vm_name="$1"
    require_vm "$vm_name" exists unlocked not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }
    macos_require_efi_tools || return 1
    local base="$VM_DIR/$vm_name/macos/OSX-KVM/BaseSystem.img"
    if [[ ! -f "$base" ]]; then
        log_message "INFO" "Recovery media was cleaned up after install. Re-preparing via macos-install..." "$vm_name"
        # install_macos takes the stopped-VM lock itself.
        install_macos "$vm_name" --version "${VM[MACOS_VERSION]:-sonoma}" --no-start || return 1
        base="$VM_DIR/$vm_name/macos/OSX-KVM/BaseSystem.img"
        [[ -f "$base" ]] || { log_message "ERROR" "Failed to restore recovery media." "$vm_name"; return 1; }
        # The re-prepared installer has a permissive upstream configuration;
        # explicitly restore it in case this VM previously used managed boot.
        local reprepare_fd
        acquire_stopped_vm_lock "$vm_name" reprepare_fd || return 1
        if ! macos_set_recovery_boot_locked "$vm_name"; then
            release_flock reprepare_fd "$VM_DIR/$vm_name/qemu.pid.lock"
            return 1
        fi
        release_flock reprepare_fd "$VM_DIR/$vm_name/qemu.pid.lock"
        log_message "INFO" "macOS recovery media attached and OpenCore recovery scanning restored." "$vm_name"
        return 0
    fi
    # Assigned indirectly by acquire_stopped_vm_lock through a nameref.
    # shellcheck disable=SC2034
    local fd
    acquire_stopped_vm_lock "$vm_name" fd || return 1
    if ! load_vm_config "$vm_name" VM; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
    fi
    if ! macos_set_recovery_boot_locked "$vm_name"; then
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
    fi
    VM[MACOS_INSTALL_MEDIA]=1
    save_vm_config "$vm_name" VM || {
        # The VM was previously in normal boot mode, so restore that profile if
        # the config state cannot be made durable.
        macos_mutate_opencore_locked "$vm_name" boot-normal "$MACOS_DEFAULT_RESOLUTION" "$MACOS_DEFAULT_BOOT_TIMEOUT" || true
        release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"; return 1
    }
    release_flock fd "$VM_DIR/$vm_name/qemu.pid.lock"
    log_message "INFO" "macOS recovery media attached and OpenCore recovery scanning restored." "$vm_name"
}

macos_doctor() {
    local vm_name="$1"
    require_qemu_toolchain || return 1
    require_vm "$vm_name" exists || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "${VM[OS_TYPE]:-}" == "macos" ]] || { log_message "ERROR" "VM is not macOS: $vm_name" "$vm_name"; return 1; }
    local macos_dir="$VM_DIR/$vm_name/macos"
    local repo="$macos_dir/OSX-KVM"
    local assets="$macos_dir/assets"
    local failures=0
    # Boot assets may live in the permanent assets/ dir (post-eject) or the live checkout.
    if [[ -f "$assets/OpenCore.qcow2" ]]; then
        log_message "INFO" "OK: assets/OpenCore.qcow2" "$vm_name"
    elif [[ -f "$repo/OpenCore/OpenCore.qcow2" ]]; then
        log_message "INFO" "OK: OSX-KVM/OpenCore/OpenCore.qcow2" "$vm_name"
    else
        log_message "ERROR" "Missing: OpenCore.qcow2" "$vm_name"; failures=1
    fi
    if [[ -f "$assets/OVMF_CODE_4M.fd" ]]; then
        log_message "INFO" "OK: assets/OVMF_CODE_4M.fd" "$vm_name"
    elif [[ -f "$repo/OVMF_CODE_4M.fd" ]]; then
        log_message "INFO" "OK: OSX-KVM/OVMF_CODE_4M.fd" "$vm_name"
    else
        log_message "ERROR" "Missing: OVMF_CODE_4M.fd" "$vm_name"; failures=1
    fi
    if [[ -f "$assets/OVMF_VARS-1920x1080.fd" ]]; then
        log_message "INFO" "OK: assets/OVMF_VARS-1920x1080.fd" "$vm_name"
    elif [[ -f "$repo/OVMF_VARS-1920x1080.fd" ]]; then
        log_message "INFO" "OK: OSX-KVM/OVMF_VARS-1920x1080.fd" "$vm_name"
    else
        log_message "ERROR" "Missing: OVMF_VARS-1920x1080.fd" "$vm_name"; failures=1
    fi
    if [[ -d "$repo/.git" ]]; then
        [[ -f "$repo/fetch-macOS-v2.py" ]] && log_message "INFO" "OK: fetch-macOS-v2.py (checkout present)" "$vm_name" || log_message "WARNING" "Missing: fetch-macOS-v2.py" "$vm_name"
    else
        log_message "INFO" "OSX-KVM checkout removed after install (recovery media cleaned up)." "$vm_name"
    fi
    if [[ -r /sys/module/kvm/parameters/ignore_msrs ]]; then
        local v; v=$(< /sys/module/kvm/parameters/ignore_msrs)
        if [[ "$v" == "Y" || "$v" == "1" ]]; then
            log_message "INFO" "OK: KVM ignore_msrs=$v" "$vm_name"
        else
            log_message "ERROR" "KVM ignore_msrs=$v. If kvm is already loaded, 'sudo modprobe kvm ignore_msrs=1' may be a no-op. Use: sudo sh -c 'echo 1 > /sys/module/kvm/parameters/ignore_msrs' (or unload/reload KVM with ignore_msrs=1)." "$vm_name"
            failures=1
        fi
    else
        log_message "ERROR" "Cannot inspect KVM ignore_msrs on this host; macOS requires ignore_msrs=1 per OSX-KVM." "$vm_name"
        failures=1
    fi
    if command -v lscpu >/dev/null 2>&1; then
        local flags; flags=$(lscpu 2>/dev/null | awk -F: '/^Flags/ {gsub(/^[[:space:]]+/,"",$2); print $2}')
        for f in avx avx2 f16c rdrand; do
            [[ " $flags " == *" $f "* ]] || log_message "WARNING" "Host CPU is missing $f; current OpenCore/VMware guidance lists it as required for modern Intel/AMD configurations." "$vm_name"
        done
    fi
    local qdevs; qdevs=$(qemu-system-x86_64 -device help 2>/dev/null || true)
    [[ "$qdevs" == *"isa-applesmc"* ]] || { log_message "ERROR" "QEMU lacks isa-applesmc device support." "$vm_name"; failures=1; }
    [[ "$qdevs" == *"vmware-svga"* ]] || { log_message "ERROR" "QEMU lacks vmware-svga device support." "$vm_name"; failures=1; }
    [[ "$qdevs" == *"qemu-xhci"* ]] || { log_message "ERROR" "QEMU lacks qemu-xhci device support." "$vm_name"; failures=1; }

    if command -v mcopy >/dev/null 2>&1 && command -v mmd >/dev/null 2>&1 &&
       command -v mdeltree >/dev/null 2>&1 && command -v mtype >/dev/null 2>&1; then
        log_message "INFO" "OK: mtools available for managed OpenCore EFI changes" "$vm_name"
    else
        log_message "WARNING" "mtools is missing; macos-eject, macos-recovery, macos-boot, and macos-verbose cannot manage the OpenCore EFI" "$vm_name"
    fi
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1 &&
       command -v file >/dev/null 2>&1 && command -v sha256sum >/dev/null 2>&1; then
        log_message "INFO" "VMHide release-verification tools are available" "$vm_name"
    else
        log_message "INFO" "VMHide installation also needs curl, unzip, file, and sha256sum" "$vm_name"
    fi

    if [[ "${VM[MACOS_GUEST_AGENT]:-1}" == "1" ]]; then
        [[ "$qdevs" == *"isa-serial"* ]] || {
            log_message "ERROR"                 "QEMU lacks isa-serial device support required by mac-guest-agent."                 "$vm_name"
            failures=1
        }

        local agent_socket="$VM_DIR/$vm_name/sockets/mac-guest-agent.sock"
        if vm_is_running "$vm_name"; then
            [[ -S "$agent_socket" ]] &&                 log_message "INFO"                     "macOS Guest Agent transport socket is present: $agent_socket"                     "$vm_name" ||                 log_message "WARNING"                     "macOS Guest Agent transport socket is not present: $agent_socket"                     "$vm_name"
        else
            log_message "INFO"                 "macOS Guest Agent enabled; socket will be created at start: $agent_socket"                 "$vm_name"
        fi
    else
        log_message "INFO" "macOS Guest Agent disabled" "$vm_name"
    fi

    macos_repo_info "$vm_name" || true
    log_message "INFO" "installer-media=${VM[MACOS_INSTALL_MEDIA]:-0}, version=${VM[MACOS_VERSION]:-unknown}" "$vm_name"
    return "$failures"
}

configure_macos() {
    local vm_name="$1"
    local -n _mac_vm="$2"
    local -n _mac_cmd="$3"
    local dry_run="${4:-0}"
    local macos_dir="$VM_DIR/$vm_name/macos"
    local repo="$macos_dir/OSX-KVM"
    local assets="$macos_dir/assets"
    # Prefer permanent assets (copied on eject); fall back to the live OSX-KVM checkout.
    local base=""
    if [[ -f "$repo/BaseSystem.img" ]]; then
        base="$repo/BaseSystem.img"
    elif [[ -f "$macos_dir/BaseSystem.img" ]]; then
        base="$macos_dir/BaseSystem.img"
    fi
    local opencore=""
    if [[ -f "$assets/OpenCore.qcow2" ]]; then
        opencore="$assets/OpenCore.qcow2"
    elif [[ -f "$repo/OpenCore/OpenCore.qcow2" ]]; then
        opencore="$repo/OpenCore/OpenCore.qcow2"
    fi
    local ovmf_code=""
    if [[ -f "$assets/OVMF_CODE_4M.fd" ]]; then
        ovmf_code="$assets/OVMF_CODE_4M.fd"
    elif [[ -f "$repo/OVMF_CODE_4M.fd" ]]; then
        ovmf_code="$repo/OVMF_CODE_4M.fd"
    fi
    local ovmf_vars=""
    if [[ -f "$assets/OVMF_VARS-1920x1080.fd" ]]; then
        ovmf_vars="$assets/OVMF_VARS-1920x1080.fd"
    elif [[ -f "$repo/OVMF_VARS-1920x1080.fd" ]]; then
        ovmf_vars="$repo/OVMF_VARS-1920x1080.fd"
    fi

    if [[ "${_mac_vm[MACOS_INSTALL_MEDIA]:-0}" == "1" ]]; then
        [[ -n "$base" && -f "$base" ]] || { log_message "ERROR" "macOS recovery media is missing. Run: qemate macos-install $vm_name --version <version>" "$vm_name"; return 1; }
    fi
    [[ -n "$opencore" && -f "$opencore" ]] || { log_message "ERROR" "OpenCore image is missing (run macos-install or macos-refresh)" "$vm_name"; return 1; }
    [[ -n "$ovmf_code" && -f "$ovmf_code" && -n "$ovmf_vars" && -f "$ovmf_vars" ]] || { log_message "ERROR" "4M OVMF firmware is missing (run macos-install or macos-refresh)" "$vm_name"; return 1; }

    local version="${_mac_vm[MACOS_VERSION]:-sonoma}"
    macos_version_supported "$version" || { log_message "ERROR" "Invalid macOS version: $version" "$vm_name"; return 1; }
    local cpu_model; cpu_model=$(macos_cpu_model "$version")
    _mac_cmd+=(
        "-drive" "if=pflash,format=raw,readonly=on,file=${ovmf_code}"
        "-drive" "if=pflash,format=raw,file=${VM_DIR}/${vm_name}/OVMF_VARS-macos.fd"
        "-device" "isa-applesmc,osk=ourhardworkbythesewordsguardedpleasedontsteal(c)AppleComputerInc"
        "-smbios" "type=2"
        "-device" "ich9-intel-hda"
        "-device" "hda-duplex"
        "-device" "ich9-ahci,id=sata"
        "-drive" "id=OpenCoreBoot,if=none,snapshot=on,format=qcow2,file=${opencore}"
        "-device" "ide-hd,bus=sata.2,drive=OpenCoreBoot"
        "-cpu" "$cpu_model"
        "-rtc" "base=utc,clock=host,driftfix=slew"
        "-global" "ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off"
        "-device" "qemu-xhci,id=xhci"
        "-device" "usb-kbd,bus=xhci.0"
        "-device" "usb-tablet,bus=xhci.0"
        "-device" "usb-ehci,id=ehci"
    )
    if [[ "${_mac_vm[MACOS_INSTALL_MEDIA]:-0}" == "1" ]]; then
        _mac_cmd+=(
            "-drive" "id=InstallMedia,if=none,file=${base},format=raw"
            "-device" "ide-hd,bus=sata.3,drive=InstallMedia"
        )
    fi
    if [[ "$dry_run" != "1" && ! -f "$VM_DIR/$vm_name/OVMF_VARS-macos.fd" ]]; then
        cp "$ovmf_vars" "$VM_DIR/$vm_name/OVMF_VARS-macos.fd" || {
            log_message "ERROR" "Failed to initialise macOS UEFI variables" "$vm_name"; return 1; }
        chmod 600 "$VM_DIR/$vm_name/OVMF_VARS-macos.fd"
    fi
}

# =============================================================================
# TPM 2.0 UTILS
# =============================================================================

stop_tpm() {
    local vm_name="$1"
    validate_vm_name "$vm_name" >/dev/null 2>&1 || return 1
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"
    [[ -f "$tpm_pid" ]] || return 0
    local pid
    pid="$(< "$tpm_pid")"
    if pid_cmdline_contains "$pid" "path=$VM_DIR/$vm_name/sockets/swtpm.sock"; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$tpm_pid"
}

# =============================================================================
# QEMU COMMAND BUILDERS
# =============================================================================

configure_cpu() {
    local -n _cpu_vm="$1"
    local -n _cpu_cmd="$2"
    local cpu_type="${_cpu_vm[CPU_TYPE]}"
    if [[ "${_cpu_vm[MACHINE_OPTIONS]:-accel=kvm}" == "accel=tcg" && "$cpu_type" == "host" ]]; then
        cpu_type="max"
    fi

    if [[ "${_cpu_vm[OS_TYPE]:-linux}" == "windows" ]]; then
        local smp_topology
        if (( _cpu_vm[CORES] >= 2 && _cpu_vm[CORES] % 2 == 0 )); then
            smp_topology="${_cpu_vm[CORES]},cores=$(( _cpu_vm[CORES] / 2 )),threads=2,sockets=1"
        else
            smp_topology="${_cpu_vm[CORES]},cores=${_cpu_vm[CORES]},threads=1,sockets=1"
        fi

        local hv_flags="hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-time"
        hv_flags+=",hv-vpindex,hv-synic,hv-stimer,hv-stimer-direct,hv-reset"
        hv_flags+=",hv-frequencies,hv-runtime,hv-tlbflush,hv-ipi"
        hv_flags+=",l3-cache=on,+topoext"
        [[ "${_cpu_vm[HIDE_KVM]:-0}" == "1" ]] && hv_flags+=",kvm=off"
        if [[ "${_cpu_vm[PERFORMANCE_PROFILE]:-balanced}" == "performance" &&
              -r /sys/module/kvm_amd/parameters/avic &&
              "$(< /sys/module/kvm_amd/parameters/avic)" == "Y" ]]; then
            hv_flags+=",hv-avic"
        fi

        _cpu_cmd+=(
            "-smp"    "$smp_topology"
            "-cpu"    "${cpu_type},${hv_flags}"
            "-global" "kvm-pit.lost_tick_policy=delay"
            "-rtc"    "base=localtime,clock=host,driftfix=slew"
            "-device" "virtio-rng-pci"
            "-device" "virtio-tablet-pci"
            "-device" "virtio-balloon-pci"
        )
    else
        _cpu_cmd+=(
            "-smp" "${_cpu_vm[CORES]},sockets=1,cores=${_cpu_vm[CORES]},threads=1"
            "-cpu" "$cpu_type"
        )
    fi
}

# Print a writable hugepage mount that has enough free pages for MEMORY, or empty.
hugepage_mount_for() {
    local memory="$1" requested_kib hugepage_kib=0 hugepage_free=0 key value unit
    requested_kib=$(size_to_mib "$memory") || return 1
    requested_kib=$(( requested_kib * 1024 ))

    if [[ -r /proc/meminfo ]]; then
        while read -r key value unit; do
            case "$key" in
                Hugepagesize:) hugepage_kib="$value" ;;
                HugePages_Free:) hugepage_free="$value" ;;
            esac
        done < /proc/meminfo
    fi

    if [[ -d /dev/hugepages && -w /dev/hugepages && "$hugepage_kib" -gt 0 ]]; then
        if (( hugepage_free * hugepage_kib >= requested_kib )); then
            printf '%s' /dev/hugepages
            return 0
        fi
    fi
    # 1G mount is a separate pool; only use it when the VM size is a multiple of 1G
    # and the mount has enough pages. HugePages_* in meminfo is the default (usually 2M) pool.
    if [[ -d /dev/hugepages-1G && -w /dev/hugepages-1G ]]; then
        local one_g_free=0
        local one_g_free_file=/sys/kernel/mm/hugepages/hugepages-1048576kB/free_hugepages
        [[ -r "$one_g_free_file" ]] && one_g_free=$(< "$one_g_free_file")
        if [[ "$one_g_free" =~ ^[0-9]+$ ]] && (( requested_kib % 1048576 == 0 && one_g_free * 1048576 >= requested_kib )); then
            printf '%s' /dev/hugepages-1G
            return 0
        fi
    fi
    return 1
}

configure_memory() {
    local -n _mem_vm="$1"
    local -n _mem_cmd="$2"

    _mem_cmd+=("-m" "${_mem_vm[MEMORY]}")
    local profile="${_mem_vm[PERFORMANCE_PROFILE]:-balanced}"
    local prealloc="${_mem_vm[MEMORY_PREALLOC]:-0}"
    local share="${_mem_vm[MEMORY_SHARE]:-0}"
    [[ "$profile" == "performance" ]] && prealloc=1

    local hugepage_path=""
    if [[ "$profile" == "performance" && ( "$prealloc" == "1" || "$share" == "1" ) ]]; then
        hugepage_path=$(hugepage_mount_for "${_mem_vm[MEMORY]}") || hugepage_path=""
        if [[ -z "$hugepage_path" ]]; then
            local hp_total=0
            if [[ -r /proc/meminfo ]]; then
                hp_total=$(awk '/^HugePages_Total:/ {print $2}' /proc/meminfo)
            fi
            if [[ "$hp_total" =~ ^[1-9] ]]; then
                log_message "WARNING" "Hugepage pool is too small for ${_mem_vm[MEMORY]}; using anonymous/memfd memory instead." "${_mem_vm[NAME]:-}"
            fi
        fi
    fi

    if [[ -n "$hugepage_path" ]]; then
        _mem_cmd+=(
            "-object" "memory-backend-file,id=mem0,size=${_mem_vm[MEMORY]},mem-path=${hugepage_path},share=on,prealloc=on"
            "-numa"   "node,memdev=mem0"
        )
    elif [[ "$share" == "1" ]]; then
        local memfd_opts="memory-backend-memfd,id=mem0,size=${_mem_vm[MEMORY]},share=on"
        [[ "$prealloc" == "1" ]] && memfd_opts+=",prealloc=on"
        _mem_cmd+=(
            "-object" "$memfd_opts"
            "-numa"   "node,memdev=mem0"
        )
    elif [[ "$prealloc" == "1" ]]; then
        _mem_cmd+=(
            "-object" "memory-backend-ram,id=mem0,size=${_mem_vm[MEMORY]},prealloc=on"
            "-numa"   "node,memdev=mem0"
        )
    fi
    [[ "$profile" == "performance" ]] && _mem_cmd+=("-overcommit" "mem-lock=on")
    return 0
}

configure_disk() {
    local vm_name="$1"
    local -n _dsk_vm="$2"
    local -n _dsk_cmd="$3"

    local disk_file drive_opts
    if [[ -n "${_dsk_vm[DISK_DEV]:-}" ]]; then
        disk_file="${_dsk_vm[DISK_DEV]}"
        [[ ! -b "$disk_file" ]] && {
            log_message "ERROR" "Physical disk device not found: $disk_file" "$vm_name"; return 1; }
        [[ ! -r "$disk_file" || ! -w "$disk_file" ]] && {
            log_message "ERROR" "No read/write access to $disk_file. Add yourself to the 'disk' group: sudo usermod -aG disk $USER" "$vm_name"; return 1; }
        # Physical block device: O_DIRECT (cache=none) is required to bypass
        # the host page cache and avoid double-buffering with the drive's own
        # hardware cache. writeback is only safe for qcow2 image files.
        if [[ "${_dsk_vm[DISK_CACHE]}" != "none" ]]; then
            log_message "WARNING" "DISK_CACHE='${_dsk_vm[DISK_CACHE]}' is not recommended for physical disks — forcing cache=none." "$vm_name"
        fi
        # discard=unmap passes TRIM from the guest directly to the SSD.
        # The host cannot TRIM a disk whose filesystem it does not manage,
        # so the guest must be the one to send TRIM commands.
        # detect-zeroes=unmap converts zero-fill writes into TRIM operations.
        drive_opts="format=raw,cache=none,aio=${_dsk_vm[DISK_IO]},discard=unmap,detect-zeroes=unmap"
        log_message "INFO" "Disk: physical device $disk_file (raw, cache=none, TRIM passthrough)" "$vm_name"
    else
        disk_file="$VM_DIR/$vm_name/disk.qcow2"
        drive_opts="format=qcow2,cache=${_dsk_vm[DISK_CACHE]},aio=${_dsk_vm[DISK_IO]},discard=${_dsk_vm[DISK_DISCARD]}"
    fi

    case "${_dsk_vm[DISK_INTERFACE]}" in
        virtio)
            local queues="${_dsk_vm[CORES]}"
            (( queues > 8 )) && queues=8
            local iothread_count=1 i thread mapping="" vqs="" comma=""
            if [[ "${_dsk_vm[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
                iothread_count="$queues"
                (( iothread_count > 4 )) && iothread_count=4
            fi
            for (( i=0; i<iothread_count; i++ )); do
                _dsk_cmd+=("-object" "iothread,id=iothread${i}")
            done

            local virtio_dev_json
            if (( iothread_count == 1 )); then
                virtio_dev_json="{\"driver\":\"virtio-blk-pci\",\"drive\":\"drive0\",\"iothread\":\"iothread0\",\"num-queues\":${queues},\"packed\":true,\"in_order\":true"
            else
                mapping="["
                comma=""
                for (( thread=0; thread<iothread_count; thread++ )); do
                    vqs="["
                    local vq_comma=""
                    for (( i=thread; i<queues; i+=iothread_count )); do
                        vqs+="${vq_comma}${i}"
                        vq_comma=","
                    done
                    vqs+="]"
                    mapping+="${comma}{\"iothread\":\"iothread${thread}\",\"vqs\":${vqs}}"
                    comma=","
                done
                mapping+="]"
                virtio_dev_json="{\"driver\":\"virtio-blk-pci\",\"drive\":\"drive0\",\"num-queues\":${queues},\"packed\":true,\"in_order\":true,\"iothread-vq-mapping\":${mapping}"
            fi
            if [[ -n "${_dsk_vm[DISK_DEV]:-}" ]]; then
                # write-cache=on: the SSD has its own hardware write cache; tell
                #   the guest so it doesn't issue redundant flush commands.
                # discard=on: advertises TRIM support to the guest.
                virtio_dev_json+=",\"write-cache\":\"on\",\"discard\":true"
            fi
            virtio_dev_json+=",\"werror\":\"stop\",\"rerror\":\"report\"}"
            _dsk_cmd+=(
                "-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}"
                "-device" "$virtio_dev_json"
            ) ;;
        nvme)
            _dsk_cmd+=(
                "-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}"
                "-device" "nvme,drive=drive0,serial=qemate-nvme,max_ioqpairs=${_dsk_vm[CORES]}"
            ) ;;
        sata)
            # q35 exposes its AHCI/SATA controller through QEMU's IDE device
            # frontend; the legacy `-drive if=sata` spelling is unsupported.
            _dsk_cmd+=(
                "-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}"
                "-device" "ide-hd,drive=drive0,bus=ide.0"
            ) ;;
        ide)
            _dsk_cmd+=("-drive" "file=${disk_file},if=${_dsk_vm[DISK_INTERFACE]},${drive_opts}") ;;
    esac
}

configure_macos_disk() {
    local vm_name="$1"
    local -n _md_vm="$2"
    local -n _md_cmd="$3"
    local disk_file drive_opts
    if [[ -n "${_md_vm[DISK_DEV]:-}" ]]; then
        disk_file="${_md_vm[DISK_DEV]}"
        [[ ! -b "$disk_file" ]] && { log_message "ERROR" "Physical disk device not found: $disk_file" "$vm_name"; return 1; }
        [[ ! -r "$disk_file" || ! -w "$disk_file" ]] && { log_message "ERROR" "No read/write access to $disk_file" "$vm_name"; return 1; }
        drive_opts="format=raw,cache=none,aio=${_md_vm[DISK_IO]},discard=unmap,detect-zeroes=unmap"
    else
        disk_file="$VM_DIR/$vm_name/disk.qcow2"
        drive_opts="format=qcow2,cache=${_md_vm[DISK_CACHE]},aio=${_md_vm[DISK_IO]},discard=${_md_vm[DISK_DISCARD]}"
    fi
    _md_cmd+=(
        "-drive" "file=${disk_file},if=none,id=MacHDD,${drive_opts}"
        "-device" "ide-hd,bus=sata.4,drive=MacHDD"
    )
}

configure_display() {
    local -n _dsp_vm="$1"
    local -n _dsp_cmd="$2"
    local headless="$3"

    if [[ "$headless" == "1" ]]; then
        _dsp_cmd+=("-display" "none"); return 0
    fi

    local video="${_dsp_vm[VIDEO_TYPE]:-virtio-vga}"
    local base_video="${video%%,*}"

    if [[ "${_dsp_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        if [[ ! "$base_video" =~ ^(qxl|qxl-vga|virtio-vga|virtio-gpu)$ ]]; then
            video="qxl-vga"; base_video="qxl-vga"
        fi
    fi

    case "$base_video" in
        qxl-vga|qxl)
            local vram_mb="${_dsp_vm[VRAM_SIZE_MB]:-64}"
            local vram_bytes=$(( vram_mb * 1024 * 1024 ))
            local qxl_opts="id=video0,ram_size=${vram_bytes},vram_size=${vram_bytes}"
            [[ "$video" == *","* ]] && qxl_opts+=",${video#*,}"
            _dsp_cmd+=("-device" "${base_video},${qxl_opts}") ;;
        virtio-vga|virtio-gpu)
            if [[ "${_dsp_vm[ENABLE_VIRTIO]:-1}" == "1" ]]; then
                _dsp_cmd+=("-device" "$video")
            else
                _dsp_cmd+=("-vga" "std")
            fi ;;
        std|vmware)
            _dsp_cmd+=("-vga" "$base_video") ;;
        *)
            if [[ "$video" == *","* ]]; then _dsp_cmd+=("-device" "$video")
            else _dsp_cmd+=("-vga" "std"); fi ;;
    esac

    if [[ "${_dsp_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        local port="${_dsp_vm[SPICE_PORT]:-5930}"
        _dsp_cmd+=(
            "-display" "none"
            "-spice"   "addr=127.0.0.1,port=${port},disable-ticketing=on,seamless-migration=on"
            "-chardev" "spicevmc,id=vdagent,name=vdagent"
            "-device"  "virtserialport,chardev=vdagent,name=com.redhat.spice.0"
        )
        log_message "INFO" "SPICE display on 127.0.0.1:${port} — connect with: remote-viewer spice://127.0.0.1:${port}" "${_dsp_vm[NAME]:-}"
    else
        _dsp_cmd+=("-display" "default")
    fi
}

configure_network() {
    local vm_name="$1"
    local -n _net_vm="$2"
    local -n _net_cmd="$3"
    local dry_run="${4:-0}"

    if [[ "${_net_vm[NETWORK_MODEL]}" == "virtio-net-pci" && "${_net_vm[ENABLE_VIRTIO]:-1}" != "1" ]]; then
        log_message "WARNING" "virtio-net-pci requested but ENABLE_VIRTIO=0; falling back to e1000." "$vm_name"
        _net_vm[NETWORK_MODEL]="e1000"
    fi

    local mac="${_net_vm[MAC_ADDRESS]}" model="${_net_vm[NETWORK_MODEL]}"
    local device_opts="${model},netdev=net0,mac=${mac}"
    if [[ "$model" == "virtio-net-pci" && "${_net_vm[OS_TYPE]:-linux}" != "macos" ]]; then
        # Both features are negotiated: older guest drivers continue to use
        # split, out-of-order virtqueues when they do not support them.
        device_opts+=",packed=on,in_order=on"
    fi

    case "${_net_vm[NETWORK_TYPE]:-user}" in
        user|nat)
            local netdev_opts="user,id=net0"
            local smb_path; smb_path=$(get_smb_share_path "$vm_name" _net_vm)

            if [[ -n "$smb_path" ]]; then
                if command -v smbd &>/dev/null; then
                    netdev_opts+=",smb=${smb_path}"
                    log_message "INFO" "SMB share active: $smb_path" "$vm_name"
                else
                    log_message "WARNING" "smbd not found — SMB share disabled. Install samba." "$vm_name"
                fi
            fi

            if [[ -n "${_net_vm[PORT_FORWARDS]:-}" ]]; then
                local fwds=(); split_list "${_net_vm[PORT_FORWARDS]}" fwds
                local fwd
                for fwd in "${fwds[@]}"; do
                    if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        # Capture the global array into local variables immediately
                        local fwd_ip="${BASH_REMATCH[2]:-}"
                        local fwd_hport="${BASH_REMATCH[3]}"
                        local fwd_gport="${BASH_REMATCH[4]}"
                        local fwd_proto="${BASH_REMATCH[5]}"

                        if host_port_in_use "$fwd_hport" "$fwd_proto"; then
                            log_message "ERROR" "Host port already in use: ${fwd_hport}/${fwd_proto}" "$vm_name"
                            return 1
                        fi
                        netdev_opts+=",hostfwd=${fwd_proto}:${fwd_ip}:${fwd_hport}-:${fwd_gport}"
                    fi
                done
            fi

            _net_cmd+=("-netdev" "$netdev_opts" "-device" "$device_opts")
            log_message "INFO" "Network: user/NAT (SLiRP)" "$vm_name" ;;

        passt)
            command -v passt &>/dev/null || { log_message "ERROR" "passt not found. Install the passt package for your distribution." "$vm_name"; return 1; }
            local passt_opts="passt,id=net0"

            if [[ -n "${_net_vm[PORT_FORWARDS]:-}" ]]; then
                local fwds=(); split_list "${_net_vm[PORT_FORWARDS]}" fwds
                local fwd
                for fwd in "${fwds[@]}"; do
                    if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        # Capture the global array into local variables immediately
                        local fwd_ip="${BASH_REMATCH[2]:-}"
                        local fwd_hport="${BASH_REMATCH[3]}"
                        local fwd_gport="${BASH_REMATCH[4]}"
                        local fwd_proto="${BASH_REMATCH[5]}"

                        if host_port_in_use "$fwd_hport" "$fwd_proto"; then
                            log_message "ERROR" "Host port already in use: ${fwd_hport}/${fwd_proto}" "$vm_name"
                            return 1
                        fi
                        if [[ -n "$fwd_ip" ]]; then
                            passt_opts+=",hostfwd=${fwd_proto}:${fwd_ip}:${fwd_hport}-:${fwd_gport}"
                        else
                            passt_opts+=",hostfwd=${fwd_proto}::${fwd_hport}-:${fwd_gport}"
                        fi
                    fi
                done
            fi

            _net_cmd+=("-netdev" "$passt_opts" "-device" "$device_opts")
            log_message "INFO" "Network: passt (unprivileged)" "$vm_name" ;;

        tap)
            local tap_name
            if [[ "$dry_run" == "1" ]]; then
                tap_name=$(tap_interface_name "$vm_name")
            else
                tap_name=$(setup_tap_interface "$vm_name" _net_vm) || return 1
            fi
            local queues=$(( _net_vm[CORES] / 2 ))
            (( queues < 1 )) && queues=1
            (( queues > 8 )) && queues=8

            local vhost="off"
            if [[ -r /dev/vhost-net && -w /dev/vhost-net ]]; then
                vhost="on"
                log_message "INFO" "vhost-net acceleration enabled" "$vm_name"
            else
                log_message "WARNING" "/dev/vhost-net not accessible. Run: sudo usermod -aG kvm $USER" "$vm_name"
            fi

            local mq_netdev=",vhost=${vhost}" mq_device=""
            if [[ "$queues" -gt 1 ]]; then
                mq_netdev=",queues=${queues},vhost=${vhost}"
                mq_device=",mq=on,vectors=$(( queues * 2 + 2 ))"
                if [[ "$model" == "virtio-net-pci" && "${_net_vm[OS_TYPE]:-linux}" != "macos" ]]; then
                    # QEMU's vhost-net eBPF RSS path cannot report packet hashes
                    # to the guest. Hash reporting is available with userspace RSS.
                    if [[ "$vhost" == "on" ]]; then
                        mq_device+=",rss=on,hash=off"
                    else
                        mq_device+=",rss=on,hash=on"
                    fi
                fi
            fi

            _net_cmd+=("-netdev" "tap,id=net0,ifname=${tap_name},script=no,downscript=no${mq_netdev}" "-device" "${device_opts}${mq_device}")
            log_message "INFO" "Network: TAP ($tap_name, queues=${queues}, vhost=${vhost})" "$vm_name" ;;

        none)
            _net_cmd+=("-nic" "none") ;;
        *)
            log_message "WARNING" "Unknown NETWORK_TYPE '${_net_vm[NETWORK_TYPE]}'; falling back to user." "$vm_name"
            _net_cmd+=("-netdev" "user,id=net0" "-device" "$device_opts") ;;
    esac
}

configure_audio() {
    local vm_name="$1"
    local -n _aud_conf="$2"
    local -n _aud_cmd="$3"
    local dry_run="${4:-0}"

    [[ "${_aud_conf[ENABLE_AUDIO]:-0}" != "1" ]] && return 0
    local pci_spec="${_aud_conf[AUDIO_PASSTHROUGH_PCI]:-}"
    if [[ -z "$pci_spec" || "$pci_spec" == "0" ]]; then
        # Emulated HDA via QEMU's default host backend (PipeWire/Pulse/ALSA).
        _aud_cmd+=("-audio" "driver=default,model=intel-hda")
        log_message "INFO" "Audio: emulated Intel HDA (set AUDIO_PASSTHROUGH_PCI for VFIO passthrough)." "$vm_name"
        return 0
    fi

    local pci_id="$pci_spec"
    [[ ! "$pci_id" =~ ^[0-9a-fA-F]{4}: ]] && pci_id="0000:$pci_id"
    local dev_path="/sys/bus/pci/devices/$pci_id"

    [[ ! -d "$dev_path" ]] && {
        log_message "ERROR" "Audio PCI device $pci_id not found" "$vm_name"; return 1; }

    if [[ "$dry_run" == "1" ]]; then
        _aud_cmd+=("-device" "vfio-pci,host=${pci_id#0000:},id=hostaudio0,bus=pcie.0")
        return 0
    fi

    local vendor vendor_id device device_id
    read -r vendor < "$dev_path/vendor"; vendor_id="${vendor#0x}"
    read -r device < "$dev_path/device"; device_id="${device#0x}"
    log_message "INFO" "Loading vfio-pci for ${vendor_id}:${device_id}" "$vm_name"

    sudo modprobe vfio-pci ids="${vendor_id}:${device_id}" 2>/dev/null || sudo modprobe vfio-pci || true

    local iommu_group; iommu_group=$(get_iommu_group "$pci_id")
    [[ -z "$iommu_group" ]] && {
        log_message "ERROR" "IOMMU group not found — is IOMMU enabled in BIOS?" "$vm_name"
        return 1
    }

    local current_driver="none" link
    if [[ -L "$dev_path/driver" ]]; then
        link=$(readlink "$dev_path/driver")
        current_driver="${link##*/}"
    fi

    if [[ "$current_driver" != "vfio-pci" ]]; then
        log_message "INFO" "Isolating IOMMU group $iommu_group for $pci_id (was: $current_driver)" "$vm_name"

        # Pre-cache sudo credentials now, while we still have a TTY when possible.
        # restore_group_drivers runs from the EXIT trap where there may be no TTY,
        # so if sudo requires a password at that point it would hang or silently fail,
        # leaving the host audio device bound to vfio-pci after the VM exits.
        #
        # Detached starts have no controlling TTY. In that case require passwordless
        # sudo for the VFIO operations (or run with existing cached credentials).
        if ! sudo -n true 2>/dev/null; then
            if [[ ! -t 0 || "${QEMATE_INTERNAL_DETACH:-0}" == "1" ]]; then
                log_message "ERROR" "Audio passthrough needs passwordless sudo in detached/non-interactive mode. Configure NOPASSWD for the VFIO paths or start without --detach." "$vm_name"
                return 1
            fi
            log_message "INFO" "Caching sudo credentials for VFIO teardown (extending timestamp)..." "$vm_name"
            # Extend the sudo timestamp so long-running VMs can still restore drivers.
            sudo -v || {
                log_message "ERROR" "sudo required for VFIO but authentication failed." "$vm_name"
                return 1
            }
            # Keep refreshing the timestamp while the VM runs (background helper).
            (
                while kill -0 "$$" 2>/dev/null; do
                    sleep 60
                    sudo -n -v 2>/dev/null || break
                done
            ) &
            disown 2>/dev/null || true
        fi

        save_original_drivers "$vm_name" "$pci_id" || {
            log_message "ERROR" "Failed to save original drivers" "$vm_name"; return 1; }

        local group_devs=()
        read -ra group_devs <<< "$(get_group_devices "$iommu_group")"
        log_message "INFO" "Binding ${#group_devs[@]} device(s) in IOMMU group $iommu_group" "$vm_name"

        local dev bind_ok=1
        for dev in "${group_devs[@]}"; do
            local dpath="/sys/bus/pci/devices/$dev"
            local v d
            read -r v < "$dpath/vendor"
            read -r d < "$dpath/device"

            echo "$v $d" | sudo tee /sys/bus/pci/drivers/vfio-pci/new_id >/dev/null 2>&1 || true
            echo "vfio-pci" | sudo tee "$dpath/driver_override" >/dev/null 2>&1 || true

            if [[ -L "$dpath/driver" ]]; then
                local cdrv_link cdrv
                cdrv_link=$(readlink "$dpath/driver")
                cdrv="${cdrv_link##*/}"
                [[ "$cdrv" != "vfio-pci" ]] && \
                    echo "$dev" | sudo tee "/sys/bus/pci/drivers/$cdrv/unbind" >/dev/null 2>&1 || true
            fi

            echo "$dev" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind >/dev/null 2>&1 || {
                log_message "ERROR" "vfio-pci bind failed for $dev" "$vm_name"
                bind_ok=0
            }
            [[ "$bind_ok" -eq 1 ]] && log_message "DEBUG" "Bound $dev to vfio-pci" "$vm_name"
        done

        sleep 1.0

        local final_driver="none"
        if [[ -L "$dev_path/driver" ]]; then
            link=$(readlink "$dev_path/driver")
            final_driver="${link##*/}"
        fi
        
        if [[ "$bind_ok" -eq 0 || "$final_driver" != "vfio-pci" ]]; then
            log_message "ERROR" "Failed to bind to vfio-pci. Check dmesg." "$vm_name"
            restore_group_drivers "$vm_name"; return 1
        fi

        local vfio_node="/dev/vfio/$iommu_group"
        if [[ -e "$vfio_node" ]]; then
            sudo chown "$(id -u):$(id -g)" "$vfio_node" 2>/dev/null || true
            sudo chmod 600 "$vfio_node"                 2>/dev/null || true
            log_message "INFO" "VFIO group node ready: $vfio_node" "$vm_name"
        fi
    fi

    _aud_cmd+=("-device" "vfio-pci,host=${pci_id#0000:},id=hostaudio0,bus=pcie.0")
    log_message "INFO" "✅ Audio PCIe passthrough ready (IOMMU group $iommu_group)" "$vm_name"
}

configure_usb_passthrough() {
    local vm_name="$1"
    local -n _usb_vm="$2"
    local -n _usb_cmd="$3"
    [[ -z "${_usb_vm[USB_DEVICES]:-}" ]] && return 0

    local usb_arr=(); split_list "${_usb_vm[USB_DEVICES]}" usb_arr
    local dev bus_opt=""
    # macOS guests already have qemu-xhci as xhci; pin host devices there.
    [[ "${_usb_vm[OS_TYPE]:-linux}" == "macos" ]] && bus_opt=",bus=xhci.0"
    for dev in "${usb_arr[@]}"; do
        _usb_cmd+=("-device" "usb-host,vendorid=0x${dev%%:*},productid=0x${dev##*:}${bus_opt}")
        log_message "INFO" "USB passthrough: $dev" "$vm_name"
    done
}

configure_shares_virtfs() {
    local vm_name="$1"
    local -n _vfs_vm="$2"
    local -n _vfs_cmd="$3"
    local idx=0

    local shares=(); split_list "${_vfs_vm[SHARED_FOLDERS]:-}" shares
    local s tag path
    for s in "${shares[@]}"; do
        tag="${s%%:*}"; path="${s#*:}"
        if [[ ! -d "$path" ]]; then
            log_message "WARNING" "Share path not found, skipping: $path" "$vm_name"; continue
        fi
        _vfs_cmd+=("-virtfs" "local,path=${path},mount_tag=${tag},security_model=mapped-xattr,id=fsdev${idx}")
        log_message "INFO" "VirtFS: '$tag' → $path" "$vm_name"
        (( idx++ )) || true
    done
}

configure_shares_virtiofs() {
    local vm_name="$1"
    local -n _cvf_vm="$2"
    local -n _cvf_cmd="$3"
    local dry_run="${4:-0}"
    local socket_dir="$VM_DIR/$vm_name/sockets"

    _cvf_vm[MEMORY_SHARE]=1
    local shares=(); split_list "${_cvf_vm[SHARED_FOLDERS]:-}" shares
    local s tag sock
    for s in "${shares[@]}"; do
        tag="${s%%:*}"; path="${s#*:}"; sock="$socket_dir/virtiofsd_${tag}.sock"
        if [[ ! -d "$path" ]]; then
            log_message "WARNING" "Share path not found, skipping: $path" "$vm_name"
            continue
        fi
        if [[ "$dry_run" != "1" && ! -S "$sock" ]]; then
            log_message "WARNING" "virtiofsd socket missing for share, skipping: $tag" "$vm_name"
            continue
        fi
        local device_opts="vhost-user-fs-pci,chardev=char_${tag},tag=${tag}"
        if [[ "${_cvf_vm[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
            # Rust virtiofsd currently exposes one request queue.  Its thread
            # pool handles requests in parallel; asking QEMU for extra request
            # queues makes virtiofsd reject virtqueue 2 with InvalidParam.
            device_opts+=",queue-size=1024"
        fi
        _cvf_cmd+=("-chardev" "socket,id=char_${tag},path=${sock}" "-device" "$device_opts")
        log_message "INFO" "VirtIO-FS: '$tag'" "$vm_name"
    done
}

configure_shares() {
    local vm_name="$1"
    local -n _cs_vm="$2"
    local -n _cs_cmd="$3"
    local dry_run="${4:-0}"

    [[ -z "${_cs_vm[SHARED_FOLDERS]:-}" ]] && return 0
    local backend; backend=$(resolve_share_backend _cs_vm)

    case "$backend" in
        virtiofs)
            log_message "INFO" "Shares: VirtIO-FS (multi-share)" "$vm_name"
            [[ "$dry_run" == "1" ]] || start_virtiofsd_daemons "$vm_name" _cs_vm || return 1
            configure_shares_virtiofs "$vm_name" _cs_vm _cs_cmd "$dry_run" ;;
        virtfs)
            log_message "INFO" "Shares: VirtFS 9p (fallback)" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
        smb)
            log_message "INFO" "Shares: SMB (single share via SLiRP)" "$vm_name" ;;
        none)
            return 0 ;;
        *)
            log_message "WARNING" "Unknown share backend '$backend', falling back to virtfs" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
    esac
}

configure_tpm() {
    local vm_name="$1"
    local -n _tpm_vm="$2"
    local -n _tpm_cmd="$3"
    local dry_run="${4:-0}"

    [[ "${_tpm_vm[ENABLE_TPM]:-0}" != "1" ]] && return 0
    command -v swtpm &>/dev/null || { log_message "ERROR" "swtpm not found; TPM is required for this VM." "$vm_name"; return 1; }

    local tpm_dir="$VM_DIR/$vm_name/tpm"
    local tpm_sock="$VM_DIR/$vm_name/sockets/swtpm.sock"
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"

    if [[ "$dry_run" == "1" ]]; then
        _tpm_cmd+=("-chardev" "socket,id=chrtpm,path=$tpm_sock" "-tpmdev" "emulator,id=tpm0,chardev=chrtpm" "-device" "tpm-crb,tpmdev=tpm0")
        return 0
    fi
    mkdir -p "$tpm_dir"

    if [[ ! -f "$tpm_dir/tpm2-00.permall" ]]; then
        swtpm_setup --tpm2 --tpmstate "$tpm_dir" --createek --allow-signing \
            --decryption --create-ek-cert --create-platform-cert \
            --lock-nvram --not-overwrite &>/dev/null || {
                log_message "ERROR" "Failed to initialise TPM state" "$vm_name"
                return 1
            }
    fi

    rm -f "$tpm_sock"
    swtpm socket --tpm2 --tpmstate "dir=$tpm_dir" --ctrl "type=unixio,path=$tpm_sock" \
        --daemon --pid "file=$tpm_pid" --log "level=0" || {
            log_message "ERROR" "Failed to start swtpm" "$vm_name"
            return 1
        }

    local i
    for (( i=0; i<20; i++ )); do
        [[ -S "$tpm_sock" ]] && break; sleep 0.2
    done

    [[ ! -S "$tpm_sock" ]] && {
        log_message "ERROR" "swtpm failed to create its control socket" "$vm_name"
        stop_tpm "$vm_name"
        return 1
    }

    _tpm_cmd+=("-chardev" "socket,id=chrtpm,path=$tpm_sock" "-tpmdev" "emulator,id=tpm0,chardev=chrtpm" "-device" "tpm-crb,tpmdev=tpm0")
    log_message "INFO" "TPM 2.0 enabled" "$vm_name"
}

# =============================================================================
# CORE VM MANAGEMENT
# =============================================================================

create() {
    require_qemu_toolchain || return 1
    local vm_name="$1"; shift
    local os_type="linux" memory="" cores="" disk_size="" disk_dev="" machine_type="" \
          machine_options="" enable_audio="" enable_tpm="" enable_uefi="" spice_enabled="" share_backend="" profile="balanced"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os-type)       [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--os-type requires a value"; return 1; }; os_type="$2";       shift 2 ;;
            --memory)        [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--memory requires a value"; return 1; }; memory="$2";         shift 2 ;;
            --cores)         [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--cores requires a value"; return 1; }; cores="$2";          shift 2 ;;
            --disk-size)     [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--disk-size requires a value"; return 1; }; disk_size="$2";      shift 2 ;;
            --disk-dev)      [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--disk-dev requires a value"; return 1; }; disk_dev="$2";        shift 2 ;;
            --machine)
                [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--machine requires a value"; return 1; }
                [[ "$2" =~ ^([^,]+)(,(accel=kvm|accel=tcg))?$ ]] || {
                    log_message "ERROR" "Invalid machine: '$2'. Use e.g. pc-q35-11.0,accel=kvm"; return 1; }
                machine_type="${BASH_REMATCH[1]}"
                machine_options="${BASH_REMATCH[3]:-accel=kvm}"
                shift 2 ;;
            --enable-audio)  enable_audio="1";    shift ;;
            --no-audio)      enable_audio="0";    shift ;;
            --enable-tpm)    enable_tpm="1";      shift ;;
            --no-tpm)        enable_tpm="0";      shift ;;
            --uefi)          enable_uefi="1";     shift ;;
            --no-uefi)       enable_uefi="0";     shift ;;
            --spice)         spice_enabled="1";   shift ;;
            --no-spice)      spice_enabled="0";   shift ;;
            --share-backend) [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--share-backend requires a value"; return 1; }; share_backend="$2";  shift 2 ;;
            --profile)       [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--profile requires a value"; return 1; }; profile="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    validate_vm_name "$vm_name" || return 1
    vm_exists "$vm_name" && { log_message "ERROR" "VM already exists: $vm_name"; return 1; }
    [[ "$os_type" != "linux" && "$os_type" != "windows" && "$os_type" != "macos" ]] && {
        log_message "ERROR" "Invalid os-type: '$os_type'. Use: linux, windows, macos"; return 1; }
    if [[ -n "$share_backend" && ! "$share_backend" =~ ^(auto|virtfs|smb|virtiofs)$ ]]; then
        log_message "ERROR" "Invalid share backend: '$share_backend'. Use: auto, virtfs, smb, virtiofs"
        return 1
    fi
    [[ "$profile" =~ ^(balanced|performance)$ ]] || {
        log_message "ERROR" "Invalid profile: '$profile'. Use: balanced, performance"; return 1; }

    # Early memlock / available-RAM check when creating a performance-profile VM
    if [[ "$profile" == "performance" ]]; then
        local check_mem="${memory:-}"
        if [[ -z "$check_mem" ]]; then
            local -A _tmp_defaults=()
            apply_os_defaults "$os_type" _tmp_defaults
            check_mem="${_tmp_defaults[MEMORY]}"
        fi
        validate_performance_memory "$vm_name" "$check_mem" || return 1
    fi

    if [[ -n "$cores" ]]; then
        [[ ! "$cores" =~ ^[0-9]+$ || "$cores" -lt 1 || "$cores" -gt 64 ]] && {
            log_message "ERROR" "Invalid cores: $cores (must be 1–64)"; return 1; }
    fi

    if [[ -n "$memory" ]]; then
        [[ ! "$memory" =~ ^([0-9]+)([GMgm])$ ]] && {
            log_message "ERROR" "Invalid memory: '$memory'. Use e.g. 4G or 2048M"; return 1; }
        local mem_val="${BASH_REMATCH[1]}" mem_unit="${BASH_REMATCH[2]}"

        if [[ -f /proc/meminfo ]]; then
            local avail=0 key val _
            while IFS=': ' read -r key val _; do
                if [[ "$key" == "MemAvailable" ]]; then
                    avail=$(( val / 1024 ))
                    break
                fi
            done < /proc/meminfo
            
            if [[ "$avail" -gt 0 ]]; then
                local check=$mem_val
                [[ "${mem_unit^^}" == "G" ]] && check=$(( mem_val * 1024 ))
                [[ "$check" -gt $(( avail * 90 / 100 )) ]] && {
                    log_message "ERROR" "Memory $memory exceeds 90% of available RAM (${avail}M available)"; return 1; }
            fi
        fi
    fi

    # Validate disk options — mutually exclusive: --disk-dev vs --disk-size
    if [[ -n "$disk_dev" ]]; then
        [[ ! -b "$disk_dev" ]] && {
            log_message "ERROR" "Not a block device: $disk_dev"; return 1; }
        [[ ! -r "$disk_dev" || ! -w "$disk_dev" ]] && {
            log_message "ERROR" "No read/write access to $disk_dev. Add yourself to the 'disk' group: sudo usermod -aG disk $USER (then log out and back in)" "$vm_name"
            return 1; }
        if disk_dev_in_use_by_other "$disk_dev" "$vm_name"; then
            log_message "ERROR" "Physical disk $disk_dev is already configured on another VM" "$vm_name"
            return 1
        fi
        [[ -n "$disk_size" ]] && \
            log_message "WARNING" "--disk-size is ignored when --disk-dev is set." "$vm_name"
    else
        [[ -n "$disk_size" && ! "$disk_size" =~ ^[0-9]+[GMgm]$ ]] && {
            log_message "ERROR" "Invalid disk size: '$disk_size'. Use e.g. 60G"; return 1; }
    fi

    local -A VM=()
    apply_os_defaults "$os_type" VM
    VM[PERFORMANCE_PROFILE]="$profile"
    if [[ "$os_type" == "windows" && "$profile" == "performance" ]]; then
        VM[DISK_INTERFACE]="virtio"
    fi

    [[ -n "$cores"           ]] && VM[CORES]="$cores"
    [[ -n "$memory"          ]] && VM[MEMORY]="$memory"
    [[ -n "$enable_uefi"     ]] && VM[ENABLE_UEFI]="$enable_uefi"
    [[ -n "$enable_audio"    ]] && VM[ENABLE_AUDIO]="$enable_audio"
    [[ -n "$enable_tpm"      ]] && VM[ENABLE_TPM]="$enable_tpm"
    [[ -n "$spice_enabled"   ]] && VM[SPICE_ENABLED]="$spice_enabled"
    [[ -n "$share_backend"   ]] && VM[SHARE_BACKEND]="$share_backend"
    [[ -n "$machine_type"    ]] && VM[MACHINE_TYPE]="$machine_type"
    [[ -n "$machine_options" ]] && VM[MACHINE_OPTIONS]="$machine_options"

    VM[NAME]="$vm_name"
    VM[OS_TYPE]="$os_type"
    VM[MACOS_VERSION]=""
    VM[MACOS_INSTALL_MEDIA]=0
    [[ "$os_type" == "macos" ]] && VM[MACOS_VERSION]="sonoma"
    VM[MAC_ADDRESS]=$(generate_mac_address "$vm_name")
    VM[MACHINE_OPTIONS]="${VM[MACHINE_OPTIONS]:-accel=kvm}"
    VM[LOCKED]="0"
    VM[PORT_FORWARDS]=""
    VM[USB_DEVICES]=""
    VM[SHARED_FOLDERS]=""
    VM[DISK_DEV]=""

    mkdir -p "$VM_DIR/$vm_name" "$VM_DIR/$vm_name/logs" "$VM_DIR/$vm_name/sockets" "$VM_DIR/$vm_name/tpm" || {
        log_message "ERROR" "Failed to create VM directories" "$vm_name"; return 1; }
    chmod 700 "$VM_DIR/$vm_name" "$VM_DIR/$vm_name/logs" "$VM_DIR/$vm_name/sockets" "$VM_DIR/$vm_name/tpm" || {
        log_message "ERROR" "Failed to secure VM directories" "$vm_name"; return 1; }

    if [[ -n "$disk_dev" ]]; then
        # Physical block device — no image file is created
        VM[DISK_DEV]="$disk_dev"
        # Physical disks must bypass the host page cache (O_DIRECT).
        # writeback is only appropriate for qcow2 image files.
        VM[DISK_CACHE]="none"
        local size_bytes
        size_bytes=$(lsblk -bno SIZE "$disk_dev" 2>/dev/null | tr -d ' ') || true
        if [[ -n "$size_bytes" && "$size_bytes" =~ ^[0-9]+$ && "$size_bytes" -gt 0 ]]; then
            VM[DISK_SIZE]="$(( size_bytes / 1073741824 ))G"
        else
            VM[DISK_SIZE]="unknown"
        fi
        log_message "WARNING" \
            "Physical device '$disk_dev' configured — any existing data WILL be destroyed by the OS installer." \
            "$vm_name"
    else
        # Virtual disk image (qcow2)
        [[ -n "$disk_size" ]] && VM[DISK_SIZE]="$disk_size"
        check_disk_space_for_create "$vm_name" "${VM[DISK_SIZE]}" || {
            rm -rf "${VM_DIR:?}/${vm_name:?}"; return 1
        }
        local -a qcow_opts=(-f qcow2)
        # Reduce fragmentation and speed up first-write for performance profiles.
        if [[ "${VM[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
            qcow_opts+=(-o "lazy_refcounts=on,preallocation=metadata,cluster_size=2M")
        else
            qcow_opts+=(-o "lazy_refcounts=on,preallocation=metadata")
        fi
        qemu-img create "${qcow_opts[@]}" "$VM_DIR/$vm_name/disk.qcow2" "${VM[DISK_SIZE]}" &>/dev/null || {
            log_message "ERROR" "Failed to create disk image" "$vm_name"
            rm -rf "${VM_DIR:?}/${vm_name:?}"; return 1
        }
        chmod 600 "$VM_DIR/$vm_name/disk.qcow2"
    fi

    save_vm_config "$vm_name" VM
    local disk_info="${VM[DISK_DEV]:-${VM[DISK_SIZE]}}"
    log_message "INFO" "VM '$vm_name' created (OS: $os_type | Mem: ${VM[MEMORY]} | Cores: ${VM[CORES]} | Disk: ${disk_info})" "$vm_name"
}

start_detached() {
    local vm_name="$1" debug="$2"; shift 2
    local -a start_args=("$@")

    require_commands setsid || return 1
    require_vm "$vm_name" exists unlocked not-running || return 1

    local self_path status_file supervisor_log log_stamp
    self_path=$(realpath "${BASH_SOURCE[0]}")
    status_file=$(mktemp "$VM_DIR/$vm_name/.detach-start.XXXXXX.status")
    printf -v log_stamp '%(%Y%m%d-%H%M%S)T' -1
    supervisor_log=$(mktemp "$VM_DIR/$vm_name/logs/supervisor-${log_stamp}.XXXXXX.log")
    QEMATE_DETACH_LAUNCH_STATUS_FILE="$status_file"
    QEMATE_DETACH_SUPERVISOR_PID=""
    trap 'cancel_detached_launch 130' INT
    trap 'cancel_detached_launch 143' TERM

    log_message "INFO" "Starting VM in detached mode: $vm_name" "$vm_name"
    if ! setsid --fork env QEMATE_INTERNAL_DETACH=1 \
        "$self_path" start "$vm_name" "${start_args[@]}" --_detach-status "$status_file" \
        </dev/null >"$supervisor_log" 2>&1; then
        rm -f "$status_file"
        QEMATE_DETACH_LAUNCH_STATUS_FILE=""
        trap 'cleanup_on_signal 130' INT
        trap 'cleanup_on_signal 143' TERM
        log_message "ERROR" "Failed to launch detached supervisor for: $vm_name" "$vm_name"
        return 1
    fi

    local state="" value="" supervisor_pid="" i
    for (( i=0; i<DETACH_START_TIMEOUT * 10; i++ )); do
        if IFS=$'\t' read -r state value < "$status_file" && [[ -n "$state" ]]; then
            if [[ "$state" == "STARTING" ]]; then
                supervisor_pid="$value"
                QEMATE_DETACH_SUPERVISOR_PID="$value"
            fi
            if [[ "$state" == "READY" ]]; then
                if [[ "$debug" == "1" ]]; then
                    sed -n '/^\[DEBUG\] Generated QEMU command:/,/^$/p' "$supervisor_log" >&2
                fi
                rm -f "$status_file"
                QEMATE_DETACH_LAUNCH_STATUS_FILE=""
                QEMATE_DETACH_SUPERVISOR_PID=""
                trap 'cleanup_on_signal 130' INT
                trap 'cleanup_on_signal 143' TERM
                log_message "INFO" "VM $vm_name started in detached mode (PID: $value)." "$vm_name"
                log_message "INFO" "Supervisor log: $supervisor_log" "$vm_name"
                return 0
            fi
            if [[ "$state" == "FAILED" ]]; then
                if [[ "$debug" == "1" ]]; then
                    sed -n '/^\[DEBUG\] Generated QEMU command:/,/^$/p' "$supervisor_log" >&2
                fi
                rm -f "$status_file"
                QEMATE_DETACH_LAUNCH_STATUS_FILE=""
                QEMATE_DETACH_SUPERVISOR_PID=""
                trap 'cleanup_on_signal 130' INT
                trap 'cleanup_on_signal 143' TERM
                log_message "ERROR" "Detached start failed (exit: ${value:-1}). Check $supervisor_log" "$vm_name"
                return 1
            fi
        fi
        sleep 0.1
    done

    QEMATE_DETACH_SUPERVISOR_PID="$supervisor_pid"
    terminate_detached_supervisor
    if [[ "$debug" == "1" ]]; then
        sed -n '/^\[DEBUG\] Generated QEMU command:/,/^$/p' "$supervisor_log" >&2
    fi
    rm -f "$status_file"
    QEMATE_DETACH_LAUNCH_STATUS_FILE=""
    QEMATE_DETACH_SUPERVISOR_PID=""
    trap 'cleanup_on_signal 130' INT
    trap 'cleanup_on_signal 143' TERM
    log_message "ERROR" "Detached start timed out after ${DETACH_START_TIMEOUT}s. Check $supervisor_log" "$vm_name"
    return 1
}

start() {
    local vm_name="$1"; shift
    local headless="0" detach="0" iso_file="" virtio_iso="" debug="0" dry_run="0"
    local internal_detach="${QEMATE_INTERNAL_DETACH:-0}"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --headless) headless="1"; shift ;;
            --detach)   detach="1"; shift ;;
            --iso)      [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--iso requires a path"; return 1; }; iso_file="$2"; shift 2 ;;
            --virtio-iso) [[ $# -ge 2 && "$2" != --* ]] || { log_message "ERROR" "--virtio-iso requires a path"; return 1; }; virtio_iso="$2"; shift 2 ;;
            --debug)    debug="1"; shift ;;
            --dry-run)  dry_run="1"; shift ;;
            --_detach-status)
                [[ "$internal_detach" == "1" && $# -ge 2 ]] || { log_message "ERROR" "Unknown option: $1"; return 1; }
                QEMATE_DETACH_STATUS_FILE="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    if [[ "$detach" == "1" && "$headless" != "1" && -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        headless="1"
        log_message "INFO" "No DISPLAY/WAYLAND_DISPLAY; detached start will use --headless"
    fi

    if [[ "$internal_detach" == "1" ]]; then
        [[ -n "$QEMATE_DETACH_STATUS_FILE" ]] || { log_message "ERROR" "Detached supervisor status file is missing"; return 1; }
        trap cleanup_start_exit EXIT
        write_detach_status "STARTING" "$BASHPID"
    fi

    require_qemu_toolchain || return 1

    if [[ "$detach" == "1" && "$internal_detach" != "1" && "$dry_run" != "1" ]]; then
        local -a detached_args=()
        [[ "$headless" == "1" ]] && detached_args+=(--headless)
        [[ -n "$iso_file" ]] && detached_args+=(--iso "$iso_file")
        [[ -n "$virtio_iso" ]] && detached_args+=(--virtio-iso "$virtio_iso")
        [[ "$debug" == "1" ]] && detached_args+=(--debug)
        start_detached "$vm_name" "$debug" "${detached_args[@]}"
        return $?
    fi

    # A dry run must not change VM state, including its command log.
    [[ "$dry_run" == "1" ]] && QEMATE_SUPPRESS_FILE_LOG=1

    require_vm "$vm_name" exists unlocked not-running || return 1

    if [[ "$dry_run" != "1" ]]; then
        QEMATE_LOCK_FILE="$VM_DIR/$vm_name/qemu.pid.lock"
        acquire_flock "$QEMATE_LOCK_FILE" QEMATE_LOCK_FD || {
            log_message "ERROR" "VM lifecycle is busy (starting or running): $vm_name" "$vm_name"
            return 1
        }
        QEMATE_ACTIVE_VM="$vm_name"
        QEMATE_PHASE="starting"
        QEMATE_CLEANUP_DONE=0
        trap cleanup_start_exit EXIT

        stop_virtiofsd_daemons "$vm_name"
        stop_tpm "$vm_name"
        rm -f "$VM_DIR/$vm_name/sockets/qmp.sock"
        rm -f "$VM_DIR/$vm_name/sockets/mac-guest-agent.sock"
    fi

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    if [[ "${VM[OS_TYPE]:-linux}" == "macos" && "${VM[MACHINE_OPTIONS]:-accel=kvm}" != "accel=kvm" ]]; then
        log_message "ERROR" "macOS VMs require KVM acceleration (MACHINE_OPTIONS=accel=kvm)" "$vm_name"
        return 1
    fi
    if [[ -n "${VM[DISK_DEV]:-}" ]] && disk_dev_in_use_by_other "${VM[DISK_DEV]}" "$vm_name"; then
        log_message "ERROR" "Physical disk ${VM[DISK_DEV]} is already configured on another VM" "$vm_name"
        return 1
    fi
    check_vm_dependencies "$vm_name" VM || return 1
    [[ "${VM[PERFORMANCE_PROFILE]:-balanced}" != "performance" ]] || \
        validate_performance_memory "$vm_name" "${VM[MEMORY]}" || return 1

    if [[ "$dry_run" == "1" ]]; then
        log_message "INFO" "Dry run for VM: $vm_name" "$vm_name"
    else
        rotate_vm_logs "$vm_name"
        log_message "INFO" "Starting VM: $vm_name" "$vm_name"
    fi

    [[ "$dry_run" != "1" && "${VM[MACHINE_OPTIONS]}" =~ accel=kvm ]] && [[ ! -w /dev/kvm ]] && {
        log_message "ERROR" "/dev/kvm not writable. Run: sudo usermod -aG kvm $USER"
        return 1
    }

    if [[ -n "${VM[SHARED_FOLDERS]:-}" ]]; then
        local eff_be; eff_be=$(resolve_share_backend VM)
        [[ "$eff_be" == "virtiofs" ]] && VM[MEMORY_SHARE]=1
    fi

    local effective_machine machine_str
    effective_machine=$(effective_machine_type "${VM[MACHINE_TYPE]}")
    machine_str="${effective_machine},${VM[MACHINE_OPTIONS]}"
    [[ "${VM[OS_TYPE]:-linux}" == "windows" ]] && machine_str+=",hpet=off"

    local qemu_cmd=(
        "qemu-system-x86_64"
        "-name" "${VM[NAME]},process=${VM[NAME]}"
        "-machine" "$machine_str"
        "-pidfile" "$VM_DIR/$vm_name/qemu.pid"
        "-qmp" "unix:$VM_DIR/$vm_name/sockets/qmp.sock,server=on,wait=off"
    )

    if [[ "${VM[OS_TYPE]:-linux}" == "macos" ]]; then
        configure_memory VM qemu_cmd
        local macos_smp="${VM[CORES]},cores=${VM[CORES]},threads=1,sockets=1"
        qemu_cmd+=("-smp" "$macos_smp")
        configure_macos "$vm_name" VM qemu_cmd "$dry_run" || return 1
        configure_macos_guest_agent "$vm_name" VM qemu_cmd
        if [[ "$headless" == "1" ]]; then
            qemu_cmd+=("-display" "none")
        else
            # 64 MiB by default is ample for the managed 1920x1080 mode and
            # still leaves users free to raise VRAM_SIZE_MB for larger displays.
            qemu_cmd+=("-device" "vmware-svga,vgamem_mb=${VM[VRAM_SIZE_MB]:-64}" "-display" "default")
        fi
        configure_macos_disk "$vm_name" VM qemu_cmd || return 1
    else
        configure_uefi "$vm_name" VM qemu_cmd "$dry_run" || return 1
        configure_cpu VM qemu_cmd
        configure_memory VM qemu_cmd

        qemu_cmd+=(
            "-device" "qemu-xhci,id=usb,bus=pcie.0"
            "-device" "usb-kbd,bus=usb.0"
            "-device" "virtio-serial-pci"
            "-device" "virtserialport,chardev=chara0,name=org.qemu.guest_agent.0"
            "-chardev" "socket,id=chara0,path=$VM_DIR/$vm_name/sockets/qga.sock,server=on,wait=off"
        )

        configure_display VM qemu_cmd "$headless"
        configure_disk "$vm_name" VM qemu_cmd || return 1
    fi

    if [[ -n "$iso_file" && "${VM[OS_TYPE]:-linux}" != "macos" ]]; then
        iso_file=$(realpath "$iso_file")
        [[ ! -f "$iso_file" ]] && { log_message "ERROR" "ISO not found: $iso_file"; return 1; }
        qemu_cmd+=("-drive" "file=${iso_file},format=raw,readonly=on,media=cdrom,id=cdrom0" "-boot" "menu=on,order=dc")
    fi

    if [[ -n "$virtio_iso" ]]; then
        virtio_iso=$(realpath "$virtio_iso")
        [[ ! -f "$virtio_iso" ]] && { log_message "ERROR" "VirtIO ISO not found: $virtio_iso"; return 1; }
        qemu_cmd+=("-drive" "file=${virtio_iso},format=raw,readonly=on,media=cdrom,id=cdrom1")
    fi

    if [[ "${VM[OS_TYPE]:-linux}" == "macos" ]]; then
        # USB host devices attach to the OpenCore qemu-xhci controller.
        configure_usb_passthrough "$vm_name" VM qemu_cmd || return 1
        if [[ -n "${VM[SHARED_FOLDERS]:-}" ]]; then
            local macos_share_be
            macos_share_be=$(resolve_share_backend VM)
            case "$macos_share_be" in
                smb)
                    case "${VM[NETWORK_TYPE]:-user}" in
                        user|nat)
                            log_message "INFO" "macOS share backend is SMB over user/NAT (\\\\10.0.2.4\\qemu). QEMU slirp SMB is SMB 1.0; modern macOS may refuse it." "$vm_name"
                            ;;
                        *)
                            log_message "WARNING" "SMB shares require NETWORK_TYPE=user or nat. Folder tags are stored but not exported for this macOS VM." "$vm_name"
                            ;;
                    esac
                    ;;
                virtiofs|virtfs)
                    log_message "WARNING" "VirtIO-FS/9p have no supported macOS guest driver. Set SHARE_BACKEND=smb with NETWORK_TYPE=user, or share from the host over TAP." "$vm_name"
                    ;;
            esac
        fi
    else
        configure_audio "$vm_name" VM qemu_cmd "$dry_run" || return 1
        configure_usb_passthrough "$vm_name" VM qemu_cmd || return 1
        configure_shares "$vm_name" VM qemu_cmd "$dry_run" || { [[ "$dry_run" == "1" ]] || stop_virtiofsd_daemons "$vm_name"; return 1; }
        configure_tpm "$vm_name" VM qemu_cmd "$dry_run" || return 1
    fi
    configure_network "$vm_name" VM qemu_cmd "$dry_run" || return 1

    local launch_cmd=("${qemu_cmd[@]}")
    if [[ -n "${VM[CPU_AFFINITY]:-}" ]]; then
        require_commands taskset || return 1
        launch_cmd=("taskset" "-c" "${VM[CPU_AFFINITY]}" "${qemu_cmd[@]}")
    fi

    if [[ "$debug" == "1" || "$dry_run" == "1" ]]; then
        printf '\n[DEBUG] Generated QEMU command:\n' >&2
        printf '%q ' "${launch_cmd[@]}" >&2
        printf '\n\n' >&2
        [[ "$detach" == "1" ]] && printf '[DEBUG] Launch mode: detached\n\n' >&2
    fi
    [[ "$dry_run" == "1" ]] && return 0

    QEMATE_PHASE="running"
    log_message "INFO" "Launching QEMU process for $vm_name..." "$vm_name"

    local qemu_status=0
    local log_stamp qemu_log
    printf -v log_stamp '%(%Y%m%d-%H%M%S)T' -1
    qemu_log="$VM_DIR/$vm_name/logs/qemu-${log_stamp}.log"
    if [[ -e "$VM_DIR/$vm_name/logs/error.log" && ! -L "$VM_DIR/$vm_name/logs/error.log" ]]; then
        mv "$VM_DIR/$vm_name/logs/error.log" "$VM_DIR/$vm_name/logs/qemu-legacy-${log_stamp}.log"
    fi
    ln -sfn "${qemu_log##*/}" "$VM_DIR/$vm_name/logs/error.log"
    if [[ "$internal_detach" == "1" ]]; then
        "${launch_cmd[@]}" {QEMATE_LOCK_FD}>&- 2>"$qemu_log" &
        local qemu_job_pid=$! qemu_pid="" ready="0" i
        QEMATE_QEMU_JOB_PID="$qemu_job_pid"
        for (( i=0; i<DETACH_START_TIMEOUT * 10; i++ )); do
            if [[ -f "$VM_DIR/$vm_name/qemu.pid" ]]; then
                read -r qemu_pid < "$VM_DIR/$vm_name/qemu.pid" || true
                if vm_pid_matches "$vm_name" "$qemu_pid" && qmp_is_ready "$vm_name"; then
                    ready="1"
                    break
                fi
            fi
            kill -0 "$qemu_job_pid" 2>/dev/null || break
            sleep 0.1
        done
        if [[ "$ready" != "1" ]]; then
            if wait "$qemu_job_pid"; then qemu_status=1; else qemu_status=$?; fi
            log_message "ERROR" "QEMU did not become ready for detached operation. Check $qemu_log" "$vm_name" || true
            return "$qemu_status"
        fi
        write_detach_status "READY" "$qemu_pid"
        QEMATE_DETACH_READY=1
        if wait "$qemu_job_pid"; then qemu_status=0; else qemu_status=$?; fi
    else
        "${launch_cmd[@]}" {QEMATE_LOCK_FD}>&- 2>"$qemu_log" || qemu_status=$?
    fi

    log_message "INFO" "QEMU process terminated (exit: $qemu_status)" "$vm_name"

    cleanup_active_vm
    rm -f "$VM_DIR/$vm_name/qemu.pid"
    trap - EXIT

    if [[ $qemu_status -eq 0 ]]; then
        QEMATE_PHASE="stopped"
        log_message "INFO" "VM $vm_name stopped cleanly." "$vm_name"
    else
        QEMATE_PHASE="failed"
        log_message "ERROR" "QEMU exited with error $qemu_status. Check $VM_DIR/$vm_name/logs/error.log" "$vm_name"
        return 1
    fi
}


stop() {
    local vm_name="$1"; shift
    local force="false" timeout_seconds="$DEFAULT_STOP_TIMEOUT"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            --timeout)
                [[ $# -ge 2 && "$2" =~ ^[0-9]+$ && "$2" -ge 1 && "$2" -le 3600 ]] || {
                    log_message "ERROR" "--timeout requires 1-3600 seconds"; return 1; }
                timeout_seconds="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    require_vm "$vm_name" exists || return 1
    if ! vm_is_running "$vm_name"; then
        if vm_lifecycle_busy "$vm_name"; then
            log_message "ERROR" "VM is still starting; retry stop when its control socket is ready" "$vm_name"
        else
            log_message "ERROR" "VM is not running" "$vm_name"
        fi
        return 1
    fi
    local pid=""
    if ! read -r pid < "$VM_DIR/$vm_name/qemu.pid"; then
        log_message "ERROR" "VM process identity changed; refusing to signal it"
        return 1
    fi
    vm_pid_matches "$vm_name" "$pid" || { log_message "ERROR" "VM process identity changed; refusing to signal it"; return 1; }
    log_message "INFO" "Stopping VM: $vm_name" "$vm_name"

    if [[ "$force" == "true" ]]; then
        vm_pid_matches "$vm_name" "$pid" && kill -9 "$pid" || true
        log_message "WARNING" "Force-stopped QEMU; the guest did not receive an orderly shutdown request." "$vm_name"
    else
        qmp_command "$vm_name" system_powerdown || {
            log_message "ERROR" "Graceful shutdown could not be requested. The VM was left running; use --force only if necessary." "$vm_name"
            return 1
        }
        log_message "INFO" "Guest shutdown requested; waiting up to ${timeout_seconds}s..." "$vm_name"
        local i
        for (( i=0; i<timeout_seconds; i++ )); do
            vm_pid_matches "$vm_name" "$pid" || break; sleep 1
        done
        if vm_pid_matches "$vm_name" "$pid"; then
            log_message "ERROR" "Guest did not shut down within ${timeout_seconds}s. It was left running; retry or use --force." "$vm_name"
            return 1
        fi
    fi

    local i
    for (( i=0; i<50; i++ )); do
        vm_pid_matches "$vm_name" "$pid" || break
        sleep 0.1
    done

    # Always attempt auxiliary cleanup so orphaned virtiofsd / swtpm / TAP
    # (e.g. after a hard-killed supervisor) are reclaimed on a normal stop.
    stop_virtiofsd_daemons "$vm_name" 2>/dev/null || true
    stop_tpm               "$vm_name" 2>/dev/null || true
    teardown_tap_interface "$vm_name" 2>/dev/null || true
    restore_group_drivers  "$vm_name" 2>/dev/null || true
    rm -f "$VM_DIR/$vm_name/qemu.pid" 2>/dev/null || true

    log_message "INFO" "VM stopped: $vm_name" "$vm_name"
}

delete() {
    local vm_name="$1"; shift
    local force="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    validate_vm_name "$vm_name" || return 1
    vm_exists "$vm_name"      || { log_message "ERROR" "VM not found"; return 1; }
    vm_is_locked "$vm_name" && [[ "$force" != "true" ]] && {
        log_message "ERROR" "VM is locked. Use --force to override."; return 1; }
    vm_is_running "$vm_name" && {
        log_message "ERROR" "VM is running. Stop it first."; return 1; }
    local operation_fd
    acquire_stopped_vm_lock "$vm_name" operation_fd || return 1

    if [[ "$force" != "true" ]]; then
        read -r -p "Delete VM '$vm_name' and all its data? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
            return 0
        fi
    fi

    # Reclaim any leftover daemons before the directory disappears.
    stop_virtiofsd_daemons "$vm_name" 2>/dev/null || true
    stop_tpm               "$vm_name" 2>/dev/null || true
    teardown_tap_interface "$vm_name" 2>/dev/null || true
    restore_group_drivers  "$vm_name" 2>/dev/null || true

    rm -rf "${VM_DIR:?}/${vm_name:?}"
    release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
    log_message "INFO" "VM deleted: $vm_name"
}

resize_disk() {
    require_qemu_toolchain || return 1
    local vm_name="$1" new_size="$2"

    require_vm "$vm_name" exists unlocked || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1

    if [[ -n "${VM[DISK_DEV]:-}" ]]; then
        log_message "ERROR" "Resize is not supported for physical device VMs (DISK_DEV=${VM[DISK_DEV]})." "$vm_name"
        return 1
    fi

    if vm_is_running "$vm_name"; then
        log_message "ERROR" "Cannot resize while VM is running. Stop the VM first; safe online resize requires QMP support, which is not implemented." "$vm_name"
        return 1
    fi
    local operation_fd
    acquire_stopped_vm_lock "$vm_name" operation_fd || return 1

    [[ ! "$new_size" =~ ^(\+)?[0-9]+[GMgm]$ ]] && {
        log_message "ERROR" "Invalid size: '$new_size'. Use e.g. 80G or +20G" "$vm_name"; return 1; }

    log_message "INFO" "Resizing disk to $new_size..." "$vm_name"
    qemu-img resize "$VM_DIR/$vm_name/disk.qcow2" "$new_size" || {
        log_message "ERROR" "Resize failed." "$vm_name"; return 1; }

    local json bytes_size=""
    json=$(qemu-img info --output=json "$VM_DIR/$vm_name/disk.qcow2")
    if [[ "$json" =~ \"virtual-size\":[[:space:]]*([0-9]+) ]]; then
        bytes_size="${BASH_REMATCH[1]}"
        # Prefer exact GiB when divisible; otherwise store MiB to avoid truncating.
        if (( bytes_size % 1073741824 == 0 )); then
            VM[DISK_SIZE]="$(( bytes_size / 1073741824 ))G"
        else
            VM[DISK_SIZE]="$(( (bytes_size + 1048575) / 1048576 ))M"
        fi
        save_vm_config "$vm_name" VM
        log_message "INFO" "Disk resized to ${VM[DISK_SIZE]}" "$vm_name"
    fi
    release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
}

# configure VM_NAME — Opens the VM config file directly in the editor.
# Do not hold qemu.pid.lock while the editor is open: that made `list` report
# "starting" and blocked start/resize for the whole edit session.
configure() {
    local vm_name="$1"
    require_vm "$vm_name" exists unlocked || return 1

    local config_file="$VM_DIR/$vm_name/config"
    local backup editor="${EDITOR:-}"
    if [[ -z "$editor" ]]; then
        if command -v nano >/dev/null 2>&1; then
            editor="nano"
        elif command -v vim >/dev/null 2>&1; then
            editor="vim"
        elif command -v vi >/dev/null 2>&1; then
            editor="vi"
        else
            log_message "ERROR" "No editor found. Set EDITOR or install nano/vim." "$vm_name"
            return 1
        fi
    elif ! command -v "${editor%% *}" >/dev/null 2>&1; then
        log_message "ERROR" "Editor not found: $editor. Set EDITOR to a valid program." "$vm_name"
        return 1
    fi

    backup="$(mktemp)"
    cp "$config_file" "$backup"

    if ! "$editor" "$config_file"; then
        log_message "ERROR" "Editor exited with an error. Restoring previous config." "$vm_name"
        cp "$backup" "$config_file"
        rm -f "$backup"
        return 1
    fi

    local -A _vtmp=()
    if ! load_vm_config "$vm_name" _vtmp 2>/dev/null; then
        log_message "ERROR" "Syntax validation failed after editing. Restoring previous config." "$vm_name"
        cp "$backup" "$config_file"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    if vm_is_running "$vm_name"; then
        log_message "INFO" "Config saved. The running VM still uses the previous settings until it is restarted." "$vm_name"
    else
        log_message "INFO" "Config applied successfully." "$vm_name"
    fi
}

# =============================================================================
# STATUS & LIST
# =============================================================================

# Lightweight field extraction for list() — avoids full validation/locking.
_list_config_field() {
    local config_file="$1" key="$2" default="${3:-}"
    local line val
    [[ -f "$config_file" ]] || { printf '%s' "$default"; return 0; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            val="${BASH_REMATCH[1]}"
            if [[ "$val" =~ ^\"(.*)\"$ ]]; then
                val=$(unquote_config_value "${BASH_REMATCH[1]}")
            elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
                val="${BASH_REMATCH[1]}"
            fi
            printf '%s' "$val"
            return 0
        fi
    done < "$config_file"
    printf '%s' "$default"
}

list() {
    [[ ! -d "$VM_DIR" ]] && { echo "No VMs found."; return 0; }
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "NAME" "STATUS" "LOCKED" "OS" "AUDIO" "TPM" "SPICE"
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "----" "------" "------" "--" "-----" "---" "-----"

    local vm_path name stat lock os audio tpm spice cfg
    for vm_path in "$VM_DIR"/*/; do
        [[ -d "$vm_path" ]] || continue
        name="${vm_path%/}"
        name="${name##*/}"
        # Skip non-VM directories (e.g. shared cache)
        [[ "$name" == .* ]] && continue
        cfg="$VM_DIR/$name/config"
        [[ -f "$cfg" ]] || continue

        stat="stopped"
        if vm_is_running "$name"; then stat="running"
        elif vm_lifecycle_busy "$name"; then stat="starting"
        fi

        lock="$(_list_config_field "$cfg" LOCKED 0)"
        [[ "$lock" == "1" ]] && lock="yes" || lock="no"
        os="$(_list_config_field "$cfg" OS_TYPE "?")"
        audio="$(_list_config_field "$cfg" ENABLE_AUDIO 0)"
        [[ "$audio" == "1" ]] && audio="on" || audio="off"
        tpm="$(_list_config_field "$cfg" ENABLE_TPM 0)"
        [[ "$tpm" == "1" ]] && tpm="on" || tpm="off"
        spice="$(_list_config_field "$cfg" SPICE_ENABLED 0)"
        [[ "$spice" == "1" ]] && spice="on" || spice="off"

        printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
            "$name" "$stat" "$lock" "$os" "$audio" "$tpm" "$spice"
    done
}

status() {
    local vm_name="$1"
    require_vm "$vm_name" exists || return 1

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1

    local running
    if vm_is_running "$vm_name"; then running="● Running"
    elif vm_lifecycle_busy "$vm_name"; then running="◐ Starting"
    else running="○ Stopped"
    fi
    echo ""
    echo "  VM: $vm_name  [$running]"
    echo "  ─────────────────────────────────────────────"
    printf "  %-16s %s\n" "OS Type:"        "${VM[OS_TYPE]:-?}"
    printf "  %-16s %s\n" "CPU:"            "${VM[CPU_TYPE]} × ${VM[CORES]} cores"
    printf "  %-16s %s\n" "Memory:"         "${VM[MEMORY]}"
    printf "  %-16s %s\n" "Profile:"        "${VM[PERFORMANCE_PROFILE]:-balanced}"
    printf "  %-16s %s\n" "Memory policy:"  "$( [[ "${VM[PERFORMANCE_PROFILE]:-balanced}" == "performance" || "${VM[MEMORY_PREALLOC]:-0}" == "1" ]] && echo "preallocated" || echo "demand-allocated" )"
    printf "  %-16s %s\n" "CPU affinity:"   "${VM[CPU_AFFINITY]:-automatic}"
    local effective_machine
    effective_machine=$(effective_machine_type "${VM[MACHINE_TYPE]}")
    if [[ "$effective_machine" == "${VM[MACHINE_TYPE]}" ]]; then
        printf "  %-16s %s\n" "Machine:" "$effective_machine (${VM[MACHINE_OPTIONS]})"
    else
        printf "  %-16s %s\n" "Machine:" "${VM[MACHINE_TYPE]} → $effective_machine (${VM[MACHINE_OPTIONS]})"
    fi
    printf "  %-16s %s\n" "Video:"          "${VM[VIDEO_TYPE]}"
    printf "  %-16s %s\n" "Disk Interface:" "${VM[DISK_INTERFACE]}"
    printf "  %-16s %s\n" "Disk I/O:"       "${VM[DISK_IO]} / cache=${VM[DISK_CACHE]} / discard=${VM[DISK_DISCARD]}"
    if [[ -n "${VM[DISK_DEV]:-}" ]]; then
        printf "  %-16s %s\n" "Disk Device:"    "${VM[DISK_DEV]} (physical, raw)"
        printf "  %-16s %s\n" "Disk Size:"      "${VM[DISK_SIZE]:-unknown}"
    else
        printf "  %-16s %s\n" "Disk Size:"      "${VM[DISK_SIZE]}"
    fi
    printf "  %-16s %s\n" "Network:"        "${VM[NETWORK_TYPE]} / ${VM[NETWORK_MODEL]}"
    printf "  %-16s %s\n" "UEFI:"           "$( [[ "${VM[ENABLE_UEFI]:-0}" == "1" ]] && echo "enabled" || echo "disabled (SeaBIOS)" )"
    local effective_share; effective_share=$(resolve_share_backend VM)
    printf "  %-16s %s\n" "Share backend:"  "${VM[SHARE_BACKEND]:-auto} (effective: $effective_share)"
    printf "  %-16s %s\n" "Security:" "$( [[ "${VM[LOCKED]:-0}" == "1" ]] && echo "locked" || echo "unlocked" )"

    [[ -n "${VM[PORT_FORWARDS]:-}" ]] && printf "  %-16s %s\n" "Port forwards:" "${VM[PORT_FORWARDS]}"

    if [[ -n "${VM[USB_DEVICES]:-}" ]]; then
        echo "  USB passthrough:"
        local usb_arr=(); split_list "${VM[USB_DEVICES]}" usb_arr
        local dev; for dev in "${usb_arr[@]}"; do printf "    • %s\n" "$dev"; done
    fi

    if [[ -n "${VM[SHARED_FOLDERS]:-}" ]]; then
        echo "  Shared folders:"
        local sh_arr=(); split_list "${VM[SHARED_FOLDERS]}" sh_arr
        local s
        for s in "${sh_arr[@]}"; do
            printf "    • %-15s → %s\n" "${s%%:*}" "${s#*:}"
        done
    fi
    echo ""
}

lock_unlock() {
    local vm_name="$1" state="$2"
    require_vm "$vm_name" exists || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    VM[LOCKED]="$state"
    save_vm_config "$vm_name" VM
    log_message "INFO" "VM $vm_name $( [[ "$state" == "1" ]] && echo "locked" || echo "unlocked" )"
}

tune_vm() {
    local vm_name="$1" profile="$2"
    [[ "$profile" =~ ^(balanced|performance)$ ]] || {
        log_message "ERROR" "Invalid profile: '$profile'. Use: balanced, performance"; return 1; }
    require_vm "$vm_name" exists unlocked || return 1
    local operation_fd
    acquire_stopped_vm_lock "$vm_name" operation_fd || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    [[ "$profile" != "performance" ]] || validate_performance_memory "$vm_name" "${VM[MEMORY]}" || return 1
    VM[PERFORMANCE_PROFILE]="$profile"
    save_vm_config "$vm_name" VM || return 1
    release_flock operation_fd "$VM_DIR/$vm_name/qemu.pid.lock"
    log_message "INFO" "VM $vm_name tuned for profile: $profile" "$vm_name"
}

doctor_item() {
    local state="$1" message="$2"
    printf "  [%-4s] %s\n" "$state" "$message"
}

doctor_qemu_command() {
    local command_name="$1" major version_output first_line
    if ! command -v "$command_name" >/dev/null 2>&1; then
        doctor_item FAIL "$command_name is not installed"
        return 1
    fi
    major=$(qemu_major_version "$command_name") || {
        doctor_item FAIL "could not determine $command_name version (QEMU ${MIN_QEMU_VERSION}+ required)"
        return 1
    }
    version_output=$("$command_name" --version 2>/dev/null)
    first_line="${version_output%%$'\n'*}"
    if (( major < MIN_QEMU_MAJOR )); then
        doctor_item FAIL "$first_line (QEMU ${MIN_QEMU_VERSION}+ required)"
        return 1
    fi
    doctor_item OK "$first_line"
}

qemu_machine_available() {
    local wanted="$1" machine _
    while read -r machine _; do
        [[ "$machine" == "$wanted" ]] && return 0
    done < <(qemu-system-x86_64 -machine help 2>/dev/null)
    return 1
}

doctor() {
    local vm_name="${1:-}" failures=0
    echo "qemate host diagnostics"
    echo "────────────────────────────────────────────────────────"

    doctor_qemu_command qemu-system-x86_64 || failures=1
    doctor_qemu_command qemu-img || failures=1
    [[ -r /dev/kvm && -w /dev/kvm ]] && doctor_item OK "KVM acceleration is accessible" || doctor_item WARN "/dev/kvm is not accessible"
    if have_unix_nc; then doctor_item OK "QMP client available (nc -U)"
    else doctor_item FAIL "OpenBSD netcat with nc -U is required for graceful stop"; failures=1
    fi
    [[ -r /dev/vhost-net && -w /dev/vhost-net ]] && doctor_item OK "vhost-net acceleration is accessible" || doctor_item INFO "vhost-net unavailable; relevant only to TAP networking"
    if [[ -r /sys/module/kvm_amd/parameters/avic ]]; then
        local avic; avic=$(< /sys/module/kvm_amd/parameters/avic)
        [[ "$avic" == "Y" ]] && doctor_item OK "AMD AVIC is active" || doctor_item INFO "AMD AVIC is disabled"
    fi
    doctor_item INFO "memlock limit: $(ulimit -l) KiB"

    [[ -z "$vm_name" ]] && return "$failures"
    echo ""
    echo "VM diagnostics: $vm_name"
    require_vm "$vm_name" exists || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    doctor_item INFO "profile=${VM[PERFORMANCE_PROFILE]:-balanced}, vCPUs=${VM[CORES]}, memory=${VM[MEMORY]}"
    local configured_machine="${VM[MACHINE_TYPE]}" effective_machine
    effective_machine=$(effective_machine_type "$configured_machine")
    doctor_item INFO "machine=${configured_machine} (effective: ${effective_machine})"
    if qemu_machine_available "$effective_machine"; then
        doctor_item OK "QEMU provides machine type: $effective_machine"
    else
        doctor_item FAIL "QEMU does not provide machine type: $effective_machine"
        failures=1
    fi
    doctor_item INFO "disk=${VM[DISK_INTERFACE]}, aio=${VM[DISK_IO]}, cache=${VM[DISK_CACHE]}"
    if [[ "${VM[DISK_IO]}" == "io_uring" && -r /proc/sys/kernel/io_uring_disabled ]]; then
        local io_uring_disabled
        io_uring_disabled=$(< /proc/sys/kernel/io_uring_disabled)
        if [[ "$io_uring_disabled" == "0" ]]; then
            doctor_item OK "kernel io_uring is enabled"
        else
            doctor_item WARN "kernel io_uring is restricted (io_uring_disabled=$io_uring_disabled)"
        fi
    fi
    if [[ "${VM[DISK_INTERFACE]}" == "virtio" && "${VM[OS_TYPE]:-linux}" != "macos" ]]; then
        local virtio_queues="${VM[CORES]}" disk_iothreads=1
        (( virtio_queues > 8 )) && virtio_queues=8
        if [[ "${VM[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
            disk_iothreads="$virtio_queues"
            (( disk_iothreads > 4 )) && disk_iothreads=4
        fi
        doctor_item INFO "VirtIO block: queues=$virtio_queues, IOThreads=$disk_iothreads, packed=on, in_order=on"
    fi
    if [[ "${VM[NETWORK_TYPE]}" != "none" &&
          "${VM[NETWORK_MODEL]}" == "virtio-net-pci" &&
          "${VM[ENABLE_VIRTIO]:-1}" == "1" &&
          "${VM[OS_TYPE]:-linux}" != "macos" ]]; then
        local net_features="packed=on, in_order=on"
        if [[ "${VM[NETWORK_TYPE]}" == "tap" && "${VM[CORES]}" -ge 4 ]]; then
            if [[ -r /dev/vhost-net && -w /dev/vhost-net ]]; then
                net_features+=", RSS=on, hash=off (vhost-net)"
            else
                net_features+=", RSS/hash=on (QEMU userspace)"
            fi
        fi
        doctor_item INFO "VirtIO network: $net_features"
    fi
    local backend; backend=$(resolve_share_backend VM)
    doctor_item INFO "share backend: ${VM[SHARE_BACKEND]:-auto} (effective: $backend)"
    [[ "$backend" != "virtfs" ]] || doctor_item WARN "VirtFS/9p favors compatibility over shared-folder performance"
    if [[ -n "${VM[DISK_DEV]:-}" && "${VM[DISK_INTERFACE]}" == "virtio" && "${VM[DISK_IO]}" == "io_uring" && "${VM[DISK_CACHE]}" == "none" ]]; then
        doctor_item OK "physical disk uses the direct VirtIO/io_uring fast path"
    fi
    if [[ "${VM[PERFORMANCE_PROFILE]:-balanced}" == "performance" ]]; then
        if validate_performance_memory "$vm_name" "${VM[MEMORY]}"; then
            doctor_item OK "locked-memory prerequisites satisfied"
        else
            failures=1
        fi
    else
        doctor_item INFO "performance profile is available via: qemate tune $vm_name performance"
    fi
    [[ -z "${VM[CPU_AFFINITY]:-}" ]] && doctor_item INFO "CPU affinity is automatic (no host cores are reserved)"
    if vm_is_running "$vm_name"; then
        [[ -S "$VM_DIR/$vm_name/sockets/qmp.sock" ]] && doctor_item OK "QMP control socket is ready" || doctor_item WARN "running VM has no QMP control socket"
    fi
    if [[ -n "${VM[PORT_FORWARDS]:-}" ]]; then
        local fwds=() fwd
        split_list "${VM[PORT_FORWARDS]}" fwds
        for fwd in "${fwds[@]}"; do
            if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                local hport="${BASH_REMATCH[3]}" proto="${BASH_REMATCH[5]}"
                if host_port_in_use "$hport" "$proto"; then
                    if vm_is_running "$vm_name"; then
                        doctor_item INFO "host port ${hport}/${proto} is in use (expected while VM is running)"
                    else
                        doctor_item WARN "host port ${hport}/${proto} is already in use (port-forward will fail at start)"
                        failures=1
                    fi
                else
                    doctor_item OK "host port ${hport}/${proto} is free"
                fi
            fi
        done
    fi
    return "$failures"
}

# =============================================================================
# LOGS / RESTART / WAIT / CONSOLE / CLONE
# =============================================================================

logs() {
    local vm_name="$1"; shift
    local follow="0" which="qemate" lines=80
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow) follow="1"; shift ;;
            --qemu) which="qemu"; shift ;;
            --supervisor) which="supervisor"; shift ;;
            --qemate) which="qemate"; shift ;;
            -n|--lines) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { log_message "ERROR" "--lines requires a number"; return 1; }
                        lines="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    require_vm "$vm_name" exists || return 1
    local log_dir="$VM_DIR/$vm_name/logs" target=""
    case "$which" in
        qemate) target="$log_dir/qemate.log" ;;
        qemu)
            if [[ -L "$log_dir/error.log" ]]; then
                target="$log_dir/$(readlink "$log_dir/error.log")"
            else
                target=$(ls -1t "$log_dir"/qemu-*.log 2>/dev/null | head -1)
            fi
            ;;
        supervisor)
            target=$(ls -1t "$log_dir"/supervisor-*.log 2>/dev/null | head -1)
            ;;
    esac
    [[ -n "$target" && -f "$target" ]] || {
        log_message "ERROR" "No $which log found for: $vm_name" "$vm_name"; return 1; }
    if [[ "$follow" == "1" ]]; then
        tail -n "$lines" -f "$target"
    else
        tail -n "$lines" "$target"
    fi
}

wait_for_vm() {
    local vm_name="$1"; shift
    local timeout_seconds=120 state="running"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --timeout) [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || { log_message "ERROR" "--timeout requires seconds"; return 1; }
                       timeout_seconds="$2"; shift 2 ;;
            --state) [[ $# -ge 2 ]] || { log_message "ERROR" "--state requires a value"; return 1; }
                     state="$2"; shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    require_vm "$vm_name" exists || return 1
    local i
    case "$state" in
        running|ready)
            for (( i=0; i<timeout_seconds*10; i++ )); do
                if vm_is_running "$vm_name" && qmp_is_ready "$vm_name"; then
                    log_message "INFO" "VM $vm_name is ready (QMP running)." "$vm_name"
                    return 0
                fi
                sleep 0.1
            done
            log_message "ERROR" "Timed out waiting for VM $vm_name to become ready" "$vm_name"
            return 1
            ;;
        stopped)
            for (( i=0; i<timeout_seconds*10; i++ )); do
                if ! vm_is_running "$vm_name" && ! vm_lifecycle_busy "$vm_name"; then
                    log_message "INFO" "VM $vm_name is stopped." "$vm_name"
                    return 0
                fi
                sleep 0.1
            done
            log_message "ERROR" "Timed out waiting for VM $vm_name to stop" "$vm_name"
            return 1
            ;;
        *) log_message "ERROR" "Unknown wait state: $state (use running|ready|stopped)"; return 1 ;;
    esac
}

restart() {
    local vm_name="$1"; shift
    local -a start_args=() stop_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force|--timeout) stop_args+=("$1"); [[ "$1" == "--timeout" && $# -ge 2 ]] && { stop_args+=("$2"); shift; }; shift ;;
            --headless|--detach|--debug|--dry-run) start_args+=("$1"); shift ;;
            --iso|--virtio-iso) [[ $# -ge 2 ]] || { log_message "ERROR" "$1 requires a path"; return 1; }
                               start_args+=("$1" "$2"); shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    require_vm "$vm_name" exists || return 1
    if vm_is_running "$vm_name" || vm_lifecycle_busy "$vm_name"; then
        stop "$vm_name" "${stop_args[@]}" || return 1
        wait_for_vm "$vm_name" --state stopped --timeout "${DEFAULT_STOP_TIMEOUT}" || return 1
    fi
    # Brief settle for TAP/virtiofsd teardown
    sleep 0.3
    start "$vm_name" "${start_args[@]}"
}

console() {
    local vm_name="$1"; shift
    local mode="qmp"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --qmp) mode="qmp"; shift ;;
            --monitor) mode="monitor"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    require_vm "$vm_name" exists running || return 1
    have_unix_nc || {
        log_message "ERROR" "OpenBSD netcat with Unix-socket support (nc -U) is required" "$vm_name"
        return 1
    }
    local socket="$VM_DIR/$vm_name/sockets/qmp.sock"
    [[ -S "$socket" ]] || {
        log_message "ERROR" "QMP socket not available: $socket" "$vm_name"; return 1; }
    if [[ "$mode" == "qmp" ]]; then
        log_message "INFO" "Interactive QMP session (Ctrl-C to exit). Capabilities negotiated on connect." "$vm_name"
        {
            printf '%s\n' '{"execute":"qmp_capabilities"}'
            cat
        } | nc -U -N "$socket"
    else
        log_message "ERROR" "HMP monitor socket is not exposed by qemate; use --qmp" "$vm_name"
        return 1
    fi
}

clone_vm() {
    require_qemu_toolchain || return 1
    local src="$1" dst="$2"; shift 2
    local full_copy="0"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --full) full_copy="1"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done
    require_vm "$src" exists unlocked not-running || return 1
    validate_vm_name "$dst" || return 1
    vm_exists "$dst" && { log_message "ERROR" "Destination VM already exists: $dst"; return 1; }

    local -A VM=()
    load_vm_config "$src" VM || return 1
    [[ -n "${VM[DISK_DEV]:-}" ]] && {
        log_message "ERROR" "Cannot clone a VM that uses a physical disk device"; return 1; }

    # Assigned indirectly by acquire_stopped_vm_lock through a nameref.
    # shellcheck disable=SC2034
    local src_fd
    acquire_stopped_vm_lock "$src" src_fd || return 1

    mkdir -p "$VM_DIR/$dst" "$VM_DIR/$dst/logs" "$VM_DIR/$dst/sockets" "$VM_DIR/$dst/tpm" || {
        release_flock src_fd "$VM_DIR/$src/qemu.pid.lock"
        log_message "ERROR" "Failed to create destination directories"; return 1; }
    chmod 700 "$VM_DIR/$dst" "$VM_DIR/$dst/logs" "$VM_DIR/$dst/sockets" "$VM_DIR/$dst/tpm"

    VM[NAME]="$dst"
    VM[MAC_ADDRESS]=$(generate_mac_address "$dst")
    VM[LOCKED]="0"
    # Do not copy live install media state blindly for macOS; user can re-attach.
    save_vm_config "$dst" VM || {
        rm -rf "${VM_DIR:?}/${dst:?}"
        release_flock src_fd "$VM_DIR/$src/qemu.pid.lock"
        return 1
    }

    local src_disk="$VM_DIR/$src/disk.qcow2" dst_disk="$VM_DIR/$dst/disk.qcow2"
    if [[ -f "$src_disk" ]]; then
        if [[ "$full_copy" == "1" ]]; then
            qemu-img convert -O qcow2 "$src_disk" "$dst_disk" || {
                log_message "ERROR" "Failed to copy disk image"; rm -rf "${VM_DIR:?}/${dst:?}"
                release_flock src_fd "$VM_DIR/$src/qemu.pid.lock"; return 1; }
        else
            # Backing-file clone: cheap, shares unchanged clusters with the source.
            qemu-img create -f qcow2 -b "$src_disk" -F qcow2 "$dst_disk" || {
                log_message "ERROR" "Failed to create linked clone disk"; rm -rf "${VM_DIR:?}/${dst:?}"
                release_flock src_fd "$VM_DIR/$src/qemu.pid.lock"; return 1; }
        fi
        chmod 600 "$dst_disk"
        if [[ "$full_copy" != "1" ]]; then
            log_message "WARNING" "Linked clone: '$dst' shares unchanged clusters with '$src'. Deleting or shrinking the source disk will break the clone. Use --full for an independent copy." "$dst"
        fi
    fi

    if [[ -d "$VM_DIR/$src/tpm" ]]; then
        mkdir -p "$VM_DIR/$dst/tpm"
        cp -a "$VM_DIR/$src/tpm/." "$VM_DIR/$dst/tpm/" 2>/dev/null || \
            log_message "WARNING" "Could not copy TPM state; the clone will initialise a new TPM." "$dst"
        chmod 700 "$VM_DIR/$dst/tpm" 2>/dev/null || true
    fi

    # Copy UEFI vars if present
    [[ -f "$VM_DIR/$src/OVMF_VARS.fd" ]] && cp -n "$VM_DIR/$src/OVMF_VARS.fd" "$VM_DIR/$dst/OVMF_VARS.fd" 2>/dev/null || true
    [[ -f "$VM_DIR/$src/OVMF_VARS-macos.fd" ]] && cp -n "$VM_DIR/$src/OVMF_VARS-macos.fd" "$VM_DIR/$dst/OVMF_VARS-macos.fd" 2>/dev/null || true
    chmod 600 "$VM_DIR/$dst"/OVMF_VARS*.fd 2>/dev/null || true

    # macOS: copy permanent boot assets (OpenCore + 4M OVMF). Do not copy the
    # temporary OSX-KVM checkout or recovery BaseSystem media — those are
    # re-created by macos-install / macos-recovery when needed.
    if [[ "${VM[OS_TYPE]:-}" == "macos" ]]; then
        local src_macos="$VM_DIR/$src/macos" dst_macos="$VM_DIR/$dst/macos"
        if [[ -d "$src_macos/assets" ]]; then
            mkdir -p "$dst_macos/assets"
            cp -n "$src_macos/assets/"* "$dst_macos/assets/" 2>/dev/null || true
            chmod 600 "$dst_macos/assets/"* 2>/dev/null || true
            chmod 700 "$dst_macos" "$dst_macos/assets" 2>/dev/null || true
        fi
        # Preserve version metadata for macos-doctor when present.
        [[ -f "$src_macos/version" ]] && cp -n "$src_macos/version" "$dst_macos/version" 2>/dev/null || true
        [[ -f "$src_macos/osx-kvm-commit" ]] && cp -n "$src_macos/osx-kvm-commit" "$dst_macos/osx-kvm-commit" 2>/dev/null || true
        chmod 600 "$dst_macos/version" "$dst_macos/osx-kvm-commit" 2>/dev/null || true
    fi

    release_flock src_fd "$VM_DIR/$src/qemu.pid.lock"
    log_message "INFO" "Cloned '$src' → '$dst' ($( [[ "$full_copy" == "1" ]] && echo full || echo linked ) disk)" "$dst"
}

# =============================================================================
# CLI / HELP
# =============================================================================

display_help() {
    cat <<EOF
qemate v${VERSION} — QEMU VM Manager
────────────────────────────────────────────────────────────────────────

USAGE
  qemate <command> [vm] [options] [--help]

VM
  create <name> [options]
      --os-type linux|windows|macos    (default: linux)
      --memory SIZE                  e.g. 4G, 8G
      --cores N                      vCPU count
      --disk-size SIZE               e.g. 60G  (qcow2 image; default)
      --disk-dev PATH                e.g. /dev/sdb, /dev/sdb1  (raw physical partition)
      --machine TYPE[,accel=kvm|tcg] (default: pc-q35-11.0,accel=kvm)
      --enable-audio | --no-audio     emulated HDA; set AUDIO_PASSTHROUGH_PCI for VFIO
      --enable-tpm   | --no-tpm        (default: on for windows)
      --uefi         | --no-uefi        (default: on for windows, off for linux)
      --spice        | --no-spice
      --share-backend auto|virtfs|smb|virtiofs
      --profile balanced|performance

  start   <name> [--headless] [--detach] [--iso PATH] [--virtio-iso PATH] [--debug] [--dry-run]
  stop    <name> [--timeout SECONDS] [--force]
  restart <name> [stop/start options]
  wait    <name> [--timeout SECONDS] [--state running|ready|stopped]
  console <name> [--qmp]
  logs    <name> [-f] [-n N] [--qemate|--qemu|--supervisor]
  clone   <src> <dst> [--full]
  delete  <name> [--force]
  resize  <name> <SIZE|+SIZE>             VM must be stopped
  list
  status  <name>
  config  <name>     edit VM config in \$EDITOR
  tune    <name> balanced|performance
  doctor  [name]

MACOS
  macos-install  <name> [--version VERSION] [--no-start] [--refresh]
      Prepare an Apple recovery installer via kholia/OSX-KVM. If --version is
      omitted, select from an interactive version list. Starts by default.
  macos-eject    <name>
      Detach recovery media after installation; next boot uses the installed disk.
      Also removes the temporary OSX-KVM checkout and recovery download artifacts.
  macos-recovery <name>
      Re-attach recovery media (re-downloads if previously cleaned up by eject).
  macos-boot     <name> [--resolution WIDTHxHEIGHT] [--timeout SECONDS]
      Configure normal OpenCore boot (default: 1920x1080, five-second picker).
  macos-verbose  <name> on|off
      Toggle verbose macOS boot output while preserving other OpenCore boot arguments.
  macos-vmhide   <name> install|remove|status
      Manage the opt-in VMHide and Lilu OpenCore kexts for an installed VM.
  macos-efi-restore <name> <backup-file>
      Restore a named OpenCore image from macos/backups/.
  macos-refresh  <name>
      Update (or re-clone) the VM's isolated OSX-KVM checkout.
  macos-doctor   <name>
      Validate OpenCore/OVMF/recovery assets, KVM and QEMU macOS devices.

NETWORK
  port-add    <name> <[ip:]host:guest[:tcp|udp]>
  port-remove <name> <[ip:]host:guest[:tcp|udp]>

USB
  usb-list   <name>
  usb-add    <name> <vendor:product>
  usb-remove <name> <vendor:product>

SHARES
  share-list   <name>
  share-add    <name> [tag:]/host/path
  share-remove <name> <tag>

SECURITY
  lock   <name>     block start, resize, delete, and config edits
  unlock <name>

EOF
}

# =============================================================================
# MAIN ENTRYPOINT
# =============================================================================

main() {
    local arg
    for arg in "$@"; do
        [[ "$arg" == "--help" || "$arg" == "-h" ]] && { display_help; exit 0; }
    done

    [[ $# -eq 0 ]] && { display_help; exit 0; }

    mkdir -p "$VM_DIR"
    chmod 700 "$VM_DIR"
    [[ "$1" == "doctor" ]] || require_commands flock

    local verb="$1"; shift
    case "$verb" in
        create)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; create      "$@" ;;
        macos-install) [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; install_macos "$@" ;;
        macos-eject)   [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; macos_finalize_install "$@" ;;
        macos-recovery) [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; macos_recovery_attach "$@" ;;
        macos-boot)    [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; macos_boot_configure "$@" ;;
        macos-verbose) [[ $# -ne 2 ]] && { echo "Error: Usage: macos-verbose <name> on|off"; exit 1; }; macos_verbose_configure "$@" ;;
        macos-vmhide)  [[ $# -lt 2 ]] && { echo "Error: VM name and action required"; exit 1; }; macos_vmhide "$@" ;;
        macos-efi-restore) [[ $# -ne 2 ]] && { echo "Error: VM name and backup file required"; exit 1; }; macos_efi_restore "$@" ;;
        macos-refresh) [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; macos_refresh_repo "$@" ;;
        macos-doctor)  [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; macos_doctor "$@" ;;
        start)         [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; start       "$@" ;;
        stop)          [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; stop        "$@" ;;
        restart)       [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; restart     "$@" ;;
        wait)          [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; wait_for_vm "$@" ;;
        console)       [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; console     "$@" ;;
        logs)          [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; logs        "$@" ;;
        clone)         [[ $# -lt 2 ]] && { echo "Error: source and destination VM names required"; exit 1; }; clone_vm "$@" ;;
        delete)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; delete      "$@" ;;
        resize)        [[ $# -lt 2 ]] && { echo "Error: VM name and size required"; exit 1; }; resize_disk "$@" ;;
        status)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; status      "$@" ;;
        tune)          [[ $# -lt 2 ]] && { echo "Error: VM name and profile required"; exit 1; }; tune_vm "$1" "$2" ;;
        doctor)        doctor "${1:-}" ;;
        configure|config) [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; configure   "$@" ;;
        list)          list ;;
        port-add)      [[ $# -lt 2 ]] && { echo "Error: VM name and port spec required"; exit 1; }
                       manage_network_ports "$1" "add"    "$2" ;;
        port-remove)   [[ $# -lt 2 ]] && { echo "Error: VM name and port spec required"; exit 1; }
                       manage_network_ports "$1" "remove" "$2" ;;
        usb-list)      [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; manage_usb "$1" "list" ;;
        usb-add)       [[ $# -lt 2 ]] && { echo "Error: VM name and vendor:product required"; exit 1; }
                       manage_usb "$1" "add"    "$2" ;;
        usb-remove)    [[ $# -lt 2 ]] && { echo "Error: VM name and vendor:product required"; exit 1; }
                       manage_usb "$1" "remove" "$2" ;;
        share-list)    [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; manage_shares "$1" "list" ;;
        share-add)     [[ $# -lt 2 ]] && { echo "Error: VM name and path required"; exit 1; }
                       manage_shares "$1" "add"    "$2" ;;
        share-remove)  [[ $# -lt 2 ]] && { echo "Error: VM name and share tag required"; exit 1; }
                       manage_shares "$1" "remove" "$2" ;;
        lock)          [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; lock_unlock "$1" "1" ;;
        unlock)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; lock_unlock "$1" "0" ;;
        *)             display_help; exit 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
