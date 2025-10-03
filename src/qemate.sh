#!/bin/bash

# qemate - Streamlined QEMU Virtual Machine Management Utility.
# Version: 3.0.1

# Exit on error, undefined variable, or pipe failure.
set -euo pipefail

# ============================================================================
# ENVIRONMENT SETUP AND CONSTANTS
# ============================================================================

readonly VM_DIR="$HOME/QVMs"
readonly LOG_LEVEL="${LOG_LEVEL:-INFO}"

# Default VM configurations
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
    [VIDEO_TYPE]="virtio-gpu"
    [DISK_CACHE]=writeback
    [DISK_IO]=threads
    [DISK_DISCARD]=unmap
    [ENABLE_VIRTIO]=1
    [MEMORY_PREALLOC]=0
    [MEMORY_SHARE]=1
)

declare -A WINDOWS_DEFAULTS=(
    [CORES]=2
    [MEMORY]="4G"
    [DISK_SIZE]=60G
    [NETWORK_TYPE]=user
    [NETWORK_MODEL]=e1000
    [DISK_INTERFACE]=ide-hd
    [ENABLE_AUDIO]=1
    [CPU_TYPE]=host
    [MACHINE_TYPE]=q35
    [VIDEO_TYPE]=virtio-vga
    [DISK_CACHE]=writeback
    [DISK_IO]=threads
    [DISK_DISCARD]=unmap
    [ENABLE_VIRTIO]=0
    [MEMORY_PREALLOC]=0
    [MEMORY_SHARE]=1
)

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Handles logging to console based on LOG_LEVEL.
log_message() {
    local level="$1"
    local message="$2"
    local vm_name="${3:-}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    # Validate log level
    case "$level" in
        "DEBUG" | "INFO" | "WARNING" | "ERROR") ;;
        *)
            echo "[ERROR] Invalid log level: $level" >&2
            return 1
            ;;
    esac

    # Check if we should output to console based on LOG_LEVEL
    local should_output=false
    case "$LOG_LEVEL" in
        "DEBUG")
            should_output=true
            ;;
        "INFO")
            [[ "$level" =~ ^(INFO|WARNING|ERROR)$ ]] && should_output=true
            ;;
        "WARNING")
            [[ "$level" =~ ^(WARNING|ERROR)$ ]] && should_output=true
            ;;
        "ERROR")
            [[ "$level" == "ERROR" ]] && should_output=true
            ;;
        *)
            [[ "$level" =~ ^(INFO|WARNING|ERROR)$ ]] && should_output=true
            ;;
    esac

    # Output to console if appropriate
    if [[ "$should_output" == true ]]; then
        echo "[$level] $message" >&2
    fi

    # Write to VM-specific log file if vm_name is provided
    if [[ -n "$vm_name" ]] && [[ -d "$VM_DIR/$vm_name/logs" ]]; then
        local log_file="$VM_DIR/$vm_name/logs/qemate_vm.log"
        local error_file="$VM_DIR/$vm_name/logs/error.log"

        # Always write to main VM log
        echo "$timestamp [$level] $message" >> "$log_file"

        # Also write errors to error-specific log
        if [[ "$level" == "ERROR" ]]; then
            echo "$timestamp [$level] $message" >> "$error_file"
        fi
    fi
}

# Checks if a VM directory exists
vm_exists() {
    local vm_name="$1"
    [[ -d "$VM_DIR/$vm_name" ]]
}

# Checks if a VM is running by verifying its PID
vm_is_running() {
    local vm_name="$1"
    local pidfile="$VM_DIR/$vm_name/qemu.pid"
    local lockfile="$pidfile.lock"

    if [[ -f "$pidfile" ]]; then
        local pid
        pid=$(cat "$pidfile")
        if kill -0 "$pid" 2> /dev/null; then
            return 0
        else
            # Acquire lock only when removing stale PID file
            exec 200> "$lockfile"
            if flock -n 200; then
                log_message "WARNING" "Removing stale PID file for VM: $vm_name" "$vm_name"
                rm -f "$pidfile"
                flock -u 200
            else
                log_message "WARNING" "Cannot remove stale PID file for VM: $vm_name (lock held)" "$vm_name"
            fi
            return 1
        fi
    else
        return 1
    fi
}

# Checks if a VM is locked
vm_is_locked() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config"

    if [[ -f "$config_file" ]]; then
        local LOCKED
        # shellcheck disable=SC1090
        source "$config_file"
        [[ "$LOCKED" == "1" ]]
    else
        return 1
    fi
}

# Validates that VM name is non-empty and contains only allowed characters
validate_vm_name() {
    local vm_name="$1"

    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name cannot be empty"
        return 1
    fi

    if [[ ! "$vm_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_message "ERROR" "VM name can only contain letters, numbers, hyphens, and underscores"
        return 1
    fi
}

# Generates a deterministic MAC address
generate_mac_address() {
    local vm_name="$1"
    printf "52:54:00:%s" "$(echo -n "$vm_name" | md5sum | cut -c1-6 | sed 's/../&:/g;s/:$//')"
}

load_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config"
    local lockfile="$config_file.lock"

    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        log_message "ERROR" "Configuration file not found or not readable for VM: $vm_name" "$vm_name"
        return 1
    fi

    # Added: Lock the config file during read
    exec 200> "$lockfile"
    if ! flock -n 200; then
        log_message "ERROR" "Cannot acquire lock on config file for VM: $vm_name" "$vm_name"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$config_file"
    # Validate required variables
    for var in NAME CORES MEMORY NETWORK_TYPE NETWORK_MODEL DISK_INTERFACE VIDEO_TYPE; do
        if [[ -z "${!var:-}" ]]; then
            log_message "ERROR" "Configuration file missing required variable: $var" "$vm_name"
            flock -u 200
            return 1
        fi
    done
    flock -u 200
}

# Saves VM configuration to file
save_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config"
    local lockfile="$config_file.lock"

    # Added: Lock the config file during write
    exec 200> "$lockfile"
    if ! flock -n 200; then
        log_message "ERROR" "Cannot acquire lock on config file for VM: $vm_name" "$vm_name"
        return 1
    fi

    cat <<- EOF > "$config_file"
NAME="$vm_name"
MACHINE_TYPE="${MACHINE_TYPE:-q35}"
CORES=${CORES:-2}
MEMORY="${MEMORY:-2G}"
MAC_ADDRESS="${MAC_ADDRESS:-$(generate_mac_address "$vm_name")}"
NETWORK_TYPE="${NETWORK_TYPE:-user}"
NETWORK_MODEL="${NETWORK_MODEL:-virtio-net-pci}"
CPU_TYPE="${CPU_TYPE:-host}"
MACHINE_OPTIONS="${MACHINE_OPTIONS:-accel=kvm}"
VIDEO_TYPE="${VIDEO_TYPE:-virtio-vga}"
DISK_INTERFACE="${DISK_INTERFACE:-virtio}"
DISK_CACHE="${DISK_CACHE:-writeback}"
DISK_IO="${DISK_IO:-threads}"
DISK_DISCARD="${DISK_DISCARD:-unmap}"
ENABLE_VIRTIO=${ENABLE_VIRTIO:-1}
MEMORY_PREALLOC=${MEMORY_PREALLOC:-0}
MEMORY_SHARE=${MEMORY_SHARE:-1}
LOCKED="${LOCKED:-0}"
OS_TYPE="${OS_TYPE:-linux}"
ENABLE_AUDIO=${ENABLE_AUDIO:-0}
PORT_FORWARDING_ENABLED=${PORT_FORWARDING_ENABLED:-0}
PORT_FORWARDS="${PORT_FORWARDS:-}"
SHARED_FOLDERS="${SHARED_FOLDERS:-}"
USB_DEVICES="${USB_DEVICES:-}"
EOF
    log_message "DEBUG" "Configuration saved for VM: $vm_name" "$vm_name"
    flock -u 200
}

# ============================================================================
# CORE VM MANAGEMENT
# ============================================================================

# Creates a new VM with specified parameters
create() {
    local vm_name="$1"
    local os_type="${2:-linux}"
    local memory="${3:-}"
    local cores="${4:-}"
    local disk_size="${5:-}"
    local machine="${6:-}"
    local enable_audio="${7:-}"

    validate_vm_name "$vm_name" || return 1

    if vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' already exists" "$vm_name"
        return 1
    fi

    log_message "INFO" "Creating VM: $vm_name" "$vm_name"

    # Validate os_type
    if [[ "$os_type" != "linux" && "$os_type" != "windows" ]]; then
        log_message "ERROR" "Invalid os-type: $os_type. Must be 'linux' or 'windows'" "$vm_name"
        return 1
    fi

    # Validate cores
    if [[ -n "$cores" ]]; then
        if [[ ! "$cores" =~ ^[0-9]+$ ]] || [[ "$cores" -lt 1 ]] || [[ "$cores" -gt 64 ]]; then
            log_message "ERROR" "Invalid CPU cores: $cores. Must be a number between 1 and 64" "$vm_name"
            return 1
        fi
    fi

    # Validate and normalize memory
    if [[ -n "$memory" ]]; then
        if [[ ! "$memory" =~ ^([0-9]+)([GMgm])$ ]]; then
            log_message "ERROR" "Invalid memory format: $memory. Use formats like: 2G, 1024M" "$vm_name"
            return 1
        fi
        local mem_size="${BASH_REMATCH[1]}"
        local mem_unit="${BASH_REMATCH[2]}"
        mem_unit=$(echo "$mem_unit" | tr '[:lower:]' '[:upper:]')
        if [[ "$mem_unit" == "M" && "$mem_size" -lt 256 ]]; then
            log_message "ERROR" "Memory size too small: $mem_size$mem_unit. Minimum is 256M" "$vm_name"
            return 1
        fi
        if [[ "$mem_unit" == "G" ]]; then
            mem_size=$(("$mem_size" * 1024))
            mem_unit="M"
        fi
        # Check against system memory
        local sys_mem
        sys_mem=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
        if [[ "$mem_size" -gt "$sys_mem" ]]; then
            log_message "ERROR" "Requested memory ($mem_size$mem_unit) exceeds system memory ($sys_mem$M)" "$vm_name"
            return 1
        fi
        memory="${mem_size}${mem_unit}"
    fi

    # Validate disk_size
    if [[ -n "$disk_size" ]]; then
        if [[ ! "$disk_size" =~ ^[0-9]+[GMgm]$ ]]; then
            log_message "ERROR" "Invalid disk size: $disk_size. Use formats like: 20G, 100G" "$vm_name"
            return 1
        fi
    fi

    # Parse machine parameter
    local machine_type="q35"
    local machine_options="accel=kvm"
    if [[ -n "$machine" ]]; then
        if [[ "$machine" =~ ^([^,]+)(,(accel=kvm|accel=tcg))?$ ]]; then
            machine_type="${BASH_REMATCH[1]}"
            machine_options="${BASH_REMATCH[3]:-accel=kvm}"
            if [[ "$machine_type" != "q35" && "$machine_type" != "pc" ]]; then
                log_message "ERROR" "Unsupported machine type: $machine_type. Use 'q35' or 'pc'" "$vm_name"
                return 1
            fi
        else
            log_message "ERROR" "Invalid machine format: $machine. Use format like: q35,accel=kvm or pc,accel=tcg" "$vm_name"
            return 1
        fi
    fi

    # Create directory structure
    local vm_path="$VM_DIR/$vm_name"
    mkdir -p "$vm_path"/{logs,sockets} || {
        log_message "ERROR" "Failed to create directory structure for VM: $vm_name" "$vm_name"
        rm -rf "${VM_DIR:?}/${vm_name:?}" 2> /dev/null
        return 1
    }
    log_message "DEBUG" "Created directory structure for VM: $vm_name" "$vm_name"

    # Set default configuration based on os_type
    if [[ "$os_type" == "windows" ]]; then
        CORES="${cores:-${WINDOWS_DEFAULTS[CORES]}}"
        MEMORY="${memory:-${WINDOWS_DEFAULTS[MEMORY]}}"
        DISK_SIZE="${disk_size:-${WINDOWS_DEFAULTS[DISK_SIZE]}}"
        NETWORK_MODEL="${WINDOWS_DEFAULTS[NETWORK_MODEL]}"
        DISK_INTERFACE="${WINDOWS_DEFAULTS[DISK_INTERFACE]}"
        ENABLE_AUDIO="${enable_audio:-${WINDOWS_DEFAULTS[ENABLE_AUDIO]}}"
        ENABLE_VIRTIO="${WINDOWS_DEFAULTS[ENABLE_VIRTIO]}"
    else
        CORES="${cores:-${LINUX_DEFAULTS[CORES]}}"
        MEMORY="${memory:-${LINUX_DEFAULTS[MEMORY]}}"
        DISK_SIZE="${disk_size:-${LINUX_DEFAULTS[DISK_SIZE]}}"
        NETWORK_MODEL="${LINUX_DEFAULTS[NETWORK_MODEL]}"
        DISK_INTERFACE="${LINUX_DEFAULTS[DISK_INTERFACE]}"
        ENABLE_AUDIO="${enable_audio:-${LINUX_DEFAULTS[ENABLE_AUDIO]}}"
        ENABLE_VIRTIO="${LINUX_DEFAULTS[ENABLE_VIRTIO]}"
    fi

    # Set common defaults
    MACHINE_TYPE="$machine_type"
    MACHINE_OPTIONS="$machine_options"
    NETWORK_TYPE="${LINUX_DEFAULTS[NETWORK_TYPE]}"
    CPU_TYPE="${LINUX_DEFAULTS[CPU_TYPE]}"
    VIDEO_TYPE="${LINUX_DEFAULTS[VIDEO_TYPE]}"
    DISK_CACHE="${LINUX_DEFAULTS[DISK_CACHE]}"
    DISK_IO="${LINUX_DEFAULTS[DISK_IO]}"
    DISK_DISCARD="${LINUX_DEFAULTS[DISK_DISCARD]}"
    MEMORY_PREALLOC="${LINUX_DEFAULTS[MEMORY_PREALLOC]}"
    MEMORY_SHARE="${LINUX_DEFAULTS[MEMORY_SHARE]}"
    MAC_ADDRESS=$(generate_mac_address "$vm_name")
    OS_TYPE="$os_type"
    LOCKED="0"
    PORT_FORWARDING_ENABLED="0"
    PORT_FORWARDS=""
    SHARED_FOLDERS=""

    # Create disk image
    local disk_path="$VM_DIR/$vm_name/disk.qcow2"
    if ! qemu-img create -f qcow2 "$disk_path" "$DISK_SIZE" &> /dev/null; then
        log_message "ERROR" "Failed to create disk image for VM: $vm_name" "$vm_name"
        rm -rf "${VM_DIR:?}/${vm_name:?}" 2> /dev/null
        return 1
    fi

    # Save configuration
    if ! save_vm_config "$vm_name"; then
        log_message "ERROR" "Failed to save configuration for VM: $vm_name" "$vm_name"
        rm -rf "${VM_DIR:?}/${vm_name:?}" 2> /dev/null
        return 1
    fi

    log_message "INFO" "VM '$vm_name' created successfully" "$vm_name"
    log_message "INFO" "  Disk: $DISK_SIZE" "$vm_name"
    log_message "INFO" "  CPU: $CORES cores" "$vm_name"
    log_message "INFO" "  Memory: $MEMORY" "$vm_name"
    log_message "INFO" "  Machine: $MACHINE_TYPE${MACHINE_OPTIONS:+,$MACHINE_OPTIONS}" "$vm_name"
    log_message "INFO" "  OS Type: $OS_TYPE" "$vm_name"
    log_message "INFO" "  Audio: $([ "$ENABLE_AUDIO" == "1" ] && echo "enabled" || echo "disabled")" "$vm_name"
}

# Starts a VM, optionally in headless mode or with an ISO file
start() {
    local vm_name="$1"
    local headless="${2:-0}"
    local iso_file="${3:-}"

    # Validate VM name
    validate_vm_name "$vm_name" || return 1

    # Check if VM exists
    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    # Check if VM is already running
    if vm_is_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is already running" "$vm_name"
        return 1
    fi

    # Load VM configuration
    load_vm_config "$vm_name" || return 1

    log_message "INFO" "Starting VM: $vm_name" "$vm_name"

    # Verify KVM acceleration if requested
    if [[ "$MACHINE_OPTIONS" =~ accel=kvm ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            log_message "DEBUG" "KVM acceleration enabled via MACHINE_OPTIONS" "$vm_name"
        else
            log_message "ERROR" "KVM acceleration requested in MACHINE_OPTIONS but /dev/kvm is not accessible" "$vm_name"
            return 1
        fi
    fi

    # Enforce VirtIO settings for network and video
    if [[ "$ENABLE_VIRTIO" != "1" ]]; then
        if [[ "$NETWORK_MODEL" == "virtio-net-pci" ]]; then
            log_message "WARNING" "VirtIO is disabled but virtio-net-pci is selected. Switching to e1000." "$vm_name"
            NETWORK_MODEL="e1000"
        fi
        if [[ "$VIDEO_TYPE" == "virtio-vga" || "$VIDEO_TYPE" == "virtio-gpu" ]]; then
            log_message "WARNING" "VirtIO is disabled but $VIDEO_TYPE is selected. Switching to std." "$vm_name"
            VIDEO_TYPE="std"
        fi
    fi

    # Validate shared memory if enabled
    if [[ "$MEMORY_SHARE" == "1" ]]; then
        if [[ ! -d "/dev/shm" ]]; then
            log_message "ERROR" "Shared memory (/dev/shm) not available" "$vm_name"
            return 1
        fi
        local mem_size
        mem_size=$(echo "$MEMORY" | grep -oE '[0-9]+')

        local mem_unit
        mem_unit=$(echo "$MEMORY" | grep -oE '[GMgm]' | tr '[:lower:]' '[:upper:]')

        local shm_size
        shm_size=$(df -m /dev/shm | tail -1 | awk '{print $4}')

        local shm_used
        shm_used=$(df -m /dev/shm | tail -1 | awk '{print $3}')

        local shm_total
        shm_total=$(df -m /dev/shm | tail -1 | awk '{print $2}')

        if [[ -n "$shm_total" && "$shm_total" != "0" ]]; then
            local shm_usage_percent=$(("$shm_used" * 100 / "$shm_total"))
            if [[ "$shm_usage_percent" -gt 50 ]]; then
                log_message "WARNING" "/dev/shm usage is high ($shm_usage_percent%). Other VMs or processes may cause contention." "$vm_name"
            fi
        fi
        if [[ "$mem_unit" == "G" ]]; then
            mem_size=$(("$mem_size" * 1024))
        fi
        if [[ "$shm_size" -lt $(("$mem_size" * 80 / 100)) ]]; then
            log_message "ERROR" "Insufficient space in /dev/shm for memory sharing" "$vm_name"
            return 1
        fi
    fi

    # Build QEMU command array
    local qemu_cmd=(
        "qemu-system-x86_64"
        "-name" "$vm_name"
        "-machine" "${MACHINE_TYPE}${MACHINE_OPTIONS:+,$MACHINE_OPTIONS}"
        "-smp" "$CORES"
        "-m" "$MEMORY"
        "-pidfile" "$VM_DIR/$vm_name/qemu.pid"
        "-daemonize"
    )

    # Handle video type
    case "$VIDEO_TYPE" in
        "std" | "cirrus" | "vmware" | "qxl")
            qemu_cmd+=("-vga" "$VIDEO_TYPE")
            log_message "DEBUG" "Using VGA type: $VIDEO_TYPE" "$vm_name"
            ;;
        "virtio-vga" | "virtio-gpu")
            if [[ "$ENABLE_VIRTIO" == "1" ]]; then
                qemu_cmd+=("-device" "virtio-gpu-pci")
                log_message "DEBUG" "Using VirtIO GPU device" "$vm_name"
            else
                log_message "WARNING" "VirtIO GPU requested but ENABLE_VIRTIO=0. Falling back to std." "$vm_name"
                qemu_cmd+=("-vga" "std")
            fi
            ;;
        *)
            log_message "WARNING" "Unsupported VIDEO_TYPE: $VIDEO_TYPE. Falling back to std." "$vm_name"
            qemu_cmd+=("-vga" "std")
            ;;
    esac

    # Handle disk interface
    case "$DISK_INTERFACE" in
        "virtio")
            if [[ "$ENABLE_VIRTIO" != "1" ]]; then
                log_message "ERROR" "virtio disk requires ENABLE_VIRTIO=1 for VM '$vm_name'"
                return 1
            fi
            qemu_cmd+=("-drive" "file=$VM_DIR/$vm_name/disk.qcow2,format=qcow2,if=none,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,id=drive0")
            qemu_cmd+=("-device" "virtio-blk-pci,drive=drive0")
            log_message "DEBUG" "Configured disk with virtio-blk-pci for VM '$vm_name'"
            ;;
        "ide")
            qemu_cmd+=("-drive" "file=$VM_DIR/$vm_name/disk.qcow2,format=qcow2,if=ide,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD")
            log_message "DEBUG" "Configured disk with ide for VM '$vm_name'"
            ;;
        "ide-hd")
            qemu_cmd+=("-drive" "file=$VM_DIR/$vm_name/disk.qcow2,format=qcow2,if=none,cache=$DISK_CACHE,aio=$DISK_IO,discard=$DISK_DISCARD,id=drive0")
            qemu_cmd+=("-device" "ide-hd,drive=drive0")
            log_message "DEBUG" "Configured disk with ide-hd for VM '$vm_name'"
            ;;
        *)
            log_message "ERROR" "Unsupported DISK_INTERFACE: $DISK_INTERFACE for VM '$vm_name'"
            return 1
            ;;
    esac

    # Add ISO if specified
    if [[ -n "$iso_file" ]]; then
        if [[ ! -f "$iso_file" ]]; then
            log_message "ERROR" "ISO file does not exist: $iso_file" "$vm_name"
            return 1
        fi
        iso_file=$(realpath "$iso_file")
        qemu_cmd+=("-drive" "file=$(printf '%q' "$iso_file"),format=raw,readonly=on,media=cdrom")
        qemu_cmd+=("-boot" "order=d,once=d")
        log_message "DEBUG" "Added ISO boot arguments: $iso_file" "$vm_name"
    fi

    # Set display option based on headless flag
    if [[ "$headless" == "1" ]]; then
        qemu_cmd+=("-display" "none")
        log_message "INFO" "Starting VM in headless mode" "$vm_name"
    else
        qemu_cmd+=("-display" "gtk")
        log_message "INFO" "Starting VM with graphical display" "$vm_name"
    fi

    # Add CPU type if specified
    if [[ -n "$CPU_TYPE" ]]; then
        qemu_cmd+=("-cpu" "$CPU_TYPE")
    fi

    # Configure networking
    configure_network "$vm_name" qemu_cmd

    # Configure audio if enabled
    if [[ "$ENABLE_AUDIO" == "1" ]]; then
        if command -v pw-cat &> /dev/null && pipewire --version &> /dev/null; then
            qemu_cmd+=("-audiodev" "pipewire,id=audio0")
            qemu_cmd+=("-device" "ich9-intel-hda")
            qemu_cmd+=("-device" "hda-output,audiodev=audio0")
            log_message "DEBUG" "Audio configured with PipeWire" "$vm_name"
        elif command -v pulseaudio &> /dev/null && pulseaudio --check &> /dev/null; then
            qemu_cmd+=("-audiodev" "pa,id=audio0")
            qemu_cmd+=("-device" "ich9-intel-hda")
            qemu_cmd+=("-device" "hda-output,audiodev=audio0")
            log_message "DEBUG" "Audio configured with PulseAudio" "$vm_name"
        elif command -v aplay &> /dev/null; then
            qemu_cmd+=("-audiodev" "alsa,id=audio0")
            qemu_cmd+=("-device" "AC97,audiodev=audio0")
            log_message "DEBUG" "Audio configured with ALSA" "$vm_name"
        else
            log_message "WARNING" "No supported audio backend (PipeWire, PulseAudio, ALSA) found. Audio disabled." "$vm_name"
        fi
    fi

    # Configure shared folders
    if [[ -n "${SHARED_FOLDERS:-}" ]]; then
        log_message "DEBUG" "SHARED_FOLDERS is set: '${SHARED_FOLDERS}', OS_TYPE: '$OS_TYPE'" "$vm_name"
        if [[ "$OS_TYPE" == "linux" ]]; then
            if [[ "$ENABLE_VIRTIO" == "1" ]]; then
                # Configure both VirtioFS and 9p shared folders based on their type
                log_message "DEBUG" "Configuring shared folders for Linux VM '$vm_name'" "$vm_name"
                configure_virtiofs_shared_folders "$vm_name" qemu_cmd
                configure_linux_shared_folders "$vm_name" qemu_cmd
            else
                log_message "WARNING" "Shared folders for Linux VM '$vm_name' require VirtIO to be enabled. Skipping shared folder configuration." "$vm_name"
            fi
        elif [[ "$OS_TYPE" == "windows" ]]; then
            # Windows SMB sharing is handled within configure_network when NETWORK_TYPE is 'user' or 'nat'.
            if [[ "$NETWORK_TYPE" != "user" && "$NETWORK_TYPE" != "nat" ]]; then
                log_message "WARNING" "Windows SMB shared folders are only configured with 'user' or 'nat' network types. Current type: $NETWORK_TYPE" "$vm_name"
            else
                log_message "DEBUG" "Windows SMB shares are configured within the -netdev user option by the configure_network function." "$vm_name"
            fi
        else
            log_message "WARNING" "Shared folder configuration not implemented for OS_TYPE '$OS_TYPE'" "$vm_name"
        fi
    else
        log_message "DEBUG" "No SHARED_FOLDERS defined for VM '$vm_name'." "$vm_name"
    fi

    # Configure USB controller and passthrough devices

    # Configure USB controller (always add it for better compatibility)
    qemu_cmd+=("-device" "qemu-xhci,id=xhci")
    log_message "DEBUG" "Added USB 3.0 (xHCI) controller" "$vm_name"

    # Configure USB passthrough devices if any
    if [[ -n "${USB_DEVICES:-}" ]]; then
        log_message "DEBUG" "Configuring USB passthrough devices: '${USB_DEVICES}'" "$vm_name"
        
        IFS=',' read -ra devices_to_pass <<< "$USB_DEVICES"
        for device_spec in "${devices_to_pass[@]}"; do
            if [[ "$device_spec" =~ ^([0-9a-fA-F]{4}):([0-9a-fA-F]{4})$ ]]; then
                local vendor_id="${BASH_REMATCH[1]}"
                local product_id="${BASH_REMATCH[2]}"
                
                # Verify device exists on host
                if command -v lsusb &> /dev/null; then
                    if ! lsusb -d "${vendor_id}:${product_id}" &> /dev/null; then
                        log_message "WARNING" "USB device ${vendor_id}:${product_id} not found on host. Skipping." "$vm_name"
                        continue
                    fi
                    
                    # Check device permissions
                    local device_path=$(find /dev/bus/usb -type c 2>/dev/null | while read dev; do
                        local dev_info=$(udevadm info --query=all --name="$dev" 2>/dev/null | grep -i "ID_VENDOR_ID\|ID_MODEL_ID")
                        if echo "$dev_info" | grep -qi "ID_VENDOR_ID=${vendor_id}" && \
                           echo "$dev_info" | grep -qi "ID_MODEL_ID=${product_id}"; then
                            echo "$dev"
                            break
                        fi
                    done)
                    
                    if [[ -n "$device_path" ]] && [[ ! -r "$device_path" || ! -w "$device_path" ]]; then
                        log_message "WARNING" "USB device ${vendor_id}:${product_id} exists but may not be accessible (insufficient permissions on $device_path)" "$vm_name"
                        log_message "WARNING" "You may need to run as root or configure udev rules. See: https://wiki.archlinux.org/title/QEMU#USB_passthrough" "$vm_name"
                    fi
                fi
                
                # Add the device with bus=xhci to attach it to the USB 3.0 controller
                qemu_cmd+=("-device" "usb-host,vendorid=0x$vendor_id,productid=0x$product_id,bus=xhci.0")
                log_message "INFO" "Added USB passthrough device: $vendor_id:$product_id" "$vm_name"
            else
                log_message "WARNING" "Invalid USB device format in config: '$device_spec'. Expected VVVV:PPPP format. Skipping." "$vm_name"
            fi
        done
    fi

    # Memory options
    if [[ "$MEMORY_PREALLOC" == "1" ]]; then
        qemu_cmd+=("-mem-prealloc")
    fi
    if [[ "$MEMORY_SHARE" == "1" ]]; then
        qemu_cmd+=("-mem-path" "/dev/shm")
    fi

    # Lock the PID file
    local pidfile="$VM_DIR/$vm_name/qemu.pid"
    local lockfile="$pidfile.lock"
    exec 200> "$lockfile"
    if ! flock -n 200; then
        log_message "ERROR" "Cannot acquire lock on PID file for VM: $vm_name" "$vm_name"
        return 1
    fi

    # Start the VM
    if "${qemu_cmd[@]}" 2> "$VM_DIR/$vm_name/logs/error.log"; then
        log_message "INFO" "VM '$vm_name' started successfully" "$vm_name"
        flock -u 200 # Release the lock immediately after starting the VM

        # Verify VM is running
        local timeout=10
        local count=0
        while [[ "$count" -lt "$timeout" ]]; do
            if vm_is_running "$vm_name"; then
                local pid
                pid=$(cat "$pidfile")
                log_message "INFO" "VM PID: $pid" "$vm_name"
                return 0
            fi
            sleep 1
            ((count++))
        done
        log_message "ERROR" "VM failed to start within $timeout seconds. Check logs: $VM_DIR/$vm_name/logs/error.log"
        if [[ -s "$VM_DIR/$vm_name/logs/error.log" ]]; then
            echo "Recent errors from QEMU log:"
            tail -n 3 "$VM_DIR/$vm_name/logs/error.log" | sed 's/^/  /'
        fi
        return 1
    else
        log_message "ERROR" "Failed to start VM '$vm_name'. Check logs: $VM_DIR/$vm_name/logs/error.log"
        if [[ -s "$VM_DIR/$vm_name/logs/error.log" ]]; then
            echo "Recent errors from QEMU log:"
            tail -n 3 "$VM_DIR/$vm_name/logs/error.log" | sed 's/^/  /'
        fi
        flock -u 200
        return 1
    fi
}

# Displays detailed status of a VM
status() {
    local vm_name="$1"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    # Load configuration
    load_vm_config "$vm_name" || return 1

    echo "VM: $vm_name"
    echo "========================"
    echo "Name: $NAME"
    echo "Machine Type: $MACHINE_TYPE${MACHINE_OPTIONS:+,$MACHINE_OPTIONS}"
    echo "OS Type: $OS_TYPE"
    echo "CPU: $CORES cores ($CPU_TYPE)"
    echo "Memory: $MEMORY"
    echo "MAC Address: $MAC_ADDRESS"
    echo "Network:"
    echo "  Type: ${NETWORK_TYPE:-unknown}"
    echo "  Model: ${NETWORK_MODEL:-unknown}"
    echo "Disk Interface: $DISK_INTERFACE"
    echo "Video: $VIDEO_TYPE"
    echo "Audio: $([ "$ENABLE_AUDIO" == "1" ] && echo "enabled" || echo "disabled")"
    echo "VirtIO: $([ "$ENABLE_VIRTIO" == "1" ] && echo "enabled" || echo "disabled")"
    echo "Locked: $([ "$LOCKED" == "1" ] && echo "yes" || echo "no")"

    if [[ "$PORT_FORWARDING_ENABLED" == "1" ]] && [[ -n "$PORT_FORWARDS" ]]; then
        echo "Port Forwards:"
        IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
        for forward in "${forwards[@]}"; do
            if [[ "$forward" =~ ^([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                echo "  ${BASH_REMATCH[1]}:${BASH_REMATCH[2]} (${BASH_REMATCH[3]})"
            else
                echo "  $forward (tcp, legacy format)"
            fi
        done
    fi

    if [[ -n "$SHARED_FOLDERS" ]]; then
        echo "Shared Folders: yes"
    else
        echo "Shared Folders: no"
    fi

    if [[ -n "$USB_DEVICES" ]]; then
        echo "USB Passthrough Devices:"
        IFS=',' read -ra devices <<< "$USB_DEVICES"
        for device in "${devices[@]}"; do
            echo "  - $device"
        done
    else
        echo "USB Passthrough Devices: no"
    fi

    echo ""

    if vm_is_running "$vm_name"; then
        local pid
        pid=$(cat "$VM_DIR/$vm_name/qemu.pid")
        echo "Status: Running (PID: $pid)"

        # Show process info if available
        if command -v ps &> /dev/null; then
            echo "Process Info:"
            ps -p "$pid" -o pid,ppid,pcpu,pmem,etime,cmd --no-headers 2> /dev/null || echo "  Process info unavailable"
        fi
        
        # Show virtiofsd processes if any
        local virtiofs_count=0
        for virtiofs_pid_file in "$VM_DIR/$vm_name/sockets"/virtiofs_*.sock.pid; do
            if [[ -f "$virtiofs_pid_file" ]]; then
                local virtiofs_pid
                virtiofs_pid=$(cat "$virtiofs_pid_file")
                if kill -0 "$virtiofs_pid" 2>/dev/null; then
                    ((virtiofs_count++))
                fi
            fi
        done
        if [[ "$virtiofs_count" -gt 0 ]]; then
            echo "VirtioFS daemons: $virtiofs_count running"
        fi
    else
        echo "Status: Stopped"
    fi

    # Show disk usage
    local disk_path="$VM_DIR/$vm_name/disk.qcow2"
    echo ""
    echo "Disk Information:"
    if [[ -f "$disk_path" ]]; then
        if vm_is_running "$vm_name"; then
            echo "  Disk info unavailable while VM is running."
        else
            if command -v qemu-img &> /dev/null; then
                qemu-img info "$disk_path" | grep -E "(virtual size|disk size|format)" | sed 's/^/  /' || {
                    echo "  Failed to retrieve disk information"
                }
            else
                echo "  Disk info unavailable (qemu-img not installed)"
            fi
        fi
    else
        echo "  Disk image not found: $disk_path"
    fi
}

# Stops a VM, optionally forcing termination
stop() {
    local vm_name="$1"
    local force="${2:-false}"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if ! vm_is_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is not running" "$vm_name"
        return 1
    fi

    local pidfile="$VM_DIR/$vm_name/qemu.pid"
    local pid
    pid=$(cat "$pidfile")

    log_message "INFO" "Stopping VM: $vm_name (PID: $pid)" "$vm_name"

    if [[ "$force" == "true" ]]; then
        # Force kill
        if kill -9 "$pid" 2> /dev/null; then
            log_message "WARNING" "VM forcefully terminated" "$vm_name"
        else
            log_message "ERROR" "Failed to force stop VM '$vm_name'" "$vm_name"
            return 1
        fi
    else
        # Graceful shutdown
        if kill -15 "$pid" 2> /dev/null; then
            # Wait for graceful shutdown
            local count=0
            while kill -0 "$pid" 2> /dev/null && [[ $count -lt 30 ]]; do
                sleep 1
                ((count++))
            done

            if kill -0 "$pid" 2> /dev/null; then
                log_message "WARNING" "Graceful shutdown timed out, forcing termination" "$vm_name"
                if kill -9 "$pid" 2> /dev/null; then
                    log_message "WARNING" "VM forcefully terminated after timeout" "$vm_name"
                else
                    log_message "ERROR" "Failed to force stop VM '$vm_name' after timeout" "$vm_name"
                    return 1
                fi
            else
                log_message "INFO" "VM '$vm_name' stopped gracefully" "$vm_name"
            fi
        else
            log_message "ERROR" "Failed to stop VM '$vm_name'" "$vm_name"
            return 1
        fi
    fi

    # Clean up PID file
    rm -f "$pidfile"

    # Stop any virtiofsd daemons
    for virtiofs_pid_file in "$VM_DIR/$vm_name/sockets"/virtiofs_*.sock.pid; do
        if [[ -f "$virtiofs_pid_file" ]]; then
            local virtiofs_pid
            virtiofs_pid=$(cat "$virtiofs_pid_file")
            if kill -0 "$virtiofs_pid" 2>/dev/null; then
                log_message "DEBUG" "Stopping virtiofsd daemon (PID: $virtiofs_pid)" "$vm_name"
                kill "$virtiofs_pid" 2>/dev/null
            fi
            rm -f "$virtiofs_pid_file"
        fi
    done

    # Clean up sockets
    rm -f "$VM_DIR/$vm_name/sockets"/*.sock
    rm -f "$VM_DIR/$vm_name/sockets"/*.pid
}

# Deletes a VM, optionally skipping confirmation
delete() {
    local vm_name="$1"
    local force="${2:-false}"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if vm_is_locked "$vm_name" && [[ "$force" != "true" ]]; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first or use --force" "$vm_name"
        return 1
    fi

    if vm_is_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is running. Stop it first" "$vm_name"
        return 1
    fi

    log_message "INFO" "Deleting VM: $vm_name" "$vm_name"

    # Warn if --force is used
    if [[ "$force" == "true" ]]; then
        log_message "WARNING" "Force-deleting VM '$vm_name' without confirmation" "$vm_name"
    else
        # Confirm deletion
        echo -n "Are you sure you want to delete VM '$vm_name'? [y/N]: "
        read -r confirmation
        if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
            log_message "INFO" "Deletion cancelled" "$vm_name"
            return 0
        fi
    fi

    # Delete VM directory
    if [[ -z "$VM_DIR" || -z "$vm_name" || ! -d "$VM_DIR/$vm_name" ]]; then
        log_message "ERROR" "Invalid path for cleanup: $VM_DIR/$vm_name" "$vm_name"
        return 1
    fi

    if rm -rf "${VM_DIR:?}/${vm_name:?}"; then
        log_message "INFO" "VM '$vm_name' deleted successfully" "$vm_name"
    else
        log_message "ERROR" "Failed to delete VM '$vm_name'" "$vm_name"
        return 1
    fi
}

# Resizes a VM's disk to a new size
resize_disk() {
    local vm_name="$1"
    local new_size="$2"
    local force="$3"

    validate_vm_name "$vm_name" || return 1
    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi
    if vm_is_running "$vm_name" && [[ "$force" != "true" ]]; then
        log_message "ERROR" "Cannot resize disk while VM is running. Stop '$vm_name' first or use --force" "$vm_name"
        return 1
    fi
    if vm_is_locked "$vm_name" && [[ "$force" != "true" ]]; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first or use --force" "$vm_name"
        return 1
    fi
    if [[ ! "$new_size" =~ ^[0-9]+[GMgm]$ ]]; then
        log_message "ERROR" "Invalid disk size format: $new_size. Use formats like: 20G, 100G" "$vm_name"
        return 1
    fi

    local disk_path="$VM_DIR/$vm_name/disk.qcow2"
    if [[ ! -f "$disk_path" ]]; then
        log_message "ERROR" "Disk image not found for VM: $vm_name" "$vm_name"
        return 1
    fi

    # Validate new size against current size
    if command -v qemu-img &> /dev/null; then
        local current_size
        current_size=$(qemu-img info "$disk_path" | grep 'virtual size' | grep -oE '[0-9]+' | head -1)
        local new_size_bytes
        if [[ "$new_size" =~ ^([0-9]+)([GMgm])$ ]]; then
            local size_num="${BASH_REMATCH[1]}"
            local size_unit="${BASH_REMATCH[2]}"
            size_unit=$(echo "$size_unit" | tr '[:lower:]' '[:upper:]')
            if [[ "$size_unit" == "G" ]]; then
                new_size_bytes=$(("$size_num" * 1024 * 1024 * 1024))
            else
                new_size_bytes=$(("$size_num" * 1024 * 1024))
            fi
            if [[ "$new_size_bytes" -lt "$current_size" ]]; then
                log_message "ERROR" "New size ($new_size) is smaller than current size. Shrinking is not supported." "$vm_name"
                return 1
            fi
        fi
    else
        log_message "ERROR" "qemu-img not found, cannot validate disk size." "$vm_name"
        return 1
    fi

    # Display warning if --force is used
    if [[ "$force" == "true" ]]; then
        echo "⚠️  WARNING: Using --force to resize VM '$vm_name' may bypass safety checks (e.g., VM running or locked)."
        echo "    This could lead to data corruption or loss. Proceed with caution."
        read -rp "Are you sure you want to continue with --force? [y/N]: " force_confirm
        force_confirm=${force_confirm,,} # Convert to lowercase
        if [[ "$force_confirm" != "y" ]]; then
            echo "Operation cancelled."
            return 1
        fi
    fi

    # Standard confirmation prompt
    echo "⚠️  You are about to resize the disk of VM '$vm_name' to $new_size."
    read -rp "Are you sure you want to proceed? [y/N]: " confirm
    confirm=${confirm,,} # Convert to lowercase
    if [[ "$confirm" != "y" ]]; then
        echo "Operation cancelled."
        return 1
    fi

    if qemu-img resize "$disk_path" "$new_size" 2> "$VM_DIR/$vm_name/logs/error.log"; then
        log_message "INFO" "Disk for VM '$vm_name' resized to $new_size" "$vm_name"
    else
        log_message "ERROR" "Failed to resize disk for VM '$vm_name'. Check logs: $VM_DIR/$vm_name/logs/error.log" "$vm_name"
        return 1
    fi
}

# Lists all VMs with their status
list() {
    if [[ ! -d "$VM_DIR" ]] || [[ -z "$(ls -A "$VM_DIR" 2> /dev/null)" ]]; then
        echo "No VMs found"
        return 0
    fi

    printf "%-15s %-10s %-8s\n" "NAME" "STATUS" "LOCKED"
    printf "%-15s %-10s %-8s\n" "----" "------" "------"

    for vm_path in "$VM_DIR"/*; do
        if [[ -d "$vm_path" ]]; then
            local vm_name
            vm_name=$(basename "$vm_path")

            local status="stopped"
            if vm_is_running "$vm_name"; then
                status="running"
            fi

            local locked="no"
            if vm_is_locked "$vm_name"; then
                locked="yes"
            fi

            printf "%-15s %-10s %-8s\n" \
                "$vm_name" "$status" "$locked"
        fi
    done
}

# Configures VM settings or opens config file in editor
configure() {
    local vm_name="$1"
    local setting="${2:-}"
    local value="${3:-}"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    if vm_is_running "$vm_name"; then
        log_message "ERROR" "Cannot modify configuration while VM is running. Stop '$vm_name' first" "$vm_name"
        return 1
    fi

    # If no setting is provided, open the config file in the default editor
    if [[ -z "$setting" ]]; then
        local config_file="$VM_DIR/$vm_name/config"
        local editor="${EDITOR:-nano}"

        if ! command -v "$editor" &> /dev/null; then
            editor="vi"
        fi

        log_message "INFO" "Opening configuration file for VM '$vm_name' in $editor" "$vm_name"
        "$editor" "$config_file" || {
            log_message "ERROR" "Failed to open configuration file with $editor" "$vm_name"
            return 1
        }
        log_message "INFO" "Configuration file for VM '$vm_name' saved" "$vm_name"
        return 0
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    case "$setting" in
        "cores")
            if [[ -z "$value" ]]; then
                echo "Current CPU cores: $CORES"
                return 0
            fi

            if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "$value" -lt 1 ]] || [[ "$value" -gt 64 ]]; then
                log_message "ERROR" "Invalid CPU count. Must be between 1 and 64" "$vm_name"
                return 1
            fi

            CORES="$value"
            save_vm_config "$vm_name"
            log_message "INFO" "CPU cores for VM '$vm_name' set to: $value" "$vm_name"
            ;;
        "memory")
            if [[ -z "$value" ]]; then
                echo "Current memory: $MEMORY"
                return 0
            fi

            if [[ ! "$value" =~ ^([0-9]+)([GMgm])$ ]]; then
                log_message "ERROR" "Invalid memory format. Use formats like: 2G, 1024M" "$vm_name"
                return 1
            fi
            local mem_size="${BASH_REMATCH[1]}"
            local mem_unit="${BASH_REMATCH[2]}"
            mem_unit=$(echo "$mem_unit" | tr '[:lower:]' '[:upper:]')
            if [[ "$mem_unit" == "M" && "$mem_size" -lt 256 ]]; then
                log_message "ERROR" "Memory size too small: $mem_size$mem_unit. Minimum is 256M" "$vm_name"
                return 1
            fi
            if [[ "$mem_unit" == "G" ]]; then
                mem_size=$(("$mem_size" * 1024))
                mem_unit="M"
            fi
            local sys_mem
            sys_mem=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
            if [[ "$mem_size" -gt "$sys_mem" ]]; then
                log_message "ERROR" "Requested memory ($mem_size$mem_unit) exceeds system memory ($sys_mem$M)" "$vm_name"
                return 1
            fi
            MEMORY="${mem_size}${mem_unit}"
            save_vm_config "$vm_name"
            log_message "INFO" "Memory for VM '$vm_name' set to: $MEMORY" "$vm_name"
            ;;
        "audio")
            if [[ -z "$value" ]]; then
                echo "Current audio: $([ "$ENABLE_AUDIO" == "1" ] && echo "enabled" || echo "disabled")"
                return 0
            fi

            case "$value" in
                "on" | "enable" | "enabled" | "1" | "true")
                    ENABLE_AUDIO="1"
                    ;;
                "off" | "disable" | "disabled" | "0" | "false")
                    ENABLE_AUDIO="0"
                    ;;
                *)
                    log_message "ERROR" "Invalid audio setting. Use: on/off, enable/disable, 1/0, true/false" "$vm_name"
                    return 1
                    ;;
            esac

            save_vm_config "$vm_name"
            log_message "INFO" "Audio for VM '$vm_name' $([ "$ENABLE_AUDIO" == "1" ] && echo "enabled" || echo "disabled")" "$vm_name"
            ;;
        *)
            echo "Available configuration settings:"
            echo "  cores    - Number of CPU cores (1-64)"
            echo "  memory   - Memory allocation (e.g., 2G, 1024M)"
            echo "  audio    - Enable/disable audio (on/off)"
            echo ""
            echo "To configure advanced machine options (e.g., KVM, TCG), edit MACHINE_OPTIONS in the config file:"
            echo "  qemate vm configure <name> # Opens config file in editor"
            return 1
            ;;
    esac
}

# ============================================================================
# SECURITY MANAGEMENT
# ============================================================================

# Locks a VM to prevent modifications
lock() {
    local vm_name="$1"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    LOCKED="1"
    save_vm_config "$vm_name"
    log_message "INFO" "VM '$vm_name' locked" "$vm_name"
}

# Unlocks a VM to allow modifications
unlock() {
    local vm_name="$1"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    LOCKED="0"
    save_vm_config "$vm_name"
    log_message "INFO" "VM '$vm_name' unlocked" "$vm_name"
}

# ============================================================================
# NETWORKING CONFIGURATION
# ============================================================================

# Configures network options for the QEMU command
configure_network() {
    local vm_name="$1"
    local -n cmd_array=$2 # Nameref to the QEMU command array (qemu_cmd)

    case "$NETWORK_TYPE" in
        "user" | "nat")
            local netdev_opts="user,id=net0"

            # Add port forwards if enabled
            if [[ "$PORT_FORWARDING_ENABLED" == "1" ]] && [[ -n "$PORT_FORWARDS" ]]; then
                IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
                for forward in "${forwards[@]}"; do
                    if [[ "$forward" =~ ^([0-9]+):([0-9]+):(tcp|udp)$ ]]; then
                        local host_port="${BASH_REMATCH[1]}"
                        local guest_port="${BASH_REMATCH[2]}"
                        local protocol="${BASH_REMATCH[3]}"
                        netdev_opts+=",hostfwd=$protocol::$host_port-:$guest_port"
                        log_message "DEBUG" "Added port forward: $host_port -> $guest_port ($protocol)" "$vm_name"
                    elif [[ "$forward" =~ ^([0-9]+):([0-9]+)$ ]]; then # Handle legacy format
                        local host_port="${BASH_REMATCH[1]}"
                        local guest_port="${BASH_REMATCH[2]}"
                        netdev_opts+=",hostfwd=tcp::$host_port-:$guest_port" # Default to TCP for legacy
                        log_message "DEBUG" "Added port forward (legacy): $host_port -> $guest_port (tcp)" "$vm_name"
                    else
                        log_message "WARNING" "Invalid port forward format: $forward, skipping" "$vm_name"
                    fi
                done
            fi

            # Add SMB shares for Windows if SHARED_FOLDERS is set
            # This is based on the QEMU help output showing smb=dir as a -netdev user sub-option
            if [[ "$OS_TYPE" == "windows" && -n "${SHARED_FOLDERS:-}" ]]; then
                log_message "DEBUG" "Configuring SMB shares for Windows VM '$vm_name' within -netdev user option" "$vm_name"
                IFS=',' read -ra shares_spec_list <<< "$SHARED_FOLDERS"
                for share_spec in "${shares_spec_list[@]}"; do
                    local folder_path
                    # SHARED_FOLDERS items are path:tag:security_model. We only need the path for smb.
                    folder_path="${share_spec%%:*}"

                    if [[ -z "$folder_path" ]]; then
                        log_message "WARNING" "Empty folder path in SHARED_FOLDERS spec for Windows SMB: '$share_spec'. Skipping." "$vm_name"
                        continue
                    fi

                    if [[ ! -d "$folder_path" ]]; then
                        log_message "WARNING" "Shared folder path '$folder_path' for Windows SMB does not exist or is not a directory. Skipping." "$vm_name"
                        continue
                    fi

                    # QEMU's smb= expects a directory. Removing trailing slash for consistency.
                    local clean_folder_path="${folder_path%/}"
                    if [[ -z "$clean_folder_path" ]]; then # Handle case where path was just "/"
                        clean_folder_path="/"
                    fi

                    netdev_opts+=",smb=${clean_folder_path}"
                    log_message "DEBUG" "Added to netdev user opts: ,smb=${clean_folder_path}" "$vm_name"
                done
            fi

            cmd_array+=("-netdev" "$netdev_opts")
            cmd_array+=("-device" "$NETWORK_MODEL,netdev=net0,mac=$MAC_ADDRESS")
            ;;
        "none")
            cmd_array+=("-nic" "none")
            ;;
        *)
            log_message "WARNING" "Unknown network type: $NETWORK_TYPE, using user networking as fallback" "$vm_name"
            local netdev_opts_default="user,id=net0"
            # Replicate SMB logic for fallback to user networking
            if [[ "$OS_TYPE" == "windows" && -n "${SHARED_FOLDERS:-}" ]]; then
                IFS=',' read -ra shares_spec_list_default <<< "$SHARED_FOLDERS"
                for share_spec_default in "${shares_spec_list_default[@]}"; do
                    local folder_path_default="${share_spec_default%%:*}"
                    if [[ -n "$folder_path_default" && -d "$folder_path_default" ]]; then
                        local clean_folder_path_default="${folder_path_default%/}"
                        if [[ -z "$clean_folder_path_default" ]]; then clean_folder_path_default="/"; fi
                        netdev_opts_default+=",smb=${clean_folder_path_default}"
                    fi
                done
            fi
            cmd_array+=("-netdev" "$netdev_opts_default")
            cmd_array+=("-device" "$NETWORK_MODEL,netdev=net0,mac=$MAC_ADDRESS") # Should ideally use a default model here if NETWORK_MODEL is invalid
            ;;
    esac

    log_message "DEBUG" "Network configured: $NETWORK_TYPE with model $NETWORK_MODEL (MAC: $MAC_ADDRESS)" "$vm_name"
}

# Sets the network type for a VM
set_network_type() {
    local vm_name="$1"
    local new_type="$2"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    if vm_is_running "$vm_name"; then
        log_message "ERROR" "Cannot modify network type while VM is running. Stop '$vm_name' first" "$vm_name"
        return 1
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    case "$new_type" in
        "user" | "nat" | "none")
            NETWORK_TYPE="$new_type"
            save_vm_config "$vm_name"
            log_message "INFO" "Network type for VM '$vm_name' changed to: $new_type" "$vm_name"
            ;;
        *)
            log_message "ERROR" "Invalid network type: $new_type" "$vm_name"
            log_message "ERROR" "Valid types: user, nat, none" "$vm_name"
            return 1
            ;;
    esac
}

# Sets the network model for a VM
set_network_model() {
    local vm_name="$1"
    local new_model="$2"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    if vm_is_running "$vm_name"; then
        log_message "ERROR" "Cannot modify network model while VM is running. Stop '$vm_name' first" "$vm_name"
        return 1
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    case "$new_model" in
        "virtio-net-pci")
            if [[ "$ENABLE_VIRTIO" != "1" ]]; then
                log_message "ERROR" "virtio-net-pci requires ENABLE_VIRTIO=1" "$vm_name"
                return 1
            fi
            NETWORK_MODEL="$new_model"
            save_vm_config "$vm_name"
            log_message "INFO" "Network model for VM '$vm_name' changed to: $new_model" "$vm_name"
            ;;
        "e1000" | "rtl8139")
            NETWORK_MODEL="$new_model"
            save_vm_config "$vm_name"
            log_message "INFO" "Network model for VM '$vm_name' changed to: $new_model" "$vm_name"
            ;;
        *)
            log_message "ERROR" "Invalid network model: $new_model" "$vm_name"
            log_message "ERROR" "Valid models: virtio-net-pci, e1000, rtl8139" "$vm_name"
            return 1
            ;;
    esac
}

# Utility function to parse and validate port specification
parse_port_spec() {
    local port_spec="$1"
    local vm_name="$2"
    local -n out_spec=$3 # Nameref to return normalized port_spec
    # shellcheck disable=SC2034
    # Suppress SC2034: out_spec is used as a nameref to return the normalized port specification

    if [[ "$port_spec" =~ ^([0-9]+):([0-9]+)(:(tcp|udp|TCP|UDP))?$ ]]; then
        local host_port="${BASH_REMATCH[1]}"
        local guest_port="${BASH_REMATCH[2]}"
        local protocol="${BASH_REMATCH[4]:-tcp}"
        protocol=$(echo "$protocol" | tr '[:upper:]' '[:lower:]')
        if [[ "$host_port" -lt 1 || "$host_port" -gt 65535 || "$guest_port" -lt 1 || "$guest_port" -gt 65535 ]]; then
            log_message "ERROR" "Ports must be between 1 and 65535: $port_spec" "$vm_name"
            return 1
        fi
        out_spec="$host_port:$guest_port:$protocol"
        return 0
    else
        log_message "ERROR" "Invalid port format: $port_spec. Use host:guest[:tcp|udp]" "$vm_name"
        return 1
    fi
}

# Manages port forwarding for a VM
manage_network_ports() {
    local vm_name="$1"
    local action="$2"
    local port_spec="${3:-}"

    validate_vm_name "$vm_name" || return 1
    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi
    if [[ "$action" != "add" && "$action" != "remove" ]]; then
        log_message "ERROR" "Invalid action. Use: add, remove" "$vm_name"
        return 1
    fi
    if [[ "$action" != "list" ]] && vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    # Load current configuration
    load_vm_config "$vm_name" || return 1

    # Prevent unbound variable errors
    PORT_FORWARDS="${PORT_FORWARDS:-}"
    PORT_FORWARDING_ENABLED="${PORT_FORWARDING_ENABLED:-0}"

    case "$action" in
        "add")
            if [[ -z "$port_spec" ]]; then
                log_message "ERROR" "Port specification required (format: host_port:guest_port[:tcp|udp])" "$vm_name"
                return 1
            fi
            local normalized_spec
            if ! parse_port_spec "$port_spec" "$vm_name" normalized_spec; then
                return 1
            fi
            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify port forwards while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi
            if [[ "$normalized_spec" =~ ^([0-9]+):([0-9]+):([a-z]+)$ ]]; then
                local host_port="${BASH_REMATCH[1]}"
                local protocol="${BASH_REMATCH[3]}"
                if [[ "$host_port" -le 1024 ]]; then
                    log_message "WARNING" "Port $host_port is privileged (≤1024) and may require root privileges" "$vm_name"
                fi
                if command -v ss &> /dev/null; then
                    if ss -tuln | grep -q ":$host_port\s"; then
                        log_message "ERROR" "Host port $host_port ($protocol) is already in use by a system service" "$vm_name"
                        return 1
                    fi
                elif command -v netstat &> /dev/null; then
                    if netstat -tuln | grep -q ":$host_port\s"; then
                        log_message "ERROR" "Host port $host_port ($protocol) is already in use by a system service" "$vm_name"
                        return 1
                    fi
                else
                    log_message "WARNING" "Cannot check for port conflicts (ss or netstat not found)" "$vm_name"
                fi
                for vm_path in "$VM_DIR"/*; do
                    if [[ -d "$vm_path" && "$vm_path" != "$VM_DIR/$vm_name" ]]; then
                        local other_vm_name
                        other_vm_name=$(basename "$vm_path")
                        local other_config="$VM_DIR/$other_vm_name/config"
                        if [[ -f "$other_config" ]]; then
                            # Use a subshell to avoid polluting global variables
                            (
                                # shellcheck disable=SC1090
                                source "$other_config"
                                local OTHER_PORT_FORWARDS="${OTHER_PORT_FORWARDS:-}"
                                if [[ -n "$OTHER_PORT_FORWARDS" ]]; then
                                    IFS=',' read -ra other_ports <<< "$OTHER_PORT_FORWARDS"
                                    for other_port in "${other_ports[@]}"; do
                                        if [[ "$other_port" =~ ^([0-9]+):([0-9]+):([a-z]+)$ ]]; then
                                            if [[ "${BASH_REMATCH[1]}" == "$host_port" && "${BASH_REMATCH[3]}" == "$protocol" ]]; then
                                                log_message "ERROR" "Host port $host_port ($protocol) is already used by VM '$other_vm_name'" "$vm_name"
                                                exit 1
                                            fi
                                        elif [[ "$other_port" =~ ^([0-9]+):([0-9]+)$ ]]; then
                                            if [[ "${BASH_REMATCH[1]}" == "$host_port" && "$protocol" == "tcp" ]]; then
                                                log_message "ERROR" "Host port $host_port (tcp) is already used by VM '$other_vm_name' (legacy format)" "$vm_name"
                                                exit 1
                                            fi
                                        fi
                                    done
                                fi
                            ) || return 1
                        fi
                    fi
                done
            fi
            IFS=',' read -ra PORTS <<< "$PORT_FORWARDS"
            for existing in "${PORTS[@]}"; do
                if [[ "$existing" == "$normalized_spec" ]]; then
                    log_message "INFO" "Port forward already exists: $normalized_spec" "$vm_name"
                    return 0
                fi
            done
            PORTS+=("$normalized_spec")
            PORT_FORWARDS=$(
                IFS=','
                echo "${PORTS[*]}"
            )
            PORT_FORWARDING_ENABLED="1"
            save_vm_config "$vm_name"
            log_message "INFO" "Port forward added: $normalized_spec" "$vm_name"
            ;;
        "remove")
            if [[ -z "$port_spec" ]]; then
                log_message "ERROR" "Port specification required (format: host_port:guest_port[:tcp|udp])" "$vm_name"
                return 1
            fi

            # Parse and normalize port_spec
            local normalized_spec
            if ! parse_port_spec "$port_spec" "$vm_name" normalized_spec; then
                return 1
            fi

            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify port forwards while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi

            # Convert existing forwards into array
            IFS=',' read -ra PORTS <<< "$PORT_FORWARDS"

            # Filter out the port to remove
            local NEW_PORTS=()
            local found=false
            for existing in "${PORTS[@]}"; do
                if [[ "$existing" == "$normalized_spec" ]]; then
                    found=true
                else
                    NEW_PORTS+=("$existing")
                fi
            done

            if ! $found; then
                # Check for similar port forwards with different protocols
                local similar_protocols=()
                if [[ "$normalized_spec" =~ ^([0-9]+):([0-9]+): ]]; then
                    local host_port="${BASH_REMATCH[1]}"
                    local guest_port="${BASH_REMATCH[2]}"
                    for existing in "${PORTS[@]}"; do
                        if [[ "$existing" =~ ^$host_port:$guest_port:([a-z]+)$ ]]; then
                            similar_protocols+=("${BASH_REMATCH[1]}")
                        fi
                    done
                fi
                if [[ ${#similar_protocols[@]} -gt 0 ]]; then
                    log_message "ERROR" "Port forward not found: $normalized_spec. Note: Port forwards exist for $host_port:$guest_port with protocols: ${similar_protocols[*]}" "$vm_name"
                else
                    log_message "ERROR" "Port forward not found: $normalized_spec" "$vm_name"
                fi
                return 1
            fi

            # Join array back into comma-separated string
            PORT_FORWARDS=$(
                IFS=','
                echo "${NEW_PORTS[*]}"
            )

            # Disable forwarding if empty
            if [[ -z "$PORT_FORWARDS" ]]; then
                PORT_FORWARDING_ENABLED="0"
            fi

            save_vm_config "$vm_name"
            log_message "INFO" "Port forward removed: $normalized_spec" "$vm_name"
            ;;
    esac
}

# ============================================================================
# SHARED FOLDERS
# ============================================================================

start_virtiofs_daemon() {
    local vm_name="$1"
    local folder_path="$2"
    local socket_path="$3"
    local tag="$4"

    # Resolve virtiofsd path
    local virtiofsd_path
    if command -v virtiofsd &> /dev/null; then
        virtiofsd_path=$(command -v virtiofsd)
    elif [ -x /usr/lib/virtiofsd ]; then
        virtiofsd_path="/usr/lib/virtiofsd"
    else
        log_message "ERROR" "virtiofsd not found. Please install virtiofsd to use VirtioFS shared folders" "$vm_name"
        return 1
    fi

    # Check if shared folder exists and is accessible
    if [[ ! -d "$folder_path" ]]; then
        log_message "ERROR" "Shared folder does not exist: $folder_path" "$vm_name"
        return 1
    fi
    if [[ ! -r "$folder_path" ]] || [[ ! -w "$folder_path" ]]; then
        log_message "ERROR" "Shared folder is not readable/writable: $folder_path" "$vm_name"
        return 1
    fi

    # Ensure socket directory exists and is writable
    local socket_dir=$(dirname "$socket_path")
    if [[ ! -d "$socket_dir" ]]; then
        log_message "DEBUG" "Creating socket directory: $socket_dir" "$vm_name"
        mkdir -p "$socket_dir" || {
            log_message "ERROR" "Failed to create socket directory: $socket_dir" "$vm_name"
            return 1
        }
    fi
    if [[ ! -w "$socket_dir" ]]; then
        log_message "ERROR" "Socket directory is not writable: $socket_dir" "$vm_name"
        return 1
    fi

    # Check permissions
    log_message "DEBUG" "Running virtiofsd with user: $(whoami), socket: $socket_path, folder: $folder_path" "$vm_name"

    # Set file descriptor limit
    local target_nofile=1000000
    local current_nofile
    current_nofile=$(ulimit -n)
    local current_nofile_hard
    current_nofile_hard=$(ulimit -Hn)
    if [[ "$current_nofile_hard" -lt "$target_nofile" ]]; then
        log_message "WARNING" "Current hard file descriptor limit ($current_nofile_hard) is less than desired ($target_nofile). Attempting to increase." "$vm_name"
        ulimit -Hn "$target_nofile" 2>/dev/null || {
            log_message "WARNING" "Failed to set hard file descriptor limit to $target_nofile. Using $current_nofile_hard." "$vm_name"
        }
        ulimit -Sn "$target_nofile" 2>/dev/null || {
            log_message "WARNING" "Failed to set soft file descriptor limit to $target_nofile. Using $current_nofile." "$vm_name"
        }
    else
        if [[ "$current_nofile" -lt "$target_nofile" ]]; then
            ulimit -n "$target_nofile" 2>/dev/null || {
                log_message "WARNING" "Failed to set file descriptor limit to $target_nofile. Using $current_nofile." "$vm_name"
            }
        fi
        log_message "DEBUG" "File descriptor limit set to $(ulimit -n)" "$vm_name"
    fi

    # Kill any existing virtiofsd and remove stale socket
    if [[ -f "$socket_path.pid" ]]; then
        local old_pid
        old_pid=$(cat "$socket_path.pid")
        if kill -0 "$old_pid" 2>/dev/null; then
            log_message "DEBUG" "Stopping existing virtiofsd (PID: $old_pid)" "$vm_name"
            kill "$old_pid" 2>/dev/null
            sleep 1
        fi
        rm -f "$socket_path.pid"
    fi
    if [[ -S "$socket_path" ]]; then
        log_message "DEBUG" "Removing stale socket: $socket_path" "$vm_name"
        rm -f "$socket_path"
    fi

    # Start virtiofsd daemon
    log_message "DEBUG" "Starting virtiofsd from $virtiofsd_path for folder: $folder_path (tag: $tag)" "$vm_name"
    "$virtiofsd_path" \
        --socket-path="$socket_path" \
        --shared-dir="$folder_path" \
        --thread-pool-size=4 \
        --log-level=debug \
        --announce-submounts \
        --sandbox none \
        2> "$VM_DIR/$vm_name/logs/virtiofsd_${tag}.log" &

    local virtiofs_pid=$!
    echo "$virtiofs_pid" > "$socket_path.pid"

    # Wait for socket to be created (max 10 seconds)
    local count=0
    while [[ ! -S "$socket_path" ]] && [[ $count -lt 100 ]]; do
        sleep 0.1
        ((count++))
    done

    if [[ ! -S "$socket_path" ]]; then
        log_message "ERROR" "virtiofsd failed to create socket: $socket_path" "$vm_name"
        if [[ -s "$VM_DIR/$vm_name/logs/virtiofsd_${tag}.log" ]]; then
            log_message "ERROR" "virtiofsd error: $(tail -n 5 "$VM_DIR/$vm_name/logs/virtiofsd_${tag}.log")" "$vm_name"
        fi
        kill "$virtiofs_pid" 2>/dev/null
        rm -f "$socket_path.pid"
        return 1
    fi

    log_message "DEBUG" "virtiofsd started successfully (PID: $virtiofs_pid)" "$vm_name"
    return 0
}

configure_virtiofs_shared_folders() {
    local vm_name="$1"
    local -n cmd_array=$2 # Nameref to QEMU command array

    if [[ "$ENABLE_VIRTIO" != "1" ]]; then
        log_message "WARNING" "VirtioFS shared folders require VirtIO to be enabled. Skipping shared folder configuration for '$vm_name'." "$vm_name"
        return
    fi

    if [[ -n "$SHARED_FOLDERS" ]]; then
        IFS=',' read -ra folders_spec_list <<< "$SHARED_FOLDERS"
        local seen_tags=()
        local virtiofs_count=0
        
        for i in "${!folders_spec_list[@]}"; do
            local current_folder_spec="${folders_spec_list[$i]}"
            local folder_path mount_tag folder_type

            # Parse the spec: path:tag:type
            IFS=':' read -r folder_path mount_tag folder_type <<< "$current_folder_spec"

            # Skip if not virtiofs type
            if [[ "$folder_type" != "virtiofs" ]]; then
                continue
            fi

            if [[ -z "$folder_path" ]]; then
                log_message "WARNING" "Empty folder path in SHARED_FOLDERS spec: '$current_folder_spec'. Skipping." "$vm_name"
                continue
            fi

            # Generate unique mount tag if not provided
            if [[ -z "$mount_tag" ]]; then
                mount_tag=$(echo -n "$folder_path" | md5sum | cut -c1-8)
                log_message "DEBUG" "Generated mount_tag '$mount_tag' for folder '$folder_path'" "$vm_name"
            fi

            # Validate mount tag format
            if [[ ! "$mount_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                log_message "ERROR" "Invalid mount tag '$mount_tag' for folder '$folder_path'. Use letters, numbers, hyphens, underscores. Skipping." "$vm_name"
                continue
            fi

            # Check for duplicate mount tags
            local tag_is_duplicate=false
            for tag in "${seen_tags[@]}"; do
                if [[ "$tag" == "$mount_tag" ]]; then
                    log_message "ERROR" "Duplicate mount tag '$mount_tag' for folder '$folder_path'. Skipping." "$vm_name"
                    tag_is_duplicate=true
                    break
                fi
            done
            if [[ "$tag_is_duplicate" == true ]]; then
                continue
            fi
            seen_tags+=("$mount_tag")

            if [[ -d "$folder_path" ]]; then
                # Create socket path
                local socket_path="$VM_DIR/$vm_name/sockets/virtiofs_${mount_tag}.sock"
                
                # Start virtiofsd daemon
                if start_virtiofs_daemon "$vm_name" "$folder_path" "$socket_path" "$mount_tag"; then
                    # Configure memory backend only once
                    if [[ "$virtiofs_count" -eq 0 ]]; then
                        # Add memory backend configuration for VirtioFS
                        cmd_array+=("-object" "memory-backend-memfd,id=mem,size=$MEMORY,share=on")
                        cmd_array+=("-numa" "node,memdev=mem")
                    fi
                    
                    # Add QEMU chardev and vhost-user-fs device
                    cmd_array+=("-chardev" "socket,id=char_fs_$i,path=$socket_path")
                    # Remove cache-size parameter as it's not supported in all QEMU versions
                    cmd_array+=("-device" "vhost-user-fs-pci,queue-size=1024,chardev=char_fs_$i,tag=$mount_tag")
                    
                    ((virtiofs_count++))
                    log_message "DEBUG" "Added VirtioFS shared folder: '$folder_path' (tag: '$mount_tag') for VM '$vm_name'" "$vm_name"
                else
                    log_message "ERROR" "Failed to setup VirtioFS for folder: '$folder_path'. Skipping." "$vm_name"
                fi
            else
                log_message "WARNING" "Shared folder path does not exist: '$folder_path'. Skipping for VM '$vm_name'." "$vm_name"
            fi
        done
    fi
}


# Configures shared folder options for Linux guest using VirtIO 9p filesystem
configure_linux_shared_folders() {
    local vm_name="$1"
    # shellcheck disable=SC2178
    local -n cmd_array=$2 # Nameref to QEMU command array

    if [[ "$ENABLE_VIRTIO" != "1" ]]; then
        log_message "WARNING" "Shared folders using virtio-9p require VirtIO to be enabled. Skipping shared folder configuration for '$vm_name'." "$vm_name"
        return
    fi

    if [[ -n "$SHARED_FOLDERS" ]]; then
        IFS=',' read -ra folders_spec_list <<< "$SHARED_FOLDERS"
        local seen_tags=()
        for i in "${!folders_spec_list[@]}"; do
            local current_folder_spec="${folders_spec_list[$i]}"
            local folder_path mount_tag folder_type

            # Parse the spec: path:tag:type
            IFS=':' read -r folder_path mount_tag folder_type <<< "$current_folder_spec"

            # Skip if not 9p type
            if [[ "$folder_type" != "9p" ]]; then
                continue
            fi

            if [[ -z "$folder_path" ]]; then
                log_message "WARNING" "Empty folder path in SHARED_FOLDERS spec: '$current_folder_spec'. Skipping." "$vm_name"
                continue
            fi

            # Generate unique mount tag if not provided
            if [[ -z "$mount_tag" ]]; then
                mount_tag=$(echo -n "$folder_path" | md5sum | cut -c1-8)
                log_message "DEBUG" "Generated mount_tag '$mount_tag' for folder '$folder_path'" "$vm_name"
            fi

            # Validate mount tag format
            if [[ ! "$mount_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                log_message "ERROR" "Invalid mount tag '$mount_tag' for folder '$folder_path'. Use letters, numbers, hyphens, underscores. Skipping." "$vm_name"
                continue
            fi

            # Check for duplicate mount tags
            local tag_is_duplicate=false
            for tag in "${seen_tags[@]}"; do
                if [[ "$tag" == "$mount_tag" ]]; then
                    log_message "ERROR" "Duplicate mount tag '$mount_tag' for folder '$folder_path'. Skipping." "$vm_name"
                    tag_is_duplicate=true
                    break
                fi
            done
            if [[ "$tag_is_duplicate" == true ]]; then
                continue
            fi
            seen_tags+=("$mount_tag")

            if [[ -d "$folder_path" ]]; then
                cmd_array+=("-fsdev" "local,id=fsdev$i,path=$folder_path,security_model=mapped-xattr")
                cmd_array+=("-device" "virtio-9p-pci,fsdev=fsdev$i,mount_tag=$mount_tag")
                log_message "DEBUG" "Added 9p shared folder: '$folder_path' (tag: '$mount_tag') for VM '$vm_name'" "$vm_name"
            else
                log_message "WARNING" "Shared folder path does not exist: '$folder_path'. Skipping for VM '$vm_name'." "$vm_name"
            fi
        done
    fi
}

# Manages shared folders for a VM
manage_shared_folders() {
    local vm_name="$1"
    local action="$2"
    local folder_path="${3:-}"
    local mount_tag="${4:-}"
    local folder_type="${5:-}"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if [[ "$action" != "list" ]] && vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    load_vm_config "$vm_name" || return 1

    # Load existing shared folders into an array
    IFS=',' read -ra folders <<< "${SHARED_FOLDERS:-}"
    local changed=false

    case "$action" in
        "add")

            if [[ -n "$SHARED_FOLDERS" ]]; then
                log_message "ERROR" "Only one shared folder is allowed." "$vm_name"
                return 1
            fi

            if [[ -z "$folder_path" ]]; then
                log_message "ERROR" "Folder path required for 'add' action" "$vm_name"
                return 1
            fi

            if [[ ! -d "$folder_path" ]]; then
                log_message "ERROR" "Directory does not exist: $folder_path" "$vm_name"
                return 1
            fi

            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify shared folders while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi

            # Resolve symlinks fully
            if command -v realpath &> /dev/null; then
                folder_path=$(realpath --no-symlinks "$folder_path" 2> /dev/null || realpath "$folder_path")
                if [[ ! -d "$folder_path" ]]; then
                    log_message "ERROR" "Resolved path does not exist or is not a directory: $folder_path" "$vm_name"
                    return 1
                fi
            else
                folder_path=$(realpath "$folder_path" 2> /dev/null || echo "$folder_path")
                log_message "WARNING" "realpath not found, symlinks may not be fully resolved for: $folder_path" "$vm_name"
            fi

            # Check if already exists - need to extract path from full folder spec
            for f in "${folders[@]}"; do
                # Extract just the folder path from the full spec (format: path:tag:type)
                IFS=':' read -r existing_path _ <<< "$f"
                if [[ "$existing_path" == "$folder_path" ]]; then
                    log_message "INFO" "Shared folder already exists: $folder_path" "$vm_name"
                    return 0
                fi
            done

            # Validate mount tag if provided
            if [[ -n "$mount_tag" ]]; then
                if [[ ! "$mount_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                    log_message "ERROR" "Invalid mount tag '$mount_tag'. Use letters, numbers, hyphens, underscores only" "$vm_name"
                    return 1
                fi

                # Check for duplicate mount tags
                for f in "${folders[@]}"; do
                    IFS=':' read -r _ existing_tag _ <<< "$f"
                    if [[ "$existing_tag" == "$mount_tag" ]]; then
                        log_message "ERROR" "Mount tag '$mount_tag' already exists" "$vm_name"
                        return 1
                    fi
                done
            fi

            # Set default mount tag if not provided (using MD5 hash)
            if [[ -z "$mount_tag" ]]; then
                mount_tag=$(echo -n "$folder_path" | md5sum | cut -c1-8)
            fi

            # Set default folder type based on OS if not provided
            if [[ -z "$folder_type" ]]; then
                if [[ "$OS_TYPE" == "linux" ]]; then
                    folder_type="virtiofs"  # Default to virtiofs for Linux
                elif [[ "$OS_TYPE" == "windows" ]]; then
                    folder_type="smb"  # Windows only supports SMB
                fi
            fi

            # Validate folder type
            if [[ "$OS_TYPE" == "linux" ]]; then
                if [[ "$folder_type" != "virtiofs" && "$folder_type" != "9p" ]]; then
                    log_message "ERROR" "Invalid folder type '$folder_type' for Linux VM. Use: virtiofs, 9p" "$vm_name"
                    return 1
                fi
            elif [[ "$OS_TYPE" == "windows" ]]; then
                if [[ "$folder_type" != "smb" ]]; then
                    log_message "ERROR" "Windows VMs only support SMB shared folders" "$vm_name"
                    return 1
                fi
            fi

            # Build the folder spec
            local folder_spec="$folder_path:$mount_tag:$folder_type"
            folders+=("$folder_spec")
            changed=true
            
            # Show mounting instructions based on folder type
            log_message "INFO" "Shared folder added: $folder_path (tag: $mount_tag, type: $folder_type)" "$vm_name"
            
            if [[ "$OS_TYPE" == "linux" ]]; then
                echo ""
                echo "To mount this folder in the guest VM:"
                if [[ "$folder_type" == "virtiofs" ]]; then
                    echo "  sudo mkdir -p /mnt/$mount_tag"
                    echo "  sudo mount -t virtiofs $mount_tag /mnt/$mount_tag"
                    echo ""
                    echo "For automatic mounting at boot, add to /etc/fstab:"
                    echo "  $mount_tag /mnt/$mount_tag virtiofs defaults 0 0"
                else
                    echo "  sudo mkdir -p /mnt/$mount_tag"
                    echo "  sudo mount -t 9p -o trans=virtio,version=9p2000.L $mount_tag /mnt/$mount_tag"
                    echo ""
                    echo "For automatic mounting at boot, add to /etc/fstab:"
                    echo "  $mount_tag /mnt/$mount_tag 9p trans=virtio,version=9p2000.L 0 0"
                fi
            elif [[ "$OS_TYPE" == "windows" ]]; then
                echo ""
                echo "The shared folder will be available as a network drive in Windows."
                echo "Access it via: \\\\10.0.2.4\\qemu"
            fi
            ;;
        "remove")
            if [[ -z "$folder_path" ]]; then
                log_message "ERROR" "Folder path or mount tag required for 'remove' action" "$vm_name"
                return 1
            fi

            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify shared folders while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi

            local new_folders=()
            local found=false
            local removed_path=""
            local removed_tag=""
            local removed_type=""

            # Check if input looks like a mount tag (no slashes, short name)
            local is_mount_tag=false
            if [[ "$folder_path" != *"/"* ]] && [[ ${#folder_path} -le 16 ]]; then
                is_mount_tag=true
            fi

            # If it might be a path, try to resolve symlinks
            if [[ "$is_mount_tag" == false ]]; then
                if command -v realpath &> /dev/null; then
                    folder_path=$(realpath --no-symlinks "$folder_path" 2> /dev/null || realpath "$folder_path" 2> /dev/null || echo "$folder_path")
                else
                    folder_path=$(realpath "$folder_path" 2> /dev/null || echo "$folder_path")
                    log_message "WARNING" "realpath not found, symlinks may not be fully resolved for: $folder_path" "$vm_name"
                fi
            fi

            for f in "${folders[@]}"; do
                # Extract components from the full spec (format: path:tag:type)
                IFS=':' read -r existing_path existing_tag existing_type <<< "$f"

                local match=false
                if [[ "$is_mount_tag" == true ]]; then
                    # Try to match by mount tag
                    if [[ "$existing_tag" == "$folder_path" ]]; then
                        match=true
                        removed_path="$existing_path"
                        removed_tag="$existing_tag"
                        removed_type="$existing_type"
                    fi
                else
                    # Try to match by path
                    if [[ "$existing_path" == "$folder_path" ]]; then
                        match=true
                        removed_path="$existing_path"
                        removed_tag="$existing_tag"
                        removed_type="$existing_type"
                    fi
                fi

                if [[ "$match" == true ]]; then
                    found=true
                    log_message "INFO" "Removing shared folder: $existing_path (tag: ${existing_tag:-auto}, type: ${existing_type:-virtiofs})" "$vm_name"
                else
                    new_folders+=("$f")
                fi
            done

            if ! $found; then
                if [[ "$is_mount_tag" == true ]]; then
                    log_message "ERROR" "Mount tag not found: $folder_path" "$vm_name"
                else
                    log_message "ERROR" "Folder not found in shared folders: $folder_path" "$vm_name"
                fi
                log_message "INFO" "Available shared folders:" "$vm_name"
                for f in "${folders[@]}"; do
                    IFS=':' read -r existing_path existing_tag existing_type <<< "$f"
                    log_message "INFO" "  - $existing_path (tag: ${existing_tag:-auto}, type: ${existing_type:-virtiofs})" "$vm_name"
                done
                return 1
            fi

            folders=("${new_folders[@]}")
            changed=true
            if [[ "$is_mount_tag" == true ]]; then
                log_message "INFO" "Shared folder removed by tag '$folder_path': $removed_path (tag: ${removed_tag:-auto}, type: ${removed_type:-virtiofs})" "$vm_name"
            else
                log_message "INFO" "Shared folder removed: $removed_path (tag: ${removed_tag:-auto}, type: ${removed_type:-virtiofs})" "$vm_name"
            fi
            ;;
        "list")
            echo "Shared folders for VM '$vm_name':"
            if [[ ${#folders[@]} -eq 0 ]]; then
                echo "  No shared folders configured"
            else
                for i in "${!folders[@]}"; do
                    local folder="${folders[$i]}"
                    # Parse the full folder spec
                    IFS=':' read -r folder_path mount_tag folder_type <<< "$folder"
                    local status="missing"
                    [[ -d "$folder_path" ]] && status="exists"
                    echo "  share$i: $folder_path ($status)"
                    echo "    tag: ${mount_tag:-auto}"
                    echo "    type: ${folder_type:-virtiofs}"
                done
                
                # Show mounting instructions
                if [[ ${#folders[@]} -gt 0 ]] && [[ "$OS_TYPE" == "linux" ]]; then
                    echo ""
                    echo "Mount instructions for guest VM:"
                    local has_virtiofs=false
                    local has_9p=false
                    for f in "${folders[@]}"; do
                        IFS=':' read -r _ _ folder_type <<< "$f"
                        [[ "$folder_type" == "virtiofs" ]] && has_virtiofs=true
                        [[ "$folder_type" == "9p" ]] && has_9p=true
                    done
                    if [[ "$has_virtiofs" == true ]]; then
                        echo "  For VirtioFS: sudo mount -t virtiofs <tag> /mnt/<mountpoint>"
                    fi
                    if [[ "$has_9p" == true ]]; then
                        echo "  For 9p: sudo mount -t 9p -o trans=virtio,version=9p2000.L <tag> /mnt/<mountpoint>"
                    fi
                fi
            fi
            ;;
        *)
            log_message "ERROR" "Invalid action: $action. Use: add, remove, list" "$vm_name"
            return 1
            ;;
    esac

    if [[ "$changed" == true ]]; then
        # Save updated folder list
        if [[ ${#folders[@]} -eq 0 ]]; then
            SHARED_FOLDERS=""
        else
            SHARED_FOLDERS=$(
                IFS=','
                echo "${folders[*]}"
            )
        fi
        save_vm_config "$vm_name"
    fi
}

# ============================================================================
# USB DEVICE MANAGEMENT
# ============================================================================

# Manages USB passthrough devices for a VM
manage_usb_devices() {
    local vm_name="$1"
    local action="$2"
    local device_spec="${3:-}"

    validate_vm_name "$vm_name" || return 1

    if ! vm_exists "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' does not exist" "$vm_name"
        return 1
    fi

    if [[ "$action" != "list" ]] && vm_is_locked "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' is locked. Unlock it first" "$vm_name"
        return 1
    fi

    load_vm_config "$vm_name" || return 1

    # Load existing devices into an array
    IFS=',' read -ra devices <<< "${USB_DEVICES:-}"
    local changed=false

    case "$action" in
        "add")
            if [[ -z "$device_spec" ]]; then
                log_message "ERROR" "Device specification required for 'add' action (format: VENDOR_ID:PRODUCT_ID)" "$vm_name"
                echo "Hint: Use 'lsusb' to find device IDs."
                return 1
            fi

            if [[ ! "$device_spec" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
                log_message "ERROR" "Invalid device format: '$device_spec'. Use VENDOR_ID:PRODUCT_ID (e.g., 1d6b:0002)" "$vm_name"
                return 1
            fi

            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify USB devices while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi

            # Check if device already exists
            for dev in "${devices[@]}"; do
                if [[ "$dev" == "$device_spec" ]]; then
                    log_message "INFO" "USB device '$device_spec' is already configured for passthrough" "$vm_name"
                    return 0
                fi
            done

            devices+=("$device_spec")
            changed=true
            log_message "INFO" "USB device '$device_spec' added for passthrough" "$vm_name"
            log_message "WARNING" "USB passthrough may require root privileges or specific udev rules for the host device" "$vm_name"
            ;;

        "remove")
            if [[ -z "$device_spec" ]]; then
                log_message "ERROR" "Device specification required for 'remove' action (format: VENDOR_ID:PRODUCT_ID)" "$vm_name"
                return 1
            fi

            if [[ ! "$device_spec" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
                log_message "ERROR" "Invalid device format: '$device_spec'. Use VENDOR_ID:PRODUCT_ID" "$vm_name"
                return 1
            fi

            if vm_is_running "$vm_name"; then
                log_message "ERROR" "Cannot modify USB devices while VM is running. Stop '$vm_name' first" "$vm_name"
                return 1
            fi

            local new_devices=()
            local found=false
            for dev in "${devices[@]}"; do
                if [[ "$dev" == "$device_spec" ]]; then
                    found=true
                else
                    new_devices+=("$dev")
                fi
            done

            if ! $found; then
                log_message "ERROR" "USB device not found in configuration: $device_spec" "$vm_name"
                return 1
            fi

            devices=("${new_devices[@]}")
            changed=true
            log_message "INFO" "USB device '$device_spec' removed from passthrough configuration" "$vm_name"
            ;;

        "list")
            echo "Configured USB passthrough devices for VM '$vm_name':"
            if [[ ${#devices[@]} -eq 0 ]]; then
                echo "  No USB devices configured for passthrough"
            else
                for dev in "${devices[@]}"; do
                    echo "  - $dev"
                done
            fi
            ;;

        *)
            log_message "ERROR" "Invalid action: $action. Use: add, remove, list" "$vm_name"
            return 1
            ;;
    esac

    if [[ "$changed" == true ]]; then
        # Save updated device list
        if [[ ${#devices[@]} -eq 0 ]]; then
            USB_DEVICES=""
        else
            USB_DEVICES=$(
                IFS=','
                echo "${devices[*]}"
            )
        fi
        save_vm_config "$vm_name"
    fi
}

# ============================================================================
# HELP AND MAIN ENTRY POINT
# ============================================================================

# Displays help text with usage instructions
display_help() {
    cat << 'EOF'
╭─────────────────────────────────────────────────────────────────╮
│                        🖥️  QEMATE v3.0.1                        │
│                 Streamlined QEMU VM Management                  │
╰─────────────────────────────────────────────────────────────────╯

VM COMMANDS
───────────
  vm create <name> [--os-type TYPE] [--memory SIZE] [--cores N] [--disk-size SIZE] [--machine TYPE] [--enable-audio]
  vm start <name> [--headless] [--iso PATH]
  vm stop <name> [--force]
  vm delete <name> [--force]
  vm resize <name> <size> [--force]
  vm list 
  vm status <name>
  vm configure <name> [cores|memory|audio] [value]

NETWORK COMMANDS
──────────────
  net type <name> <type>
  net model <name> <model>
  net port add <name> <host:guest[:tcp|udp]>
  net port remove <name> <host:guest[:tcp|udp]>

SHARED FOLDER COMMANDS
─────────────────────
  shared add <name> <folder_path> [mount_tag] [type]
  shared remove <name> <folder_path|mount_tag> 
  shared list <name>

  Types: virtiofs (default for Linux), 9p, smb (Windows only)

USB COMMANDS
──────────
  usb add <name> <vendor_id:product_id>
  usb remove <name> <vendor_id:product_id>
  usb list <name>

SECURITY COMMANDS
────────────────
  security lock <name>
  security unlock <name>
EOF
}

# Main entry point for command parsing
main() {
    # Verify QEMU binary
    if ! command -v qemu-system-x86_64 &> /dev/null; then
        log_message "ERROR" "qemu-system-x86_64 not found. Please install QEMU."
        exit 1
    fi

    # Verifies that Bash version is 5.0 or higher
    if [[ "${BASH_VERSION%%.*}" -lt 5 ]]; then
        log_message "ERROR" "Bash 5.0 or higher is required. Current version: $BASH_VERSION"
        exit 1
    fi

    # Verify QEMU version
    [[ $(qemu-system-x86_64 --version 2> /dev/null | grep -oE '[0-9]+' | head -1) -ge 9 ]] \
        || {
            log_message "ERROR" "QEMU 9 or higher is required. Install or upgrade QEMU."
            exit 1
        }

    # Create VM directory if it doesn't exist
    mkdir -p "$VM_DIR"

    # Check if any arguments were provided
    if [[ $# -eq 0 ]]; then
        display_help
        exit 1
    fi

    # Parse command line arguments
    case "${1:-}" in
        "vm")
            shift
            if [[ $# -eq 0 ]]; then
                log_message "ERROR" "Usage: qemate vm <command> [<name>] [options]"
                display_help
                exit 1
            fi
            case "$1" in
                "create")
                    shift
                    local vm_name=""
                    local os_type="linux"
                    local memory=""
                    local cores=""
                    local disk_size=""
                    local machine=""
                    local enable_audio=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --memory)
                                memory="$2"
                                shift 2
                                ;;
                            --cores)
                                cores="$2"
                                shift 2
                                ;;
                            --disk-size)
                                disk_size="$2"
                                shift 2
                                ;;
                            --machine)
                                machine="$2"
                                shift 2
                                ;;
                            --os-type)
                                os_type="$2"
                                shift 2
                                ;;
                            --enable-audio)
                                enable_audio="1"
                                shift
                                ;;
                            -*)
                                log_message "ERROR" "Unknown option: $1"
                                display_help
                                exit 1
                                ;;
                            *)
                                if [[ -z "$vm_name" ]]; then
                                    vm_name="$1"
                                elif [[ "$1" == "linux" || "$1" == "windows" ]]; then
                                    os_type="$1"
                                else
                                    log_message "ERROR" "Invalid argument: $1"
                                    display_help
                                    exit 1
                                fi
                                shift
                                ;;
                        esac
                    done
                    if [[ -z "$vm_name" ]]; then
                        log_message "ERROR" "VM name is required"
                        display_help
                        exit 1
                    fi
                    create "$vm_name" "$os_type" "$memory" "$cores" "$disk_size" "$machine" "$enable_audio"
                    ;;
                "resize")
                    shift
                    local vm_name=""
                    local disk_size=""
                    local force="false"
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --force)
                                force="true"
                                shift
                                ;;
                            -*)
                                log_message "ERROR" "Unknown option: $1"
                                exit 1
                                ;;
                            *)
                                if [[ -z "$vm_name" ]]; then
                                    vm_name="$1"
                                elif [[ -z "$disk_size" ]]; then
                                    disk_size="$1"
                                else
                                    log_message "ERROR" "Too many arguments for resize command"
                                    exit 1
                                fi
                                shift
                                ;;
                        esac
                    done
                    if [[ -z "$vm_name" || -z "$disk_size" ]]; then
                        log_message "ERROR" "Usage: qemate vm resize [--force] <name> <size>"
                        exit 1
                    fi
                    resize_disk "$vm_name" "$disk_size" "$force"
                    ;;
                "start")
                    shift
                    local vm_name=""
                    local headless="0"
                    local iso_file=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --headless)
                                headless="1"
                                shift
                                ;;
                            --iso)
                                if [[ $# -lt 2 ]]; then
                                    log_message "ERROR" "ISO file path required for --iso option"
                                    exit 1
                                fi
                                iso_file="$2"
                                shift 2
                                ;;
                            -*)
                                log_message "ERROR" "Unknown option: $1"
                                display_help
                                exit 1
                                ;;
                            *)
                                if [[ -n "$vm_name" ]]; then
                                    log_message "ERROR" "Only one VM name can be specified"
                                    display_help
                                    exit 1
                                fi
                                vm_name="$1"
                                shift
                                ;;
                        esac
                    done
                    if [[ -z "$vm_name" ]]; then
                        log_message "ERROR" "Usage: qemate vm start [--headless] [--iso PATH] <name>"
                        exit 1
                    fi
                    start "$vm_name" "$headless" "$iso_file"
                    ;;
                "stop")
                    shift
                    local force="false"
                    local vm_name=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --force)
                                force="true"
                                shift
                                ;;
                            -*)
                                log_message "ERROR" "Unknown option: $1"
                                exit 1
                                ;;
                            *)
                                if [[ -n "$vm_name" ]]; then
                                    log_message "ERROR" "Only one VM name can be specified"
                                    exit 1
                                fi
                                vm_name="$1"
                                shift
                                ;;
                        esac
                    done
                    if [[ -z "$vm_name" ]]; then
                        log_message "ERROR" "Usage: qemate vm stop [--force] <name>"
                        exit 1
                    fi
                    stop "$vm_name" "$force"
                    ;;
                "delete")
                    shift
                    local force="false"
                    local vm_name=""
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --force)
                                force="true"
                                shift
                                ;;
                            -*)
                                log_message "ERROR" "Unknown option: $1"
                                exit 1
                                ;;
                            *)
                                if [[ -n "$vm_name" ]]; then
                                    log_message "ERROR" "Only one VM name can be specified"
                                    exit 1
                                fi
                                vm_name="$1"
                                shift
                                ;;
                        esac
                    done
                    if [[ -z "$vm_name" ]]; then
                        log_message "ERROR" "Usage: qemate vm delete [--force] <name>"
                        exit 1
                    fi
                    delete "$vm_name" "$force"
                    ;;
                "list")
                    list
                    ;;
                "status")
                    if [[ $# -ne 2 ]]; then
                        log_message "ERROR" "Usage: qemate vm status <name>"
                        exit 1
                    fi
                    status "$2"
                    ;;
                "configure")
                    shift
                    if [[ $# -eq 0 ]]; then
                        log_message "ERROR" "Usage: qemate vm configure <name> [cores|memory|audio] [value]"
                        exit 1
                    fi
                    configure "$@"
                    ;;
                *)
                    log_message "ERROR" "Invalid vm command: $1"
                    display_help
                    exit 1
                    ;;
            esac
            ;;
        "net")
            shift
            if [[ $# -lt 1 ]]; then
                log_message "ERROR" "Usage: qemate net <type|model|port [add|remove]> <name> [value]"
                exit 1
            fi
            local subcommand="$1"
            shift
            case "$subcommand" in
                "type")
                    if [[ $# -lt 2 ]]; then
                        log_message "ERROR" "Usage: qemate net type <name> [user|nat|none]"
                        exit 1
                    fi
                    set_network_type "$1" "${2:-}"
                    ;;
                "model")
                    if [[ $# -lt 2 ]]; then
                        log_message "ERROR" "Usage: qemate net model <name> [virtio-net-pci|e1000|rtl8139]"
                        exit 1
                    fi
                    set_network_model "$1" "${2:-}"
                    ;;
                "port")
                    if [[ $# -lt 2 ]]; then
                        log_message "ERROR" "Usage: qemate net port <add|remove> <name> <host:guest[:tcp|udp]>"
                        exit 1
                    fi
                    local port_action="$1"
                    local vm_name="$2"
                    local port_spec="${3:-}"
                    shift 3
                    case "$port_action" in
                        "add")
                            if [[ -z "$port_spec" ]]; then
                                log_message "ERROR" "Usage: qemate net port add <name> <host:guest[:tcp|udp]>"
                                exit 1
                            fi
                            local normalized_spec
                            if ! parse_port_spec "$port_spec" "$vm_name" normalized_spec; then
                                exit 1
                            fi
                            manage_network_ports "$vm_name" "add" "$normalized_spec" || exit 1
                            ;;
                        "remove")
                            if [[ -z "$port_spec" ]]; then
                                log_message "ERROR" "Usage: qemate net port remove <name> <host:guest[:tcp|udp]>"
                                exit 1
                            fi
                            local normalized_spec
                            if ! parse_port_spec "$port_spec" "$vm_name" normalized_spec; then
                                exit 1
                            fi
                            manage_network_ports "$vm_name" "remove" "$normalized_spec" || exit 1
                            ;;
                        *)
                            log_message "ERROR" "Invalid port action: $port_action. Use: add, remove"
                            exit 1
                            ;;
                    esac
                    ;;
                *)
                    log_message "ERROR" "Invalid net action: $subcommand. Use: type, model, port"
                    exit 1
                    ;;
            esac
            ;;
        "shared")
            shift
            if [[ $# -lt 2 ]]; then
                log_message "ERROR" "Usage: qemate shared <add|remove|list> <name> [folder_path] [mount_tag] [type]"
                exit 1
            fi
            case "$1" in
                "add")
                    if [[ $# -lt 3 ]]; then
                        log_message "ERROR" "Usage: qemate shared add <name> <folder_path> [mount_tag] [type]"
                        exit 1
                    fi
                    manage_shared_folders "$2" "$1" "$3" "${4:-}" "${5:-}"
                    ;;
                "remove")
                    if [[ $# -lt 3 ]]; then
                        log_message "ERROR" "Usage: qemate shared remove <name> <folder_path_or_mount_tag>"
                        exit 1
                    fi
                    manage_shared_folders "$2" "$1" "$3"
                    ;;
                "list")
                    manage_shared_folders "$2" "$1"
                    ;;
                *)
                    log_message "ERROR" "Invalid shared command: $1. Use: add, remove, list"
                    exit 1
                    ;;
            esac
            ;;
        "usb")
            shift
            if [[ $# -lt 2 ]]; then
                log_message "ERROR" "Usage: qemate usb <add|remove|list> <name> [vendor:product]"
                exit 1
            fi
            case "$1" in
                "add" | "remove")
                    if [[ $# -ne 3 ]]; then
                        log_message "ERROR" "Usage: qemate usb $1 <name> <vendor_id:product_id>"
                        exit 1
                    fi
                    manage_usb_devices "$2" "$1" "$3"
                    ;;
                "list")
                    if [[ $# -ne 2 ]]; then
                        log_message "ERROR" "Usage: qemate usb list <name>"
                        exit 1
                    fi
                    manage_usb_devices "$2" "$1"
                    ;;
                *)
                    log_message "ERROR" "Invalid usb command: $1. Use: add, remove, list"
                    exit 1
                    ;;
            esac
            ;;
        "security")
            shift
            if [[ $# -ne 2 ]]; then
                log_message "ERROR" "Usage: qemate security <lock|unlock> <name>"
                exit 1
            fi
            case "$1" in
                "lock")
                    lock "$2"
                    ;;
                "unlock")
                    unlock "$2"
                    ;;
                *)
                    log_message "ERROR" "Invalid security command: $1. Use: lock, unlock"
                    exit 1
                    ;;
            esac
            ;;
        "help" | "--help" | "-h" | "version" | "--version" | "-v")
            display_help
            ;;
        *)
            log_message "ERROR" "Unknown group or command: $1"
            exit 1
            ;;
    esac
}

# Run main function with all arguments
main "$@"