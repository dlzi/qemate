#!/bin/bash
################################################################################
# Qemate - QEMU Virtual Machine Manager                                        #
# Description: A streamlined command-line tool for managing QEMU virtual       #
#              machines with support for creation, control, and networking.    #
# Author: Daniel Zilli                                                         #
################################################################################

# Exit on error, undefined variable, or pipe failure
set -euo pipefail

################################################################################
# === CONSTANTS AND CONFIGURATION ===
################################################################################

# Script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd)" || {
    echo "ERROR: Failed to determine script directory" >&2
    exit 1
}
readonly SCRIPT_DIR

# Version detection
version=$(cat "${SCRIPT_DIR}/../VERSION" 2> /dev/null || echo "2.0.0")
readonly version

# Paths and binaries
declare -r VM_DIR="${QEMATE_VM_DIR:-${HOME}/QVMs}"
declare -r QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
declare -r QEMU_IMG_BIN="${QEMU_IMG_BIN:-qemu-img}"

# Default VM settings
declare -r DEFAULT_DISK_SIZE="20G"
declare -r DEFAULT_MACHINE_TYPE="q35"
declare -r DEFAULT_CORES=2
declare -r DEFAULT_MEMORY="2G"
declare -r DEFAULT_NETWORK_MODEL="e1000"
declare -r DEFAULT_DISK_INTERFACE="virtio-blk-pci"
declare -r DEFAULT_OS_TYPE="linux"
declare -r VM_STOP_TIMEOUT=10
declare -r MAX_VMS=100
declare -r MAX_DISK_USAGE_GB=1000
declare -r DEFAULT_LOG_LEVEL="ERROR"

# Valid options
declare -r -a VALID_NETWORK_TYPES=("nat" "user" "none")
declare -r -a VALID_NETWORK_MODELS=("e1000" "virtio-net-pci")
declare -r -a REQUIRED_COMMANDS=("qemu-system-x86_64" "qemu-img" "pgrep" "mktemp" "find" "sed" "numfmt")

# Logging configuration
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)
declare -r COLOR_INFO='\033[0;34m'
declare -r COLOR_SUCCESS='\033[0;32m'
declare -r COLOR_WARNING='\033[0;33m'
declare -r COLOR_ERROR='\033[0;31m'
declare -r COLOR_RESET='\033[0m'
: "${LOG_LEVEL:=INFO}"

# Path to store the persistent TEMP_DIR location
declare -r TEMP_DIR_FILE="/tmp/qemate_temp_dir.$USER"
declare TEMP_DIR=""

################################################################################
# === UTILITY FUNCTIONS ===
################################################################################

# Function: logs a message to a file and outputs it to the console with color-coded formatting based on log level
# Args: $1: log level
#       $2: message to log
#       $3: optional VM name for context (defaults to empty)
# Returns: 0 if the message is logged or skipped, non-zero on write failure
# Side Effects: writes to a log file and outputs to stdout/stderr
log_message() {
    local level="$1"
    local message="$2"
    local vm_name="${3:-}"

    # Skip logging if level is below configured LOG_LEVEL
    [[ "${LOG_LEVELS[$level]:-3}" -lt "${LOG_LEVELS[${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}]:-3}" ]] && return 0
    [[ "$level" == "DEBUG" && "${LOG_LEVELS[${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}]:-3}" -gt 0 ]] && return 0

    local timestamp pid formatted log_file
    timestamp=$(date '+%Y-%m-%d %H:%M:%S' 2> /dev/null || echo "UNKNOWN_TIME")
    pid=$$

    # Format message with color coding based on log level
    case "$level" in
        INFO) formatted=$(printf "%s[INFO]%s %s" "$COLOR_INFO" "$COLOR_RESET" "$message") ;;
        SUCCESS) formatted=$(printf "%s[SUCCESS]%s %s" "$COLOR_SUCCESS" "$COLOR_RESET" "$message") ;;
        WARNING) formatted=$(printf "%s[WARNING]%s %s" "$COLOR_WARNING" "$COLOR_RESET" "$message") ;;
        ERROR) formatted=$(printf "%s[ERROR]%s %s" "$COLOR_ERROR" "$COLOR_RESET" "$message") ;;
        DEBUG) formatted=$(printf "[DEBUG] %s" "$message") ;;
        *) formatted=$(printf "%s" "$message") ;;
    esac

    log_file=$(get_log_file "$vm_name")
    mkdir -p "$(dirname "$log_file")" 2> /dev/null \
        || log_message "WARNING" "Failed to create log directory: $(dirname "$log_file")"

    printf "[%s] [%s] [PID:%d] %s\n" "$timestamp" "$level" "$pid" "$message" >> "$log_file" 2> /dev/null || {
        printf "[%s] [WARNING] Failed to write to log file: %s\n" "$timestamp" "$log_file" >&2
    }

    if [[ -t 1 || -t 2 ]]; then
        echo -e "$formatted"
    else
        echo -e "$formatted" | sed 's/\x1b\[[0-9;]*m//g'
    fi
}

# Function: determines the appropriate log file path for a VM or defaults to a temporary log
# Args: $1: VM name
# Returns: path to the log file
get_log_file() {
    local vm_name="$1"
    local log_file log_dir

    if [[ -n "$vm_name" && -d "$VM_DIR/$vm_name" ]]; then
        log_dir="$VM_DIR/$vm_name/logs"
        log_file="$log_dir/error.log"
        ensure_directory "$log_dir" 700 || log_file="$TEMP_DIR/qemate_error.log"
    else
        log_file="$TEMP_DIR/qemate_error.log"
    fi

    echo "$log_file"
}

# Function: creates a directory with specified permissions if it doesn't exist
# Args: $1: directory path
#       $2: Permissions
# Returns: 0 on success, 1 on failure
ensure_directory() {
    local dir="$1"
    local perms="${2:-700}"

    mkdir -p "$dir" || return 1
    chmod "$perms" "$dir" || return 1
    return 0
}

# Function: validates a VM name based on length, characters, and pattern restrictions
# Args: $1: name to validate
# Returns: 0 if valid, 1 if invalid
is_valid_name() {
    local name="$1"
    [[ -n "$name" && "${#name}" -le 64 && "$name" =~ ^[a-zA-Z0-9_-]+$ && "$name" != *".."* ]]
}

# Function: creates a secure temporary file in the specified directory
# Args: $1: directory path (defaults to TEMP_DIR)
#       $2: file prefix (defaults to "qemate_tmp")
# Returns: path to the created temporary file
# Side Effects: creates a file with 600 permissions or exits on failure
create_secure_temp_file() {
    local dir="${1:-$TEMP_DIR}"
    local prefix="${2:-qemate_tmp}"
    local temp_file

    if ! ensure_directory "$dir" 700; then
        log_message "ERROR" "Failed to create temp directory: $dir"
        cleanup
        exit 1
    fi
    temp_file=$(mktemp -p "$dir" "${prefix}.XXXXXX") || {
        log_message "ERROR" "Failed to create temp file in $dir"
        cleanup
        exit 1
    }
    chmod 600 "$temp_file" || log_message "WARNING" "Failed to set permissions on temp file: $temp_file"

    echo "$temp_file"
}

# Function: standardizes memory input to megabytes
# Args: $1: memory input (e.g., 2048M, 2G)
# Returns: memory in megabytes
standardize_memory() {
    local input="$1"
    if [[ "$input" =~ ^[1-9][0-9]*[MG]$ ]]; then
        local value=${input%[MG]}
        local unit=${input: -1}
        if [[ "$unit" == "G" ]]; then
            echo "$((value * 1024))M"
        else
            echo "${value}M"
        fi
    else
        log_message "ERROR" "Invalid memory format: '$input'. Use format like 2048M or 4G." ""
        return 1
    fi
}

# Function: performs cleanup of VM temporary directories and global temp directory
# Args: $1: log level (optional)
#       $2: VM name (optional)
# Returns: none
# Side Effects: removes VM-specific temp directory if it exists
#               preserves TEMP_DIR unless no other VMs or script instances are running
cleanup() {
    local log_level="${1:-}" vm_name="${2:-}" dir check_name
    [[ -n "$log_level" ]] && log_message "$log_level" "Performing cleanup" "$vm_name"

    # Clean VM-specific temp directory
    if [[ -n "$vm_name" ]]; then
        local temp_dir="${VM_DIR}/${vm_name}/tmp"
        [[ -d "$temp_dir" ]] && ! rm -rf "$temp_dir" \
            && log_message "WARNING" "Failed to remove VM temp dir: $temp_dir" "$vm_name"
    fi

    # Check if TEMP_DIR should be preserved
    if [[ -d "$TEMP_DIR" ]]; then
        # Check for other running VMs
        shopt -s nullglob
        for dir in "$VM_DIR"/*; do
            if [[ -d "$dir" && -f "$dir/config" ]]; then
                check_name=$(basename "$dir")
                [[ "$check_name" == "$vm_name" ]] && continue
                pgrep -f "guest=$check_name" > /dev/null && {
                    shopt -u nullglob
                    log_message "DEBUG" "Other VMs are still running, preserving TEMP_DIR: $TEMP_DIR" "$vm_name"
                    return
                }
            fi
        done
        shopt -u nullglob

        # Check for other running Qemate instances
        local script_pid=$$
        if pgrep -f "$SCRIPT_DIR/qemate.sh" | grep -v "^${script_pid}$" > /dev/null; then
            log_message "DEBUG" "Other Qemate instances running, preserving TEMP_DIR: $TEMP_DIR" "$vm_name"
            return
        fi

        # No other VMs or instances, remove TEMP_DIR and TEMP_DIR_FILE
        log_message "DEBUG" "No other VMs or instances running, removing TEMP_DIR: $TEMP_DIR" "$vm_name"
        ! rm -rf "$TEMP_DIR" \
            && log_message "WARNING" "Failed to remove TEMP_DIR: $TEMP_DIR" "$vm_name"
        [[ -f "$TEMP_DIR_FILE" ]] && ! rm -f "$TEMP_DIR_FILE" \
            && log_message "WARNING" "Failed to remove TEMP_DIR_FILE: $TEMP_DIR_FILE" "$vm_name"
    fi
}

# Function: validates a VM identifier for a given context
# Args: $1: VM name
#       $2: context (e.g., delete, start)
# Returns: 0 if valid, exits with error if invalid
validate_vm_identifier() {
    local identifier="$1" context="$2"
    if ! is_valid_name "$identifier"; then
        log_message "ERROR" "Invalid VM name for $context: $identifier" "$identifier"
        exit 1
    fi

    if [[ ! -d "$VM_DIR/$identifier" ]]; then
        log_message "ERROR" "VM does not exist: $identifier" "$identifier"
        exit 1
    fi

    if [[ ! -f "$VM_DIR/$identifier/config" ]]; then
        log_message "ERROR" "VM config file missing: $identifier" "$identifier"
        exit 1
    fi
    return 0
}

# Function: checks if a VM is currently running
# Args: $1: VM name
# Returns: 0 if running, 1 if not running
# Side Effects: none
is_vm_running() {
    local vm_name="$1"
    pgrep -f "guest=$vm_name" > /dev/null
}

# Function: retrieves the PID of a running VM
# Args: $1: VM name
# Returns: outputs PID if found, empty string if not running
# Side Effects: none
get_vm_pid() {
    local vm_name="$1"
    pgrep -f "guest=$vm_name,process=qemu-$vm_name" 2> /dev/null || echo ""
}

################################################################################
# === SYSTEM INITIALIZATION ===
################################################################################

# Verifies that the system meets the requirements for running the script.
# Side Effects:
#   Exits with an error if required commands are missing or VM directory is not writable.
#   Logs a warning if disk space is low or CPU virtualization checks fail.
#   Calls check_cpu_virtualization to assess virtualization support.
check_system_requirements() {
    local missing=()
    local free_space
    local virt_support=0

    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        command -v "$cmd" > /dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Missing commands: ${missing[*]}. Install qemu-system-x86, qemu-utils, procps, findutils, sed, util-linux"
        cleanup
        exit 1
    fi
    if [[ ! -w "$VM_DIR" ]]; then
        log_message "ERROR" "VM directory ($VM_DIR) is not writable"
        cleanup
        exit 1
    fi

    free_space=$(df -k "$VM_DIR" | awk 'NR==2 {print $4}')
    [[ -n "$free_space" && "$free_space" -lt 5242880 ]] \
        && log_message "WARNING" "Low disk space: $((free_space / 1024))MB free in $VM_DIR (5GB recommended)"

    # Checks for CPU virtualization support and KVM availability.
    [[ -f /proc/cpuinfo ]] && grep -q -E 'vmx|svm' /proc/cpuinfo && virt_support=1

    if [[ -e /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
        log_message "DEBUG" "KVM acceleration available"
    elif [[ -e /dev/kvm ]]; then
        log_message "WARNING" "KVM device exists but is not accessible. Add user to 'kvm' group: sudo usermod -a -G kvm $USER"
    elif [[ "$virt_support" -eq 1 ]]; then
        log_message "WARNING" "CPU supports virtualization but KVM not available. Check BIOS settings"
    else
        log_message "WARNING" "No CPU virtualization support detected. VMs may run slowly"
    fi
}

# Function: creates or reuses a temporary directory
# Args: none
# Returns: none
# Side Effects: sets TEMP_DIR, updates TEMP_DIR_FILE, logs messages, exits on failure
create_temp_dir() {
    # Check if TEMP_DIR_FILE exists and points to a valid directory
    if [[ -f "$TEMP_DIR_FILE" && -r "$TEMP_DIR_FILE" ]]; then
        TEMP_DIR=$(cat "$TEMP_DIR_FILE" 2> /dev/null || echo "")
        if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
            # Verify permissions (must be 700)
            local perms
            perms=$(stat -c %a "$TEMP_DIR" 2> /dev/null || echo "")
            if [[ "$perms" != "700" ]]; then
                log_message "DEBUG" "Invalid permissions on $TEMP_DIR: $perms, creating new directory"
                rm -f "$TEMP_DIR_FILE" 2> /dev/null
                TEMP_DIR=""
            fi

            # Verify ownership (must be current user)
            local owner
            owner=$(stat -c %u "$TEMP_DIR" 2> /dev/null || echo "")
            if [[ -n "$TEMP_DIR" && "$owner" != "$(id -u)" ]]; then
                log_message "DEBUG" "Directory $TEMP_DIR not owned by user, creating new directory"
                rm -f "$TEMP_DIR_FILE" 2> /dev/null
                TEMP_DIR=""
            fi

            # Clean directory contents if reusing
            if [[ -n "$TEMP_DIR" ]]; then
                find "$TEMP_DIR" -maxdepth 1 -type f -delete 2> /dev/null || {
                    log_message "DEBUG" "Failed to clean $TEMP_DIR, creating new directory"
                    rm -f "$TEMP_DIR_FILE" 2> /dev/null
                    TEMP_DIR=""
                }
            fi

            # If TEMP_DIR is still valid, reuse it
            if [[ -n "$TEMP_DIR" ]]; then
                log_message "DEBUG" "Reusing temporary directory: $TEMP_DIR"
                readonly TEMP_DIR
                # Ensure TEMP_DIR_FILE permissions
                chmod 600 "$TEMP_DIR_FILE" 2> /dev/null || {
                    log_message "WARNING" "Failed to set permissions on $TEMP_DIR_FILE"
                }
                return 0
            fi
        else
            log_message "DEBUG" "Stored directory missing or invalid, creating new one"
            rm -f "$TEMP_DIR_FILE" 2> /dev/null
        fi
    fi

    # Create a new temporary directory
    TEMP_DIR=$(mktemp -d -t "qemate.$USER.XXXXXXXXXX") || {
        log_message "ERROR" "Failed to create temp directory"
        cleanup
        exit 1
    }

    # Set permissions
    chmod 700 "$TEMP_DIR" || {
        rm -rf "$TEMP_DIR"
        log_message "ERROR" "Failed to set temp dir permissions"
        cleanup
        exit 1
    }

    # Store the directory path
    echo "$TEMP_DIR" > "$TEMP_DIR_FILE" 2> /dev/null || {
        log_message "WARNING" "Failed to write temp dir path to $TEMP_DIR_FILE"
        rm -rf "$TEMP_DIR"
        cleanup
        exit 1
    }
    chmod 600 "$TEMP_DIR_FILE" 2> /dev/null || {
        log_message "WARNING" "Failed to set permissions on $TEMP_DIR_FILE"
    }

    log_message "DEBUG" "Created new temporary directory: $TEMP_DIR"
    readonly TEMP_DIR
}

# Function: initializes the system by setting up directories and checking requirements
# Args: none
# Returns: none
# Side Effects: creates TEMP_DIR, VM_DIR, sets up signal handlers, exits on failure
initialize_system() {
    # Initialize TEMP_DIR
    create_temp_dir || {
        log_message "ERROR" "Failed to initialize temporary directory"
        cleanup
        exit 1
    }

    # Ensure VM_DIR exists with correct permissions
    if ! ensure_directory "$VM_DIR" 700; then
        log_message "ERROR" "Failed to initialize VM directory: $VM_DIR"
        cleanup
        exit 1
    fi

    # Check system requirements and set up signal handlers
    check_system_requirements
    setup_signal_handlers
}

# Sets up signal handlers for graceful script termination.
# Side Effects:
#   Registers traps for SIGINT, SIGTERM, and SIGHUP signals.
#   Logs a debug message indicating handlers are set.
setup_signal_handlers() {
    trap 'signal_handler SIGINT' INT
    trap 'signal_handler SIGTERM' TERM
    trap 'signal_handler SIGHUP' HUP

    log_message "DEBUG" "Signal handlers set up"
}

# Handles signals by logging and performing cleanup.
# Args:
#   $1: Signal received (defaults to EXIT).
# Returns:
#   Exits with code 130 for non-EXIT signals, otherwise no return due to exit.
# Side Effects:
#   Logs the received signal and performs cleanup.
#   Exits the script for non-EXIT signals.
signal_handler() {
    local signal="${1:-EXIT}"
    local vm_name="${2:-}"

    log_message "INFO" "Received signal: $signal (PID: $$)" "$vm_name"
    cleanup "INFO" "$vm_name"

    [[ "$signal" != "EXIT" ]] && exit 130
}

# Checks if any VMs (other than the specified one) are running.
# Args:
#   $1: VM name to exclude (optional).
# Returns:
#   0 if no other VMs are running, 1 if at least one other VM is running.
# Side Effects:
#   None.
are_other_vms_running() {
    local exclude_vm="${1:-}"
    local vm_name

    shopt -s nullglob
    for dir in "$VM_DIR"/*; do
        if [[ -d "$dir" && -f "$dir/config" ]]; then
            vm_name=$(basename "$dir")
            [[ "$vm_name" == "$exclude_vm" ]] && continue

            if is_vm_running "$vm_name"; then
                shopt -u nullglob
                return 1 # Another VM is running
            fi
        fi
    done
    shopt -u nullglob

    return 0 # No other VMs are running
}

################################################################################
# === CONFIGURATION MANAGEMENT ===
################################################################################

# Sources a VM's configuration file and validates its contents.
# Args:
#   $1: VM name.
# Returns:
#   Path to the configuration file on success; exits on failure.
# Side Effects:
#   Exits with an error if the VM name is invalid, the config file is missing/unreadable, or required variables are unset.
#   Sources the config file into the current shell environment.
# Notes:
#   Disables ShellCheck SC1090 (non-constant source) as the config file path is dynamically constructed.
source_vm_config() {
    local vm_name="$1"
    local config_file="$VM_DIR/$vm_name/config"
    if ! is_valid_name "$vm_name"; then
        log_message "ERROR" "Invalid VM name: $vm_name" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        log_message "ERROR" "Config file not found or unreadable: $config_file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    # shellcheck disable=SC1090
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to source config file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    if [[ -z "${NAME:-}" ]]; then
        log_message "ERROR" "Missing required config variable: NAME" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    echo "$config_file"
}

# Retrieves a specific key's value from a VM's configuration file.
# Args:
#   $1: VM name.
#   $2: Configuration key to retrieve.
#   $3: Default value if the key is not found or the config file is inaccessible.
# Returns:
#   The value of the key if found, otherwise the default value.
#   Returns exit code 1 if the config file is missing or sourcing fails, 0 otherwise.
# Notes:
#   Uses a subshell to source the config file safely, avoiding modifications to the current environment.
get_vm_config() {
    local vm_name="$1" key="$2" default="$3"
    # Fix SC2318: Use two locals
    local config_file="$VM_DIR/$vm_name/config"
    local value

    [[ -f "$config_file" ]] || {
        echo "$default"
        return 1 # Indicate failure or default used
    }
    # Run in subshell to isolate sourcing
    # Fix SC2181: Check command directly
    if value=$(bash -c ". \"$config_file\" 2>/dev/null && echo \"\${$key:-$default}\""); then
        echo "$value"
        return 0
    else
        # Sourcing failed or key not found (subshell exited non-zero implicitly?)
        # This path might be tricky depending on why the subshell failed.
        # Assuming failure means use default.
        log_message "DEBUG" "Subshell failed sourcing $config_file or key $key missing." "$vm_name"
        echo "$default"
        return 1 # Indicate failure or default used
    fi
}

# Function: updates a key-value pair in a VM's configuration file
# Args: $1: VM name
#       $2: configuration key to update
#       $3: new value for the key
# Returns: 0 on success, 1 on failure
# Side Effects: modifies the VM's configuration file
#               creates and removes a temporary config file during modification
#               sets permissions (600) on the config file, logging a warning if this fails
#               logs errors and exits on failure
update_vm_config() {
    local vm_name="$1" key="$2" value="$3" config_file temp_dir temp_config
    config_file=$(source_vm_config "$vm_name") || return 1
    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        log_message "ERROR" "Config file not found or unreadable: $config_file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    temp_dir=$(dirname "$config_file")
    temp_config=$(create_secure_temp_file "$temp_dir" "qemate_config") || {
        log_message "ERROR" "Failed to create temporary config file for VM $vm_name" "$vm_name"
        cleanup "$vm_name"
        exit 1
    }
    cp "$config_file" "$temp_config" || {
        rm -f "$temp_config"
        log_message "ERROR" "Failed to copy config file for VM $vm_name" "$vm_name"
        cleanup "$vm_name"
        exit 1
    }
    if grep -q "^${key}=" "$temp_config"; then
        sed -i "s/^${key}=.*/${key}=\"${value}\"/" "$temp_config" || {
            rm -f "$temp_config"
            log_message "ERROR" "Failed to update config key $key for VM $vm_name" "$vm_name"
            cleanup "$vm_name"
            exit 1
        }
    else
        echo "${key}=\"${value}\"" >> "$temp_config" || {
            rm -f "$temp_config"
            log_message "ERROR" "Failed to append config key $key for VM $vm_name" "$vm_name"
            cleanup "$vm_name"
            exit 1
        }
    fi
    mv "$temp_config" "$config_file" || {
        rm -f "$temp_config"
        log_message "ERROR" "Failed to update config file for VM $vm_name" "$vm_name"
        cleanup "$vm_name"
        exit 1
    }
    chmod 600 "$config_file" || log_message "WARNING" "Failed to set permissions on config file: $config_file" "$vm_name"
    return 0
}

# Generates a new VM configuration file with specified parameters.
# Args:
#   $1: VM name.
#   $2: Machine type (e.g., q35, pc).
#   $3: Number of CPU cores.
#   $4: Memory size (e.g., 2048M, 2G).
#   $5: MAC address for networking.
#   $6: OS type (e.g., linux, windows).
#   $7: Path to the configuration file.
# Returns:
#   0 on success, 1 on failure (e.g., file write issues).
# Side Effects:
#   Creates the configuration directory if it doesn't exist.
#   Writes a new configuration file at the specified path.
#   Exits with an error if the config directory cannot be created.
# Notes:
#   Standardizes memory to GiB format using standardize_memory.
#   Adjusts disk interface and virtio settings for Windows OS.
#   Uses default values for unspecified settings (e.g., DEFAULT_DISK_INTERFACE, DEFAULT_NETWORK_MODEL).
generate_vm_config() {
    local vm_name="$1" machine_type="$2" cores="$3" memory="$4" mac_address="$5" os_type="$6" enable_audio="$7" config_path="$8"
    local config_dir std_memory enable_virtio disk_interface
    config_dir=$(dirname "$config_path")
    if ! ensure_directory "$config_dir" 700; then
        log_message "ERROR" "Cannot create config directory: $config_dir" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi
    std_memory=$(standardize_memory "$memory") || std_memory="$DEFAULT_MEMORY"
    enable_virtio=1
    disk_interface="$DEFAULT_DISK_INTERFACE"
    network_model="$DEFAULT_NETWORK_MODEL"
    [[ "$os_type" == "windows" ]] && {
        enable_virtio=0
        disk_interface="ide-hd"
        network_model="e1000"
    }
    cat << EOF > "$config_path" || return 1
NAME="$vm_name"
MACHINE_TYPE="$machine_type"
CORES=$cores
MEMORY="$std_memory"
MAC_ADDRESS="$mac_address"
NETWORK_TYPE="user"
NETWORK_MODEL="$network_model"
PORT_FORWARDING_ENABLED=0
PORT_FORWARDS=""
CPU_TYPE="host"
ENABLE_AUDIO="$enable_audio"
ENABLE_KVM=1
ENABLE_IO_THREADS=0
DISK_CACHE="writeback"
DISK_IO="threads"
DISK_DISCARD="unmap"
ENABLE_VIRTIO=$enable_virtio
MACHINE_OPTIONS="accel=kvm"
VIDEO_TYPE="virtio-vga"
DISK_INTERFACE="$disk_interface"
MEMORY_PREALLOC=0
MEMORY_SHARE=1
LOCKED=0
OS_TYPE="$os_type"
EOF
}

################################################################################
# === VM MANAGEMENT ===
################################################################################

# Function: creates a new virtual machine with specified parameters and a unique MAC address
# Args: $1: VM name
#       $2+: additional arguments (disk size, ISO file, machine type, cores, memory, OS type, enable audio)
# Returns: 0 on success, non-zero on failure
# Side Effects: creates VM directory, disk image, and config file; logs messages; may start VM if ISO provided
vm_create() {
    local vm_name="$1"
    local mac_address disk_size iso_file machine_type cores memory os_type enable_audio
    shift

    # Check resource limits
    local vm_count disk_usage
    vm_count=$(find "$VM_DIR" -maxdepth 1 -type d | wc -l)
    ((vm_count--)) # Exclude VM_DIR itself
    if [[ "$vm_count" -ge "$MAX_VMS" ]]; then
        log_message "DEBUG" "VM limit check failed: $vm_count >= $MAX_VMS" "$vm_name"
        log_message "ERROR" "Maximum VM limit ($MAX_VMS) reached" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    disk_usage=$(du -s "$VM_DIR" 2> /dev/null | cut -f1) # disk_usage in KB
    local limit_kb=$((MAX_DISK_USAGE_GB * 1024 * 1024))  # Convert GB to KB
    if [[ -n "$disk_usage" && "$disk_usage" -gt "$limit_kb" ]]; then
        log_message "DEBUG" "Disk usage check failed: $disk_usage > $limit_kb" "$vm_name"
        log_message "ERROR" "Disk usage limit (${MAX_DISK_USAGE_GB}GB) exceeded" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Generate a unique MAC address
    local seed mac
    seed=$(($(date +%s%N 2> /dev/null || date +%s) + $$ + RANDOM + RANDOM))
    RANDOM=$seed
    mac=$(printf "52:54:00:%02x:%02x:%02x" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    if [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && "$mac" != "52:54:00:00:00:00" ]]; then
        mac_address="$mac"
    else
        log_message "ERROR" "Failed to generate valid MAC address" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Parse arguments safely
    mapfile -t args < <(parse_vm_create_args "$vm_name" "$@") || return 1
    disk_size="${args[0]}"
    iso_file="${args[1]}"
    machine_type="${args[2]}"
    cores="${args[3]}"
    memory="${args[4]}"
    os_type="${args[5]:-$DEFAULT_OS_TYPE}"
    enable_audio="${args[6]:-0}"

    # Standardize memory (exits on error)
    memory=$(standardize_memory "$memory") || return 1

    # Check if VM already exists
    if [[ -d "$VM_DIR/$vm_name" ]]; then
        log_message "ERROR" "VM '$vm_name' already exists" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Create VM directory
    if ! ensure_directory "$VM_DIR/$vm_name" 700; then
        log_message "ERROR" "Failed to create VM directory" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Create config in temporary location first
    local temp_config
    temp_config=$(create_secure_temp_file "$TEMP_DIR" "qemate_vm_cfg") || {
        rmdir "$VM_DIR/$vm_name" 2> /dev/null
        log_message "ERROR" "Failed to create temp config file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    }

    # Generate config content
    if ! generate_vm_config "$vm_name" "$machine_type" "$cores" "$memory" "$mac_address" "$os_type" "$enable_audio" "$temp_config"; then
        rm -f "$temp_config"
        rmdir "$VM_DIR/$vm_name" 2> /dev/null
        log_message "ERROR" "Failed to generate VM configuration" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Create disk image
    if ! "$QEMU_IMG_BIN" create -f qcow2 "$VM_DIR/$vm_name/disk.qcow2" "$disk_size" > /dev/null 2>&1; then
        rm -f "$temp_config"
        rmdir "$VM_DIR/$vm_name" 2> /dev/null
        log_message "ERROR" "Failed to create disk image" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Finalize: Move config, set permissions
    if mv "$temp_config" "$VM_DIR/$vm_name/config"; then
        if ! chmod 600 "$VM_DIR/$vm_name/config" "$VM_DIR/$vm_name/disk.qcow2"; then
            log_message "WARNING" "Failed to set permissions on VM files" "$vm_name"
        fi
    else
        rm -f "$VM_DIR/$vm_name/disk.qcow2" "$VM_DIR/$vm_name/config" "$temp_config" 2> /dev/null
        rmdir "$VM_DIR/$vm_name" 2> /dev/null
        log_message "ERROR" "Failed to finalize VM config" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    log_message "SUCCESS" "Created VM '$vm_name' (OS: $os_type)" "$vm_name"

    # Start VM if ISO is provided and valid
    if [[ -n "$iso_file" && -f "$iso_file" && -r "$iso_file" ]]; then
        log_message "INFO" "Starting VM '$vm_name' with ISO '$iso_file'" "$vm_name"
        vm_start "$vm_name" --iso "$iso_file"
    fi
    return 0
}

# Function: parses arguments for VM creation and assigns defaults if not provided
# Args: $1: VM name
#       $2+: Command-line options
# Returns: 0 on success, non-zero on failure
# Side Effects: outputs parsed values (disk_size, iso_file, machine_type, cores, memory, os_type, enable_audio) to stdout
#               logs error messages for unknown options or invalid values
parse_vm_create_args() {
    local vm_name="$1"
    local disk_size="$DEFAULT_DISK_SIZE" iso_file="" machine_type="$DEFAULT_MACHINE_TYPE"
    local cores="$DEFAULT_CORES" memory="$DEFAULT_MEMORY" os_type="$DEFAULT_OS_TYPE" enable_audio=0
    local valid_machine_types=("pc-q35" "pc-i440fx" "virt") valid_os_types=("linux" "windows" "bsd" "other")

    # Validate VM name
    if ! is_valid_name "$vm_name"; then
        log_message "ERROR" "Invalid VM name: '$vm_name'"
        cleanup
        exit 1
    fi

    # Check if defaults are set
    for var in DEFAULT_DISK_SIZE DEFAULT_MACHINE_TYPE DEFAULT_CORES DEFAULT_MEMORY DEFAULT_OS_TYPE; do
        if [[ -z "${!var}" ]]; then
            log_message "ERROR" "Default value for $var is not set" "$vm_name"
            cleanup "$vm_name"
            exit 1
        fi
    done

    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --disk-size)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --disk-size requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*[GM]$ ]]; then
                    log_message "ERROR" "Invalid disk size: '$2'. Must be a number followed by G or M (e.g., 10G, 512M)" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                disk_size="$2"
                shift 2
                ;;
            --iso)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --iso requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                if [[ ! -f "$2" || ! -r "$2" ]]; then
                    log_message "ERROR" "Invalid or inaccessible ISO file: '$2'" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                iso_file="$2"
                shift 2
                ;;
            --machine)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --machine requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                local valid_machine=0
                for type in "${valid_machine_types[@]}"; do
                    if [[ "$2" == "$type" ]]; then
                        valid_machine=1
                        break
                    fi
                done
                if [[ $valid_machine -eq 0 ]]; then
                    log_message "ERROR" "Invalid machine type: '$2'. Must be one of: ${valid_machine_types[*]}" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                machine_type="$2"
                shift 2
                ;;
            --cores)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --cores requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*$ ]] || [[ "$2" -gt 64 ]]; then
                    log_message "ERROR" "Invalid core count: '$2'. Must be a number between 1 and 64" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                cores="$2"
                shift 2
                ;;
            --memory)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --memory requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                if ! [[ "$2" =~ ^[1-9][0-9]*[GM]$ ]]; then
                    log_message "ERROR" "Invalid memory size: '$2'. Must be a number followed by G or M (e.g., 4G, 512M)" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                memory="$2"
                shift 2
                ;;
            --os-type)
                if [[ $# -lt 2 ]]; then
                    log_message "ERROR" "Option --os-type requires a value" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                local valid_os=0
                for type in "${valid_os_types[@]}"; do
                    if [[ "$2" == "$type" ]]; then
                        valid_os=1
                        break
                    fi
                done
                if [[ $valid_os -eq 0 ]]; then
                    log_message "ERROR" "Invalid OS type: '$2'. Must be one of: ${valid_os_types[*]}" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
                os_type="$2"
                shift 2
                ;;
            --enable-audio)
                enable_audio=1
                shift
                ;;
            *)
                log_message "ERROR" "Unknown option for 'create': '$1'" "$vm_name"
                cleanup "$vm_name"
                exit 1
                ;;
        esac
    done

    # Output parsed values
    printf "%s\n" "$disk_size" "$iso_file" "$machine_type" "$cores" "$memory" "$os_type" "$enable_audio"
    return 0
}

# Function: sets up temporary directories and lock files for starting a VM
# Args: $1: VM name
# Returns: path to the lock directory on success, non-zero exit code on failure
# Side Effects: creates temporary directory
#               creates or clears error log file
#               removes stale temporary directory if no valid PID is found
#               logs error messages on failure
vm_start_setup() {
    local vm_name="$1"
    local vm_temp_dir vm_lock_dir log_file log_dir pid_file pid
    local timeout_secs=10

    if [[ -z "${VM_DIR}" || ! -d "${VM_DIR}" || ! -w "${VM_DIR}" ]]; then
        log_message "ERROR" "VM_DIR is not set or not writable: '${VM_DIR}'" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Initialize paths
    vm_temp_dir="${VM_DIR}/${vm_name}/tmp"
    vm_lock_dir="${vm_temp_dir}/qemu-${vm_name}.lock"
    log_file="${VM_DIR}/${vm_name}/logs/error.log"
    log_dir=$(dirname "$log_file")
    pid_file="${vm_lock_dir}/pid"

    # Check for existing temp dir and lock
    if [[ -d "$vm_temp_dir" ]]; then
        if [[ -f "$pid_file" ]]; then
            pid=$(cat "$pid_file" 2> /dev/null || true)
            if [[ -n "$pid" && -e "/proc/$pid" ]]; then
                # Validate QEMU process
                if get_vm_pid "$vm_name" > /dev/null 2>&1; then
                    log_message "ERROR" "VM '$vm_name' is running or has active lock (PID: $pid)" "$vm_name"
                    cleanup "$vm_name"
                    exit 1
                fi
            fi
        fi

        # Clean up stale directory with timeout
        log_message "DEBUG" "Removing stale temp directory: $vm_temp_dir" "$vm_name"
        if ! timeout "$timeout_secs" rm -rf "$vm_temp_dir" 2> /dev/null; then
            log_message "ERROR" "Failed to clean up stale temp directory: $vm_temp_dir" "$vm_name"
            cleanup "$vm_name"
            exit 1
        fi
    fi

    # Create directories with atomic operations and secure permissions
    local created_dirs=()
    for dir in "$vm_temp_dir" "$vm_lock_dir" "$log_dir"; do
        if ! mkdir -p "$dir" 2> /dev/null; then
            # Cleanup created directories on failure
            for created_dir in "${created_dirs[@]}"; do
                rm -rf "$created_dir" 2> /dev/null
            done
            log_message "ERROR" "Failed to create directory: $dir" "$vm_name"
            cleanup "$vm_name"
            exit 1
        fi
        # Explicitly set permissions for the entire path
        if ! chmod -R 700 "$dir" 2> /dev/null; then
            # Cleanup created directories on failure
            for created_dir in "${created_dirs[@]}"; do
                rm -rf "$created_dir" 2> /dev/null
            done
            log_message "ERROR" "Failed to set permissions for directory: $dir" "$vm_name"
            cleanup "$vm_name"
            exit 1
        fi
        created_dirs+=("$dir")
    done

    # Create/clear log file
    if ! touch "$log_file" 2> /dev/null || ! chmod 600 "$log_file" 2> /dev/null; then
        # Cleanup all created directories
        for created_dir in "${created_dirs[@]}"; do
            rm -rf "$created_dir" 2> /dev/null
        done
        log_message "ERROR" "Failed to create or set permissions on log file: $log_file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    # Verify directory permissions
    for dir in "$vm_temp_dir" "$vm_lock_dir" "$log_dir"; do
        if [[ ! -d "$dir" || "$(stat -c %a "$dir" 2> /dev/null)" != "700" ]]; then
            # Cleanup
            for created_dir in "${created_dirs[@]}"; do
                rm -rf "$created_dir" 2> /dev/null
            done
            log_message "ERROR" "Invalid permissions on directory: $dir" "$vm_name"
            cleanup "$vm_name"
            exit 1
        fi
    done

    # Verify log file permissions
    if [[ ! -f "$log_file" || "$(stat -c %a "$log_file" 2> /dev/null)" != "600" ]]; then
        # Cleanup
        for created_dir in "${created_dirs[@]}"; do
            rm -rf "$created_dir" 2> /dev/null
        done
        log_message "ERROR" "Invalid permissions on log file: $log_file" "$vm_name"
        cleanup "$vm_name"
        exit 1
    fi

    echo "$vm_lock_dir"
    return 0
}

# Function: generates QEMU configuration arguments for starting a VM
# Args: $1: VM name
# Returns: 0 on success, non-zero on failure
# Side Effects: outputs QEMU arguments and video type to stdout
#               logs warnings for invalid configuration values or unavailable PipeWire.
vm_start_config() {
    local vm_name="$1"

    # Check if VM name is provided
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name not provided" "N/A" >&2
        return 1
    fi

    local machine_type cores memory cpu_type enable_kvm machine_options memory_prealloc memory_share enable_io_threads video_type enable_audio

    # Get configuration with proper error handling
    machine_type=$(get_vm_config "$vm_name" "MACHINE_TYPE" "$DEFAULT_MACHINE_TYPE") || return $?
    cores=$(get_vm_config "$vm_name" "CORES" "$DEFAULT_CORES") || return $?
    memory=$(get_vm_config "$vm_name" "MEMORY" "$DEFAULT_MEMORY") || return $?
    cpu_type=$(get_vm_config "$vm_name" "CPU_TYPE" "host") || return $?
    enable_kvm=$(get_vm_config "$vm_name" "ENABLE_KVM" "1") || return $?
    machine_options=$(get_vm_config "$vm_name" "MACHINE_OPTIONS" "accel=kvm") || return $?
    memory_prealloc=$(get_vm_config "$vm_name" "MEMORY_PREALLOC" "0") || return $?
    memory_share=$(get_vm_config "$vm_name" "MEMORY_SHARE" "1") || return $?
    enable_io_threads=$(get_vm_config "$vm_name" "ENABLE_IO_THREADS" "0") || return $?
    video_type=$(get_vm_config "$vm_name" "VIDEO_TYPE" "virtio-vga") || return $?
    enable_audio=$(get_vm_config "$vm_name" "ENABLE_AUDIO" "0") || return $?

    # Log key configuration values for debugging
    log_message "DEBUG" "Raw video_type: '$video_type'" "$vm_name"

    # Validate numeric values
    if ! [[ "$cores" =~ ^[1-9][0-9]*$ ]]; then
        log_message "WARNING" "Invalid cores value '$cores' for VM '$vm_name', defaulting to $DEFAULT_CORES" "$vm_name" >&2
        cores="$DEFAULT_CORES"
    fi

    if ! [[ "$memory" =~ ^[1-9][0-9]*[MG]?$ ]]; then
        log_message "WARNING" "Invalid memory value '$memory' for VM '$vm_name', defaulting to $DEFAULT_MEMORY" "$vm_name" >&2
        memory="$DEFAULT_MEMORY"
    fi

    # Validate boolean values
    for bool_var in enable_kvm memory_prealloc memory_share enable_io_threads enable_audio; do
        local var_value=${!bool_var}
        if ! [[ "$var_value" =~ ^[01]$ ]]; then
            local default_value
            case "$bool_var" in
                enable_kvm | memory_share) default_value="1" ;;
                *) default_value="0" ;;
            esac
            log_message "WARNING" "Invalid $bool_var value '$var_value' for VM '$vm_name', defaulting to $default_value" "$vm_name" >&2
            declare "$bool_var=$default_value"
        fi
    done

    # Sanitize and validate video_type - DO NOT add to qemu_args here
    # This is critical because the traceback showed it was added twice
    video_type=$(echo "$video_type" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-' '_')
    if [[ ! "$video_type" =~ ^(virtio-vga|qxl|vga)$ ]]; then
        if [[ "$video_type" == "virtio" ]]; then
            video_type="virtio-vga"
        else
            log_message "WARNING" "Invalid video type '$video_type' for VM '$vm_name', defaulting to virtio-vga" "$vm_name" >&2
            video_type="virtio-vga"
        fi
    fi

    # Define the character sets using single quotes for literal interpretation
    # shellcheck disable=SC2016
    local delete_chars=';|&$()[]{}\\<>"`'"'" # Set of characters to delete
    local allowed_chars='a-zA-Z0-9,=_-'      # Set of characters allowed (used with tr -C)

    # Sanitize and validate machine_options
    if [[ -n "$machine_options" && ! "$machine_options" =~ ^[a-zA-Z0-9,=_-]+$ ]]; then
        log_message "WARNING" "Potentially unsafe machine options: $machine_options for VM $vm_name" "$vm_name" >&2

        # Sanitize using the variables - double-quote them in the command
        machine_options=$(echo "$machine_options" | tr -d "$delete_chars" | tr -C "$allowed_chars" '_')

        log_message "INFO" "Sanitized machine options to: $machine_options" "$vm_name" >&2
    fi

    # Build QEMU arguments array
    local -a qemu_args=(
        "-machine" "type=${machine_type},${machine_options}"
        "-cpu" "${cpu_type},migratable=off"
        "-smp" "cores=${cores},threads=1"
        "-m" "${memory}"
        "-name" "guest=${vm_name},process=qemu-${vm_name}"
    )

    # Add conditional arguments
    [[ "$enable_kvm" -eq 1 ]] && qemu_args+=("-enable-kvm")
    [[ "$enable_io_threads" -eq 1 ]] && qemu_args+=("-object" "iothread,id=iothread0")

    # Fix swapped options
    # memory_prealloc should map to -mem-prealloc (not -overcommit)
    [[ "$memory_prealloc" -eq 1 ]] && qemu_args+=("-mem-prealloc")

    # memory_share should map to -overcommit mem-lock=on (not -mem-prealloc)
    [[ "$memory_share" -eq 1 ]] && qemu_args+=("-overcommit" "mem-lock=on")

    # Add audio if enabled
    [[ "$enable_audio" -eq 1 ]] || return 0
    if command -v pipewire > /dev/null 2>&1 && systemctl --user is-active pipewire > /dev/null 2>&1; then
        qemu_args+=("-audiodev" "pipewire,id=pipewire0" "-device" "ich9-intel-hda" "-device" "hda-micro,audiodev=pipewire0")
    else
        log_message "WARNING" "PipeWire unavailable or inactive. Audio disabled for VM '$vm_name'." "$vm_name"
    fi

    # Return the arguments (excluding video_type which will be handled separately)
    printf "%s\n" "${qemu_args[@]}"

    # Return video_type separately to avoid duplicate -device entries
    # This will be the last line of output, which can be captured separately
    echo "$video_type"

    return 0
}

# Function: builds QEMU disk, network, and display arguments for a virtual machine
# Args: $1: VM name
#       $2: headless mode (1 for headless, 0 for graphical)
#       $3: video type (e.g., virtio-vga, qxl, vga)
# Returns: 0 on success, 1 on failure
# Side Effects: outputs disk drive, disk device, network device, netdev, and display arguments to stdout
#               logs debug, warning, or error messages to stderr
build_vm_args() {
    local vm_name="$1" headless="$2" video_type="$3"

    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required." "" >&2
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "build_vm_args"; then
        log_message "ERROR" "Invalid VM name: '$vm_name'." "$vm_name" >&2
        return 1
    fi

    # Validate VM_DIR
    if [[ -z "$VM_DIR" || ! -d "$VM_DIR" || ! -w "$VM_DIR" ]]; then
        log_message "ERROR" "VM_DIR is not set or inaccessible." "$vm_name" >&2
        return 1
    fi

    # Validate disk path
    local disk_path="$VM_DIR/$vm_name/disk.qcow2"
    if [[ ! -f "$disk_path" || ! -r "$disk_path" ]]; then
        log_message "ERROR" "Disk file not found or unreadable: $disk_path" "$vm_name" >&2
        return 1
    fi
    log_message "DEBUG" "Using disk path: $disk_path" "$vm_name" >&2

    # --- Disk Arguments ---
    local enable_virtio aio_mode cache_mode disk_discard disk_interface
    enable_virtio=$(get_vm_config "$vm_name" "ENABLE_VIRTIO" "1") || {
        log_message "WARNING" "Failed to get ENABLE_VIRTIO, defaulting to 1" "$vm_name" >&2
        enable_virtio=1
    }
    disk_interface=$(get_vm_config "$vm_name" "DISK_INTERFACE" "virtio-blk-pci") || {
        log_message "WARNING" "Failed to get DISK_INTERFACE, defaulting to virtio-blk-pci" "$vm_name" >&2
        disk_interface="virtio-blk-pci"
    }

    # Sanitize disk_interface
    disk_interface=$(echo "$disk_interface" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-_' '_')
    log_message "DEBUG" "Disk interface: $disk_interface" "$vm_name" >&2

    # Validate disk_interface
    case "$disk_interface" in
        virtio-blk-pci | ide-hd | scsi-hd | nvme) ;;
        *)
            disk_interface="virtio-blk-pci"
            log_message "WARNING" "Invalid disk interface '$disk_interface', defaulting to virtio-blk-pci" "$vm_name" >&2
            ;;
    esac

    # Build drive options string
    local drive_opts="if=none,id=disk0,file=$disk_path,format=qcow2"

    if [[ "$enable_virtio" -eq 1 ]]; then
        aio_mode=$(get_vm_config "$vm_name" "DISK_IO" "threads") || {
            log_message "WARNING" "Failed to get DISK_IO, defaulting to threads" "$vm_name" >&2
            aio_mode="threads"
        }
        cache_mode=$(get_vm_config "$vm_name" "DISK_CACHE" "writeback") || {
            log_message "WARNING" "Failed to get DISK_CACHE, defaulting to writeback" "$vm_name" >&2
            cache_mode="writeback"
        }
        disk_discard=$(get_vm_config "$vm_name" "DISK_DISCARD" "unmap") || {
            log_message "WARNING" "Failed to get DISK_DISCARD, defaulting to unmap" "$vm_name" >&2
            disk_discard="unmap"
        }

        # Sanitize inputs
        aio_mode=$(echo "$aio_mode" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-_' '_')
        cache_mode=$(echo "$cache_mode" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-_' '_')
        disk_discard=$(echo "$disk_discard" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-_' '_')

        # Validate inputs
        [[ "$aio_mode" =~ ^(threads|native)$ ]] || {
            aio_mode="threads"
            log_message "WARNING" "Invalid aio_mode '$aio_mode', defaulting to threads" "$vm_name" >&2
        }
        [[ "$cache_mode" =~ ^(writeback|none|directsync|writethrough|unsafe)$ ]] || {
            cache_mode="writeback"
            log_message "WARNING" "Invalid cache_mode '$cache_mode', defaulting to writeback" "$vm_name" >&2
        }
        [[ "$disk_discard" =~ ^(unmap|ignore)$ ]] || {
            disk_discard="unmap"
            log_message "WARNING" "Invalid disk_discard '$disk_discard', defaulting to unmap" "$vm_name" >&2
        }

        # Handle aio=native case
        [[ "$aio_mode" == "native" ]] && cache_mode="none"

        # Append VirtIO options
        drive_opts+=",aio=$aio_mode,cache=$cache_mode,discard=$disk_discard"
    else
        # Non-VirtIO defaults
        drive_opts+=",aio=threads,cache=writeback,discard=unmap"
    fi
    log_message "DEBUG" "Drive options: $drive_opts" "$vm_name" >&2

    # --- Network Arguments ---
    local network_type network_model mac_address port_forwarding_enabled port_forwards netdev_args fwd_args entry host guest proto
    network_type=$(get_vm_config "$vm_name" "NETWORK_TYPE" "user") || {
        log_message "WARNING" "Failed to get NETWORK_TYPE, defaulting to user" "$vm_name" >&2
        network_type="user"
    }
    network_model=$(get_vm_config "$vm_name" "NETWORK_MODEL" "virtio-net-pci") || {
        log_message "WARNING" "Failed to get NETWORK_MODEL, defaulting to virtio-net-pci" "$vm_name" >&2
        network_model="virtio-net-pci"
    }
    mac_address=$(get_vm_config "$vm_name" "MAC_ADDRESS" "") || {
        log_message "WARNING" "Failed to get MAC_ADDRESS, using empty" "$vm_name" >&2
        mac_address=""
    }
    port_forwarding_enabled=$(get_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0") || {
        log_message "WARNING" "Failed to get PORT_FORWARDING_ENABLED, defaulting to 0" "$vm_name" >&2
        port_forwarding_enabled=0
    }
    port_forwards=$(get_vm_config "$vm_name" "PORT_FORWARDS" "") || {
        log_message "WARNING" "Failed to get PORT_FORWARDS, using empty" "$vm_name" >&2
        port_forwards=""
    }

    # Validate MAC address format (if provided)
    if [[ -n "$mac_address" && ! "$mac_address" =~ ^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$ ]]; then
        log_message "WARNING" "Invalid MAC address '$mac_address', ignoring" "$vm_name" >&2
        mac_address=""
    fi
    log_message "DEBUG" "Network model: $network_model, MAC: $mac_address" "$vm_name" >&2

    netdev_args="user,id=net0"
    if [[ "$port_forwarding_enabled" -eq 1 && -n "$port_forwards" ]]; then
        fwd_args=""
        IFS=',' read -ra forwards <<< "$port_forwards"
        for entry in "${forwards[@]}"; do
            IFS=':' read -r host guest proto <<< "$entry"
            # Validate port numbers and protocol
            if [[ -z "$host" || -z "$guest" || ! "$host" =~ ^[0-9]+$ || ! "$guest" =~ ^[0-9]+$ || ! "$proto" =~ ^(tcp|udp)$ ]]; then
                log_message "WARNING" "Invalid port forwarding entry '$entry', skipping" "$vm_name" >&2
                continue
            fi
            proto="${proto:-tcp}"
            fwd_args="${fwd_args},hostfwd=${proto}::${host}-:${guest}"
        done
        netdev_args="${netdev_args}${fwd_args}"
    fi
    log_message "DEBUG" "Netdev arguments: $netdev_args" "$vm_name" >&2

    # --- Display Arguments ---
    local display_args=()
    log_message "DEBUG" "Raw video_type: '$video_type'" "$vm_name" >&2
    if [[ "$headless" -eq 1 ]]; then
        display_args=("-display" "none" "-nographic")
    else
        if [[ ! "$video_type" =~ ^(virtio-vga|qxl|vga)$ ]]; then
            log_message "WARNING" "Invalid video type '$video_type', defaulting to virtio-vga" "$vm_name" >&2
            video_type="virtio-vga"
        fi
        display_args=("-device" "$video_type" "-display" "gtk")
    fi
    log_message "DEBUG" "Display arguments: ${display_args[*]}" "$vm_name" >&2

    # Output disk, network, and display arguments
    printf '%s\n' "-drive" "$drive_opts" "-device" "$disk_interface,drive=disk0,id=disk0-dev" \
        "-netdev" "$netdev_args" "-device" "${network_model},netdev=net0,mac=${mac_address}" \
        "${display_args[@]}"
    return 0
}

# Function: starts a virtual machine with specified options
# Args: $1: VM name
#       $2+: optional arguments
# Returns: 0 on success, 1 on failure
# Side Effects: creates temporary and lock directories via vm_start_setup
#               writes PID to lock file
#               logs debug, info, warning, success, or error messages to stderr
#               starts QEMU process in the background and disowns it, redirecting QEMU stderr to $VM_DIR/$vm_name/qemu.log
#               removes temporary directory on failure
vm_start() {
    local vm_name="$1" iso_file="" headless=0 extra_args=""

    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required." "" >&2
        return 1
    fi

    if ! validate_vm_identifier "$vm_name" "start"; then
        log_message "ERROR" "Invalid VM name: '$vm_name'." "$vm_name" >&2
        return 1
    fi

    # Parse optional arguments
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --headless)
                headless=1
                shift
                ;;
            --iso)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_message "ERROR" "--iso requires a file path." "$vm_name" >&2
                    return 1
                fi
                iso_file="$2"
                shift 2
                ;;
            --extra-args)
                if [[ $# -lt 2 || -z "$2" ]]; then
                    log_message "ERROR" "--extra-args requires arguments." "$vm_name" >&2
                    return 1
                fi
                # Only allow alphanumeric, underscore, dot, and hyphen characters
                extra_args="${2//[^a-zA-Z0-9_.-]/}"
                shift 2
                ;;
            *)
                log_message "ERROR" "Unknown option for 'start': $1" "$vm_name" >&2
                return 1
                ;;
        esac
    done

    # Validate ISO file
    if [[ -n "$iso_file" && (! -f "$iso_file" || ! -r "$iso_file") ]]; then
        log_message "ERROR" "Invalid or unreadable ISO file: $iso_file" "$vm_name" >&2
        return 1
    fi
    log_message "DEBUG" "ISO file: ${iso_file:-none}" "$vm_name" >&2

    # Check for existing VM instance
    local existing_pid
    existing_pid=$(get_vm_pid "$vm_name") || {
        log_message "ERROR" "Failed to check VM PID." "$vm_name" >&2
        return 1
    }

    if [[ -n "$existing_pid" ]]; then
        log_message "ERROR" "VM '$vm_name' already running (PID: $existing_pid)" "$vm_name" >&2
        return 1
    fi

    # Setup VM lock and temporary directory
    local vm_lock
    vm_lock=$(vm_start_setup "$vm_name") || {
        log_message "ERROR" "Failed to setup VM lock directory." "$vm_name" >&2
        return 1
    }

    # Fetch configuration arguments
    local -a config_args
    mapfile -t config_args < <(vm_start_config "$vm_name") || {
        rm -rf "${vm_lock%/*}"
        log_message "ERROR" "Failed to fetch VM configuration." "$vm_name" >&2
        return 1
    }

    # Debug config_args
    log_message "DEBUG" "config_args: ${config_args[*]}" "$vm_name" >&2

    local video_type="${config_args[-1]}"
    # Sanitize video_type
    video_type=$(echo "$video_type" | tr -d '[:space:]\r\n' | tr -C 'a-zA-Z0-9-' '_')
    log_message "DEBUG" "Sanitized video_type: '$video_type'" "$vm_name" >&2
    unset 'config_args[-1]'

    # Fetch disk, network, and display arguments
    local -a vm_args
    mapfile -t vm_args < <(build_vm_args "$vm_name" "$headless" "$video_type") || {
        rm -rf "${vm_lock%/*}"
        log_message "ERROR" "Failed to build disk, network, or display arguments." "$vm_name" >&2
        return 1
    }

    # Combine all QEMU arguments
    local -a qemu_args=("${config_args[@]}" "${vm_args[@]}")
    if [[ -n "$iso_file" ]]; then
        qemu_args+=("-drive" "file=$(printf '%q' "$iso_file"),format=raw,readonly=on,media=cdrom" "-boot" "order=d,once=d")
        log_message "DEBUG" "Added ISO boot arguments" "$vm_name" >&2
    fi
    if [[ -n "$extra_args" ]]; then
        read -r -a parsed_extra_args <<< "$extra_args"
        qemu_args+=("${parsed_extra_args[@]}")
    fi

    # Start QEMU process with stderr redirected
    local log_file="$VM_DIR/$vm_name/qemu.log"
    log_message "INFO" "Starting VM '$vm_name'" "$vm_name" >&2
    "$QEMU_BIN" "${qemu_args[@]}" >> "$log_file" 2>&1 &
    local pid=$!
    disown "$pid"

    # Verify process started
    sleep 0.5
    if ! kill -0 "$pid" 2> /dev/null; then
        rm -rf "${vm_lock%/*}"
        log_message "ERROR" "Failed to start VM, QEMU process (PID: $pid) terminated prematurely. Check $log_file for details." "$vm_name" >&2
        return 1
    fi

    # Write PID to lock file
    if ! echo "$pid" > "$vm_lock/pid"; then
        log_message "WARNING" "Failed to write PID $pid to lock file." "$vm_name" >&2
    fi

    log_message "SUCCESS" "Started VM '$vm_name' (PID: $pid)" "$vm_name" >&2
    return 0
}

# Function: stops a running VM gracefully or forcefully
# Args: $1: VM name (required, must be a valid identifier)
#       $2: optional --force flag to use SIGKILL instead of SIGTERM
# Returns: 0 on success, non-zero on failure
# Side Effects: sends SIGTERM (or SIGKILL if --force) to the VM process
#               removes temporary directory ($VM_DIR/$vm_name/tmp) on successful stop
#               logs success, info, warning, or error messages to stderr
vm_stop() {
    local vm_name="$1" force=0
    local pid signal timeout_retries=2
    local -i attempt=0

    # Check if VM name is provided
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required." "" >&2
        return 1
    fi

    # Shift to process optional arguments
    shift

    # Parse optional --force flag
    if [[ $# -eq 1 && "$1" == "--force" ]]; then
        force=1
    elif [[ $# -gt 0 ]]; then
        log_message "ERROR" "Unknown arguments for 'stop': $*" "$vm_name" >&2
        return 1
    fi

    # Validate VM name
    if ! validate_vm_identifier "$vm_name" "stop"; then
        log_message "ERROR" "Invalid VM name: '$vm_name'." "$vm_name" >&2
        return 1
    fi

    # Get and validate PID
    pid=$(get_vm_pid "$vm_name")
    if [[ -z "$pid" ]]; then
        log_message "SUCCESS" "VM '$vm_name' is not running." "$vm_name" >&2
        cleanup "DEBUG" "$vm_name" 2> /dev/null
        return 0
    fi
    if ! [[ "$pid" =~ ^[0-9]+$ ]]; then
        log_message "ERROR" "Invalid PID for VM '$vm_name': '$pid'." "$vm_name" >&2
        cleanup "DEBUG" "$vm_name" 2> /dev/null
        return 1
    fi

    log_message "DEBUG" "Found PID $pid for VM '$vm_name'." "$vm_name" >&2

    # Check if PID exists
    if ! kill -0 "$pid" 2> /dev/null; then
        log_message "SUCCESS" "VM '$vm_name' (PID: $pid) is not running or inaccessible." "$vm_name" >&2
        cleanup "DEBUG" "$vm_name" 2> /dev/null
        return 0
    fi

    # Check for zombie process
    if ps -p "$pid" -o stat= | grep -q 'Z'; then
        log_message "SUCCESS" "VM '$vm_name' (PID: $pid) was a zombie process and is considered stopped." "$vm_name" >&2
        cleanup "DEBUG" "$vm_name" 2> /dev/null
        return 0
    fi

    log_message "INFO" "Stopping VM '$vm_name' (PID: $pid)..." "$vm_name" >&2

    # Set signal based on force flag
    signal="TERM"
    [[ "$force" -eq 1 ]] && signal="KILL"

    # Attempt to send signal with retries
    while [[ "$attempt" -lt "$timeout_retries" ]]; do
        log_message "DEBUG" "Sending SIG$signal to PID $pid (attempt $((attempt + 1))/$timeout_retries)." "$vm_name" >&2
        if kill "-$signal" "$pid" 2> /dev/null; then
            break
        elif ! kill -0 "$pid" 2> /dev/null; then
            log_message "SUCCESS" "VM '$vm_name' (PID: $pid) stopped during attempt." "$vm_name" >&2
            cleanup "DEBUG" "$vm_name" 2> /dev/null
            return 0
        fi
        log_message "WARNING" "Failed to send SIG$signal to PID $pid (attempt $((attempt + 1))/$timeout_retries)." "$vm_name" >&2
        ((attempt++))
        sleep 1
    done

    if [[ "$attempt" -ge "$timeout_retries" ]]; then
        log_message "ERROR" "Failed to send SIG$signal to VM process (PID: $pid) after $timeout_retries attempts." "$vm_name" >&2
        return 1
    fi

    # Wait for termination with increased timeout
    local timeout="${VM_STOP_TIMEOUT:-10}" count=0
    log_message "DEBUG" "Waiting for PID $pid to terminate (timeout: $timeout seconds)." "$vm_name" >&2
    while [[ "$count" -lt "$timeout" ]]; do
        # Use || true to prevent set -e from exiting on failure
        if ! kill -0 "$pid" 2> /dev/null || true; then
            log_message "SUCCESS" "Stopped VM '$vm_name' (PID: $pid)." "$vm_name" >&2
            cleanup "DEBUG" "$vm_name" 2> /dev/null
            return 0
        fi
        # Check process state
        local state
        state=$(ps -p "$pid" -o stat= 2> /dev/null || echo "gone")
        if [[ "$state" == "Z" ]]; then
            log_message "SUCCESS" "VM '$vm_name' (PID: $pid) became a zombie process and is considered stopped." "$vm_name" >&2
            cleanup "DEBUG" "$vm_name" 2> /dev/null
            return 0
        fi
        log_message "DEBUG" "PID $pid still running, state: $state, after $count seconds." "$vm_name" >&2
        sleep 1
        ((count++))
    done

    # Handle timeout
    if [[ "$force" -eq 0 ]]; then
        log_message "ERROR" "VM '$vm_name' (PID: $pid) did not stop gracefully within $timeout seconds. Try 'vm stop $vm_name --force'." "$vm_name" >&2
        return 1
    else
        log_message "ERROR" "Failed to force stop VM '$vm_name' (PID: $pid) within $timeout seconds. Manual intervention may be required." "$vm_name" >&2
        return 1
    fi
}

# Function: displays the status and configuration of a VM
# Args:
#   $1: VM name
# Returns: 0 on success, non-zero on failure (e.g., missing config)
# Side Effects: outputs formatted status information to stdout
#               logs warnings for disk info or config retrieval failures
# Notes: retrieves disk size/usage via qemu-img, displays network details
#        sources config file to access VM settings
vm_status() {
    local vm_name="$1" config_file disk_path disk_size disk_usage status_text pid memory_display

    # Validate VM
    validate_vm_identifier "$vm_name" "status" || return 1
    config_file="${VM_DIR:?VM_DIR must be set}/$vm_name/config"
    disk_path="${VM_DIR:?VM_DIR must be set}/$vm_name/disk.qcow2"

    # Check config file
    [[ ! -f "$config_file" ]] && {
        log_message "ERROR" "Config file not found: $config_file" "$vm_name"
        return 1
    }
    [[ ! -r "$config_file" ]] && {
        log_message "ERROR" "Config file not readable: $config_file" "$vm_name"
        return 1
    }

    # Initialize variables
    disk_size="Not found"
    disk_usage="Not found"
    status_text="Stopped"
    pid=""
    local MEMORY="Unknown" CORES="Unknown" MAC_ADDRESS="Unknown" NETWORK_TYPE="user"
    local PORT_FORWARDING_ENABLED=0 PORT_FORWARDS=""

    # Source config
    # shellcheck disable=SC1090
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to source config file: $config_file" "$vm_name"
        return 1
    fi

    # Fix MEMORY if numeric (e.g., "2048" -> "2048M")
    if [[ "$MEMORY" =~ ^[0-9]+$ ]]; then
        log_message "WARNING" "Invalid memory format '$MEMORY' in $config_file, assuming megabytes" "$vm_name"
        MEMORY="${MEMORY}M"
    fi

    # Check status
    if is_vm_running "$vm_name"; then
        status_text="Running"
        pid=$(get_vm_pid "$vm_name" 2> /dev/null || echo "Unknown")
    fi

    # Get disk info
    if [[ -f "$disk_path" && -r "$disk_path" ]]; then
        local disk_info
        if disk_info=$("$QEMU_IMG_BIN" info "$disk_path" 2> /dev/null); then
            # Extract virtual size (prefer human-readable, e.g., "20 GiB")
            disk_size=$(echo "$disk_info" | grep "virtual size:" | sed -E 's/.*virtual size: ([0-9.]+ ?[KMGT]?i?B).*/\1/' || echo "Not found")
            # Extract disk size (e.g., "5 GiB")
            disk_usage=$(echo "$disk_info" | grep "disk size:" | head -n 1 | sed -E 's/.*disk size: ([0-9.]+ ?[KMGT]?i?B).*/\1/' || echo "Not found")

            # If sizes are in bytes (e.g., due to older qemu-img), convert with numfmt
            if [[ "$disk_size" =~ ^[0-9]+$ ]]; then
                disk_size=$(echo "$disk_size" | numfmt --to=iec-i --suffix=B 2> /dev/null || echo "$disk_size")
            fi
            if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
                disk_usage=$(echo "$disk_usage" | numfmt --to=iec-i --suffix=B 2> /dev/null || echo "$disk_usage")
            fi
        else
            log_message "WARNING" "Failed to retrieve disk info for $disk_path" "$vm_name"
        fi
    else
        log_message "INFO" "Disk file not found or not readable: $disk_path" "$vm_name"
    fi

    # Standardize memory
    memory_display=$(standardize_memory "$MEMORY" 2> /dev/null || echo "$MEMORY")

    # Output status
    printf "VM Status: %s\n========================================\n" "$vm_name"
    if [[ "$status_text" == "Running" ]]; then
        printf "State:        %s (PID: %s)\n" "$status_text" "$pid"
    else
        printf "State:        %s\n" "$status_text"
    fi
    printf "Memory:       %-20s\n" "$memory_display"
    printf "CPU Cores:    %-20s\n" "$CORES"
    printf "Disk Size:    %-20s\n" "$disk_size"
    printf "Disk Usage:   %-20s\n" "$disk_usage"
    printf "Network Type: %-20s\n" "$NETWORK_TYPE"
    printf "MAC Address:  %-20s\n" "$MAC_ADDRESS"

    # Display port forwards
    if [[ ("$NETWORK_TYPE" == "user" || "$NETWORK_TYPE" == "nat") && "$PORT_FORWARDING_ENABLED" -eq 1 ]]; then
        printf "\nPort Forwards:\n"
        if [[ -n "$PORT_FORWARDS" ]]; then
            echo "$PORT_FORWARDS" | tr ',' '\n' | while IFS=':' read -r host guest proto; do
                if [[ -n "$host" && -n "$guest" ]]; then
                    printf "  %s -> %s (%s)\n" "$host" "$guest" "${proto:-tcp}"
                else
                    log_message "WARNING" "Invalid port forward format: $host:$guest:$proto" "$vm_name"
                fi
            done
        else
            printf "  None configured\n"
        fi
    fi

    return 0
}

# Function: deletes a VM and its associated files
# Args: $1: VM name
#       $2: force flag (1 to stop and delete running/locked VMs, 0 otherwise)
# Returns: 0 on success, non-zero on failure (e.g., locked VM, running without force)
# Side Effects: removes VM directory ($VM_DIR/$vm_name) and all contents
#               stops running VM if force is enabled
#               prompts for confirmation
#               logs success, info, or error messages
vm_delete() {
    local vm_name="$1"
    local force=0 # Default to 0 (not forced)

    # Check if --force flag is provided
    if [[ $# -gt 1 && "$2" == "--force" ]]; then
        force=1
    fi

    local vm_dir="${VM_DIR:?VM_DIR must be set}/$vm_name"

    # Validate arguments
    [[ -z "$vm_name" ]] && {
        log_message "ERROR" "No VM name provided" ""
        return 1
    }

    # Only check for extra args if there are more than 2 arguments passed
    if [[ $# -gt 2 ]]; then
        log_message "ERROR" "Unexpected arguments for delete: ${*:3}" "$vm_name"
        return 1
    fi

    # Validate VM identifier
    validate_vm_identifier "$vm_name" "delete" || return 1

    # Check lock status
    local locked
    locked=$(get_vm_config "$vm_name" "LOCKED" "0") || {
        log_message "ERROR" "Failed to retrieve lock status for VM: $vm_name" "$vm_name"
        return 1
    }

    if [[ "$locked" -eq 1 && "$force" -ne 1 ]]; then
        log_message "ERROR" "VM '$vm_name' is locked. Use 'qemate vm unlock $vm_name' or --force." "$vm_name"
        return 1
    elif [[ "$locked" -eq 1 ]]; then
        log_message "WARNING" "Deleting locked VM '$vm_name' due to --force flag." "$vm_name"
    fi

    # Check running status
    if is_vm_running "$vm_name"; then
        if [[ "$force" -ne 1 ]]; then
            log_message "ERROR" "VM '$vm_name' is running. Stop it first or use --force." "$vm_name"
            return 1
        else
            log_message "INFO" "VM '$vm_name' is running, attempting force stop before deletion..." "$vm_name"
            if ! vm_stop "$vm_name" --force; then
                log_message "ERROR" "Failed to force stop running VM '$vm_name'. Deletion aborted." "$vm_name"
                return 1
            fi
            sleep 1 # Brief delay to ensure VM stops
        fi
    fi

    # Confirmation prompt
    if [[ "${force:-0}" -eq 0 && -t 0 ]]; then
        read -r -p "Permanently delete VM '$vm_name' and all its data? [y/N]: " confirm
        if [[ ! "$confirm" =~ ^[yY]$ ]]; then
            log_message "INFO" "Deletion of VM '$vm_name' canceled by user." "$vm_name"
            return 0
        fi
    fi

    # Perform deletion
    log_message "INFO" "Deleting VM directory: $vm_dir" "$vm_name"
    if ! rm -rf "$vm_dir"; then
        if [[ -e "$vm_dir" ]]; then
            log_message "ERROR" "Failed to delete VM directory: $vm_dir" "$vm_name"
            return 1
        else
            log_message "WARNING" "rm command failed, but directory $vm_dir seems gone." "$vm_name"
        fi
    fi

    log_message "SUCCESS" "Successfully deleted VM '$vm_name'" "$vm_name"
    return 0
}

# Function: lists all VMs with their status and lock state
# Args: none
# Returns: 0 on success, non-zero on failure (e.g., invalid VM_DIR)
# Side Effects: outputs a formatted table of VM names, statuses, and lock states to stdout
#               logs warnings for invalid VMs and info if no VMs are found
# Notes: skips invalid directories, uses nullglob, sorts VMs alphabetically
vm_list() {
    local vm_dirs=() vm_name status locked locked_display vm_dir
    local header=("NAME" "STATUS" "LOCKED")

    # Validate environment
    [[ -z "${VM_DIR:-}" ]] && {
        log_message "ERROR" "VM_DIR environment variable not set" ""
        return 1
    }
    [[ -z "${TEMP_DIR:-}" ]] && {
        log_message "ERROR" "TEMP_DIR environment variable not set" ""
        return 1
    }
    [[ ! -d "$VM_DIR" ]] && {
        log_message "ERROR" "VM directory does not exist: $VM_DIR" ""
        return 1
    }
    [[ ! -r "$VM_DIR" ]] && {
        log_message "ERROR" "VM directory not readable: $VM_DIR" ""
        return 1
    }

    command -v is_vm_running > /dev/null 2>&1 || {
        log_message "ERROR" "is_vm_running function not found" ""
        return 1
    }

    # Verify log file is writable
    local log_file
    log_file=$(get_log_file "") || {
        log_message "ERROR" "Cannot determine log file location" ""
        return 1
    }
    [[ -w "$log_file" || ! -e "$log_file" ]] || {
        log_message "ERROR" "Log file not writable: $log_file" ""
        return 1
    }

    # Collect valid VM directories
    shopt -s nullglob
    for dir in "${VM_DIR:?VM_DIR must be set}"/*; do
        if [[ -d "$dir" && ! -L "$dir" && -f "$dir/config" && -r "$dir/config" ]]; then
            vm_name=$(basename "$dir")
            if is_valid_name "$vm_name"; then
                vm_dirs+=("$vm_name")
            else
                log_message "WARNING" "Skipping VM directory with invalid name: $vm_name" ""
            fi
        fi
    done
    shopt -u nullglob

    # Sort VMs alphabetically
    if [[ ${#vm_dirs[@]} -gt 0 ]]; then
        readarray -t vm_dirs < <(printf '%s\n' "${vm_dirs[@]}" | sort)
    fi

    # Output table
    if [[ ${#vm_dirs[@]} -eq 0 ]]; then
        log_message "INFO" "No VMs found in $VM_DIR" ""
        printf "No VMs found\n"
        return 0
    fi

    log_message "INFO" "Found ${#vm_dirs[@]} VM(s) in $VM_DIR" ""
    printf "%-24s %-12s %-12s\n" "${header[@]}"
    printf "%s\n" "--------------------------------------------------"
    for vm_name in "${vm_dirs[@]}"; do
        vm_dir="${VM_DIR:?VM_DIR must be set}/$vm_name"
        status="Stopped"
        if is_vm_running "$vm_name"; then
            status="Running"
        fi
        locked=$(get_vm_config "$vm_name" "LOCKED" "0" 2> /dev/null) || {
            log_message "WARNING" "Failed to retrieve lock status for VM: $vm_name" "$vm_name"
            locked="0"
        }
        locked_display=$([[ "$locked" == "1" ]] && echo "Yes" || echo "No")
        printf "%-24.24s %-12s %-12s\n" "$vm_name" "$status" "$locked_display"
    done

    return 0
}

# Function: guides the user through an interactive VM creation process
# Args: none
# Returns: 0 on success or if canceled, non-zero on failure (e.g., invalid input)
# Side Effects: prompts user for VM configuration via stdin
#               calls vm_create with user-provided values on confirmation
#               logs info, warnings, or error messages
# Notes: validates inputs interactively, displays a summary, allows cancellation
vm_wizard() {
    local vm_name disk_size iso_file machine_type cores memory os_type enable_audio confirm std_memory
    local valid_os_types=("linux" "windows")
    local valid_machine_types=("q35" "pc-i440fx" "pc-q35" "virt")
    local max_cores min_disk_size=1 # Minimum 1G

    # Validate environment
    [[ -z "${VM_DIR:-}" ]] && {
        log_message "ERROR" "VM_DIR environment variable not set"
        return 1
    }
    [[ -z "${TEMP_DIR:-}" ]] && {
        log_message "ERROR" "TEMP_DIR environment variable not set"
        return 1
    }
    command -v qemu-img > /dev/null 2>&1 || {
        log_message "ERROR" "qemu-img command not found"
        return 1
    }

    # Determine max cores
    if ! max_cores=$(nproc 2> /dev/null); then
        log_message "WARNING" "Failed to determine CPU core count with nproc. Falling back to 8 cores." ""
        max_cores=8
    fi

    log_message "INFO" "Starting interactive VM creation wizard..."

    # Trap signals for graceful exit
    trap 'log_message "INFO" "VM creation wizard canceled by signal" ""; return 0' INT TERM HUP

    # Get VM Name
    while true; do
        read -r -p "Enter VM name (alphanumeric, -, _, not starting with -): " vm_name
        [[ "$vm_name" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" ""
            return 0
        }
        if ! is_valid_name "$vm_name" || [[ "$vm_name" =~ ^- ]]; then
            log_message "ERROR" "Invalid VM name format: '$vm_name'. Use letters, numbers, hyphens, underscores, not starting with hyphen." ""
        elif [[ -e "${VM_DIR:?VM_DIR must be set}/$vm_name" ]]; then
            log_message "ERROR" "VM '$vm_name' already exists at $VM_DIR/$vm_name." ""
        else
            break
        fi
    done

    # Get OS Type
    while true; do
        read -r -p "OS type [${valid_os_types[*]}] (default: $DEFAULT_OS_TYPE): " os_type
        [[ "$os_type" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        os_type="${os_type:-$DEFAULT_OS_TYPE}"
        os_type="${os_type,,}" # Convert to lowercase
        for valid_type in "${valid_os_types[@]}"; do
            [[ "$os_type" == "$valid_type" ]] && break 2
        done
        log_message "ERROR" "Invalid OS type: '$os_type'. Choose from ${valid_os_types[*]}." "$vm_name"
    done

    # Get Disk Size
    while true; do
        read -r -p "Disk size (e.g., 20G, 50G, min ${min_disk_size}G) (default: $DEFAULT_DISK_SIZE): " disk_size
        [[ "$disk_size" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        disk_size="${disk_size:-$DEFAULT_DISK_SIZE}"
        if [[ "$disk_size" =~ ^[1-9][0-9]*[GM]$ ]]; then
            local size_value=${disk_size%[GM]}
            local size_unit=${disk_size: -1}
            [[ "$size_unit" == "M" ]] && {
                log_message "ERROR" "Disk size '$disk_size' too small. Minimum is ${min_disk_size}G." "$vm_name"
                continue
            }
            [[ "$size_value" -lt "$min_disk_size" ]] && {
                log_message "ERROR" "Disk size '$disk_size' too small. Minimum is ${min_disk_size}G." "$vm_name"
                continue
            }
            disk_size="${size_value}G" # Normalize to G
            break
        else
            log_message "ERROR" "Invalid disk size format: '$disk_size'. Use format like 20G." "$vm_name"
        fi
    done

    # Get ISO File Path
    while true; do
        read -r -p "Installation ISO file path (optional, leave blank for none): " iso_file
        [[ "$iso_file" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        if [[ -z "$iso_file" ]]; then
            break
        elif [[ ! -f "$iso_file" || ! -r "$iso_file" ]]; then
            log_message "WARNING" "ISO file '$iso_file' does not exist or is not readable. Try again or leave blank." "$vm_name"
        elif ! file "$iso_file" | grep -qi "ISO 9660"; then
            log_message "WARNING" "File '$iso_file' does not appear to be a valid ISO. Try again or leave blank." "$vm_name"
        else
            break
        fi
    done

    # Get Machine Type
    while true; do
        read -r -p "QEMU machine type [${valid_machine_types[*]}] (default: $DEFAULT_MACHINE_TYPE): " machine_type
        [[ "$machine_type" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        machine_type="${machine_type:-$DEFAULT_MACHINE_TYPE}"
        for valid_type in "${valid_machine_types[@]}"; do
            [[ "$machine_type" == "$valid_type" ]] && break 2
        done
        log_message "ERROR" "Invalid machine type: '$machine_type'. Choose from ${valid_machine_types[*]}." "$vm_name"
    done

    # Get CPU Cores
    while true; do
        read -r -p "Number of CPU cores (1-$max_cores, default: $DEFAULT_CORES): " cores
        [[ "$cores" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        cores="${cores:-$DEFAULT_CORES}"
        if [[ "$cores" =~ ^[1-9][0-9]*$ && "$cores" -ge 1 && "$cores" -le "$max_cores" ]]; then
            break
        else
            log_message "ERROR" "Invalid number of cores: '$cores'. Must be 1-$max_cores." "$vm_name"
        fi
    done

    # Get Memory
    while true; do
        read -r -p "Memory (e.g., 2048M, 4G, min 512M) (default: $DEFAULT_MEMORY): " memory
        [[ "$memory" == "cancel" ]] && {
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        }
        memory="${memory:-$DEFAULT_MEMORY}"
        if std_memory=$(standardize_memory "$memory" 2> /dev/null); then
            memory="$std_memory"
            local mem_value=${memory%M} # Strip 'M' (standardize_memory ensures 'M')
            if [[ "$mem_value" -ge 512 ]]; then
                break
            else
                log_message "ERROR" "Memory '$memory' ($mem_value MB) too small. Minimum is 512M." "$vm_name"
            fi
        else
            log_message "ERROR" "Invalid memory format: '$memory'. Use format like 2048M or 4G." "$vm_name"
        fi
    done

    # Get Audio
    read -r -p "Enable audio? [y/N]: " enable_audio_input
    [[ "$enable_audio_input" == "cancel" ]] && {
        log_message "INFO" "VM creation canceled by user" "$vm_name"
        return 0
    }
    enable_audio=0
    [[ "$enable_audio_input" =~ ^[yY]$ ]] && enable_audio=1

    # Display Summary
    echo -e "\n--- VM Configuration Summary ---"
    printf "%-15s %s\n" "Name:" "$vm_name"
    printf "%-15s %s\n" "OS Type:" "$os_type"
    printf "%-15s %s\n" "Disk Size:" "$disk_size"
    printf "%-15s %s\n" "ISO File:" "${iso_file:-None}"
    printf "%-15s %s\n" "Machine Type:" "$machine_type"
    printf "%-15s %s\n" "CPU Cores:" "$cores"
    printf "%-15s %s\n" "Memory:" "$memory"
    printf "%-15s %s\n" "Audio:" "$( ((enable_audio)) && echo "Enabled" || echo "Disabled")"
    echo "------------------------------"

    # Confirmation
    while true; do
        read -r -p "Create VM with these settings? [Y/n/cancel]: " confirm
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        elif [[ "$confirm" =~ ^[Cc]ancel$ ]]; then
            log_message "INFO" "VM creation canceled by user" "$vm_name"
            return 0
        elif [[ -z "$confirm" || "$confirm" =~ ^[Yy]$ ]]; then
            break
        else
            log_message "ERROR" "Invalid input: '$confirm'. Enter Y, n, or cancel." "$vm_name"
        fi
    done

    # Build arguments for vm_create
    local create_args=()
    create_args+=("--disk-size" "$disk_size")
    [[ -n "$iso_file" ]] && create_args+=("--iso" "$iso_file")
    create_args+=("--machine" "$machine_type")
    create_args+=("--cores" "$cores")
    create_args+=("--memory" "$memory")
    create_args+=("--os-type" "$os_type")
    ((enable_audio)) && create_args+=("--enable-audio")

    # Call vm_create
    log_message "INFO" "Creating VM '$vm_name' with specified settings" "$vm_name"
    if ! vm_create "$vm_name" "${create_args[@]}"; then
        log_message "ERROR" "Failed to create VM '$vm_name'" "$vm_name"
        return 1
    fi
    log_message "SUCCESS" "VM '$vm_name' created successfully" "$vm_name"
    return 0
}

# Function: edits a VM's configuration file using a text editor
# Args: $1: VM name
#       $2: Force flag (1 to bypass lock check, 0 otherwise)
# Returns: 0 on success, non-zero on failure
# Side Effects: opens config file ($VM_DIR/$vm_name/config) in the specified editor
#               logs messages indicating the result
vm_edit() {
    local vm_name="$1"
    local force="${2:-0}"
    local config_file="${VM_DIR:?VM_DIR must be set}/$vm_name/config"
    local editor="${EDITOR:-nano}"
    local locked

    # Validate input and environment
    [[ -z "$vm_name" ]] && {
        log_message "ERROR" "No VM name provided"
        return 1
    }
    [[ -z "$TEMP_DIR" ]] && {
        log_message "ERROR" "TEMP_DIR environment variable not set"
        return 1
    }

    log_message "DEBUG" "Editing VM: vm_name=$vm_name, config=$config_file, editor=$editor, force=$force" "$vm_name"

    # Validate VM identifier and check prerequisites
    if ! validate_vm_identifier "$vm_name" "edit" 2> /dev/null; then
        log_message "ERROR" "Invalid VM identifier: $vm_name" "$vm_name"
        return 1
    fi

    # Check if config file exists and is writable
    if [[ ! -f "$config_file" ]]; then
        log_message "ERROR" "Config file does not exist: $config_file" "$vm_name"
        return 1
    fi
    if [[ ! -w "$config_file" ]]; then
        log_message "ERROR" "Config file not writable: $config_file" "$vm_name"
        return 1
    fi

    # Check lock status unless force is enabled
    if [[ "$force" -ne 1 ]]; then
        locked=$(get_vm_config "$vm_name" "LOCKED" "0" 2> /dev/null) || {
            log_message "ERROR" "Failed to retrieve lock status for VM: $vm_name" "$vm_name"
            return 1
        }
        if [[ "$locked" == "1" ]]; then
            log_message "ERROR" "VM is locked: $vm_name" "$vm_name"
            return 1
        fi
    fi

    # Warn if VM is running
    if is_vm_running "$vm_name" 2> /dev/null; then
        log_message "WARNING" "VM $vm_name is running, changes may not take effect until restart" "$vm_name"
    fi

    # Verify editor exists
    if ! command -v "$editor" > /dev/null 2>&1; then
        log_message "ERROR" "Editor not found: $editor" "$vm_name"
        return 1
    fi

    # Edit the config file
    log_message "INFO" "Opening config file for VM $vm_name in $editor" "$vm_name"
    if ! "$editor" "$config_file"; then
        log_message "ERROR" "Failed to edit config file: $config_file" "$vm_name"
        return 1
    fi

    log_message "SUCCESS" "Config file updated for VM $vm_name: $config_file" "$vm_name"
    return 0
}

# Function: sets the lock state of a VM
# Args: $1: VM name
#       $2: lock state
# Returns: 0 on success, may exit on failure
# Side Effects: updates the VM's configuration file
#               logs messages indicating the result
vm_set_lock() {
    local vm_name="$1"
    local lock_state="$2"

    # Validate VM identifier
    validate_vm_identifier "$vm_name" "set lock" || return 1

    # Get current lock state, default to "0" if not set
    local current_locked
    current_locked=$(get_vm_config "$vm_name" "LOCKED" "0")

    # Check if already in desired state
    if [[ "$current_locked" == "$lock_state" ]]; then
        local state_text
        if [[ "$lock_state" == "1" ]]; then
            state_text="locked"
        else
            state_text="unlocked"
        fi
        log_message "INFO" "VM '$vm_name' is already $state_text." "$vm_name"
        return 0
    fi

    # Update lock state
    update_vm_config "$vm_name" "LOCKED" "$lock_state" || {
        log_message "ERROR" "Failed to set lock state for VM '$vm_name'." "$vm_name"
        return 1
    }

    # Log success
    local action_text
    if [[ "$lock_state" == "1" ]]; then
        action_text="Locked"
    else
        action_text="Unlocked"
    fi
    log_message "SUCCESS" "$action_text VM '$vm_name'." "$vm_name"
    return 0
}

# Function: locks a VM by setting LOCKED=1
# Args: $1: VM name
# Returns: 0 on success, may exit on failure
vm_lock() {
    vm_set_lock "$1" "1"
}

# Function: unlocks a VM by setting LOCKED=0
# Args: $1: VM name
# Returns: 0 on success, may exit on failure
vm_unlock() {
    vm_set_lock "$1" "0"
}

################################################################################
# === NETWORK MANAGEMENT ===
################################################################################

# Function: checks if the VM's network type supports port forwarding
# Args: $1: VM name
# Returns: 0 if port forwarding is supported, 1 if not
# Side Effects: logs error messages if the network type is invalid
check_port_forwarding_support() {
    local vm_name="$1" network_type

    # Validate inputs early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "port forwarding check"; then
        return 1
    fi

    # Get network type
    network_type=$(get_vm_config "$vm_name" "NETWORK_TYPE" "user")

    # Check if network type supports port forwarding
    if [[ "$network_type" != "user" && "$network_type" != "nat" ]]; then
        log_message "ERROR" "Port forwarding requires 'user' or 'nat' network type, got '$network_type'" "$vm_name"
        return 1
    fi

    return 0
}

# Function: lists all configured port forwards for a VM
# Args: $1: VM name
# Returns: 0 on success, 1 on failure
# Side Effects: outputs a formatted table of host port, guest port, and protocol to stdout
#               logs info messages if no port forwards are configured
net_port_list() {
    local vm_name="$1" port_forwarding_enabled current_forwards

    # Validate inputs early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "port list"; then
        return 1
    fi
    if ! check_port_forwarding_support "$vm_name"; then
        return 1
    fi

    # Get current configuration
    port_forwarding_enabled=$(get_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0")
    current_forwards=$(get_vm_config "$vm_name" "PORT_FORWARDS" "")

    # Check if port forwarding is disabled or no forwards exist
    if [[ "$port_forwarding_enabled" == "0" || -z "$current_forwards" ]]; then
        log_message "INFO" "No port forwards configured for VM '$vm_name'" "$vm_name"
        return 0
    fi

    # Output port forwards in a formatted table
    printf "Port Forwards for %s:\n====================================\n%-10s %-10s %-5s\n------------------------------------\n" "$vm_name" "HOST" "GUEST" "PROTO"
    local valid_entries=false
    IFS=',' read -ra forwards <<< "$current_forwards"
    for entry in "${forwards[@]}"; do
        if [[ "$entry" =~ ^([0-9]+):([0-9]+)(:(tcp|udp))?$ ]]; then
            local host="${BASH_REMATCH[1]}"
            local guest="${BASH_REMATCH[2]}"
            local proto="${BASH_REMATCH[4]:-tcp}" # Default to tcp if not specified
            printf "%-10s %-10s %-5s\n" "$host" "$guest" "$proto"
            valid_entries=true
        else
            log_message "WARNING" "Skipping invalid port forward entry: $entry" "$vm_name"
        fi
    done

    # Log if no valid entries were found
    if ! $valid_entries; then
        log_message "INFO" "No valid port forwards configured for VM '$vm_name'" "$vm_name"
    fi

    return 0
}

# Function: adds a new port forwarding rule to a VM's configuration
# Args: $1: VM name
#       $2+: options for host port (--host), guest port (--guest), and protocol (--proto)
# Returns: 0 on success, 1 on failure
# Side Effects: updates VM configuration to enable port forwarding and add the new rule
#               logs success or error messages
net_port_add() {
    local vm_name="$1" host_port="" guest_port="" proto="tcp" port_forwarding_enabled current_forwards new_forward
    shift

    # Validate VM name early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "port add"; then
        return 1
    fi

    # Parse command-line options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                if [[ -z "$2" ]]; then
                    log_message "ERROR" "Missing value for --host option" "$vm_name"
                    return 1
                fi
                host_port="$2"
                shift 2
                ;;
            --guest)
                if [[ -z "$2" ]]; then
                    log_message "ERROR" "Missing value for --guest option" "$vm_name"
                    return 1
                fi
                guest_port="$2"
                shift 2
                ;;
            --proto)
                if [[ -z "$2" ]]; then
                    log_message "ERROR" "Missing value for --proto option" "$vm_name"
                    return 1
                fi
                proto="${2,,}" # Lowercase protocol
                shift 2
                ;;
            *)
                log_message "ERROR" "Unknown option for 'port add': $1" "$vm_name"
                return 1
                ;;
        esac
    done

    # Validate inputs
    if [[ -z "$host_port" || -z "$guest_port" ]]; then
        log_message "ERROR" "Both --host and --guest ports are required" "$vm_name"
        return 1
    fi
    if ! [[ "$host_port" =~ ^[0-9]+$ && "$host_port" -ge 1 && "$host_port" -le 65535 ]]; then
        log_message "ERROR" "Invalid host port: '$host_port'. Must be between 1 and 65535" "$vm_name"
        return 1
    fi
    if ! [[ "$guest_port" =~ ^[0-9]+$ && "$guest_port" -ge 1 && "$guest_port" -le 65535 ]]; then
        log_message "ERROR" "Invalid guest port: '$guest_port'. Must be between 1 and 65535" "$vm_name"
        return 1
    fi
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        log_message "ERROR" "Invalid protocol: '$proto'. Must be 'tcp' or 'udp'" "$vm_name"
        return 1
    fi
    if ! check_port_forwarding_support "$vm_name"; then
        return 1
    fi
    if is_vm_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' must be stopped to modify port forwards" "$vm_name"
        return 1
    fi

    # Get current configuration
    port_forwarding_enabled=$(get_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0")
    current_forwards=$(get_vm_config "$vm_name" "PORT_FORWARDS" "")

    # Check for duplicate host port
    if [[ -n "$current_forwards" ]]; then
        IFS=',' read -ra forwards <<< "$current_forwards"
        for entry in "${forwards[@]}"; do
            if [[ "$entry" =~ ^([0-9]+):[0-9]+(:(tcp|udp))?$ ]]; then
                local hport="${BASH_REMATCH[1]}"
                if [[ "$hport" == "$host_port" ]]; then
                    log_message "ERROR" "Host port $host_port already forwarded in rule: $entry" "$vm_name"
                    return 1
                fi
            else
                log_message "WARNING" "Skipping invalid port forward entry: $entry" "$vm_name"
            fi
        done
    fi

    # Create new port forward rule
    new_forward="${host_port}:${guest_port}:${proto}"
    if [[ -n "$current_forwards" ]]; then
        current_forwards="${current_forwards},${new_forward}"
    else
        current_forwards="$new_forward"
    fi

    # Update configuration
    if ! update_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "1"; then
        log_message "ERROR" "Failed to enable port forwarding for VM '$vm_name'" "$vm_name"
        return 1
    fi
    if ! update_vm_config "$vm_name" "PORT_FORWARDS" "$current_forwards"; then
        log_message "ERROR" "Failed to update port forwards for VM '$vm_name'" "$vm_name"
        return 1
    fi

    log_message "SUCCESS" "Added port forward $host_port -> $guest_port ($proto) for VM '$vm_name'" "$vm_name"
    return 0
}

# Function: removes a port forwarding rule from a VM's configuration
# Args: $1: VM name
#       $2: port specification (e.g., "port" or "port:proto")
# Returns: 0 on success or if port not found, 1 on failure
# Side Effects: updates VM configuration to remove the specified port forward
#               disables port forwarding if no forwards remain
#               logs success, info, or error messages
net_port_remove() {
    local vm_name="$1" port_spec="$2" port proto current_forwards new_forwards hport hproto

    # Validate inputs early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if [[ -z "$port_spec" ]]; then
        log_message "ERROR" "Port specification (host_port[:protocol]) is required" "$vm_name"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "port remove"; then
        return 1
    fi
    if ! check_port_forwarding_support "$vm_name"; then
        return 1
    fi
    if is_vm_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' must be stopped to modify port forwards" "$vm_name"
        return 1
    fi

    # Parse port specification (host_port[:protocol])
    if [[ "$port_spec" == *":"* ]]; then
        port="${port_spec%%:*}"
        proto="${port_spec#*:}"
    else
        port="$port_spec"
        proto="tcp" # Default to tcp if protocol not specified
    fi
    proto="${proto,,}" # Lowercase protocol

    # Validate port and protocol
    if ! [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 ]]; then
        log_message "ERROR" "Invalid host port: '$port'. Must be between 1 and 65535" "$vm_name"
        return 1
    fi
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        log_message "ERROR" "Invalid protocol: '$proto'. Must be 'tcp' or 'udp'" "$vm_name"
        return 1
    fi

    # Get current configuration
    local port_forwarding_enabled
    port_forwarding_enabled=$(get_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0")
    current_forwards=$(get_vm_config "$vm_name" "PORT_FORWARDS" "")

    # Check if port forwarding is disabled or no forwards exist
    if [[ "$port_forwarding_enabled" == "0" || -z "$current_forwards" ]]; then
        log_message "INFO" "No port forwards configured for VM '$vm_name', nothing to remove" "$vm_name"
        return 0
    fi

    # Process port forwards to remove the specified rule
    local found=false
    new_forwards=""
    IFS=',' read -ra forwards <<< "$current_forwards"
    for entry in "${forwards[@]}"; do
        # Parse entry: host:guest[:proto]
        if [[ "$entry" =~ ^([0-9]+):[0-9]+(:(tcp|udp))?$ ]]; then
            hport="${BASH_REMATCH[1]}"
            hproto="${BASH_REMATCH[3]:-tcp}" # Default to tcp if not specified

            # Skip the entry if it matches the port and protocol to remove
            if [[ "$hport" == "$port" && "$hproto" == "$proto" ]]; then
                found=true
                log_message "DEBUG" "Found port forward to remove: $entry" "$vm_name"
                continue
            fi
        else
            log_message "WARNING" "Skipping invalid port forward entry: $entry" "$vm_name"
        fi
        # Add non-matching entry to new list
        [[ -n "$new_forwards" ]] && new_forwards+=","
        new_forwards+="$entry"
    done

    # If no matching port forward was found, return success
    if ! $found; then
        log_message "INFO" "Port forward for host port $port ($proto) not found for VM '$vm_name'" "$vm_name"
        return 0
    fi

    # Update configuration
    if [[ -z "$new_forwards" ]]; then
        # No forwards remain, disable port forwarding
        log_message "INFO" "No port forwards remain, disabling port forwarding for VM '$vm_name'" "$vm_name"
        if ! update_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0"; then
            log_message "ERROR" "Failed to disable port forwarding for VM '$vm_name'" "$vm_name"
            return 1
        fi
        if ! update_vm_config "$vm_name" "PORT_FORWARDS" ""; then
            log_message "ERROR" "Failed to clear port forwards for VM '$vm_name'" "$vm_name"
            return 1
        fi
    else
        # Update with remaining forwards
        if ! update_vm_config "$vm_name" "PORT_FORWARDS" "$new_forwards"; then
            log_message "ERROR" "Failed to update port forwards for VM '$vm_name'" "$vm_name"
            return 1
        fi
        # Ensure port forwarding is enabled
        if ! update_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "1"; then
            log_message "ERROR" "Failed to enable port forwarding for VM '$vm_name'" "$vm_name"
            return 1
        fi
    fi

    log_message "SUCCESS" "Removed port forward for host port $port ($proto) from VM '$vm_name'" "$vm_name"
    return 0
}

# Function: sets the network type for a VM
# Args: $1: VM name
#       $2: network type
# Returns: 0 on success, 1 on failure
# Side Effects: updates VM configuration with the new network type
#               disables port forwarding and clears port forwards if network type is 'none'
#               logs success, warnings, or error messages
net_type_set() {
    local vm_name="$1" net_type="$2"

    # Validate inputs early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if [[ -z "$net_type" ]]; then
        log_message "ERROR" "Network type is required" "$vm_name"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "net set"; then
        return 1
    fi
    if is_vm_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' must be stopped to change network type" "$vm_name"
        return 1
    fi

    # Validate network type
    local valid_type=false
    for type in "${VALID_NETWORK_TYPES[@]}"; do
        if [[ "$net_type" == "$type" ]]; then
            valid_type=true
            break
        fi
    done
    if ! $valid_type; then
        log_message "ERROR" "Invalid network type: $net_type. Valid types: ${VALID_NETWORK_TYPES[*]}" "$vm_name"
        return 1
    fi

    # Update configuration
    if ! update_vm_config "$vm_name" "NETWORK_TYPE" "$net_type"; then
        log_message "ERROR" "Failed to set network type for '$vm_name'" "$vm_name"
        return 1
    fi

    # Handle 'none' network type
    if [[ "$net_type" == "none" ]]; then
        if ! update_vm_config "$vm_name" "PORT_FORWARDING_ENABLED" "0"; then
            log_message "WARNING" "Failed to disable port forwarding for '$vm_name'" "$vm_name"
        fi
        if ! update_vm_config "$vm_name" "PORT_FORWARDS" ""; then
            log_message "WARNING" "Failed to clear port forwards for '$vm_name'" "$vm_name"
        fi
    fi

    log_message "SUCCESS" "Set network type to '$net_type' for '$vm_name'" "$vm_name"
    return 0
}

# Function: sets or displays the network model for a VM
# Args: $1: VM name
#       $2: network model (e.g., virtio-net-pci, e1000)
# Returns: 0 on success, 1 on failure
# Side Effects: updates VM configuration with the new network model if specified
#               outputs current network model if no model is provided
#               logs success, info, or error messages
net_model_set() {
    local vm_name="$1" net_model="$2" current_model

    # Validate inputs early
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "VM name is required"
        return 1
    fi
    if ! validate_vm_identifier "$vm_name" "net model"; then
        return 1
    fi
    if is_vm_running "$vm_name"; then
        log_message "ERROR" "VM '$vm_name' must be stopped to change network model" "$vm_name"
        return 1
    fi

    # Display current model if no new model provided
    if [[ -z "$net_model" ]]; then
        current_model=$(get_vm_config "$vm_name" "NETWORK_MODEL" "$DEFAULT_NETWORK_MODEL")
        log_message "INFO" "Current network model for '$vm_name': $current_model" "$vm_name"
        echo "$current_model"
        return 0
    fi

    # Validate network model
    local valid_model=false
    for model in "${VALID_NETWORK_MODELS[@]}"; do
        if [[ "$net_model" == "$model" ]]; then
            valid_model=true
            break
        fi
    done
    if ! $valid_model; then
        log_message "ERROR" "Invalid network model: $net_model. Valid models: ${VALID_NETWORK_MODELS[*]}" "$vm_name"
        return 1
    fi

    # Update configuration
    if ! update_vm_config "$vm_name" "NETWORK_MODEL" "$net_model"; then
        log_message "ERROR" "Failed to set network model for '$vm_name'" "$vm_name"
        return 1
    fi
    log_message "SUCCESS" "Set network model to '$net_model' for '$vm_name'" "$vm_name"
    return 0
}

################################################################################
# === COMMAND HANDLERS ===
################################################################################

# Function: displays help text for the specified command or subcommand
# Args: $1: help type
# Returns: 0 on success
# Side Effects: outputs help text to stdout
show_help() {
    local help_type="$1"

    case "$help_type" in
        main)
            cat << MAIN_HELP
┌────────────────────────────────────────────────────────────────────┐
│              Qemate ${version} - QEMU Virtual Machine Manager           │
└────────────────────────────────────────────────────────────────────┘

USAGE:
    qemate COMMAND [SUBCOMMAND] [OPTIONS]

COMMANDS:
    vm        Manage virtual machines
    net       Configure networking
    help      Show help
    version   Show version

EXAMPLES:
    qemate vm create myvm --memory 4G --cores 4

    Run 'qemate COMMAND help' for more details
MAIN_HELP
            ;;
        vm)
            cat << VM_HELP
┌────────────────────────────────────────────────────────────────────┐
│                       Qemate VM Command Help                       │
└────────────────────────────────────────────────────────────────────┘

USAGE:
    qemate vm SUBCOMMAND [OPTIONS]

SUBCOMMANDS:
    create NAME [--memory VALUE] [--cores VALUE] [--disk-size VALUE] 
               [--machine VALUE] [--iso PATH] [--os-type VALUE] [--enable-audio]
    start NAME  [--iso PATH] [--headless] [--extra-args "QEMU_OPTIONS"]
    stop NAME   [--force]
    status NAME
    delete NAME [--force]
    list
    wizard
    edit NAME
    lock NAME
    unlock NAME

EXAMPLES:
    qemate vm create myvm --memory 4096 --cores 4 --enable-audio
    qemate vm start myvm --iso install.iso
VM_HELP
            ;;
        net)
            cat << NET_HELP
┌────────────────────────────────────────────────────────────────────┐
│                       Qemate Net Command Help                      │
└────────────────────────────────────────────────────────────────────┘

USAGE:
    qemate net SUBCOMMAND [OPTIONS]

SUBCOMMANDS:
    port add NAME    [--host PORT] [--guest PORT] [--proto PROTO]
    port remove NAME PORT[:PROTO]
    port list NAME
    set NAME         {nat|user|none}
    model NAME       [{e1000|virtio-net-pci}]

OPTIONS:
    --host PORT       Host port
    --guest PORT      Guest port
    --proto PROTO     Protocol (tcp/udp)

EXAMPLES:
    qemate net port add myvm --host 8080 --guest 80
    qemate net set myvm nat
NET_HELP
            ;;
    esac
}

################################################################################
# === MAPPING OF COMMANDS TO THEIR HANDLERS ===
################################################################################

# SC2034: These are used indirectly via 'local -n' in dispatch_command.
# Shellcheck doesn't detect this usage easily. Suppress or ignore these warnings.
# shellcheck disable=SC2034
declare -A commands=(
    [vm]="handle_vm"
    [net]="handle_net"
    [help]="show_main_help"
    [version]="show_version"
)

# Variable: defines mappings of vm subcommands to their handler functions
# Args: none
# Side Effects: none
# shellcheck disable=SC2034
declare -A vm_commands=(
    [create]="vm_create"
    [start]="vm_start"
    [stop]="vm_stop"
    [status]="vm_status"
    [delete]="vm_delete"
    [list]="vm_list"
    [wizard]="vm_wizard"
    [edit]="vm_edit"
    [lock]="vm_lock"
    [unlock]="vm_unlock"
)

# Variable: defines mappings of network subcommands to their handler functions
# Args: none
# Side Effects: none
# shellcheck disable=SC2034
declare -A net_commands=(
    [port]="handle_net_port"
    [set]="net_type_set"
    [model]="net_model_set"
)

# Variable: defines mappings of port-related subcommands to their handler functions
# Args: none
# Side Effects: none
# shellcheck disable=SC2034
declare -A net_port_commands=(
    [list]="net_port_list"
    [add]="net_port_add"
    [remove]="net_port_remove"
)

# Function: dispatches a command to its corresponding handler function
# Args: $1: name of the dispatch table
#       $2: command or subcommand to execute
#       $3+: additional arguments to pass to the handler
# Returns: 0 on success, non-zero on failure
# Side Effects: logs error messages and displays help text for unknown commands using log_message.
dispatch_command() {
    local dispatch_table="$1" command="$2"

    # Validate inputs
    if [[ -z "$dispatch_table" ]]; then
        log_message "ERROR" "Missing dispatch table name"
        return 1
    fi
    if [[ -z "$command" ]]; then
        log_message "ERROR" "Missing command"
        show_help "${dispatch_table%_commands}"
        return 1
    fi

    shift 2

    # Access dispatch table
    local -n cmd_table="$dispatch_table" 2> /dev/null || {
        log_message "ERROR" "Invalid dispatch table: $dispatch_table"
        return 1
    }

    # Check if command exists in table
    if [[ ! -v cmd_table[$command] ]]; then
        log_message "ERROR" "Unknown command: $command"
        show_help "${dispatch_table%_commands}"
        return 1
    fi

    # Execute handler
    "${cmd_table[$command]}" "$@"
}

# Function: handles VM-related subcommands and validates arguments
# Args: $1: VM subcommand
#       $2+: subcommand arguments
# Returns: 0 on success, non-zero on failure
# Side Effects: displays help text and exits if no subcommand or 'help' is provided
#               logs error messages for unknown subcommands
#               calls dispatch_command to execute the subcommand
handle_vm() {
    # Show help if no arguments or subcommand is 'help'
    if [[ $# -eq 0 || "$1" == "help" ]]; then
        show_help "vm"
        exit 0
    fi

    local subcommand="$1"
    shift

    # Validate subcommand
    local valid_subcommands="create start stop status delete edit lock unlock list wizard"
    local is_valid=0
    for valid_cmd in $valid_subcommands; do
        if [[ "$subcommand" == "$valid_cmd" ]]; then
            is_valid=1
            break
        fi
    done

    if [[ $is_valid -eq 0 ]]; then
        log_message "ERROR" "Unknown VM subcommand: $subcommand" "" >&2
        log_message "INFO" "Valid subcommands: $valid_subcommands" "" >&2
        show_help "vm"
        exit 1
    fi

    # Validate arguments and dispatch subcommand
    case "$subcommand" in
        create)
            "validate_vm_${subcommand}_args" "$@" || exit 1
            dispatch_command "vm_commands" "$subcommand" "$@"
            ;;
        start)
            [[ $# -lt 1 ]] && {
                log_message "ERROR" "Missing VM name for 'vm $subcommand' subcommand" "" >&2
                log_message "INFO" "Usage: qemate vm $subcommand VM_NAME [--iso PATH] [--headless] [--extra-args \"QEMU_OPTIONS\"]" "" >&2
                exit 1
            }
            local vm_name="$1"
            shift
            "validate_vm_start_args" "$vm_name" "$@" || exit 1
            dispatch_command "vm_commands" "$subcommand" "$vm_name" "$@"
            ;;
        stop | status | delete | edit | lock | unlock)
            [[ $# -lt 1 ]] && {
                log_message "ERROR" "Missing VM name for 'vm $subcommand' subcommand" "" >&2
                log_message "INFO" "Usage: qemate vm $subcommand VM_NAME [--force]" "" >&2
                exit 1
            }
            local vm_name="$1"
            shift
            if [[ $# -gt 0 && "$1" == "--force" ]]; then
                validate_vm_name_command "$subcommand" "$vm_name" "--force" || exit 1
                dispatch_command "vm_commands" "$subcommand" "$vm_name" "--force"
            else
                [[ $# -gt 0 ]] && {
                    log_message "ERROR" "Unexpected arguments for '$subcommand': $*" "$vm_name" >&2
                    log_message "INFO" "Usage: qemate vm $subcommand VM_NAME [--force]" "$vm_name" >&2
                    show_help "vm"
                    exit 1
                }
                validate_vm_name_command "$subcommand" "$vm_name" || exit 1
                dispatch_command "vm_commands" "$subcommand" "$vm_name"
            fi
            ;;
        list | wizard)
            [[ $# -gt 0 ]] && {
                log_message "ERROR" "Unexpected arguments for '$subcommand': $*" "" >&2
                log_message "INFO" "Usage: qemate vm $subcommand" "" >&2
                show_help "vm"
                exit 1
            }
            dispatch_command "vm_commands" "$subcommand"
            ;;
    esac
}

# Function: handles network-related subcommands
# Args: $1: network subcommand
#       $2+: subcommand arguments
# Returns: 0 on success, non-zero on failure
# Side Effects: displays help text and exits if no subcommand or 'help' is provided
#               calls dispatch_command to execute the subcommand
handle_net() {
    # Show help if no arguments or subcommand is 'help'
    if [[ $# -eq 0 || "$1" == "help" ]]; then
        show_help "net"
        exit 0
    fi

    local subcommand="$1"

    # Validate subcommand
    local valid_subcommands="port set model" # Add other subcommands as needed
    local is_valid=0
    for valid_cmd in $valid_subcommands; do
        if [[ "$subcommand" == "$valid_cmd" ]]; then
            is_valid=1
            break
        fi
    done

    if [[ $is_valid -eq 0 ]]; then
        log_message "ERROR" "Unknown network subcommand: $subcommand"
        log_message "INFO" "Valid subcommands: $valid_subcommands"
        exit 1
    fi

    # Validate minimum arguments for subcommands requiring a VM name
    if [[ "$subcommand" == "set" || "$subcommand" == "model" ]]; then
        if [[ $# -lt 2 ]]; then
            log_message "ERROR" "Missing VM name for 'net $subcommand' subcommand"
            log_message "INFO" "Usage: qemate net $subcommand VM_NAME [OPTIONS]"
            exit 1
        fi
    fi

    dispatch_command "net_commands" "$subcommand" "${@:2}"
}

# Function: handles port-related subcommands for network configuration
# Args: $1: port subcommand
#       $2+: subcommand arguments
# Returns: 0 on success, non-zero on failure
# Side Effects: displays help text and exits if no subcommand or 'help' is provided
#               dogs error messages for missing VM name or unknown subcommands
#               calls dispatch_command to execute the subcommand
handle_net_port() {
    if [[ $# -eq 0 || "$1" == "help" ]]; then
        show_help "net"
        exit 0
    fi

    local valid_subcommands="add list remove"
    local is_valid=0
    for valid_cmd in $valid_subcommands; do
        if [[ "$1" == "$valid_cmd" ]]; then
            is_valid=1
            break
        fi
    done
    if [[ $is_valid -eq 0 ]]; then
        log_message "ERROR" "Unknown subcommand: $1"
        log_message "INFO" "Valid subcommands: $valid_subcommands"
        exit 1
    fi

    local subcommand="$1"
    shift

    # Ensure VM name is provided
    if [[ $# -eq 0 ]]; then
        log_message "ERROR" "Missing VM name for 'port $subcommand'" ""
        exit 1
    fi

    local vm_name="$1"
    shift

    case "$subcommand" in
        add)
            validate_net_port_add_args "$vm_name" "$@" || exit 1
            ;;
        remove | list)
            validate_net_port_subcommand "$subcommand" "$vm_name" "$@" || exit 1
            ;;
        *)
            log_message "ERROR" "Unknown port subcommand: $subcommand"
            show_help "net"
            exit 1
            ;;
    esac

    dispatch_command "net_port_commands" "$subcommand" "$vm_name" "$@"
}

# Function: validates arguments for the VM create subcommand
# Args: $1: VM name
#       $2+: options
# Returns: 0 on success, non-zero on failure
# Side Effects: logs error messages for invalid VM names or options
validate_vm_create_args() {
    local vm_name="$1"

    # Validate VM name is provided
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "Missing VM name for 'create' command"
        return 1
    fi

    # Validate VM name format
    if ! is_valid_name "$vm_name"; then
        log_message "ERROR" "Invalid VM name: $vm_name" "$vm_name"
        return 1
    fi

    shift

    local valid_options="--memory --cores --disk-size --machine --iso --os-type"

    # Process all options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --memory | --cores | --disk-size)
                # Validate option has a value
                if [[ $# -lt 2 || "${2:0:1}" == "-" ]]; then
                    log_message "ERROR" "Option $1 requires a value" "$vm_name"
                    return 1
                fi
                # Validate numeric value
                if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                    log_message "ERROR" "Option $1 requires a positive integer, got '$2'" "$vm_name"
                    return 1
                fi
                shift 2
                ;;
            --machine | --iso | --os-type)
                # Validate option has a value
                if [[ $# -lt 2 || "${2:0:1}" == "-" ]]; then
                    log_message "ERROR" "Option $1 requires a value" "$vm_name"
                    return 1
                fi
                # Additional validation for --iso
                if [[ "$1" == "--iso" && ! -f "$2" && ! "$2" =~ ^[a-zA-Z0-9]+:// ]]; then
                    log_message "WARNING" "ISO file '$2' does not exist or is not a file" "$vm_name"
                fi
                # Validate --os-type against a known list
                if [[ "$1" == "--os-type" && ! "$2" =~ ^(linux|windows|macos|other)$ ]]; then
                    log_message "WARNING" "Unsupported OS type '$2'. Supported: linux, windows, macos, other" "$vm_name"
                fi
                shift 2
                ;;
            --*)
                # Check for potential typos in option names
                local matched=0
                for opt in $valid_options; do
                    if [[ "$1" == "${opt:0:3}"* ]]; then
                        log_message "ERROR" "Unknown option '$1'. Did you mean '$opt'?" "$vm_name"
                        matched=1
                        break
                    fi
                done
                if [[ $matched -eq 0 ]]; then
                    log_message "ERROR" "Unknown option for 'create': $1" "$vm_name"
                    log_message "INFO" "Valid options: $valid_options" "$vm_name"
                fi
                return 1
                ;;
            *)
                log_message "ERROR" "Unexpected argument for 'create': $1" "$vm_name"
                log_message "INFO" "Usage: qemate vm create NAME [--memory MB] [--cores N] [--disk-size GB] [--machine TYPE] [--iso PATH] [--os-type TYPE]" "$vm_name"
                return 1
                ;;
        esac
    done

    return 0
}

# Function: validates arguments for the VM start subcommand
# Args: $1: VM name
#       $2+: options
# Returns: 0 on success, non-zero on failure
# Side Effects: logs error messages for invalid VM identifiers or options
validate_vm_start_args() {
    local vm_name="$1"

    # Validate VM name is provided
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "Missing VM name for 'start' command"
        return 1
    fi

    shift

    # Validate VM exists
    if ! validate_vm_identifier "$vm_name" "start"; then
        return 1
    fi

    local valid_options="--iso --headless --extra-args"

    # Process all options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iso | --extra-args)
                # Validate option has a value
                if [[ $# -lt 2 || "${2:0:1}" == "-" ]]; then
                    log_message "ERROR" "Option $1 requires a value" "$vm_name"
                    return 1
                fi
                # Validate --iso file or URL
                if [[ "$1" == "--iso" && ! -f "$2" && ! "$2" =~ ^[a-zA-Z0-9]+:// ]]; then
                    log_message "WARNING" "ISO file '$2' does not exist or is not a file" "$vm_name"
                fi
                shift 2
                ;;
            --headless)
                # Flag option without a value
                shift
                ;;
            --*)
                # Check for potential typos in option names
                local matched=0
                for opt in $valid_options; do
                    if [[ "$1" == "${opt:0:3}"* ]]; then
                        log_message "ERROR" "Unknown option '$1'. Did you mean '$opt'?" "$vm_name"
                        matched=1
                        break
                    fi
                done
                if [[ $matched -eq 0 ]]; then
                    log_message "ERROR" "Unknown option for 'start': $1" "$vm_name"
                    log_message "INFO" "Valid options: $valid_options" "$vm_name"
                fi
                return 1
                ;;
            *)
                log_message "ERROR" "Unexpected argument for 'start': $1" "$vm_name"
                log_message "INFO" "Usage: qemate vm start NAME [--iso PATH] [--headless] [--extra-args \"QEMU_OPTIONS\"]" "$vm_name"
                return 1
                ;;
        esac
    done

    return 0
}

# Function: validates arguments for VM subcommands requiring a VM name
# Args: $1: subcommand (e.g., stop, status, delete)
#       $2: VM name
#       $3+: additional arguments (optional, only --force is supported)
# Returns: 0 on success, non-zero on failure (e.g., invalid VM, unsupported option)
# Side Effects: logs error messages for invalid VM identifiers or options
validate_vm_name_command() {
    local command="$1"
    local vm_name="$2"
    shift 2

    # Validate subcommand is provided
    if [[ -z "$command" ]]; then
        log_message "ERROR" "Missing subcommand"
        return 1
    fi

    # Validate VM name is provided
    if [[ -z "$vm_name" ]]; then
        log_message "ERROR" "Missing VM name for '$command' command"
        return 1
    fi

    # Validate VM exists
    if ! validate_vm_identifier "$vm_name" "$command"; then
        return 1
    fi

    local valid_options="--force"

    # Process additional options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                # Flag option without a value
                shift
                ;;
            --*)
                log_message "ERROR" "Unknown option for '$command': $1" "$vm_name"
                log_message "INFO" "Valid option: --force" "$vm_name"
                return 1
                ;;
            *)
                log_message "ERROR" "Unexpected argument for '$command': $1" "$vm_name"
                log_message "INFO" "Usage: qemate vm $command NAME [--force]" "$vm_name"
                return 1
                ;;
        esac
    done

    return 0
}

# Function: validates arguments for the net port add subcommand
# Args: $1: VM name
#       $2+: options
# Returns: 0 on success, non-zero on failure
# Side Effects: logs error messages for invalid VM, ports, or protocol
validate_net_port_add_args() {
    local vm_name="$1"
    shift

    # Validate VM name first
    if ! validate_vm_identifier "$vm_name" "port add"; then
        return 1
    fi

    # Define variables with defaults
    local host_port="" guest_port="" proto="tcp"
    local valid_options="--host --guest --proto"

    # Parse all options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host | --guest | --proto)
                if [[ $# -lt 2 || "${2:0:1}" == "-" ]]; then
                    log_message "ERROR" "Missing value for option: $1" "$vm_name"
                    return 1
                fi

                case "$1" in
                    --host)
                        host_port="$2"
                        ;;
                    --guest)
                        guest_port="$2"
                        ;;
                    --proto)
                        proto="$2"
                        # Normalize protocol to lowercase
                        proto="${proto,,}"
                        ;;
                esac
                shift 2
                ;;
            *)
                # Check if the option resembles a known option with a typo
                local matched=0
                for opt in $valid_options; do
                    if [[ "$1" == "${opt:0:2}"* ]]; then
                        log_message "ERROR" "Unknown option '$1'. Did you mean '$opt'?" "$vm_name"
                        matched=1
                        break
                    fi
                done

                if [[ $matched -eq 0 ]]; then
                    log_message "ERROR" "Unknown option for 'port add': $1" "$vm_name"
                fi
                return 1
                ;;
        esac
    done

    # Validate required parameters
    if [[ -z "$host_port" || -z "$guest_port" ]]; then
        log_message "ERROR" "Both --host and --guest ports are required" "$vm_name"
        return 1
    fi

    # Validate host port
    if ! [[ "$host_port" =~ ^[0-9]+$ ]] || [[ "$host_port" -le 0 ]] || [[ "$host_port" -ge 65536 ]]; then
        log_message "ERROR" "Invalid host port: '$host_port'. Must be a number between 1-65535" "$vm_name"
        return 1
    fi

    # Validate guest port
    if ! [[ "$guest_port" =~ ^[0-9]+$ ]] || [[ "$guest_port" -le 0 ]] || [[ "$guest_port" -ge 65536 ]]; then
        log_message "ERROR" "Invalid guest port: '$guest_port'. Must be a number between 1-65535" "$vm_name"
        return 1
    fi

    # Validate protocol
    if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
        log_message "ERROR" "Invalid protocol: '$proto'. Must be 'tcp' or 'udp'" "$vm_name"
        return 1
    fi

    return 0
}

# Function: validates arguments for net port list or remove subcommands
# Args: $1: subcommand (list or remove)
#       $2: VM name
#       $3+: port specification for remove (e.g., port[:proto])
# Returns: 0 on success, non-zero on failure
# Side Effects: logs error messages for invalid VM, missing port, or invalid port/protocol
validate_net_port_subcommand() {
    local subcommand="$1"

    # Validate subcommand
    local valid_subcommands="list remove"
    if ! [[ "$valid_subcommands" =~ (^| )$subcommand($| ) ]]; then
        log_message "ERROR" "Invalid subcommand: '$subcommand'. Must be 'list' or 'remove'"
        return 1
    fi

    # Check if VM name parameter is provided
    if [[ $# -lt 2 ]]; then
        log_message "ERROR" "Missing VM name."
        return 1
    fi

    local vm_name="$2"
    # Validate VM name
    if ! validate_vm_identifier "$vm_name" "port $subcommand"; then
        return 1
    fi

    # Additional validation only needed for 'remove' subcommand
    if [[ "$subcommand" == "remove" ]]; then
        # Check if port specification is provided
        if [[ $# -lt 3 ]]; then
            log_message "ERROR" "Missing port specification for 'port remove'" "$vm_name"
            return 1
        fi
        port_spec="$3"
        # Parse port and protocol
        if [[ "$port_spec" == *":"* ]]; then
            port="${port_spec%%:*}"
            proto="${port_spec#*:}"
            # Normalize protocol to lowercase
            proto="${proto,,}"
        else
            port="$port_spec"
            proto="tcp" # Default protocol
        fi
        # Validate port number
        if ! [[ "$port" =~ ^[0-9]+$ ]] || [[ "$port" -le 0 ]] || [[ "$port" -ge 65536 ]]; then
            log_message "ERROR" "Invalid port: '$port'. Must be a number between 1-65535" "$vm_name"
            return 1
        fi
        # Validate protocol
        if [[ "$proto" != "tcp" && "$proto" != "udp" ]]; then
            log_message "ERROR" "Invalid protocol: '$proto'. Must be 'tcp' or 'udp'" "$vm_name"
            return 1
        fi
    fi
    return 0
}

# Function: displays the main help text and exits
# Args: none
# Returns: exits with status 0
# Side Effects: outputs main help text to stdout
show_main_help() {
    show_help "main"
    exit 0
}

# Function: displays the version of Qemate and exits
# Args: none
# Returns: exits with status 0
# Side Effects: outputs version string to stdout
show_version() {
    echo "Qemate ${version}"
    exit 0
}

################################################################################
# MAIN ENTRY POINT
################################################################################
main() {
    # Show help if no arguments were provided
    [[ $# -eq 0 ]] && show_main_help

    # Set up the environment and any required configurations
    initialize_system

    # Process the command ($1) and pass remaining arguments to the handler
    # $1 = command name, ${@:2} = all arguments after the command
    dispatch_command "commands" "$1" "${@:2}"
}

# Execute the main function with all script arguments
main "$@"
