#!/bin/bash
################################################################################
# Qemate VM Module                                                             #
#                                                                              #
# Description: Core functions for managing QEMU virtual machines in Qemate.    #
# Author: Daniel Zilli                                                         #
# Version: 1.1.1                                                               #
# License: BSD 3-Clause License                                                #
# Date: April 2025                                                             #
################################################################################

# ============================================================================ #
# INITIALIZATION                                                               #
# ============================================================================ #

# Ensure SCRIPT_DIR is set by the parent script
[[ -z "${SCRIPT_DIR:-}" ]] && {
    echo "Error: SCRIPT_DIR not set." >&2
    exit 1
}

# Constants
readonly QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
readonly QEMU_IMG_BIN="${QEMU_IMG_BIN:-qemu-img}"
readonly DEFAULT_DISK_SIZE="20G"
readonly DEFAULT_MACHINE_TYPE="q35"
readonly DEFAULT_CORES=2
readonly DEFAULT_MEMORY="2G"

# ============================================================================ #
# HELPER FUNCTIONS                                                             #
# ============================================================================ #

# Parse arguments for VM creation
# Arguments:
#   $1: VM name
#   $@: Additional arguments for VM creation
# Returns:
#   Line-separated list of parsed arguments
parse_vm_create_args() {
    local vm_name="$1"
    shift
    local disk_size="$DEFAULT_DISK_SIZE" iso_file="" machine_type="$DEFAULT_MACHINE_TYPE" cores="$DEFAULT_CORES" memory="$DEFAULT_MEMORY"
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --disk-size)
            disk_size="$2"
            shift 2
            ;;
        --iso)
            iso_file="$2"
            shift 2
            ;;
        --machine)
            machine_type="$2"
            shift 2
            ;;
        --cores)
            cores="$2"
            shift 2
            ;;
        --memory)
            memory="$2"
            shift 2
            ;;
        *)
            log_message "ERROR" "Unknown option for 'create': $1."
            return 1
            ;;
        esac
    done
    printf "%s\n" "$disk_size" "$iso_file" "$machine_type" "$cores" "$memory"
}

# Standardize memory format to a consistent representation
# Arguments:
#   $1: Memory specification (e.g., 2048M or 2G)
# Returns:
#   Standardized memory format (always in G)
standardize_memory() {
    local memory="$1"
    
    if [[ "$memory" =~ ^([0-9]+)([MmGg])$ ]]; then
        local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
        if [[ "$unit" =~ [Mm] ]]; then
            local gib=$((num / 1024))
            [[ $((num % 1024)) -ne 0 ]] && log_message "WARNING" "Memory $num${unit} not a clean GiB, rounding to ${gib}G."
            printf "%dG" "$gib"
        else
            printf "%dG" "$num"
        fi
    else
        log_message "ERROR" "Invalid memory format: $memory (use e.g., 2048M or 2G)."
        return 1
    fi
}

# Generate VM configuration file
# Arguments:
#   $1: VM name
#   $2: Machine type
#   $3: Number of CPU cores
#   $4: Memory size
#   $5: MAC address
#   $6: Configuration file path
# Returns:
#   0 on success, non-zero on failure
generate_vm_config() {
    local vm_name="$1" machine_type="$2" cores="$3" memory="$4" mac_address="$5" config_file="$6"
    local max_id=0
    
    # Find the highest existing VM ID
    for config in "$VM_DIR"/*/config; do
        [[ -f "$config" ]] || continue
        if source "$config" && [[ "${ID:-0}" -gt "$max_id" ]]; then
            max_id="${ID}"
        fi
    done
    local new_id=$((max_id + 1))
    
    # Create the configuration file
    cat <<EOF >"$config_file" || return 1
ID=$new_id
NAME="$vm_name"
MACHINE_TYPE="$machine_type"
CORES=$cores
MEMORY="$memory"
MAC_ADDRESS="$mac_address"
NETWORK_TYPE="user"
NETWORK_MODEL="virtio-net-pci"
PORT_FORWARDING_ENABLED=0
PORT_FORWARDS=""
CPU_TYPE="host"
ENABLE_KVM=1
ENABLE_IO_THREADS=0
DISK_CACHE="none"
DISK_IO="native"
DISK_DISCARD="unmap"
ENABLE_VIRTIO=1
MACHINE_OPTIONS="accel=kvm"
VIDEO_TYPE="virtio-vga"
DISK_INTERFACE="virtio-blk-pci"
MEMORY_PREALLOC=0
MEMORY_SHARE=1
EOF
}

# Check if a VM is running
# Arguments:
#   $1: VM name
# Returns:
#   0 if running, 1 if not running
is_vm_running() {
    local vm_name="$1"
    pgrep -f "guest=$vm_name" >/dev/null
    return $?
}

# ============================================================================ #
# VM MANAGEMENT FUNCTIONS                                                      #
# ============================================================================ #

# Create a new virtual machine
# Arguments:
#   $1: VM name
#   $@: Additional arguments for VM creation
# Returns:
#   0 on success, non-zero on failure
vm_create() {
    local vm_name="$1" mac_address
    
    # Generate MAC address for the VM
    mac_address=$(generate_mac) || {
        log_message "ERROR" "Failed to generate MAC address."
        return 1
    }
    shift
    
    # Parse VM creation arguments
    mapfile -t args < <(parse_vm_create_args "$vm_name" "$@") || return 1
    local disk_size="${args[0]}" iso_file="${args[1]}" machine_type="${args[2]}" cores="${args[3]}" memory="${args[4]}"
    memory=$(standardize_memory "$memory") || return 1

    # Validate VM name and check if it already exists
    is_valid_name "$vm_name" || {
        log_message "ERROR" "Invalid VM name: $vm_name (use a-z, A-Z, 0-9, _, -)."
        return 1
    }
    [[ -d "$VM_DIR/$vm_name" ]] && {
        log_message "ERROR" "VM '$vm_name' already exists."
        return 1
    }

    # Create VM directory
    mkdir -p "$VM_DIR/$vm_name" || {
        log_message "ERROR" "Failed to create directory for $vm_name."
        return 1
    }
    
    # Create temporary config file
    local temp_config
    temp_config=$(mktemp -t "qemate_vm.XXXXXX") || {
        log_message "ERROR" "Failed to create temp config."
        rmdir "$VM_DIR/$vm_name" 2>/dev/null
        return 1
    }
    
    # Generate VM configuration
    generate_vm_config "$vm_name" "$machine_type" "$cores" "$memory" "$mac_address" "$temp_config" || {
        rm -f "$temp_config"
        rmdir "$VM_DIR/$vm_name" 2>/dev/null
        return 1
    }

    # Create disk image
    "$QEMU_IMG_BIN" create -f qcow2 "$VM_DIR/$vm_name/disk.qcow2" "$disk_size" >/dev/null 2>&1 || {
        log_message "ERROR" "Failed to create disk image for $vm_name."
        rm -f "$temp_config"
        rmdir "$VM_DIR/$vm_name" 2>/dev/null
        return 1
    }
    
    # Move config file to final location and set permissions
    mv "$temp_config" "$VM_DIR/$vm_name/config" && chmod 600 "$VM_DIR/$vm_name/config" "$VM_DIR/$vm_name/disk.qcow2" || {
        log_message "ERROR" "Failed to finalize VM config for $vm_name."
        rm -f "$VM_DIR/$vm_name/disk.qcow2" "$VM_DIR/$vm_name/config" "$temp_config" 2>/dev/null
        rmdir "$VM_DIR/$vm_name" 2>/dev/null
        return 1
    }
    
    log_message "SUCCESS" "Created VM '$vm_name'."
    
    # Start VM with ISO if provided
    [[ -n "$iso_file" ]] && vm_start "$vm_name" --iso "$iso_file"
    
    # Update VM cache
    cache_vms
}

# Start a virtual machine
# Arguments:
#   $1: VM name or ID
#   $@: Additional arguments for VM startup
# Returns:
#   0 on success, non-zero on failure
vm_start() {
    local name_or_id="$1" iso_file="" headless=0 extra_args=""
    shift
    
    # Parse VM start arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --headless) 
            headless=1
            shift 
            ;;
        --iso) 
            iso_file="$2"
            shift 2 
            ;;
        --extra-args) 
            extra_args="$2"
            shift 2 
            ;;
        *) 
            log_message "ERROR" "Unknown option for 'start': $1."
            return 1 
            ;;
        esac
    done

    # Resolve VM name from ID if necessary
    local vm_name
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: $name_or_id."
        return 1
    }
    validate_vm_identifier "$vm_name" "vm_start" || return 1

    local vm_dir="$VM_DIR/$vm_name" 
    local vm_lock="$TEMP_DIR/qemu-$vm_name.lock" 
    local log_file="$LOG_DIR/${vm_name}_$(date +%Y%m%d_%H%M%S).log"
    
    # Check if VM is already running
    pgrep -f "guest=$vm_name,process=qemu-$vm_name" >/dev/null && {
        log_message "ERROR" "VM '$vm_name' already running."
        return 1
    }
    
    # Check display availability for non-headless mode
    [[ "$headless" -eq 0 && -z "${DISPLAY:-}" ]] && ! xset q >/dev/null 2>&1 && {
        log_message "ERROR" "No X display detected. Use --headless."
        return 1
    }

    # Acquire lock for VM operations
    acquire_lock "$vm_lock" || return 1
    
    # Load VM configuration
    source "$vm_dir/config" || {
        log_message "ERROR" "Failed to read config for $vm_name."
        release_lock "$vm_lock"
        return 1
    }
    
    # Create log file
    touch "$log_file" && chmod 600 "$log_file" || {
        log_message "ERROR" "Failed to create log file: $log_file."
        release_lock "$vm_lock"
        return 1
    }

    # Build QEMU arguments
    local -a qemu_args=(
        "-machine" "type=${MACHINE_TYPE:-$DEFAULT_MACHINE_TYPE},${MACHINE_OPTIONS:-accel=kvm}"
        "-cpu" "${CPU_TYPE:-host},migratable=off"
        "-smp" "cores=${CORES:-$DEFAULT_CORES},threads=1"
        "-m" "${MEMORY:-$DEFAULT_MEMORY}"
    )
    
    # Add KVM and IO threads if enabled
    [[ "${ENABLE_KVM:-1}" -eq 1 ]] && qemu_args+=("-enable-kvm")
    [[ "${ENABLE_IO_THREADS:-0}" -eq 1 ]] && qemu_args+=("-object" "iothread,id=iothread0")
    
    # Memory options
    [[ "${MEMORY_PREALLOC:-0}" -eq 1 ]] && qemu_args+=("-overcommit" "mem-lock=on")
    [[ "${MEMORY_SHARE:-1}" -eq 1 ]] && qemu_args+=("-mem-prealloc")

    # VM naming
    qemu_args+=("-name" "guest=$vm_name,process=qemu-$vm_name")
    
    # Display options
    if [[ "$headless" -eq 1 ]]; then
        qemu_args+=("-display" "none" "-nographic")
    else
        local video_dev="${VIDEO_TYPE:-virtio-vga}"
        if [[ "$video_dev" == "virtio" ]]; then
            video_dev="virtio-vga"  # Ensure we use the full device name
        elif [[ ! "$video_dev" =~ ^(virtio-vga|qxl|vga)$ ]]; then
            video_dev="virtio-vga"  # Default to virtio-vga for invalid values
        fi
        qemu_args+=("-device" "$video_dev" "-display" "gtk")
    fi

    # Disk options
    local aio_mode="${DISK_IO:-io_uring}"
    local cache_mode="${DISK_CACHE:-none}"
    if [[ "$aio_mode" == "native" ]]; then
        cache_mode="direct=on"
    else
        cache_mode="${DISK_CACHE:-writeback}"
    fi
    
    # Validate disk exists
    [[ ! -f "$VM_DIR/$vm_name/disk.qcow2" ]] && { 
        log_message "ERROR" "Disk not found for $vm_name"
        release_lock "$vm_lock"
        return 1
    }
    
    # Add disk to QEMU arguments
    qemu_args+=("-drive" "file=$VM_DIR/$vm_name/disk.qcow2,format=qcow2,aio=$aio_mode,cache=$cache_mode,discard=${DISK_DISCARD:-unmap}")

    # Add disk interface if virtio is enabled
    [[ "${ENABLE_VIRTIO:-1}" -eq 1 ]] && qemu_args+=("-device" "${DISK_INTERFACE:-virtio-blk-pci},drive=disk0,id=disk0")
    
    # Add ISO if specified
    [[ -n "$iso_file" && -f "$iso_file" ]] && qemu_args+=("-drive" "file=$(printf '%q' "$iso_file"),format=raw,readonly=on,media=cdrom" "-boot" "order=d,once=d")

    # Build network arguments
    mapfile -t net_args < <(build_network_args "$vm_name") || {
        log_message "WARNING" "Failed to build network args for '$vm_name'. Using default NAT."
        net_args=("-netdev" "user,id=net0" "-device" "${NETWORK_MODEL:-virtio-net-pci},netdev=net0,mac=${MAC_ADDRESS}")
    }
    qemu_args+=("${net_args[@]}")
    
    # Add extra arguments if provided
    [[ -n "$extra_args" ]] && qemu_args+=($extra_args)

    # Start VM
    log_message "INFO" "Starting VM '$vm_name'."
    "$QEMU_BIN" "${qemu_args[@]}" >>"$log_file" 2>&1 &
    local pid=$!

    # For test mode, skip the process check
    if [[ "${QEMATE_TEST_MODE:-0}" -eq 1 ]]; then
        echo "$pid" >"$vm_lock/pid" || {
            log_message "ERROR" "Failed to write PID to $vm_lock/pid."
            kill "$pid" 2>/dev/null
            release_lock "$vm_lock"
            return 1
        }
        release_lock "$vm_lock" || return 1
        log_message "SUCCESS" "Started VM '$vm_name' (PID: $pid)."
        return 0
    fi

    # Regular verification for non-test mode
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        log_message "ERROR" "Failed to start VM '$vm_name'. Check $log_file for details."
        release_lock "$vm_lock"
        return 1
    fi
    
    # Write PID to lock file
    echo "$pid" >"$vm_lock/pid" || {
        log_message "ERROR" "Failed to write PID to $vm_lock/pid."
        kill "$pid" 2>/dev/null
        release_lock "$vm_lock"
        return 1
    }
    
    release_lock "$vm_lock" || return 1
    log_message "SUCCESS" "Started VM '$vm_name' (PID: $pid)."
}

# Stop a running virtual machine
# Arguments:
#   $1: VM name or ID
#   $2: --force (optional) to force-stop the VM
# Returns:
#   0 on success, non-zero on failure
vm_stop() {
    local name_or_id="$1" force=0
    shift
    [[ $# -gt 0 && "$1" == "--force" ]] && {
        force=1
        shift
    }

    # Resolve VM name from ID if necessary
    local vm_name
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: $name_or_id."
        return 1
    }
    validate_vm_identifier "$vm_name" "vm_stop" || return 1

    # Get VM process ID
    local pid
    pid=$(pgrep -f "guest=$vm_name,process=qemu-$vm_name") || {
        log_message "INFO" "VM '$vm_name' is not running."
        return 0
    }
    
    # Stop VM (force or graceful)
    if [[ "$force" -eq 1 ]]; then
        kill -9 "$pid" || {
            log_message "ERROR" "Failed to force stop VM '$vm_name' (PID: $pid)."
            return 1
        }
    else
        kill "$pid" || {
            log_message "ERROR" "Failed to stop VM '$vm_name' (PID: $pid)."
            return 1
        }
    fi
    
    # Wait for VM to stop
    for _ in {1..10}; do
        if ! kill -0 "$pid" 2>/dev/null; then
            log_message "SUCCESS" "Stopped VM '$vm_name'."
            return 0
        fi
        sleep 1
    done
    
    log_message "ERROR" "Failed to stop VM '$vm_name' within timeout."
    return 1
}

# Check VM status
# Arguments:
#   $1: VM name or ID
# Returns:
#   0 on success, non-zero on failure
vm_status() {
    local name_or_id="$1"
    
    # Resolve VM name from ID if necessary
    local vm_name
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: $name_or_id."
        return 1
    }
    validate_vm_identifier "$vm_name" "vm_status" || return 1

    # Check if VM is running and report status
    if pgrep -f "guest=$vm_name,process=qemu-$vm_name" >/dev/null; then
        local pid
        pid=$(pgrep -f "guest=$vm_name,process=qemu-$vm_name")
        log_message "INFO" "VM '$vm_name' is running (PID: $pid)."
    else
        log_message "INFO" "VM '$vm_name' is stopped."
    fi
}

# Delete a virtual machine
# Arguments:
#   $1: VM name or ID
#   $2: --force (optional) to force-delete a running VM
# Returns:
#   0 on success, non-zero on failure
vm_delete() {
    [[ $# -lt 1 ]] && {
        log_message "ERROR" "Missing NAME_OR_ID for 'delete'."
        return 1
    }
    local name_or_id="$1" force=0
    shift
    [[ $# -gt 0 && "$1" == "--force" ]] && {
        force=1
        shift
    }

    # Resolve VM name from ID if necessary
    local vm_name
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: $name_or_id."
        return 1
    }
    validate_vm_identifier "$vm_name" "vm_delete" || return 1

    # Check if VM is running
    if pgrep -f "guest=$vm_name,process=qemu-$vm_name" >/dev/null && [[ "$force" -eq 0 ]]; then
        log_message "ERROR" "VM '$vm_name' is running. Use --force to delete."
        return 1
    fi

    # Prompt for confirmation (unless in test mode)
    if [[ "${QEMATE_TEST_MODE:-0}" -eq 0 ]]; then
        local confirm
        read -r -p "Are you sure you want to delete VM '$vm_name'? [y/N] " confirm
        case "$confirm" in
        [yY] | [yY][eE][sS])
            log_message "INFO" "User confirmed deletion of VM '$vm_name'."
            ;;
        *)
            log_message "INFO" "Deletion of VM '$vm_name' canceled by user."
            return 0
            ;;
        esac
    fi

    # Force stop VM if needed
    [[ "$force" -eq 1 ]] && vm_stop "$vm_name" --force
    
    # Delete VM files
    rm -rf "$VM_DIR/$vm_name" || {
        log_message "ERROR" "Failed to delete VM '$vm_name'."
        return 1
    }
    log_message "SUCCESS" "Deleted VM '$vm_name'."
    
    # Update VM cache
    cache_vms
}

# List all virtual machines
# Arguments: None
# Returns:
#   0 on success, non-zero on failure
vm_list() {
    # Update VM cache - force a refresh in test mode
    cache_vms
    
    # Check if any VMs exist
    if [[ ${#VM_CACHE[@]} -eq 0 ]]; then
        log_message "INFO" "No VMs found."
        return 0
    fi
    
    # Display VM list header
    printf "%-5s %-20s %-10s\n" "ID" "NAME" "STATUS"
    printf "%s\n" "----------------------------------------"
    
    # List each VM with its status
    for vm_name in "${!VM_CACHE[@]}"; do
        local status="Stopped"
        is_vm_running "$vm_name" && status="Running"
        printf "%-5s %-20s %-10s\n" "${VM_CACHE[$vm_name]}" "$vm_name" "$status"
    done
}


# Interactive wizard for VM creation
# Arguments: None
# Returns:
#   0 on success, non-zero on failure
vm_wizard() {
    log_message "INFO" "Starting VM creation wizard."
    local vm_name disk_size iso_file machine_type cores memory

    # VM name prompt
    while true; do
        read -r -p "Enter VM name: " vm_name
        if is_valid_name "$vm_name"; then
            break
        else
            log_message "ERROR" "Invalid VM name: $vm_name (use a-z, A-Z, 0-9, _, -)."
        fi
    done

    # Disk size prompt
    read -r -p "Disk size (default: $DEFAULT_DISK_SIZE): " disk_size
    disk_size="${disk_size:-$DEFAULT_DISK_SIZE}"

    # ISO file prompt
    read -r -p "ISO file path (optional): " iso_file

    # Machine type prompt
    read -r -p "Machine type (default: $DEFAULT_MACHINE_TYPE): " machine_type
    machine_type="${machine_type:-$DEFAULT_MACHINE_TYPE}"

    # Number of cores prompt
    while true; do
        read -r -p "Number of cores (default: $DEFAULT_CORES): " cores
        cores="${cores:-$DEFAULT_CORES}"
        if [[ "$cores" =~ ^[0-9]+$ && "$cores" -gt 0 ]]; then
            break
        else
            log_message "ERROR" "Invalid number of cores: $cores (must be a positive integer)."
        fi
    done

    # Memory prompt
    while true; do
        read -r -p "Memory (default: $DEFAULT_MEMORY, e.g., 2048M or 2G): " memory
        memory="${memory:-$DEFAULT_MEMORY}"
        if standardize_memory "$memory" >/dev/null 2>&1; then
            memory=$(standardize_memory "$memory")
            break
        else
            log_message "ERROR" "Invalid memory format: $memory (use e.g., 2048M or 2G)."
        fi
    done

    # Create VM with collected parameters
    vm_create "$vm_name" --disk-size "$disk_size" --iso "$iso_file" --machine "$machine_type" --cores "$cores" --memory "$memory"
}

# Edit VM configuration
# Arguments:
#   $1: VM name or ID
# Returns:
#   0 on success, non-zero on failure
vm_edit() {
    local name_or_id="$1"
    
    # Resolve VM name from ID if necessary
    local vm_name
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: $name_or_id."
        return 1
    }
    validate_vm_identifier "$vm_name" "vm_edit" || return 1

    # Check if VM is running
    if pgrep -f "guest=$vm_name,process=qemu-$vm_name" >/dev/null; then
        log_message "ERROR" "Cannot edit running VM '$vm_name'. Stop it first."
        return 1
    fi
    
    # Open editor for VM configuration
    local editor="${EDITOR:-nano}"
    "$editor" "$VM_DIR/$vm_name/config" || {
        log_message "ERROR" "Failed to edit config for $vm_name."
        return 1
    }
    log_message "SUCCESS" "Edited config for VM '$vm_name'."
    
    # Update VM cache
    cache_vms
}