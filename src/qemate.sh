#!/bin/bash

# qemate - Streamlined QEMU Virtual Machine Management Utility.
# Version: 4.1.0

if [ -z "${BASH_VERSION:-}" ]; then
    echo "Error: qemate must be run with bash, not sh." >&2
    echo "  Use: bash $0 $*" >&2
    exit 1
fi

set -euo pipefail
umask 0077

# ============================================================================
# CONSTANTS & DEFAULTS
# ============================================================================

readonly VM_DIR="${QEMATE_VM_DIR:-$HOME/QVMs}"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Linux: High performance, standard VirtIO defaults
declare -A LINUX_DEFAULTS=(
    [CORES]=2
    [MEMORY]="2G"
    [DISK_SIZE]=40G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=virtio-net-pci
    [DISK_INTERFACE]=virtio
    [ENABLE_AUDIO]=0
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
)

# Windows: Optimized for VirtIO and CPU Topology
declare -A WINDOWS_DEFAULTS=(
    [CORES]=4
    [MEMORY]="4G"
    [DISK_SIZE]=60G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=virtio-net-pci
    [DISK_INTERFACE]=nvme
    [ENABLE_AUDIO]=0
    [CPU_TYPE]="host,hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-vpindex,hv-synic,hv-stimer,hv-stimer-direct,hv-reset,hv-frequencies,hv-runtime,hv-tlbflush,hv-reenlightenment,hv-ipi,kvm=off,l3-cache=on"
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
)

# ============================================================================
# SIGNAL HANDLING
# ============================================================================

# Track state for the trap handler
declare -g QEMATE_ACTIVE_VM=""
declare -g QEMATE_PHASE=""

cleanup_on_signal() {
    local exit_code=$?
    
    # Only execute aggressive cleanup if we were interrupted during VM startup
    if [[ "$QEMATE_PHASE" == "starting" && -n "$QEMATE_ACTIVE_VM" ]]; then
        log_message "WARNING" "Launch interrupted. Cleaning up orphaned daemons for: $QEMATE_ACTIVE_VM"
        stop_virtiofsd_daemons "$QEMATE_ACTIVE_VM" 2>/dev/null
        stop_tpm "$QEMATE_ACTIVE_VM" 2>/dev/null
        rm -f "$VM_DIR/$QEMATE_ACTIVE_VM/qemu.pid.lock" 2>/dev/null
    fi
    
    exit "$exit_code"
}

trap cleanup_on_signal INT TERM

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

check_vm_dependencies() {
    local vm_name="$1"
    local -n _deps_vm="$2"
    local missing=()

    # 1. Check TPM Requirements
    if [[ "${_deps_vm[ENABLE_TPM]:-0}" == "1" ]]; then
        command -v swtpm >/dev/null || missing+=("swtpm")
        command -v swtpm_setup >/dev/null || missing+=("swtpm_setup (swtpm-tools)")
    fi

    # 2. Check Shared Folder Backends
    local backend; backend=$(resolve_share_backend _deps_vm)
    if [[ "$backend" == "virtiofs" ]]; then
        if ! command -v virtiofsd >/dev/null && [[ ! -x /usr/lib/virtiofsd ]]; then
            missing+=("virtiofsd")
        fi
    elif [[ "$backend" == "smb" ]]; then
        command -v smbd >/dev/null || missing+=("smbd (samba)")
    fi

    # 3. Check SPICE Dependencies
    if [[ "${_deps_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        # Ensure qemu was compiled with spice support (basic check)
        if ! qemu-system-x86_64 -display help 2>/dev/null | grep -q "spice"; then
             log_message "WARNING" "QEMU may not be compiled with SPICE support on this host." "$vm_name"
        fi
    fi

    # 4. Check Audio (Non-fatal, but good to surface early)
    if [[ "${_deps_vm[ENABLE_AUDIO]:-0}" == "1" ]]; then
        local aud_backend; aud_backend=$(detect_audio_backend)
        if [[ "$aud_backend" == "none" ]]; then
             log_message "WARNING" "Audio is enabled but no backend (PulseAudio/PipeWire/ALSA) was detected." "$vm_name"
        fi
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Pre-flight failed. Missing required host dependencies: ${missing[*]}" "$vm_name"
        return 1
    fi
    return 0
}

log_message() {
    local level="$1" message="$2" vm_name="${3:-}"
    local timestamp; timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    if [[ ! "$level" =~ ^(DEBUG|INFO|WARNING|ERROR)$ ]]; then
        echo "[ERROR] Invalid log level: $level" >&2
        return 1
    fi

    local should_output=false
    case "$LOG_LEVEL" in
        DEBUG)   should_output=true ;;
        INFO)    [[ "$level" =~ ^(INFO|WARNING|ERROR)$ ]] && should_output=true ;;
        WARNING) [[ "$level" =~ ^(WARNING|ERROR)$ ]]      && should_output=true ;;
        ERROR)   [[ "$level" == "ERROR" ]]                && should_output=true ;;
    esac

    if [[ "$should_output" == true ]]; then
        echo "[$level] $message" >&2
    fi

    if [[ -n "$vm_name" && -d "$VM_DIR/$vm_name/logs" ]]; then
        echo "$timestamp [$level] $message" >> "$VM_DIR/$vm_name/logs/qemate_vm.log"
        if [[ "$level" == "ERROR" ]]; then
            echo "$timestamp [$level] $message" >> "$VM_DIR/$vm_name/logs/error.log"
        fi
    fi
    return 0
}

vm_exists() { [[ -d "$VM_DIR/$1" ]]; }

vm_is_running() {
    local vm_name="$1" pidfile="$VM_DIR/$1/qemu.pid"
    [[ -f "$pidfile" ]] || return 1
    local pid; pid=$(cat "$pidfile")
    
    if kill -0 "$pid" 2>/dev/null; then
        if grep -a -q "process=${vm_name}" "/proc/$pid/cmdline" 2>/dev/null; then
            return 0
        fi
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
    [[ -z "$1" ]] && { log_message "ERROR" "VM name cannot be empty"; return 1; }
    [[ "${#1}" -gt 40 ]] && {
        log_message "ERROR" "VM name too long (max 40 characters)"; return 1; }
    [[ ! "$1" =~ ^[a-zA-Z0-9_-]+$ ]] && {
        log_message "ERROR" "VM name: letters, numbers, hyphens, underscores only"; return 1; }
    return 0
}

generate_mac_address() {
    printf "52:54:00:%s" "$(echo -n "$1" | md5sum | cut -c1-6 | sed 's/../&:/g;s/:$//')"
}

parse_usb_id() {
    local spec="$1"
    if [[ ! "$spec" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
        log_message "ERROR" "Invalid USB ID: '$spec'. Use vendor:product hex (e.g. 046d:c52b)"
        return 1
    fi
    return 0
}

parse_share_spec() {
    local spec="$1"
    if [[ "$spec" =~ ^([^/:][^:]*):(.+)$ ]]; then
        local _tag="${BASH_REMATCH[1]}" _path="${BASH_REMATCH[2]}"
        if [[ "$_tag" == *","* || "$_path" == *","* ]]; then
            log_message "ERROR" "Share tag and path must not contain commas: '$spec'"
            return 1
        fi
        echo "${_tag}:${_path}"
    elif [[ -d "$spec" ]]; then
        local _derived; _derived="$(basename "$spec")"
        if [[ "$_derived" == *","* || "$spec" == *","* ]]; then
            log_message "ERROR" "Share tag and path must not contain commas: '$spec'"
            return 1
        fi
        echo "${_derived}:${spec}"
    else
        log_message "ERROR" "Invalid share spec: '$spec'. Use /host/path or tag:/host/path"
        return 1
    fi
}

acquire_flock() {
    local lockfile="$1"
    local -n _af_fd="$2"
    exec {_af_fd}>"$lockfile"
    if ! flock -n "$_af_fd"; then
        exec {_af_fd}>&-
        return 1
    fi
    return 0
}

release_flock() {
    local -n _rf_fd="$1"
    local lockfile="$2"
    flock -u "$_rf_fd"
    exec {_rf_fd}>&-
    rm -f "$lockfile"
}

require_vm() {
    local vm_name="$1"; shift
    validate_vm_name "$vm_name" || return 1
    local flag
    for flag in "$@"; do
        case "$flag" in
            exists)
                vm_exists "$vm_name" || {
                    log_message "ERROR" "VM not found: $vm_name"; return 1; } ;;
            running)
                vm_is_running "$vm_name" || {
                    log_message "ERROR" "VM is not running"; return 1; } ;;
            not-running|stopped)
                if vm_is_running "$vm_name"; then
                    log_message "ERROR" "VM is already running"; return 1
                fi ;;
            unlocked)
                if vm_is_locked "$vm_name"; then
                    log_message "ERROR" "VM is locked"; return 1
                fi ;;
        esac
    done
    return 0
}

split_list() {
    local raw="$1"
    local -n _sl_out="$2"
    _sl_out=()
    local _sl_tmp=()
    IFS=',' read -ra _sl_tmp <<< "$raw"
    local item
    for item in "${_sl_tmp[@]}"; do
        [[ -n "$item" ]] && _sl_out+=("$item")
    done
}

apply_os_defaults() {
    local os_type="$1"
    local -n _aod_vm="$2"
    local -n _aod_src
    if [[ "$os_type" == "windows" ]]; then
        _aod_src=WINDOWS_DEFAULTS
    else
        _aod_src=LINUX_DEFAULTS
    fi
    local key
    for key in "${!_aod_src[@]}"; do
        _aod_vm[$key]="${_aod_src[$key]}"
    done
}

resolve_share_backend() {
    local -n _rsb_vm="$1"
    local backend="${_rsb_vm[SHARE_BACKEND]:-auto}"
    local shares=()
    split_list "${_rsb_vm[SHARED_FOLDERS]:-}" shares
    local share_count="${#shares[@]}"

    if [[ "$backend" != "auto" ]]; then
        if [[ "$backend" == "smb" && "$share_count" -gt 1 ]]; then
            log_message "WARNING" \
                "SMB backend does not support multiple shares. Falling back to virtiofs." \
                "${_rsb_vm[NAME]:-unknown}"
            echo "virtiofs"
            return
        fi
        echo "$backend"
        return
    fi

    if [[ "$share_count" -gt 1 ]]; then
        if have_virtiofsd; then
            echo "virtiofs"
        else
            log_message "WARNING" \
                "Multiple shares requested but virtiofsd not available. Falling back to single-share SMB." \
                "${_rsb_vm[NAME]:-unknown}"
            echo "smb"
        fi
    else
        if [[ "${_rsb_vm[OS_TYPE]:-linux}" == "windows" ]]; then
            echo "smb"
        else
            if have_virtiofsd; then
                echo "virtiofs"
            else
                echo "virtfs"
            fi
        fi
    fi
}

get_smb_share_path() {
    local vm_name="$1"
    local -n _gsp_vm="$2"
    [[ -z "${_gsp_vm[SHARED_FOLDERS]:-}" ]] && return 0
    local backend; backend=$(resolve_share_backend _gsp_vm)
    [[ "$backend" != "smb" ]] && return 0

    local shares=()
    split_list "${_gsp_vm[SHARED_FOLDERS]}" shares
    if [[ "${#shares[@]}" -eq 0 ]]; then
        return 0
    fi

    if [[ "${#shares[@]}" -gt 1 ]]; then
        log_message "WARNING" "SMB supports only one share. Using first: ${shares[0]}" "$vm_name"
    fi

    local first="${shares[0]}"
    local path="${first#*:}"
    if [[ ! -d "$path" ]]; then
        log_message "ERROR" "SMB share path not found: $path" "$vm_name"
        return 1
    fi
    echo "$path"
}

# ============================================================================
# CONFIG I/O
# ============================================================================

load_vm_config() {
    local vm_name="$1"
    local -n _lvc_vm="$2"
    local config_file="$VM_DIR/$vm_name/config"

    [[ ! -f "$config_file" ]] && {
        log_message "ERROR" "Config not found for: $vm_name" "$vm_name"; return 1; }
        
    # Security: Verify ownership and permissions
    local stat_out
    stat_out=$(stat -c "%U %a" "$config_file")
    local owner="${stat_out% *}"
    local perms="${stat_out#* }"
    
    [[ "$owner" != "$USER" ]] && {
        log_message "ERROR" "Security Breach: config is not owned by $USER" "$vm_name"; return 1; }
    [[ "$perms" =~ [2367]$ ]] && {
        log_message "WARNING" "Security: config file is world-writable. Hardening permissions to 600." "$vm_name"
        chmod 600 "$config_file"
    }

    local -A _ALLOWED_KEYS=(
        [NAME]=1 [OS_TYPE]=1 [MACHINE_TYPE]=1 [MACHINE_OPTIONS]=1
        [CORES]=1 [MEMORY]=1 [CPU_TYPE]=1 [NETWORK_TYPE]=1
        [NETWORK_MODEL]=1 [MAC_ADDRESS]=1 [PORT_FORWARDING_ENABLED]=1
        [PORT_FORWARDS]=1 [VIDEO_TYPE]=1 [DISK_INTERFACE]=1
        [DISK_CACHE]=1 [DISK_IO]=1 [DISK_DISCARD]=1 [ENABLE_VIRTIO]=1
        [MEMORY_PREALLOC]=1 [MEMORY_SHARE]=1 [ENABLE_AUDIO]=1
        [USB_DEVICES]=1 [SHARED_FOLDERS]=1 [SHARE_BACKEND]=1
        [ENABLE_TPM]=1 [SPICE_ENABLED]=1 [SPICE_PORT]=1
        [VRAM_SIZE_MB]=1 [LOCKED]=1 [DISK_SIZE]=1
    )

    local _fd line_num=0
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

    # Strict parsing loop
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Trim leading and trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        
        # Skip empty lines and full-line comments
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Match strict KEY=VALUE or KEY="VALUE" format
        if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=[\"\']?(.*)[\"\']?$ ]]; then
            local _key="${BASH_REMATCH[1]}"
            local _val="${BASH_REMATCH[2]}"
            
            # Clean up any trailing quotes that the regex might have missed
            _val="${_val%\"}"
            _val="${_val%\'}"

            if [[ -n "${_ALLOWED_KEYS[$_key]:-}" ]]; then
                _lvc_vm[$_key]="$_val"
            else
                log_message "WARNING" "Config line $line_num: Unknown key '$_key' ignored." "$vm_name"
            fi
        else
            log_message "ERROR" "Config line $line_num: Syntax error -> '$line'" "$vm_name"
            release_flock _fd "$config_file.lock"
            return 1
        fi
    done < "$config_file"

    # Validation: Ensure critical keys are present
    local var
    for var in NAME CORES MEMORY NETWORK_TYPE NETWORK_MODEL DISK_INTERFACE VIDEO_TYPE; do
        if [[ -z "${_lvc_vm[$var]:-}" ]]; then
            log_message "ERROR" "Config missing critical required field: $var" "$vm_name"
            release_flock _fd "$config_file.lock"
            return 1
        fi
    done
    
    release_flock _fd "$config_file.lock"
    return 0
}

save_vm_config() {
    local vm_name="$1"
    local -n _svc_vm="$2"
    local config_file="$VM_DIR/$vm_name/config"

    local _fd
    acquire_flock "$config_file.lock" _fd || {
        log_message "ERROR" "Cannot lock config for: $vm_name" "$vm_name"; return 1; }

cat >"$config_file" <<EOF
NAME="${_svc_vm[NAME]:-$vm_name}"
OS_TYPE="${_svc_vm[OS_TYPE]:-linux}"
MACHINE_TYPE="${_svc_vm[MACHINE_TYPE]:-q35}"
MACHINE_OPTIONS="${_svc_vm[MACHINE_OPTIONS]:-accel=kvm}"
CORES="${_svc_vm[CORES]:-2}"
MEMORY="${_svc_vm[MEMORY]:-2G}"
CPU_TYPE="${_svc_vm[CPU_TYPE]:-host}"
NETWORK_TYPE="${_svc_vm[NETWORK_TYPE]:-user}"
NETWORK_MODEL="${_svc_vm[NETWORK_MODEL]:-virtio-net-pci}"
MAC_ADDRESS="${_svc_vm[MAC_ADDRESS]:-$(generate_mac_address "$vm_name")}"
PORT_FORWARDING_ENABLED="${_svc_vm[PORT_FORWARDING_ENABLED]:-0}"
PORT_FORWARDS="${_svc_vm[PORT_FORWARDS]:-}"
VIDEO_TYPE="${_svc_vm[VIDEO_TYPE]:-virtio-vga}"
DISK_INTERFACE="${_svc_vm[DISK_INTERFACE]:-virtio}"
DISK_CACHE="${_svc_vm[DISK_CACHE]:-writeback}"
DISK_IO="${_svc_vm[DISK_IO]:-io_uring}"
DISK_DISCARD="${_svc_vm[DISK_DISCARD]:-unmap}"
ENABLE_VIRTIO="${_svc_vm[ENABLE_VIRTIO]:-1}"
MEMORY_PREALLOC="${_svc_vm[MEMORY_PREALLOC]:-0}"
MEMORY_SHARE="${_svc_vm[MEMORY_SHARE]:-0}"
ENABLE_AUDIO="${_svc_vm[ENABLE_AUDIO]:-0}"
USB_DEVICES="${_svc_vm[USB_DEVICES]:-}"
SHARED_FOLDERS="${_svc_vm[SHARED_FOLDERS]:-}"
SHARE_BACKEND="${_svc_vm[SHARE_BACKEND]:-auto}"
ENABLE_TPM="${_svc_vm[ENABLE_TPM]:-0}"
SPICE_ENABLED="${_svc_vm[SPICE_ENABLED]:-0}"
SPICE_PORT="${_svc_vm[SPICE_PORT]:-5930}"
VRAM_SIZE_MB="${_svc_vm[VRAM_SIZE_MB]:-64}"
LOCKED="${_svc_vm[LOCKED]:-0}"
DISK_SIZE="${_svc_vm[DISK_SIZE]:-40G}"
EOF

    chmod 600 "$config_file"
    log_message "DEBUG" "Config saved for: $vm_name" "$vm_name"
    release_flock _fd "$config_file.lock"
}

# ============================================================================
# NETWORK MANAGEMENT
# ============================================================================

parse_port_spec() {
    local port_spec="$1" vm_name="$2"
    local -n out_spec="$3"
    
    if [[ "$port_spec" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+)(:(tcp|udp))?$ ]]; then
        local ip="${BASH_REMATCH[2]:-}"
        local host_port="${BASH_REMATCH[3]}"
        local guest_port="${BASH_REMATCH[4]}"
        local proto="${BASH_REMATCH[6]:-tcp}"
        
        if [[ -n "$ip" ]]; then
            out_spec="${ip}:${host_port}:${guest_port}:${proto}"
        else
            out_spec="${host_port}:${guest_port}:${proto}"
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
    local new_array=() found=0

    case "$action" in
        add)
            local p
            for p in "${port_array[@]}"; do
                [[ "$p" == "$normalized" ]] && {
                    log_message "WARNING" "Port rule already exists: $normalized" "$vm_name"; return 0; }
                new_array+=("$p")
            done
            new_array+=("$normalized")
            VM[PORT_FORWARDING_ENABLED]=1
            log_message "INFO" "Added port forwarding: $normalized" "$vm_name" ;;
        remove)
            local p
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

configure_network() {
    local vm_name="$1"
    local -n _net_vm="$2"
    local -n _net_cmd="$3"

    if [[ "${_net_vm[NETWORK_MODEL]}" == "virtio-net-pci" && \
          "${_net_vm[ENABLE_VIRTIO]:-1}" != "1" ]]; then
        log_message "WARNING" \
            "NETWORK_MODEL=virtio-net-pci but ENABLE_VIRTIO=0; falling back to e1000. Install VirtIO-Win drivers then set ENABLE_VIRTIO=1." \
            "$vm_name"
        _net_vm[NETWORK_MODEL]="e1000"
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
                    log_message "WARNING" \
                        "smbd not found — SMB share will not work. Install samba." \
                        "$vm_name"
                fi
            fi

            if [[ "${_net_vm[PORT_FORWARDING_ENABLED]:-0}" == "1" ]] && \
               [[ -n "${_net_vm[PORT_FORWARDS]:-}" ]]; then
                local fwds=(); split_list "${_net_vm[PORT_FORWARDS]}" fwds
                local fwd
                for fwd in "${fwds[@]}"; do
                    if [[ "$fwd" =~ ^(([0-9\.]+):)?([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        local ip="${BASH_REMATCH[2]:-}"
                        local hport="${BASH_REMATCH[3]}"
                        local gport="${BASH_REMATCH[4]}"
                        local proto="${BASH_REMATCH[5]}"
                        netdev_opts+=",hostfwd=${proto}:${ip}:${hport}-:${gport}"
                    fi
                done
            fi

            _net_cmd+=("-netdev" "$netdev_opts")
            _net_cmd+=("-device" "${_net_vm[NETWORK_MODEL]},netdev=net0,mac=${_net_vm[MAC_ADDRESS]}") ;;
        none)
            _net_cmd+=("-nic" "none") ;;
        *)
            _net_cmd+=("-netdev" "user,id=net0")
            _net_cmd+=("-device" "${_net_vm[NETWORK_MODEL]},netdev=net0,mac=${_net_vm[MAC_ADDRESS]}") ;;
    esac
}

# ============================================================================
# AUDIO
# ============================================================================

have_virtiofsd() {
    local _bin
    _bin=$(command -v virtiofsd 2>/dev/null || \
        { [[ -x /usr/lib/virtiofsd ]] && echo /usr/lib/virtiofsd; })
    [[ -n "$_bin" ]] && "$_bin" --version &>/dev/null
}

detect_audio_backend() {
    if pactl info &>/dev/null 2>&1; then echo "pa"
    elif command -v pipewire &>/dev/null; then echo "pipewire"
    elif [[ -e /dev/snd ]]; then echo "alsa"
    else echo "none"
    fi
}

configure_audio() {
    local vm_name="$1"
    local -n _aud_vm="$2"
    local -n _aud_cmd="$3"

    [[ "${_aud_vm[ENABLE_AUDIO]:-0}" != "1" ]] && return 0

    local backend; backend=$(detect_audio_backend)
    if [[ "$backend" == "none" ]]; then
        log_message "WARNING" "No audio backend found (PA/PipeWire/ALSA). Audio disabled." "$vm_name"
        return 0
    fi

    _aud_cmd+=(
        "-audiodev" "${backend},id=audio0"
        "-device"   "intel-hda,id=sound0"
        "-device"   "hda-duplex,audiodev=audio0"
    )
    log_message "INFO" "Audio: intel-hda via $backend" "$vm_name"
}

# ============================================================================
# USB PASSTHROUGH
# ============================================================================

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
                echo "  Tip: run 'lsusb' to find device IDs, then: qemate.sh usb add $vm_name VENDOR:PRODUCT"
            else
                echo "USB devices for VM: $vm_name"
                local dev desc
                for dev in "${usb_array[@]}"; do
                    desc=""
                    desc=$(lsusb 2>/dev/null | grep -i "ID ${dev}" | \
                        sed 's/.*ID [^ ]* //' | head -1) || true
                    printf "  %-12s  %s\n" "$dev" "${desc:-(not currently connected to host)}"
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
        *)
            log_message "ERROR" "Unknown USB action: $action. Use: add, remove, list"
            return 1 ;;
    esac

    VM[USB_DEVICES]=$(IFS=,; echo "${usb_array[*]:-}")
    save_vm_config "$vm_name" VM
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

# ============================================================================
# SHARED FOLDERS
# ============================================================================

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
                local s tag path
                for s in "${share_array[@]}"; do
                    tag="${s%%:*}" path="${s#*:}"
                    printf "  %-15s → %s\n" "$tag" "$path"
                done
            fi
            return 0 ;;
        add)
            local resolved; resolved=$(parse_share_spec "$spec") || return 1
            local new_tag="${resolved%%:*}" new_path="${resolved#*:}"
            
            # Resolve to an absolute path before validation
            new_path=$(realpath -m "$new_path")
            
            [[ ! -d "$new_path" ]] && {
                log_message "ERROR" "Host path does not exist: $new_path"; return 1; }
                
            local s
            for s in "${share_array[@]:-}"; do
                [[ "${s%%:*}" == "$new_tag" ]] && {
                    log_message "ERROR" "Share tag '$new_tag' already exists."; return 1; }
            done
            share_array+=("${new_tag}:${new_path}")
            log_message "INFO" "Share added: $new_tag → $new_path" "$vm_name" ;;
        remove)
            local new_array=() found=0 s
            for s in "${share_array[@]:-}"; do
                [[ "${s%%:*}" != "$spec" ]] && new_array+=("$s") || found=1
            done
            [[ $found -eq 0 ]] && {
                log_message "ERROR" "Share tag not found: $spec" "$vm_name"; return 1; }
            share_array=("${new_array[@]:-}")
            log_message "INFO" "Share removed: $spec" "$vm_name" ;;
    esac

    VM[SHARED_FOLDERS]=$(IFS=,; echo "${share_array[*]:-}")
    save_vm_config "$vm_name" VM
}

configure_shares_virtfs() {
    local vm_name="$1"
    local -n _vfs_vm="$2"
    local -n _vfs_cmd="$3"
    local idx=0

    local shares=(); split_list "${_vfs_vm[SHARED_FOLDERS]:-}" shares
    local s tag path
    for s in "${shares[@]}"; do
        tag="${s%%:*}" path="${s#*:}"
        if [[ ! -d "$path" ]]; then
            log_message "WARNING" "Share path not found, skipping: $path" "$vm_name"
            continue
        fi
        _vfs_cmd+=("-virtfs" \
            "local,path=${path},mount_tag=${tag},security_model=mapped-xattr,id=fsdev${idx}")
        log_message "INFO" "VirtFS: '$tag' → $path" "$vm_name"
        (( idx++ )) || true
    done
}

start_virtiofsd_daemons() {
    local vm_name="$1"
    local -n _svd_vm="$2"
    local socket_dir="$VM_DIR/$vm_name/sockets"

    local shares=()
    split_list "${_svd_vm[SHARED_FOLDERS]:-}" shares

    declare -A seen_tags=()
    local s tag path sock pidf virtiofsd_bin

    virtiofsd_bin=$(command -v virtiofsd 2>/dev/null || \
        { [[ -x /usr/lib/virtiofsd ]] && echo /usr/lib/virtiofsd; })

    if [[ -z "$virtiofsd_bin" ]]; then
        log_message "ERROR" "virtiofsd not found" "$vm_name"
        return 1
    fi

    for s in "${shares[@]}"; do
        tag="${s%%:*}"
        path="${s#*:}"

        if [[ -n "${seen_tags[$tag]:-}" ]]; then
            log_message "ERROR" "Duplicate share tag: $tag" "$vm_name"
            stop_virtiofsd_daemons "$vm_name"
            return 1
        fi
        seen_tags[$tag]=1

        [[ ! -d "$path" ]] && continue

        sock="$socket_dir/virtiofsd_${tag}.sock"
        pidf="$VM_DIR/$vm_name/virtiofsd_${tag}.pid"

        "$virtiofsd_bin" \
            --socket-path="$sock" \
            --shared-dir="$path" \
            --announce-submounts \
            --sandbox=namespace \
            &> "$VM_DIR/$vm_name/logs/virtiofsd_${tag}.log" &

        echo "$!" > "$pidf"

        if ! timeout 4 bash -c "until [[ -S '$sock' ]]; do sleep 0.1; done"; then
            log_message "ERROR" "virtiofsd failed: $tag" "$vm_name"
            stop_virtiofsd_daemons "$vm_name"
            return 1
        fi
        log_message "INFO" "virtiofsd ready: $tag" "$vm_name"
    done
}

stop_virtiofsd_daemons() {
    local vm_name="$1"
    local pid_file pid
    
    # Use a glob to catch all instances (Production, Backup, etc.)
    for pid_file in "$VM_DIR/$vm_name"/virtiofsd_*.pid; do
        [[ -e "$pid_file" ]] || continue
        
        pid=$(cat "$pid_file")
        
        # Check if the process actually exists and is virtiofsd
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            
            # Give it a moment to exit gracefully, then force
            sleep 0.5
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
        fi
        
        # Always remove the PID file, even if the process was already dead
        rm -f "$pid_file"
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
        tag="${s%%:*}"
        sock="$socket_dir/virtiofsd_${tag}.sock"
        if [[ ! -S "$sock" ]]; then
            log_message "WARNING" "virtiofsd socket missing for share: $tag" "$vm_name"; continue
        fi
        _cvf_cmd+=(
            "-chardev" "socket,id=char_${tag},path=${sock}"
            "-device"  "vhost-user-fs-pci,chardev=char_${tag},tag=${tag}"
        )
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
            log_message "INFO" "Using VirtIO-FS (multi-share capable)" "$vm_name"
            start_virtiofsd_daemons "$vm_name" _cs_vm || return 1
            configure_shares_virtiofs "$vm_name" _cs_vm _cs_cmd ;;
        virtfs)
            log_message "INFO" "Using VirtFS (9p fallback)" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
        smb)
            log_message "INFO" "Using SMB (single share)" "$vm_name" ;;
        *)
            log_message "WARNING" "Unknown backend '$backend', falling back to virtfs" "$vm_name"
            configure_shares_virtfs "$vm_name" _cs_vm _cs_cmd ;;
    esac
}

# ============================================================================
# TPM 2.0
# ============================================================================

configure_tpm() {
    local vm_name="$1"
    local -n _tpm_vm="$2"
    local -n _tpm_cmd="$3"

    [[ "${_tpm_vm[ENABLE_TPM]:-0}" != "1" ]] && return 0

    if ! command -v swtpm &>/dev/null; then
        log_message "WARNING" "swtpm not found — TPM disabled." "$vm_name"
        return 0
    fi

    local tpm_dir="$VM_DIR/$vm_name/tpm"
    local tpm_sock="$VM_DIR/$vm_name/sockets/swtpm.sock"
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"
    mkdir -p "$tpm_dir"

    if [[ ! -f "$tpm_dir/tpm2-00.permall" ]]; then
        swtpm_setup --tpm2 --tpmstate "$tpm_dir" --createek --allow-signing \
            --decryption --create-ek-cert --create-platform-cert \
            --lock-nvram --not-overwrite &>/dev/null || true
    fi

    swtpm socket --tpm2 --tpmstate "dir=$tpm_dir" \
        --ctrl "type=unixio,path=$tpm_sock" \
        --daemon --pid "file=$tpm_pid" --log "level=0"

    local i
    for (( i=0; i<20; i++ )); do
        [[ -S "$tpm_sock" ]] && break
        sleep 0.2
    done

    if [[ ! -S "$tpm_sock" ]]; then
        log_message "WARNING" "swtpm failed to start" "$vm_name"
        return 0
    fi

    _tpm_cmd+=(
        "-chardev" "socket,id=chrtpm,path=$tpm_sock"
        "-tpmdev"  "emulator,id=tpm0,chardev=chrtpm"
        "-device"  "tpm-crb,tpmdev=tpm0"
    )
    log_message "INFO" "TPM 2.0 enabled" "$vm_name"
}

stop_tpm() {
    local vm_name="$1"
    local tpm_pid="$VM_DIR/$vm_name/swtpm.pid"
    [[ -f "$tpm_pid" ]] || return 0
    local pid; pid=$(cat "$tpm_pid")
    kill "$pid" 2>/dev/null || true
    rm -f "$tpm_pid"
}

# ============================================================================
# DISPLAY
# ============================================================================

configure_display() {
    local vm_name="$1"
    local -n _dsp_vm="$2"
    local -n _dsp_cmd="$3"
    local headless="$4"

    if [[ "$headless" == "1" ]]; then
        _dsp_cmd+=("-display" "none")
        return 0
    fi

    local video="${_dsp_vm[VIDEO_TYPE]:-virtio-vga}"
    local base_video="${video%%,*}"

    if [[ "${_dsp_vm[SPICE_ENABLED]:-0}" == "1" ]]; then
        if [[ "$base_video" != qxl* && "$base_video" != virtio-vga && \
              "$base_video" != virtio-gpu ]]; then
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
        # NOTE: virtio-serial-pci is intentionally omitted here.
        # It is already added by start() for the guest agent. The vdagent
        # virtserialport attaches to that same controller without redeclaring it.
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

configure_cpu() {
    local vm_name="$1"
    local -n _cpu_vm="$2"
    local -n _cpu_cmd="$3"

    if [[ "${_cpu_vm[OS_TYPE]:-linux}" == "windows" ]]; then
        local smp_cores=$(( _cpu_vm[CORES] / 2 ))
        (( smp_cores < 1 )) && smp_cores=1

        _cpu_cmd+=("-smp" "${_cpu_vm[CORES]},cores=${smp_cores},threads=2,sockets=1")
        _cpu_cmd+=(
            "-cpu" "${_cpu_vm[CPU_TYPE]},hv-relaxed,hv-vapic,hv-spinlocks=0x1fff,hv-time,hv-vpindex,hv-synic,hv-stimer,hv-stimer-direct,hv-reset,hv-frequencies,hv-runtime,hv-tlbflush,hv-reenlightenment,hv-ipi,kvm=off,l3-cache=on,+topoext"
        )
        _cpu_cmd+=("-global" "kvm-pit.lost_tick_policy=delay")
        _cpu_cmd+=("-rtc"    "base=localtime,clock=host,driftfix=slew")
        _cpu_cmd+=("-device" "virtio-rng-pci")
        _cpu_cmd+=("-device" "virtio-tablet-pci")
        _cpu_cmd+=("-device" "virtio-balloon-pci")
    else
        _cpu_cmd+=("-smp" "${_cpu_vm[CORES]}")
        _cpu_cmd+=("-cpu" "${_cpu_vm[CPU_TYPE]}")
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

    local disk_file="$VM_DIR/$vm_name/disk.qcow2"
    local drive_opts="format=qcow2,cache=${_dsk_vm[DISK_CACHE]},aio=${_dsk_vm[DISK_IO]},discard=${_dsk_vm[DISK_DISCARD]}"

    # Define a dedicated IOThread for asynchronous disk processing
    _dsk_cmd+=("-object" "iothread,id=iothread0")

    case "${_dsk_vm[DISK_INTERFACE]}" in
        virtio)
            _dsk_cmd+=("-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}")
            _dsk_cmd+=("-device" "virtio-blk-pci,drive=drive0,iothread=iothread0,num-queues=${_dsk_vm[CORES]}") ;;
        nvme)
            _dsk_cmd+=("-drive"  "file=${disk_file},if=none,id=drive0,${drive_opts}")
            _dsk_cmd+=("-device" "nvme,drive=drive0,serial=qemate-nvme,num_queues=${_dsk_vm[CORES]},iothread=iothread0") ;;

        *)
            _dsk_cmd+=("-drive"  "file=${disk_file},if=${_dsk_vm[DISK_INTERFACE]},${drive_opts}") ;;
    esac
}

# ============================================================================
# CORE VM MANAGEMENT
# ============================================================================

create() {
    local vm_name="$1"; shift
    local os_type="linux" memory="" cores="" disk_size="" machine_type="" machine_options="" \
          enable_audio="" enable_tpm="" spice_enabled="" share_backend=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --os-type)       os_type="$2";        shift 2 ;;
            --memory)        memory="$2";          shift 2 ;;
            --cores)         cores="$2";           shift 2 ;;
            --disk-size)     disk_size="$2";       shift 2 ;;
            --machine)       
                [[ "$2" =~ ^([^,]+)(,(accel=kvm|accel=tcg))?$ ]] || {
                    log_message "ERROR" "Invalid machine: '$2'. Use e.g. q35,accel=kvm"; return 1; }
                machine_type="${BASH_REMATCH[1]}"
                machine_options="${BASH_REMATCH[3]:-accel=kvm}"
                shift 2 ;;
            --enable-audio)  enable_audio="1";     shift ;;
            --no-audio)      enable_audio="0";     shift ;;
            --enable-tpm)    enable_tpm="1";       shift ;;
            --no-tpm)        enable_tpm="0";       shift ;;
            --spice)         spice_enabled="1";    shift ;;
            --no-spice)      spice_enabled="0";    shift ;;
            --share-backend) share_backend="$2";   shift 2 ;;
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
        
        if [[ -f /proc/meminfo ]]; then
            local avail; avail=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
            if [[ -n "$avail" ]]; then
                local check=$mem_val; [[ "${mem_unit^^}" == "G" ]] && check=$((mem_val * 1024))
                [[ "$check" -gt $((avail * 90 / 100)) ]] && {
                    log_message "ERROR" \
                        "Memory $memory exceeds 90% of available RAM (${avail}M available)"; return 1; }
            fi
        fi
    fi

    [[ -n "$disk_size" && ! "$disk_size" =~ ^[0-9]+[GMgm]$ ]] && {
        log_message "ERROR" "Invalid disk size: '$disk_size'. Use e.g. 60G"; return 1; }

    local -A VM=()
    apply_os_defaults "$os_type" VM

    [[ -n "$cores"           ]] && VM[CORES]="$cores"
    [[ -n "$memory"          ]] && VM[MEMORY]="$memory"
    [[ -n "$disk_size"       ]] && VM[DISK_SIZE]="$disk_size"
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

    mkdir -p -m 700 "$VM_DIR/$vm_name"/{logs,sockets,tpm} || {
        log_message "ERROR" "Failed to create VM directories" "$vm_name"; return 1; }

    if ! qemu-img create -f qcow2 "$VM_DIR/$vm_name/disk.qcow2" "${VM[DISK_SIZE]}" &>/dev/null; then
        log_message "ERROR" "Failed to create disk image" "$vm_name"
        rm -rf "${VM_DIR:?}/${vm_name:?}"; return 1
    fi
    chmod 600 "$VM_DIR/$vm_name/disk.qcow2"

    save_vm_config "$vm_name" VM
    log_message "INFO" \
        "VM '$vm_name' created (OS: $os_type | Mem: ${VM[MEMORY]} | Cores: ${VM[CORES]} | Disk: ${VM[DISK_SIZE]})" \
        "$vm_name"
}

start() {
    local vm_name="$1"; shift
    local headless="0" iso_file="" virtio_iso="" debug="0"
    export PATH="$VM_DIR/$vm_name/bin:$PATH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --headless)   headless="1";    shift ;;
            --iso)        iso_file="$2";   shift 2 ;;
            --virtio-iso) virtio_iso="$2"; shift 2 ;;
            --debug)      debug="1";       shift ;;
            *) log_message "ERROR" "Unknown option: $1"; return 1 ;;
        esac
    done

    QEMATE_ACTIVE_VM="$vm_name"
    QEMATE_PHASE="starting"

    if ! vm_is_running "$vm_name"; then
        stop_virtiofsd_daemons "$vm_name"
        stop_tpm "$vm_name"
    fi

    require_vm "$vm_name" exists not-running || return 1
    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    check_vm_dependencies "$vm_name" VM || return 1
    log_message "INFO" "Starting VM: $vm_name" "$vm_name"

    [[ "${VM[MACHINE_OPTIONS]}" =~ accel=kvm ]] && [[ ! -w /dev/kvm ]] && {
        log_message "ERROR" \
            "/dev/kvm not writable. Run: sudo usermod -aG kvm $USER (then re-login)"
        return 1; }

    if [[ -n "${VM[SHARED_FOLDERS]:-}" ]]; then
        local eff_be; eff_be=$(resolve_share_backend VM)
        [[ "$eff_be" == "virtiofs" ]] && VM[MEMORY_SHARE]=1
    fi

    # Build the -machine string here so hpet=off can be appended for Windows
    # without emitting a second -machine flag from configure_cpu.
    local machine_str="${VM[MACHINE_TYPE]},${VM[MACHINE_OPTIONS]}"
    [[ "${VM[OS_TYPE]:-linux}" == "windows" ]] && machine_str+=",hpet=off"

    local qemu_cmd=(
        "qemu-system-x86_64"
        "-name"    "${VM[NAME]},process=${VM[NAME]}"
        "-machine" "$machine_str"
        "-pidfile" "$VM_DIR/$vm_name/qemu.pid"
    )

    configure_cpu    "$vm_name" VM qemu_cmd
    configure_memory "$vm_name" VM qemu_cmd

    # virtio-serial-pci declared once here; SPICE vdagent port reuses it.
    qemu_cmd+=(
        "-device"  "qemu-xhci,id=usb,bus=pcie.0"
        "-device"  "usb-kbd,bus=usb.0"
        "-device"  "virtio-serial-pci"
        "-device"  "virtserialport,chardev=chara0,name=org.qemu.guest_agent.0"
        "-chardev" "socket,id=chara0,path=$VM_DIR/$vm_name/sockets/qga.sock,server=on,wait=off"
    )

    configure_display        "$vm_name" VM qemu_cmd "$headless"
    configure_disk           "$vm_name" VM qemu_cmd

    if [[ -n "$iso_file" ]]; then
        iso_file=$(realpath "$iso_file")
        [[ ! -f "$iso_file" ]] && { log_message "ERROR" "ISO not found: $iso_file"; return 1; }
        qemu_cmd+=(
            "-drive" "file=${iso_file},format=raw,readonly=on,media=cdrom,id=cdrom0"
            "-boot"  "menu=on,order=dc"
        )
    fi

    if [[ -n "$virtio_iso" ]]; then
        virtio_iso=$(realpath "$virtio_iso")
        [[ ! -f "$virtio_iso" ]] && {
            log_message "ERROR" "VirtIO ISO not found: $virtio_iso"; return 1; }
        qemu_cmd+=(
            "-drive" "file=${virtio_iso},format=raw,readonly=on,media=cdrom,id=cdrom1"
        )
    fi

    configure_audio           "$vm_name" VM qemu_cmd
    configure_usb_passthrough "$vm_name" VM qemu_cmd
    configure_shares          "$vm_name" VM qemu_cmd || { stop_virtiofsd_daemons "$vm_name"; return 1; }
    configure_tpm             "$vm_name" VM qemu_cmd
    configure_network         "$vm_name" VM qemu_cmd

    # --debug: dump the full QEMU command to the log before launching
    if [[ "$debug" == "1" ]]; then
        log_message "DEBUG" "QEMU command: ${qemu_cmd[*]}" "$vm_name"
    fi

    local lockfile="$VM_DIR/$vm_name/qemu.pid.lock"
    local _fd
    acquire_flock "$lockfile" _fd || {
        log_message "ERROR" "Cannot acquire start lock"; return 1; }

    log_message "INFO" "VM process launched. Waiting for shutdown..." "$vm_name"
    QEMATE_PHASE="running"

    if PATH="$VM_DIR/$vm_name/bin:$PATH" "${qemu_cmd[@]}" {_fd}>&- 2>"$VM_DIR/$vm_name/logs/error.log"; then
        log_message "INFO" "VM process terminated. Initiating sidecar cleanup..." "$vm_name"
        stop_virtiofsd_daemons "$vm_name"
        stop_tpm "$vm_name"
        rm -f "$VM_DIR/$vm_name/qemu.pid"
        flock -u "$_fd"
        exec {_fd}>&-
        QEMATE_PHASE="stopped"
        log_message "INFO" "Cleanup complete. Session ended." "$vm_name"
        return 0
    else
        log_message "ERROR" "QEMU failed to launch or crashed. Check error.log" "$vm_name"
        stop_virtiofsd_daemons "$vm_name"
        stop_tpm "$vm_name"
        rm -f "$VM_DIR/$vm_name/qemu.pid"
        flock -u "$_fd"
        exec {_fd}>&-
        QEMATE_PHASE="failed"
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
    local pid; pid=$(cat "$VM_DIR/$vm_name/qemu.pid")
    if ! kill -0 "$pid" 2>/dev/null; then
        log_message "ERROR" "VM is not running"; return 1
    fi
    log_message "INFO" "Stopping VM: $vm_name" "$vm_name"

    if [[ "$force" == "true" ]]; then
        kill -9 "$pid" || true
    else
        kill -15 "$pid" || true
        local i
        for (( i=0; i<30; i++ )); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" || true; fi
    fi
    rm -f "$VM_DIR/$vm_name/qemu.pid"
    stop_virtiofsd_daemons "$vm_name"
    stop_tpm "$vm_name"
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
    vm_exists "$vm_name" || { log_message "ERROR" "VM not found"; return 1; }
    vm_is_locked "$vm_name" && [[ "$force" != "true" ]] && {
        log_message "ERROR" "VM is locked. Use --force to override."; return 1; }
    vm_is_running "$vm_name" && {
        log_message "ERROR" "VM is running. Stop it first."; return 1; }

    if [[ "$force" != "true" ]]; then
        echo -n "Delete VM '$vm_name' and all its data? [y/N]: "
        read -r confirm
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
    vm_is_running "$vm_name" && [[ "$force" != "true" ]] && {
        log_message "ERROR" "VM is running. Use --force (requires online resize support)." "$vm_name"
        return 1; }

    [[ ! "$new_size" =~ ^(\+)?[0-9]+[GMgm]$ ]] && {
        log_message "ERROR" "Invalid size: '$new_size'. Use e.g. 80G or +20G" "$vm_name"
        return 1; }

    log_message "INFO" "Resizing disk to $new_size..." "$vm_name"
    if ! qemu-img resize "$VM_DIR/$vm_name/disk.qcow2" "$new_size"; then
        log_message "ERROR" "Resize failed." "$vm_name"
        return 1
    fi

    local bytes_size; bytes_size=$(qemu-img info "$VM_DIR/$vm_name/disk.qcow2" | grep '^virtual size:' | sed -E 's/.* \(([0-9]+) bytes\)/\1/')
    if [[ -n "$bytes_size" ]]; then
        local gigabytes=$(( bytes_size / 1073741824 ))
        local -A VM=()
        load_vm_config "$vm_name" VM || return 1
        VM[DISK_SIZE]="${gigabytes}G"
        save_vm_config "$vm_name" VM
        log_message "INFO" "Disk resized to ${gigabytes}G" "$vm_name"
    fi
}

list() {
    [[ ! -d "$VM_DIR" ]] && { echo "No VMs found."; return 0; }
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "NAME" "STATUS" "LOCKED" "OS" "AUDIO" "TPM" "SPICE"
    printf "%-18s %-10s %-8s %-10s %-6s %-5s %-5s\n" \
        "----" "------" "------" "--" "-----" "---" "-----"
    local vm_path name stat lock
    for vm_path in "$VM_DIR"/*/; do
        [[ -d "$vm_path" ]] || continue
        name=$(basename "$vm_path")
        stat="stopped"; vm_is_running "$name" && stat="running"
        lock="no";      vm_is_locked  "$name" && lock="yes"
        
        local -A VM=()
        local os="?" audio="?" tpm="?" spice="?"
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
    printf "  %-16s %s\n" "OS Type:"       "${VM[OS_TYPE]:-?}"
    printf "  %-16s %s\n" "CPU:"           "${VM[CPU_TYPE]} × ${VM[CORES]} cores"
    printf "  %-16s %s\n" "Memory:"        "${VM[MEMORY]}"
    printf "  %-16s %s\n" "Machine:"       "${VM[MACHINE_TYPE]} (${VM[MACHINE_OPTIONS]})"
    printf "  %-16s %s\n" "Video:"         "${VM[VIDEO_TYPE]}"
    printf "  %-16s %s\n" "Disk Interface:" "${VM[DISK_INTERFACE]}"
    printf "  %-16s %s\n" "Disk Size:"     "${VM[DISK_SIZE]}"
    printf "  %-16s %s\n" "Network:"       "${VM[NETWORK_TYPE]} / ${VM[NETWORK_MODEL]}"
    printf "  %-16s %s\n" "Share backend:" "${VM[SHARE_BACKEND]:-auto}"

    [[ -n "${VM[PORT_FORWARDS]:-}" ]] && \
        printf "  %-16s %s\n" "Port forwards:" "${VM[PORT_FORWARDS]}"

    if [[ -n "${VM[USB_DEVICES]:-}" ]]; then
        echo "  USB passthrough:"
        local usb_arr=(); split_list "${VM[USB_DEVICES]}" usb_arr
        local dev
        for dev in "${usb_arr[@]}"; do
            printf "    • %s\n" "$dev"
        done
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

configure() {
    local vm_name="$1" setting="${2:-}" value="${3:-}"
    require_vm "$vm_name" exists || return 1
    vm_is_running "$vm_name" && {
        log_message "ERROR" "Stop the VM before configuring"; return 1; }

    if [[ "$setting" == "--raw" ]]; then
        vm_is_locked "$vm_name" && {
            log_message "ERROR" "VM is locked. Run 'security unlock $vm_name' first."; return 1; }
        local config_file="$VM_DIR/$vm_name/config"
        local backup; backup="$(mktemp)"
        cp "$config_file" "$backup"
        "${EDITOR:-nano}" "$config_file"
        
        local -A _vtmp=()
        if ! load_vm_config "$vm_name" _vtmp 2>/dev/null; then
            log_message "ERROR" "Config validation failed after editing." "$vm_name"
            echo -n "Restore previous config? [Y/n]: "
            read -r _restore
            if [[ ! "$_restore" =~ ^[Nn]$ ]]; then
                cp "$backup" "$config_file"
                log_message "INFO" "Config restored." "$vm_name"
            fi
        fi
        rm -f "$backup"
        return 0
    fi

    [[ -z "$setting" || -z "$value" ]] && {
        log_message "ERROR" "Missing setting or value: vm configure $vm_name <setting> <value>"; return 1; }

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    case "$setting" in
        cores)
            [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 1 || "$value" -gt 64 ]] && {
                log_message "ERROR" "Invalid cores: '$value' (must be 1–64)"; return 1; }
            VM[CORES]="$value" ;;
        memory)
            [[ ! "$value" =~ ^[0-9]+[GMgm]$ ]] && {
                log_message "ERROR" "Invalid memory: '$value' (use e.g. 4G or 2048M)"; return 1; }
            VM[MEMORY]="$value" ;;
        audio)
            VM[ENABLE_AUDIO]=$( [[ "$value" =~ ^(on|1|true)$ ]] && echo 1 || echo 0 ) ;;
        tpm)
            VM[ENABLE_TPM]=$(   [[ "$value" =~ ^(on|1|true)$ ]] && echo 1 || echo 0 ) ;;
        spice)
            VM[SPICE_ENABLED]=$([[ "$value" =~ ^(on|1|true)$ ]] && echo 1 || echo 0 ) ;;
        spice-port)
            [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 1024 || "$value" -gt 65535 ]] && {
                log_message "ERROR" "Invalid port: '$value' (must be 1024–65535)"; return 1; }
            VM[SPICE_PORT]="$value" ;;
        video)
            local base_val="${value%%,*}"
            case "$base_val" in
                virtio-vga|virtio-gpu|qxl-vga|qxl|std|vmware) ;;
                *) log_message "ERROR" "Invalid video. Use: virtio-vga, virtio-gpu, qxl-vga, qxl, std, vmware"; return 1 ;;
            esac
            VM[VIDEO_TYPE]="$value" ;;
        network-type)
            case "$value" in
                user|nat|none) VM[NETWORK_TYPE]="$value" ;;
                *) log_message "ERROR" "Invalid network-type. Use: user, nat, none"; return 1 ;;
            esac ;;
        network-model)
            case "$value" in
                virtio-net-pci|e1000|rtl8139) VM[NETWORK_MODEL]="$value" ;;
                *) log_message "ERROR" "Invalid network-model. Use: virtio-net-pci, e1000, rtl8139"; return 1 ;;
            esac ;;
        share-backend)
            case "$value" in
                auto|virtfs|smb|virtiofs) ;;
                *) log_message "ERROR" "Invalid share-backend. Use: auto, virtfs, smb, virtiofs"; return 1 ;;
            esac
            VM[SHARE_BACKEND]="$value" ;;
        vram)
            [[ ! "$value" =~ ^[0-9]+$ || "$value" -lt 16 || "$value" -gt 512 ]] && {
                log_message "ERROR" "Invalid vram (MiB): '$value' (16–512 recommended)"; return 1; }
            VM[VRAM_SIZE_MB]="$value" ;;
        *)
            echo "Available settings: cores, memory, audio, tpm, spice, spice-port, video, network-type, network-model, share-backend, vram"
            return 1 ;;
    esac
    save_vm_config "$vm_name" VM
    log_message "INFO" "Set $setting=$value for VM: $vm_name" "$vm_name"
}

lock()   { lock_unlock "$1" "1"; }
unlock() { lock_unlock "$1" "0"; }
lock_unlock() {
    local vm_name="$1" state="$2"
    require_vm "$vm_name" exists || return 1

    local -A VM=()
    load_vm_config "$vm_name" VM || return 1
    VM[LOCKED]="$state"
    save_vm_config "$vm_name" VM
    log_message "INFO" \
        "VM $vm_name $( [[ "$state" == "1" ]] && echo "locked" || echo "unlocked" )"
}

# ============================================================================
# HELP
# ============================================================================

display_help() {
    cat <<'EOF'
╭─────────────────────────────────────────────────────────────────────────╮
│                           🖥️  QEMATE v4.1.0                             │
╰─────────────────────────────────────────────────────────────────────────╯
Usage: qemate.sh <command> [subcommand] [args]

VM COMMANDS
  vm create <n> [options]
    --os-type linux|windows      OS preset  (default: linux)
    --memory  SIZE               e.g. 4G, 8G
    --cores   N                  CPU cores
    --disk-size SIZE             e.g. 60G
    --enable-audio / --no-audio
    --enable-tpm   / --no-tpm    TPM 2.0 (needs swtpm)
    --spice        / --no-spice  SPICE display + clipboard (auto-on for Windows)
    --share-backend auto|virtfs|smb|virtiofs

  vm start     <n> [--headless] [--iso PATH] [--virtio-iso PATH] [--debug]
  vm stop      <n> [--force]
  vm delete    <n> [--force]
  vm resize    <n> <SIZE> [--force]
  vm list
  vm status    <n>
  vm configure <n> <setting> <value>
    settings: cores, memory, audio, tpm, spice, spice-port, video, network-type, network-model, share-backend, vram
  vm configure <n> --raw         open config in $EDITOR directly (use with caution)

USB PASSTHROUGH
  usb add    <n> <vendor:product>   e.g.  usb add myvm 046d:c52b
  usb remove <n> <vendor:product>
  usb list   <n>

SHARED FOLDERS
  share add    <n> /host/path           tag auto-derived from folder name
  share add    <n> tag:/host/path       explicit tag
  share remove <n> <tag>
  share list   <n>

NETWORK PORT FORWARDING
  net port add    <n> <[ip:]host:guest[:tcp|udp]>
  net port remove <n> <[ip:]host:guest[:tcp|udp]>

SECURITY COMMANDS
  security lock|unlock <n>
EOF
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    [[ "${BASH_VERSION%%.*}" -ge 5 ]] || { echo "Error: Bash 5+ required"; exit 1; }
    
    # Global Help Intercept
    local arg
    for arg in "$@"; do
        if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
            display_help; exit 0
        fi
    done

    mkdir -p "$VM_DIR"
    [[ $# -eq 0 ]] && { display_help; exit 1; }

    local _cmd
    for _cmd in qemu-system-x86_64 qemu-img; do
        if ! command -v "$_cmd" &>/dev/null; then
            echo "Error: required binary '$_cmd' not found in PATH." >&2
            exit 1
        fi
    done

    local category="$1"; shift
    case "$category" in
        vm)
            [[ $# -eq 0 ]] && { display_help; exit 1; }
            local action="$1"; shift
            case "$action" in
                create)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm create'";    exit 1; }
                    create     "$@" ;;
                start)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm start'";     exit 1; }
                    start      "$@" ;;
                stop)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm stop'";      exit 1; }
                    stop       "$@" ;;
                delete)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm delete'";    exit 1; }
                    delete     "$@" ;;
                resize)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm resize'";    exit 1; }
                    resize_disk "$@" ;;
                status)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm status'";    exit 1; }
                    status     "$@" ;;
                configure)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required for 'vm configure'"; exit 1; }
                    configure  "$@" ;;
                list) list ;;
                *) display_help; exit 1 ;;
            esac ;;
        net)
            [[ $# -eq 0 ]] && { display_help; exit 1; }
            local action="$1"; shift
            case "$action" in
                port)
                    [[ $# -lt 3 ]] && {
                        echo "Error: need subaction, VM name, and port spec"; exit 1; }
                    local subaction="$1"; shift
                    case "$subaction" in
                        add)    manage_network_ports "$1" "add"    "$2" ;;
                        remove) manage_network_ports "$1" "remove" "$2" ;;
                        *) echo "Usage: net port <add|remove> ..."; exit 1 ;;
                    esac ;;
                *) display_help; exit 1 ;;
            esac ;;
        usb)
            [[ $# -lt 1 ]] && { display_help; exit 1; }
            local action="$1"; shift
            [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }
            local vm_name="$1"; shift
            case "$action" in
                list)   manage_usb "$vm_name" "list" ;;
                add)
                    [[ $# -eq 0 ]] && { echo "Error: USB vendor:product required"; exit 1; }
                    manage_usb "$vm_name" "add" "$1" ;;
                remove)
                    [[ $# -eq 0 ]] && { echo "Error: USB vendor:product required"; exit 1; }
                    manage_usb "$vm_name" "remove" "$1" ;;
                *) display_help; exit 1 ;;
            esac ;;
        share)
            [[ $# -lt 1 ]] && { display_help; exit 1; }
            local action="$1"; shift
            [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }
            local vm_name="$1"; shift
            case "$action" in
                list)   manage_shares "$vm_name" "list" ;;
                add)
                    [[ $# -eq 0 ]] && { echo "Error: host path required"; exit 1; }
                    manage_shares "$vm_name" "add" "$1" ;;
                remove)
                    [[ $# -eq 0 ]] && { echo "Error: share tag required"; exit 1; }
                    manage_shares "$vm_name" "remove" "$1" ;;
                *) display_help; exit 1 ;;
            esac ;;
        security)
            [[ $# -eq 0 ]] && { display_help; exit 1; }
            local action="$1"; shift
            case "$action" in
                lock)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }
                    lock   "$@" ;;
                unlock)
                    [[ $# -eq 0 ]] && { echo "Error: VM name required"; exit 1; }
                    unlock "$@" ;;
                *) display_help; exit 1 ;;
            esac ;;
        *) display_help; exit 1 ;;
    esac
}

main "$@"