#!/bin/bash
# =============================================================================
# qemate — Streamlined QEMU Virtual Machine Management Utility
#
# VERSION:  4.2.1
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

readonly VM_DIR="${QEMATE_VM_DIR:-$HOME/QVMs}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Linux defaults: high-performance VirtIO stack.
declare -A LINUX_DEFAULTS=(
    [CORES]=2
    [MEMORY]="2G"
    [DISK_SIZE]=40G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=virtio-net-pci
    [DISK_INTERFACE]=virtio
    [ENABLE_AUDIO]=0
    [AUDIO_PASSTHROUGH_PCI]=0
    [CPU_TYPE]=host
    [MACHINE_TYPE]=q35
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
)

# Windows defaults: NVMe disk, Hyper-V enlightenments, SMB shares.
declare -A WINDOWS_DEFAULTS=(
    [CORES]=4
    [MEMORY]="4G"
    [DISK_SIZE]=60G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=virtio-net-pci
    [DISK_INTERFACE]=nvme
    [ENABLE_AUDIO]=0
    [AUDIO_PASSTHROUGH_PCI]=0
    [CPU_TYPE]=host
    [MACHINE_TYPE]=q35
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
    [ENABLE_UEFI]=1
)
# =============================================================================

declare -g QEMATE_ACTIVE_VM=""
declare -g QEMATE_PHASE=""

# Clean up orphaned daemons and lock files when interrupted during launch.
cleanup_on_signal() {
    local exit_code=$?
    if [[ "$QEMATE_PHASE" == "starting" && -n "$QEMATE_ACTIVE_VM" ]]; then
        log_message "WARNING" "Launch interrupted. Cleaning up: $QEMATE_ACTIVE_VM"
        stop_virtiofsd_daemons  "$QEMATE_ACTIVE_VM" 2>/dev/null
        stop_tpm                "$QEMATE_ACTIVE_VM" 2>/dev/null
        teardown_tap_interface  "$QEMATE_ACTIVE_VM" 2>/dev/null
        rm -f "${VM_DIR:?}/${QEMATE_ACTIVE_VM:?}/qemu.pid.lock" 2>/dev/null
    fi
    exit "$exit_code"
}

trap cleanup_on_signal INT TERM

# =============================================================================
# LOGGING
# =============================================================================

# log_message LEVEL MESSAGE [VM_NAME]
# Levels: DEBUG < INFO < WARNING < ERROR (default LOG_LEVEL=INFO)
# Set LOG_LEVEL=DEBUG to see all output; ERROR to see only errors.
log_message() {
    local level="${1:-INFO}"
    local message="${2:-}"
    local vm_name="${3:-}"

    local -A _rank=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)
    local msg_rank="${_rank[$level]:-1}"
    local min_rank="${_rank[${LOG_LEVEL:-INFO}]:-1}"

    if (( msg_rank >= min_rank )); then
        echo "[${level}] ${message}"
        if [[ -n "$vm_name" && -d "$VM_DIR/$vm_name/logs" ]]; then
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
    [[ -f "$pidfile" ]] || return 1

    local pid
    read -r pid < "$pidfile"
    if kill -0 "$pid" 2>/dev/null; then
        local cmdline
        # /proc/PID/cmdline separates arguments with NUL bytes.
        # read -d '' stops at the first NUL, returning only argv[0].
        # tr replaces all NULs with spaces so the full argument list is searchable.
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null) || true
        [[ "$cmdline" == *"process=${vm_name}"* ]] && return 0
    fi

    local lockfile="$pidfile.lock" _fd
    if acquire_flock "$lockfile" _fd; then
        log_message "WARNING" "Removing stale PID file for VM: $vm_name" "$vm_name"
        rm -f "$pidfile"
        release_flock _fd "$lockfile"
    fi
    return 1
}

vm_is_locked() {
    local config_file="$VM_DIR/$1/config"
    [[ -f "$config_file" ]] && grep -q '^LOCKED="1"' "$config_file"
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

release_flock() {
    local -n _rf_fd="$1"
    local lockfile="$2"
    flock -u "$_rf_fd"
    exec {_rf_fd}>&-
    rm -f "$lockfile"
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

apply_os_defaults() {
    local os_type="$1"
    local -n _vm="$2"
    local -n _src
    [[ "$os_type" == "windows" ]] && _src=WINDOWS_DEFAULTS || _src=LINUX_DEFAULTS
    local key
    for key in "${!_src[@]}"; do
        _vm[$key]="${_src[$key]}"
    done
}

# =============================================================================
# CONFIGURATION I/O
# =============================================================================

readonly -a CONFIG_KEYS=(
    NAME OS_TYPE MACHINE_TYPE MACHINE_OPTIONS
    CORES MEMORY CPU_TYPE
    NETWORK_TYPE NETWORK_MODEL BRIDGE_NAME MAC_ADDRESS
    PORT_FORWARDING_ENABLED PORT_FORWARDS
    VIDEO_TYPE VRAM_SIZE_MB
    DISK_INTERFACE DISK_CACHE DISK_IO DISK_DISCARD DISK_SIZE DISK_DEV
    ENABLE_VIRTIO MEMORY_PREALLOC MEMORY_SHARE
    ENABLE_AUDIO AUDIO_PASSTHROUGH_PCI
    USB_DEVICES SHARED_FOLDERS SHARE_BACKEND
    ENABLE_TPM SPICE_ENABLED SPICE_PORT ENABLE_UEFI
    LOCKED
)

load_vm_config() {
    local vm_name="$1"
    local -n _lvc_vm="$2"
    local config_file="$VM_DIR/$vm_name/config"

    [[ ! -f "$config_file" ]] && {
        log_message "ERROR" "Config not found for: $vm_name" "$vm_name"; return 1; }

    # Security check using pure stat format
    local owner perms
    read -r owner perms < <(stat -c "%U %a" "$config_file")
    [[ "$owner" != "$USER" ]] && {
        log_message "ERROR" "Security: config not owned by $USER" "$vm_name"; return 1; }
    [[ "$perms" =~ [2367]$ ]] && {
        log_message "WARNING" "Config is world-writable. Hardening to 600." "$vm_name"
        chmod 600 "$config_file"
    }

    local -A allowed=()
    local k; for k in "${CONFIG_KEYS[@]}"; do allowed[$k]=1; done

    local _fd
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

    local line line_num=0 _key _val
    while IFS= read -r line || [[ -n "$line" ]]; do
        (( line_num++ ))
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue

        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
            _key="${BASH_REMATCH[1]}"
            _val="${BASH_REMATCH[2]}"
            if [[ "$_val" =~ ^\"(.*)\"$ ]] || [[ "$_val" =~ ^\'(.*)\'$ ]]; then
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

    release_flock _fd "$config_file.lock"
}

save_vm_config() {
    local vm_name="$1"
    local -n _svc_vm="$2"
    local config_file="$VM_DIR/$vm_name/config"

    local _fd
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

    local tmp
    tmp="$(mktemp "$config_file.XXXXXX")"
    local key
    for key in "${CONFIG_KEYS[@]}"; do
        case "$key" in
            MAC_ADDRESS) printf '%s="%s"\n' "$key" "${_svc_vm[$key]:-$(generate_mac_address "$vm_name")}" ;;
            MACHINE_OPTIONS) printf '%s="%s"\n' "$key" "${_svc_vm[$key]:-accel=kvm}" ;;
            *)           printf '%s="%s"\n' "$key" "${_svc_vm[$key]:-}" ;;
        esac
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

    if [[ "${_deps_vm[ENABLE_UEFI]:-0}" == "1" ]]; then
        local _c="" _v=""
        find_ovmf _c _v || missing+=("edk2-ovmf (OVMF firmware not found; install with: sudo pacman -S edk2-ovmf)")
    fi

    if [[ "${_deps_vm[ENABLE_TPM]:-0}" == "1" ]]; then
        command -v swtpm       >/dev/null || missing+=("swtpm")
        command -v swtpm_setup >/dev/null || missing+=("swtpm_setup (swtpm-tools)")
    fi

    local backend
    backend=$(resolve_share_backend _deps_vm)
    if [[ "$backend" == "virtiofs" ]]; then
        have_virtiofsd || missing+=("virtiofsd")
    elif [[ "$backend" == "smb" ]]; then
        command -v smbd >/dev/null || missing+=("smbd (samba)")
    fi

    if [[ "${_deps_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        qemu-system-x86_64 -display help 2>/dev/null | grep -q "spice" || \
            log_message "WARNING" "QEMU may not be compiled with SPICE support." "$vm_name"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Pre-flight failed. Missing: ${missing[*]}" "$vm_name"
        return 1
    fi
}

# =============================================================================
# NETWORK UTILS
# =============================================================================

setup_tap_interface() {
    local vm_name="$1"
    local -n _sti_vm="$2"
    local tap_name="qtap-${vm_name:0:10}"
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
    local tap_name="qtap-${vm_name:0:10}"
    if ip link show "$tap_name" &>/dev/null; then
        ip link set "$tap_name" down       2>/dev/null || true
        ip tuntap del dev "$tap_name" mode tap 2>/dev/null || true
        log_message "INFO" "TAP '$tap_name' removed." "$vm_name"
    fi
}

parse_port_spec() {
    local port_spec="$1" vm_name="$2"
    local -n out_spec="$3"
    if [[ "$port_spec" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+)(:(tcp|udp))?$ ]]; then
        local ip="${BASH_REMATCH[2]:-}"
        local host_port="${BASH_REMATCH[3]}"
        local guest_port="${BASH_REMATCH[4]}"
        local proto="${BASH_REMATCH[6]:-tcp}"
        if [[ -n "$ip" ]]; then out_spec="${ip}:${host_port}:${guest_port}:${proto}"
        else                    out_spec="${host_port}:${guest_port}:${proto}"
        fi
        return 0
    fi
    log_message "ERROR" "Invalid port format: '$port_spec'. Use [IP:]HOST:GUEST[:PROTO]" "$vm_name"
    return 1
}

manage_network_ports() {
    local vm_name="$1" action="$2" port_spec="${3:-}"
    require_vm "$vm_name" exists unlocked || return 1
    vm_is_running "$vm_name" && { log_message "ERROR" "Cannot modify ports while running"; return 1; }

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
            new_array+=("$normalized")
            VM[PORT_FORWARDING_ENABLED]=1
            log_message "INFO" "Added port forwarding: $normalized" "$vm_name" ;;
        remove)
            for p in "${port_array[@]}"; do
                [[ "$p" != "$normalized" ]] && new_array+=("$p") || found=1
            done
            [[ $found -eq 0 ]] && {
                log_message "WARNING" "Port rule not found: $normalized" "$vm_name"; return 1; }
            [[ ${#new_array[@]} -eq 0 ]] && VM[PORT_FORWARDING_ENABLED]=0
            log_message "INFO" "Removed port forwarding: $normalized" "$vm_name" ;;
    esac

    VM[PORT_FORWARDS]=$(IFS=,; echo "${new_array[*]:-}")
    save_vm_config "$vm_name" VM
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
    local state_file="$VM_DIR/$vm_name/driver_state"
    [[ ! -f "$state_file" ]] && return 0

    log_message "INFO" "Restoring original host drivers..." "$vm_name"
    local pci_id driver vendor_id device_id

    while read -r pci_id driver vendor_id device_id; do
        [[ -z "$pci_id" || -z "$driver" ]] && continue
        local dev_path="/sys/bus/pci/devices/$pci_id"

        if [[ -L "$dev_path/driver" ]]; then
            local link current
            link=$(readlink "$dev_path/driver")
            current="${link##*/}"
            [[ "$current" != "$driver" ]] && \
                echo "$pci_id" | sudo tee "/sys/bus/pci/drivers/$current/unbind" >/dev/null 2>&1 || true
        fi

        echo "" | sudo tee "$dev_path/driver_override" >/dev/null 2>&1 || true

        if [[ -n "${vendor_id:-}" && -n "${device_id:-}" ]]; then
            echo "${vendor_id} ${device_id}" | \
                sudo tee /sys/bus/pci/drivers/vfio-pci/remove_id >/dev/null 2>&1 || true
        fi

        log_message "INFO" "Rebinding $pci_id to $driver..." "$vm_name"
        if ! echo "$pci_id" | sudo tee "/sys/bus/pci/drivers/$driver/bind" >/dev/null 2>&1; then
            log_message "WARNING" "Bind failed. Triggering PCI rescan for $pci_id..." "$vm_name"
            echo 1 | sudo tee "/sys/bus/pci/devices/$pci_id/remove" >/dev/null 2>&1
            sleep 0.5
            echo 1 | sudo tee "/sys/bus/pci/rescan" >/dev/null 2>&1

            if [[ -L "$dev_path/driver" ]]; then
                log_message "INFO"  "✅ $pci_id recovered via rescan." "$vm_name"
            else
                log_message "ERROR" "❌ Failed to restore $pci_id even after rescan." "$vm_name"
            fi
        else
            log_message "INFO" "✅ $pci_id restored to $driver." "$vm_name"
        fi
    done < "$state_file"

    rm -f "$state_file"
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
}

# =============================================================================
# SHARE UTILS
# =============================================================================

have_virtiofsd() {
    local bin
    bin=$(command -v virtiofsd 2>/dev/null || { [[ -x /usr/lib/virtiofsd ]] && echo /usr/lib/virtiofsd; } || true)
    [[ -n "$bin" ]] && "$bin" --version &>/dev/null
}

resolve_share_backend() {
    local -n _rsb_vm="$1"
    local backend="${_rsb_vm[SHARE_BACKEND]:-auto}"
    local shares=()
    split_list "${_rsb_vm[SHARED_FOLDERS]:-}" shares
    local share_count="${#shares[@]}"

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
    [[ "$action" != "list" ]] && vm_is_running "$vm_name" && {
        log_message "ERROR" "Stop the VM before modifying shares"; return 1; }

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
}

start_virtiofsd_daemons() {
    local vm_name="$1"
    local -n _svd_vm="$2"
    local socket_dir="$VM_DIR/$vm_name/sockets"

    local shares=(); split_list "${_svd_vm[SHARED_FOLDERS]:-}" shares

    local virtiofsd_bin
    virtiofsd_bin=$(command -v virtiofsd 2>/dev/null || { [[ -x /usr/lib/virtiofsd ]] && echo /usr/lib/virtiofsd; } || true)
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
        [[ ! -d "$path" ]] && continue

        sock="$socket_dir/virtiofsd_${tag}.sock"
        pidf="$VM_DIR/$vm_name/virtiofsd_${tag}.pid"

        "$virtiofsd_bin" --socket-path="$sock" --shared-dir="$path" --announce-submounts --sandbox=namespace \
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

    for pid_file in "$VM_DIR/$vm_name"/virtiofsd_*.pid; do
        [[ -e "$pid_file" ]] || continue
        read -r pid < "$pid_file"
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            sleep 0.5
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pid_file"
    done
    rm -f "$VM_DIR/$vm_name/sockets"/virtiofsd_*.sock* 2>/dev/null
}

# =============================================================================
# UEFI / OVMF UTILS
# =============================================================================

# Returns the OVMF CODE and VARS paths, or empty strings if not found.
find_ovmf() {
    local -n _code_ref="$1"
    local -n _vars_ref="$2"
    local search_dirs=(
        /usr/share/edk2/x64
        /usr/share/edk2-ovmf/x64
        /usr/share/OVMF
        /usr/share/ovmf/x64
    )
    # Try plain .fd first, then Arch's .4m.fd variant
    local d suffix
    for d in "${search_dirs[@]}"; do
        for suffix in "" ".4m"; do
            local code="$d/OVMF_CODE${suffix}.fd"
            local vars="$d/OVMF_VARS${suffix}.fd"
            if [[ -f "$code" && -f "$vars" ]]; then
                _code_ref="$code"
                _vars_ref="$vars"
                return 0
            fi
        done
    done
    return 1
}

configure_uefi() {
    local vm_name="$1"
    local -n _uefi_vm="$2"
    local -n _uefi_cmd="$3"

    [[ "${_uefi_vm[ENABLE_UEFI]:-0}" != "1" ]] && return 0

    local ovmf_code="" ovmf_vars_tmpl=""
    if ! find_ovmf ovmf_code ovmf_vars_tmpl; then
        log_message "ERROR" "OVMF firmware not found. Install edk2-ovmf (Arch: sudo pacman -S edk2-ovmf)" "$vm_name"
        return 1
    fi

    # Each VM gets its own writable NVRAM copy so UEFI variables persist.
    local vm_vars="$VM_DIR/$vm_name/OVMF_VARS.fd"
    if [[ ! -f "$vm_vars" ]]; then
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
# TPM 2.0 UTILS
# =============================================================================

stop_tpm() {
    local vm_name="$1"
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"
    [[ -f "$tpm_pid" ]] || return 0
    kill "$(< "$tpm_pid")" 2>/dev/null || true
    rm -f "$tpm_pid"
}

# =============================================================================
# QEMU COMMAND BUILDERS
# =============================================================================

configure_cpu() {
    local vm_name="$1"
    local -n _cpu_vm="$2"
    local -n _cpu_cmd="$3"

    if [[ "${_cpu_vm[OS_TYPE]:-linux}" == "windows" ]]; then
        local smp_cores=$(( _cpu_vm[CORES] / 2 ))
        (( smp_cores < 1 )) && smp_cores=1

        local hv_flags="hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-time"
        hv_flags+=",hv-vpindex,hv-synic,hv-stimer,hv-stimer-direct,hv-reset"
        hv_flags+=",hv-frequencies,hv-runtime,hv-tlbflush,hv-reenlightenment,hv-ipi"
        hv_flags+=",kvm=off,l3-cache=on,+topoext"

        _cpu_cmd+=(
            "-smp"    "${_cpu_vm[CORES]},cores=${smp_cores},threads=2,sockets=1"
            "-cpu"    "${_cpu_vm[CPU_TYPE]},${hv_flags}"
            "-global" "kvm-pit.lost_tick_policy=delay"
            "-rtc"    "base=localtime,clock=host,driftfix=slew"
            "-device" "virtio-rng-pci"
            "-device" "virtio-tablet-pci"
            "-device" "virtio-balloon-pci"
        )
    else
        _cpu_cmd+=(
            "-smp" "${_cpu_vm[CORES]}"
            "-cpu" "${_cpu_vm[CPU_TYPE]}"
        )
    fi
}

configure_memory() {
    local vm_name="$1"
    local -n _mem_vm="$2"
    local -n _mem_cmd="$3"

    _mem_cmd+=("-m" "${_mem_vm[MEMORY]}")
    if [[ "${_mem_vm[MEMORY_SHARE]:-0}" == "1" ]]; then
        _mem_cmd+=(
            "-object" "memory-backend-memfd,id=mem0,size=${_mem_vm[MEMORY]},share=on"
            "-numa"   "node,memdev=mem0"
        )
    elif [[ "${_mem_vm[MEMORY_PREALLOC]:-0}" == "1" ]]; then
        _mem_cmd+=(
            "-object" "memory-backend-ram,id=mem0,size=${_mem_vm[MEMORY]},prealloc=on"
            "-numa"   "node,memdev=mem0"
        )
    fi
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

    _dsk_cmd+=("-object" "iothread,id=iothread0")

    case "${_dsk_vm[DISK_INTERFACE]}" in
        virtio)
            local virtio_dev_opts="drive=drive0,iothread=iothread0,num-queues=${_dsk_vm[CORES]}"
            if [[ -n "${_dsk_vm[DISK_DEV]:-}" ]]; then
                # write-cache=on: the SSD has its own hardware write cache; tell
                #   the guest so it doesn't issue redundant flush commands.
                # packed=on: packed virtqueue reduces per-I/O CPU overhead (QEMU 5+).
                # discard=on: advertises TRIM support to the guest.
                virtio_dev_opts+=",write-cache=on,packed=on,discard=on"
            fi
            _dsk_cmd+=(
                "-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}"
                "-device" "virtio-blk-pci,${virtio_dev_opts}"
            ) ;;
        nvme)
            _dsk_cmd+=(
                "-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}"
                "-device" "nvme,drive=drive0,serial=qemate-nvme,num_queues=${_dsk_vm[CORES]}"
            ) ;;
        *)
            _dsk_cmd+=("-drive" "file=${disk_file},if=${_dsk_vm[DISK_INTERFACE]},${drive_opts}") ;;
    esac
}

configure_display() {
    local vm_name="$1"
    local -n _dsp_vm="$2"
    local -n _dsp_cmd="$3"
    local headless="$4"

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
    else
        _dsp_cmd+=("-display" "default")
    fi
}

configure_network() {
    local vm_name="$1"
    local -n _net_vm="$2"
    local -n _net_cmd="$3"

    if [[ "${_net_vm[NETWORK_MODEL]}" == "virtio-net-pci" && "${_net_vm[ENABLE_VIRTIO]:-1}" != "1" ]]; then
        log_message "WARNING" "virtio-net-pci requested but ENABLE_VIRTIO=0; falling back to e1000." "$vm_name"
        _net_vm[NETWORK_MODEL]="e1000"
    fi

    local mac="${_net_vm[MAC_ADDRESS]}" model="${_net_vm[NETWORK_MODEL]}"

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

            if [[ "${_net_vm[PORT_FORWARDING_ENABLED]:-0}" == "1" && -n "${_net_vm[PORT_FORWARDS]:-}" ]]; then
                local fwds=(); split_list "${_net_vm[PORT_FORWARDS]}" fwds
                local fwd
                for fwd in "${fwds[@]}"; do
                    if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        netdev_opts+=",hostfwd=${BASH_REMATCH[5]}:${BASH_REMATCH[2]:-}:${BASH_REMATCH[3]}-:${BASH_REMATCH[4]}"
                    fi
                done
            fi

            _net_cmd+=("-netdev" "$netdev_opts" "-device" "${model},netdev=net0,mac=${mac}")
            log_message "INFO" "Network: user/NAT (SLiRP)" "$vm_name" ;;

        passt)
            command -v passt &>/dev/null || { log_message "ERROR" "passt not found. Install it (e.g. pacman -S passt)" "$vm_name"; return 1; }
            local passt_opts="passt,id=net0"

            if [[ "${_net_vm[PORT_FORWARDING_ENABLED]:-0}" == "1" && -n "${_net_vm[PORT_FORWARDS]:-}" ]]; then
                local fwds=(); split_list "${_net_vm[PORT_FORWARDS]}" fwds
                local fwd
                for fwd in "${fwds[@]}"; do
                    if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        passt_opts+=",hostfwd=${BASH_REMATCH[5]}::${BASH_REMATCH[3]}-:${BASH_REMATCH[4]}"
                    fi
                done
            fi

            _net_cmd+=("-netdev" "$passt_opts" "-device" "${model},netdev=net0,mac=${mac}")
            log_message "INFO" "Network: passt (unprivileged)" "$vm_name" ;;

        tap)
            local tap_name; tap_name=$(setup_tap_interface "$vm_name" _net_vm) || return 1
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
            fi

            _net_cmd+=("-netdev" "tap,id=net0,ifname=${tap_name},script=no,downscript=no${mq_netdev}" "-device" "${model},netdev=net0,mac=${mac}${mq_device}")
            log_message "INFO" "Network: TAP ($tap_name, queues=${queues}, vhost=${vhost})" "$vm_name" ;;

        none)
            _net_cmd+=("-nic" "none") ;;
        *)
            log_message "WARNING" "Unknown NETWORK_TYPE '${_net_vm[NETWORK_TYPE]}'; falling back to user." "$vm_name"
            _net_cmd+=("-netdev" "user,id=net0" "-device" "${model},netdev=net0,mac=${mac}") ;;
    esac
}

configure_audio() {
    local vm_name="$1"
    local -n _aud_conf="$2"
    local -n _aud_cmd="$3"

    [[ "${_aud_conf[ENABLE_AUDIO]:-0}" != "1" ]] && return 0
    local pci_spec="${_aud_conf[AUDIO_PASSTHROUGH_PCI]:-}"
    [[ -z "$pci_spec" || "$pci_spec" == "0" ]] && return 0

    local pci_id="$pci_spec"
    [[ ! "$pci_id" =~ ^[0-9a-fA-F]{4}: ]] && pci_id="0000:$pci_id"
    local dev_path="/sys/bus/pci/devices/$pci_id"

    [[ ! -d "$dev_path" ]] && {
        log_message "ERROR" "Audio PCI device $pci_id not found" "$vm_name"; return 1; }

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

        # Pre-cache sudo credentials now, while we still have a TTY.
        # restore_group_drivers runs from the EXIT trap where there may be no TTY,
        # so if sudo requires a password at that point it would hang or silently fail,
        # leaving the host audio device bound to vfio-pci after the VM exits.
        if ! sudo -n true 2>/dev/null; then
            log_message "INFO" "Caching sudo credentials for VFIO teardown..." "$vm_name"
            sudo -v || {
                log_message "ERROR" "sudo required for VFIO but authentication failed." "$vm_name"
                return 1
            }
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
    local dev
    for dev in "${usb_arr[@]}"; do
        _usb_cmd+=("-device" "usb-host,vendorid=0x${dev%%:*},productid=0x${dev##*:}")
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
    local socket_dir="$VM_DIR/$vm_name/sockets"

    _cvf_vm[MEMORY_SHARE]=1
    local shares=(); split_list "${_cvf_vm[SHARED_FOLDERS]:-}" shares
    local s tag sock
    for s in "${shares[@]}"; do
        tag="${s%%:*}"; sock="$socket_dir/virtiofsd_${tag}.sock"
        if [[ ! -S "$sock" ]]; then
            log_message "WARNING" "virtiofsd socket missing for share: $tag" "$vm_name"; continue
        fi
        _cvf_cmd+=("-chardev" "socket,id=char_${tag},path=${sock}" "-device" "vhost-user-fs-pci,chardev=char_${tag},tag=${tag}")
        log_message "INFO" "VirtIO-FS: '$tag'" "$vm_name"
    done
}

configure_shares() {
    local vm_name="$1"
    local -n _cs_vm="$2"
    local -n _cs_cmd="$3"

    [[ -z "${_cs_vm[SHARED_FOLDERS]:-}" ]] && return 0
    local backend; backend=$(resolve_share_backend _cs_vm)

    case "$backend" in
        virtiofs)
            log_message "INFO" "Shares: VirtIO-FS (multi-share)" "$vm_name"
            start_virtiofsd_daemons "$vm_name" _cs_vm || return 1
            configure_shares_virtiofs "$vm_name" _cs_vm _cs_cmd ;;
        virtfs)
            log_message "INFO" "Shares: VirtFS 9p (fallback)" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
        smb)
            log_message "INFO" "Shares: SMB (single share via SLiRP)" "$vm_name" ;;
        *)
            log_message "WARNING" "Unknown share backend '$backend', falling back to virtfs" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
    esac
}

configure_tpm() {
    local vm_name="$1"
    local -n _tpm_vm="$2"
    local -n _tpm_cmd="$3"

    [[ "${_tpm_vm[ENABLE_TPM]:-0}" != "1" ]] && return 0
    command -v swtpm &>/dev/null || { log_message "WARNING" "swtpm not found — TPM disabled." "$vm_name"; return 0; }

    local tpm_dir="$VM_DIR/$vm_name/tpm"
    local tpm_sock="$VM_DIR/$vm_name/sockets/swtpm.sock"
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"
    mkdir -p "$tpm_dir"

    if [[ ! -f "$tpm_dir/tpm2-00.permall" ]]; then
        swtpm_setup --tpm2 --tpmstate "$tpm_dir" --createek --allow-signing \
            --decryption --create-ek-cert --create-platform-cert \
            --lock-nvram --not-overwrite &>/dev/null || true
    fi

    swtpm socket --tpm2 --tpmstate "dir=$tpm_dir" --ctrl "type=unixio,path=$tpm_sock" \
        --daemon --pid "file=$tpm_pid" --log "level=0"

    local i
    for (( i=0; i<20; i++ )); do
        [[ -S "$tpm_sock" ]] && break; sleep 0.2
    done

    [[ ! -S "$tpm_sock" ]] && { log_message "WARNING" "swtpm failed to start" "$vm_name"; return 0; }

    _tpm_cmd+=("-chardev" "socket,id=chrtpm,path=$tpm_sock" "-tpmdev" "emulator,id=tpm0,chardev=chrtpm" "-device" "tpm-crb,tpmdev=tpm0")
    log_message "INFO" "TPM 2.0 enabled" "$vm_name"
}

# =============================================================================
# CORE VM MANAGEMENT
# =============================================================================

create() {
    local vm_name="$1"; shift
    local os_type="linux" memory="" cores="" disk_size="" disk_dev="" machine_type="" \
          machine_options="" enable_audio="" enable_tpm="" enable_uefi="" spice_enabled="" share_backend=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os-type)       os_type="$2";       shift 2 ;;
            --memory)        memory="$2";         shift 2 ;;
            --cores)         cores="$2";          shift 2 ;;
            --disk-size)     disk_size="$2";      shift 2 ;;
            --disk-dev)      disk_dev="$2";        shift 2 ;;
            --machine)
                [[ "$2" =~ ^([^,]+)(,(accel=kvm|accel=tcg))?$ ]] || {
                    log_message "ERROR" "Invalid machine: '$2'. Use e.g. q35,accel=kvm"; return 1; }
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
            --share-backend) share_backend="$2";  shift 2 ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    validate_vm_name "$vm_name" || return 1
    vm_exists "$vm_name" && { log_message "ERROR" "VM already exists: $vm_name"; return 1; }
    [[ "$os_type" != "linux" && "$os_type" != "windows" ]] && {
        log_message "ERROR" "Invalid os-type: '$os_type'. Use: linux, windows"; return 1; }

    if [[ -n "$cores" ]]; then
        [[ ! "$cores" =~ ^[0-9]+$ || "$cores" -lt 1 || "$cores" -gt 64 ]] && {
            log_message "ERROR" "Invalid cores: $cores (must be 1–64)"; return 1; }
    fi

    if [[ -n "$memory" ]]; then
        [[ ! "$memory" =~ ^([0-9]+)([GMgm])$ ]] && {
            log_message "ERROR" "Invalid memory: '$memory'. Use e.g. 4G or 2048M"; return 1; }
        local mem_val="${BASH_REMATCH[1]}" mem_unit="${BASH_REMATCH[2]}"
        
        # Bash native memory check replacing awk
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
        [[ -n "$disk_size" ]] && \
            log_message "WARNING" "--disk-size is ignored when --disk-dev is set." "$vm_name"
    else
        [[ -n "$disk_size" && ! "$disk_size" =~ ^[0-9]+[GMgm]$ ]] && {
            log_message "ERROR" "Invalid disk size: '$disk_size'. Use e.g. 60G"; return 1; }
    fi

    local -A VM=()
    apply_os_defaults "$os_type" VM

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
    VM[MAC_ADDRESS]=$(generate_mac_address "$vm_name")
    VM[LOCKED]="0"
    VM[PORT_FORWARDING_ENABLED]="0"
    VM[PORT_FORWARDS]=""
    VM[USB_DEVICES]=""
    VM[SHARED_FOLDERS]=""
    VM[DISK_DEV]=""

    mkdir -p -m 700 "$VM_DIR/$vm_name"/{logs,sockets,tpm} || {
        log_message "ERROR" "Failed to create VM directories" "$vm_name"; return 1; }

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
        qemu-img create -f qcow2 "$VM_DIR/$vm_name/disk.qcow2" "${VM[DISK_SIZE]}" &>/dev/null || {
            log_message "ERROR" "Failed to create disk image" "$vm_name"
            rm -rf "${VM_DIR:?}/${vm_name:?}"; return 1
        }
        chmod 600 "$VM_DIR/$vm_name/disk.qcow2"
    fi

    save_vm_config "$vm_name" VM
    local disk_info="${VM[DISK_DEV]:-${VM[DISK_SIZE]}}"
    log_message "INFO" "VM '$vm_name' created (OS: $os_type | Mem: ${VM[MEMORY]} | Cores: ${VM[CORES]} | Disk: ${disk_info})" "$vm_name"
}

start() {
    local vm_name="$1"; shift
    local headless="0" iso_file="" virtio_iso="" debug="0"

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --headless) headless="1"; shift ;;
            --iso)      iso_file="$2"; shift 2 ;;
            --virtio-iso) virtio_iso="$2"; shift 2 ;;
            --debug)    debug="1"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    QEMATE_ACTIVE_VM="$vm_name"
    QEMATE_PHASE="starting"
    trap 'restore_group_drivers "$QEMATE_ACTIVE_VM"' EXIT

    if ! vm_is_running "$vm_name"; then
        stop_virtiofsd_daemons "$vm_name"
        stop_tpm "$vm_name"
    fi

    require_vm "$vm_name" exists not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    check_vm_dependencies "$vm_name" VM || return 1

    log_message "INFO" "Starting VM: $vm_name" "$vm_name"

    # ←←← Everything after this point is the real start logic (unchanged) ←←←
    [[ "${VM[MACHINE_OPTIONS]}" =~ accel=kvm ]] && [[ ! -w /dev/kvm ]] && {
        log_message "ERROR" "/dev/kvm not writable. Run: sudo usermod -aG kvm $USER"
        return 1
    }

    if [[ -n "${VM[SHARED_FOLDERS]:-}" ]]; then
        local eff_be; eff_be=$(resolve_share_backend VM)
        [[ "$eff_be" == "virtiofs" ]] && VM[MEMORY_SHARE]=1
    fi

    local machine_str="${VM[MACHINE_TYPE]},${VM[MACHINE_OPTIONS]}"
    [[ "${VM[OS_TYPE]:-linux}" == "windows" ]] && machine_str+=",hpet=off"

    local qemu_cmd=(
        "qemu-system-x86_64"
        "-name" "${VM[NAME]},process=${VM[NAME]}"
        "-machine" "$machine_str"
        "-pidfile" "$VM_DIR/$vm_name/qemu.pid"
    )

    configure_uefi "$vm_name" VM qemu_cmd || return 1
    configure_cpu "$vm_name" VM qemu_cmd
    configure_memory "$vm_name" VM qemu_cmd

    qemu_cmd+=(
        "-device" "qemu-xhci,id=usb,bus=pcie.0"
        "-device" "usb-kbd,bus=usb.0"
        "-device" "virtio-serial-pci"
        "-device" "virtserialport,chardev=chara0,name=org.qemu.guest_agent.0"
        "-chardev" "socket,id=chara0,path=$VM_DIR/$vm_name/sockets/qga.sock,server=on,wait=off"
    )

    configure_display "$vm_name" VM qemu_cmd "$headless"
    configure_disk "$vm_name" VM qemu_cmd

    if [[ -n "$iso_file" ]]; then
        iso_file=$(realpath "$iso_file")
        [[ ! -f "$iso_file" ]] && { log_message "ERROR" "ISO not found: $iso_file"; return 1; }
        qemu_cmd+=("-drive" "file=${iso_file},format=raw,readonly=on,media=cdrom,id=cdrom0" "-boot" "menu=on,order=dc")
    fi

    if [[ -n "$virtio_iso" ]]; then
        virtio_iso=$(realpath "$virtio_iso")
        [[ ! -f "$virtio_iso" ]] && { log_message "ERROR" "VirtIO ISO not found: $virtio_iso"; return 1; }
        qemu_cmd+=("-drive" "file=${virtio_iso},format=raw,readonly=on,media=cdrom,id=cdrom1")
    fi

    configure_audio "$vm_name" VM qemu_cmd
    configure_usb_passthrough "$vm_name" VM qemu_cmd
    configure_shares "$vm_name" VM qemu_cmd || { stop_virtiofsd_daemons "$vm_name"; return 1; }
    configure_tpm "$vm_name" VM qemu_cmd
    configure_network "$vm_name" VM qemu_cmd

    if [[ "$debug" == "1" ]]; then
        echo -e "\n[DEBUG] Generated QEMU command:\n${qemu_cmd[*]}\n" >&2
    fi

    local lockfile="$VM_DIR/$vm_name/qemu.pid.lock" _fd
    acquire_flock "$lockfile" _fd || { log_message "ERROR" "Cannot acquire start lock"; return 1; }

    QEMATE_PHASE="running"
    log_message "INFO" "Launching QEMU process for $vm_name..." "$vm_name"

    local qemu_status=0
    "${qemu_cmd[@]}" {_fd}>&- 2>"$VM_DIR/$vm_name/logs/error.log" || qemu_status=$?

    log_message "INFO" "QEMU process terminated (exit: $qemu_status)" "$vm_name"

    stop_virtiofsd_daemons "$vm_name"
    stop_tpm "$vm_name"
    teardown_tap_interface "$vm_name"
    rm -f "$VM_DIR/$vm_name/qemu.pid"
    release_flock _fd "$lockfile"

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
    local force="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    require_vm "$vm_name" exists running || return 1
    local pid
    read -r pid < "$VM_DIR/$vm_name/qemu.pid"
    kill -0 "$pid" 2>/dev/null || { log_message "ERROR" "VM is not running"; return 1; }
    log_message "INFO" "Stopping VM: $vm_name" "$vm_name"

    if [[ "$force" == "true" ]]; then
        kill -9 "$pid" || true
    else
        kill -15 "$pid" || true
        local i
        for (( i=0; i<30; i++ )); do
            kill -0 "$pid" 2>/dev/null || break; sleep 1
        done
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" || true
    fi

    rm -f "$VM_DIR/$vm_name/qemu.pid" "$VM_DIR/$vm_name/qemu.pid.lock"
    stop_virtiofsd_daemons "$vm_name"
    stop_tpm               "$vm_name"
    teardown_tap_interface "$vm_name"
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

    if [[ "$force" != "true" ]]; then
        read -r -p "Delete VM '$vm_name' and all its data? [y/N]: " confirm
        [[ ! "$confirm" =~ ^[Yy]$ ]] && return 0
    fi
    rm -rf "${VM_DIR:?}/${vm_name:?}"
    log_message "INFO" "VM deleted: $vm_name"
}

resize_disk() {
    local vm_name="$1" new_size="$2"; shift 2
    local force="false"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force="true"; shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    require_vm "$vm_name" exists || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1

    if [[ -n "${VM[DISK_DEV]:-}" ]]; then
        log_message "ERROR" "Resize is not supported for physical device VMs (DISK_DEV=${VM[DISK_DEV]})." "$vm_name"
        return 1
    fi

    vm_is_running "$vm_name" && [[ "$force" != "true" ]] && {
        log_message "ERROR" "VM is running. Use --force (requires online resize support)." "$vm_name"
        return 1
    }

    [[ ! "$new_size" =~ ^(\+)?[0-9]+[GMgm]$ ]] && {
        log_message "ERROR" "Invalid size: '$new_size'. Use e.g. 80G or +20G" "$vm_name"; return 1; }

    log_message "INFO" "Resizing disk to $new_size..." "$vm_name"
    qemu-img resize "$VM_DIR/$vm_name/disk.qcow2" "$new_size" || {
        log_message "ERROR" "Resize failed." "$vm_name"; return 1; }

    # Parse qemu-img JSON directly via Bash Regex instead of piping grep
    local json bytes_size=""
    json=$(qemu-img info --output=json "$VM_DIR/$vm_name/disk.qcow2")
    if [[ "$json" =~ \"virtual-size\":[[:space:]]*([0-9]+) ]]; then
        bytes_size="${BASH_REMATCH[1]}"
        VM[DISK_SIZE]="$(( bytes_size / 1073741824 ))G"
        save_vm_config "$vm_name" VM
        log_message "INFO" "Disk resized to ${VM[DISK_SIZE]}" "$vm_name"
    fi
}

# configure VM_NAME — Opens the VM config file directly in the editor.
configure() {
    local vm_name="$1"
    require_vm "$vm_name" exists unlocked || return 1
    vm_is_running "$vm_name" && {
        log_message "ERROR" "Stop the VM before configuring"; return 1; }

    local config_file="$VM_DIR/$vm_name/config"
    local backup
    backup="$(mktemp)"
    cp "$config_file" "$backup"

    "${EDITOR:-nano}" "$config_file"

    local -A _vtmp=()
    if ! load_vm_config "$vm_name" _vtmp 2>/dev/null; then
        log_message "ERROR" "Syntax validation failed after editing. Restoring previous config." "$vm_name"
        cp "$backup" "$config_file"
        rm -f "$backup"
        return 1
    fi
    rm -f "$backup"
    log_message "INFO" "Config applied successfully." "$vm_name"
}

# =============================================================================
# STATUS & LIST
# =============================================================================

list() {
    [[ ! -d "$VM_DIR" ]] && { echo "No VMs found."; return 0; }
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "NAME" "STATUS" "LOCKED" "OS" "AUDIO" "TPM" "SPICE"
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "----" "------" "------" "--" "-----" "---" "-----"

    local vm_path name stat lock os audio tpm spice
    for vm_path in "$VM_DIR"/*/; do
        [[ -d "$vm_path" ]] || continue
        name="${vm_path%/}"
        name="${name##*/}"
        stat="stopped"; vm_is_running "$name" && stat="running"
        lock="no"; vm_is_locked  "$name" && lock="yes"

        local -A VM=()
        os="?" audio="?" tpm="?" spice="?"
        if load_vm_config "$name" VM 2>/dev/null; then
            os="${VM[OS_TYPE]:-?}"
            audio="${VM[ENABLE_AUDIO]:-0}"; [[ "$audio" == "1" ]] && audio="on"  || audio="off"
            tpm="${VM[ENABLE_TPM]:-0}";     [[ "$tpm"   == "1" ]] && tpm="on"    || tpm="off"
            spice="${VM[SPICE_ENABLED]:-0}"; [[ "$spice" == "1" ]] && spice="on" || spice="off"
        fi
        printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
            "$name" "$stat" "$lock" "$os" "$audio" "$tpm" "$spice"
    done
}

status() {
    local vm_name="$1"
    require_vm "$vm_name" exists || return 1

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1

    local running; vm_is_running "$vm_name" && running="● Running" || running="○ Stopped"
    echo ""
    echo "  VM: $vm_name  [$running]"
    echo "  ─────────────────────────────────────────────"
    printf "  %-16s %s\n" "OS Type:"        "${VM[OS_TYPE]:-?}"
    printf "  %-16s %s\n" "CPU:"            "${VM[CPU_TYPE]} × ${VM[CORES]} cores"
    printf "  %-16s %s\n" "Memory:"         "${VM[MEMORY]}"
    printf "  %-16s %s\n" "Machine:"        "${VM[MACHINE_TYPE]} (${VM[MACHINE_OPTIONS]})"
    printf "  %-16s %s\n" "Video:"          "${VM[VIDEO_TYPE]}"
    printf "  %-16s %s\n" "Disk Interface:" "${VM[DISK_INTERFACE]}"
    if [[ -n "${VM[DISK_DEV]:-}" ]]; then
        printf "  %-16s %s\n" "Disk Device:"    "${VM[DISK_DEV]} (physical, raw)"
        printf "  %-16s %s\n" "Disk Size:"      "${VM[DISK_SIZE]}"
    else
        printf "  %-16s %s\n" "Disk Size:"      "${VM[DISK_SIZE]}"
    fi
    printf "  %-16s %s\n" "Network:"        "${VM[NETWORK_TYPE]} / ${VM[NETWORK_MODEL]}"
    printf "  %-16s %s\n" "UEFI:"           "$( [[ "${VM[ENABLE_UEFI]:-0}" == "1" ]] && echo "enabled" || echo "disabled (SeaBIOS)" )"
    printf "  %-16s %s\n" "Share backend:"  "${VM[SHARE_BACKEND]:-auto}"
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

# =============================================================================
# CLI / HELP
# =============================================================================

display_help() {
    cat <<'EOF'
QEMATE v4.2.1 — QEMU VM Manager
────────────────────────────────────────────────────────────────────────

USAGE
  qemate <command> [vm] [options] [--help]

VM
  create <name> [options]
      --os-type linux|windows        (default: linux)
      --memory SIZE                  e.g. 4G, 8G
      --cores N                      vCPU count
      --disk-size SIZE               e.g. 60G  (qcow2 image; default)
      --disk-dev PATH                e.g. /dev/sdb, /dev/sdb1  (raw physical partition)
      --enable-audio | --no-audio
      --enable-tpm   | --no-tpm
      --uefi         | --no-uefi        (default: on for windows, off for linux)
      --spice        | --no-spice
      --share-backend auto|virtfs|smb|virtiofs

  start   <name> [--headless] [--iso PATH] [--virtio-iso PATH] [--debug]
  stop    <name> [--force]
  delete  <name> [--force]
  resize  <name> <SIZE|+SIZE>
  list
  status  <name>
  config  <name>     edit VM config in $EDITOR

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
  lock   <name>
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

    mkdir -p "$VM_DIR"
    [[ $# -eq 0 ]] && { display_help; exit 1; }

    local cmd
    for cmd in qemu-system-x86_64 qemu-img; do
        command -v "$cmd" &>/dev/null || {
            echo "Error: required binary '$cmd' not found in PATH." >&2; exit 1; }
    done

    local verb="$1"; shift
    case "$verb" in
        create)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; create      "$@" ;;
        start)         [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; start       "$@" ;;
        stop)          [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; stop        "$@" ;;
        delete)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; delete      "$@" ;;
        resize)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; resize_disk "$@" ;;
        status)        [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; status      "$@" ;;
        configure)     [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }; configure   "$@" ;;
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

main "$@"