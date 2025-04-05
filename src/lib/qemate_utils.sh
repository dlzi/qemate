#!/bin/bash
################################################################################
# Qemate Utilities Module                                                      #
#                                                                              #
# Description: Utility functions for logging, signal handling, system checks,  #
#              and VM management in Qemate.                                    #
# Author: Daniel Zilli                                                         #
# Version: 1.1.0                                                               #
# License: BSD 3-Clause License                                                #
# Date: April 2025                                                             #
################################################################################

# Ensure SCRIPT_DIR is set by the parent script
[[ -z "${SCRIPT_DIR:-}" ]] && {
    echo "Error: SCRIPT_DIR not set." >&2
    exit 1
}

###############################################################################
# CONSTANTS AND INITIALIZATION
###############################################################################

# Directory structure constants
if [[ -z "${VM_DIR:-}" ]]; then
    VM_DIR="${HOME}/QVMs"
    readonly VM_DIR
fi
if [[ -z "${LOG_DIR:-}" ]]; then
    LOG_DIR="${VM_DIR}/logs"
    readonly LOG_DIR
fi

# Create temporary directory with proper error handling
if ! TEMP_DIR=$(mktemp -d -t "qemate.XXXXXXXXXX" 2>/dev/null); then
    echo "Error: Failed to create temp directory." >&2
    exit 1
fi
if [[ "${QEMATE_TEST_MODE:-0}" -eq 1 ]]; then
    export TEMP_DIR
else
    readonly TEMP_DIR
fi

# Define required commands
readonly REQUIRED_COMMANDS=("qemu-system-x86_64" "qemu-img" "pgrep" "mktemp" "find" "sed" "flock")

# Logging setup
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARNING]=2 [ERROR]=3)

# Terminal color definitions
readonly COLOR_INFO='\033[0;34m'     # Blue
readonly COLOR_SUCCESS='\033[0;32m'  # Green
readonly COLOR_WARNING='\033[0;33m'  # Yellow
readonly COLOR_ERROR='\033[0;31m'    # Red
readonly COLOR_RESET='\033[0m'       # Reset

: "${LOG_LEVEL:=INFO}" "${DEBUG:=0}"

# VM cache
declare -A VM_CACHE
VM_CACHE_TIMESTAMP=0

###############################################################################
# DIRECTORY INITIALIZATION
###############################################################################

# Initialize directories with proper permissions
for dir in "$VM_DIR" "$LOG_DIR" "$TEMP_DIR"; do
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "Error: Failed to create directory: $dir." >&2
        exit 1
    fi
    if ! chmod 700 "$dir" 2>/dev/null; then
        echo "Error: Failed to set permissions on $dir." >&2
        exit 1
    fi
done

###############################################################################
# LOGGING FUNCTIONS
###############################################################################

# Format a log message with appropriate color coding
# Arguments:
#   $1 - Log level (INFO, SUCCESS, WARNING, ERROR, DEBUG)
#   $2 - Message to format
# Returns:
#   Formatted message string with color codes
format_message() {
    local level="$1" message="$2"
    case "$level" in
        INFO)    printf "%s[INFO]%s %s" "$COLOR_INFO" "$COLOR_RESET" "$message" ;;
        SUCCESS) printf "%s[SUCCESS]%s %s" "$COLOR_SUCCESS" "$COLOR_RESET" "$message" ;;
        WARNING) printf "%s[WARNING]%s %s" "$COLOR_WARNING" "$COLOR_RESET" "$message" ;;
        ERROR)   printf "%s[ERROR]%s %s" "$COLOR_ERROR" "$COLOR_RESET" "$message" ;;
        DEBUG)   printf "[DEBUG] %s" "$message" ;;
        *)       printf "%s" "$message" ;;
    esac
}

# Log a message to both console and log file
# Arguments:
#   $1 - Log level (INFO, SUCCESS, WARNING, ERROR, DEBUG)
#   $2 - Message to log
# Returns:
#   0 on success, 1 on failure
log_message() {
    local level="$1" message="$2" timestamp
    
    # Get current timestamp with error handling
    if ! timestamp=$(date '+%Y-%m-%d %H:%M:%S'); then
        echo "Error: Failed to get timestamp." >&2
        return 1
    fi
    
    local pid=$$
    
    # Skip if log level is below configured threshold
    [[ "${LOG_LEVELS[$level]:-3}" -lt "${LOG_LEVELS[$LOG_LEVEL]:-1}" ]] && return 0
    
    # Format the message
    local formatted
    if ! formatted=$(format_message "$level" "$message"); then
        return 1
    fi
    
    # Print to console if appropriate for the log level
    if [[ "$level" == "DEBUG" && "$DEBUG" == "1" ]] || [[ "$level" != "DEBUG" ]]; then
        # Strip colors for non-terminal output
        if [[ -t 1 || -t 2 ]]; then
            echo -e "$formatted"
        else
            echo -e "$formatted" | sed 's/\x1b\[[0-9;]*m//g'
        fi
        
        # Append to log file with error handling
        if ! printf "%s [%s] [%s] %s\n" "$timestamp" "$pid" "$level" "$message" >>"$LOG_DIR/qemate.log" 2>/dev/null; then
            echo "Warning: Failed to write to log file: $LOG_DIR/qemate.log" >&2
        fi
    fi
    
    return 0
}

###############################################################################
# SIGNAL HANDLING
###############################################################################

# Set up signal handlers for graceful cleanup
# Arguments: None
# Returns: None
setup_signal_handlers() {
    trap 'signal_handler SIGINT' INT
    trap 'signal_handler SIGTERM' TERM
    trap 'signal_handler SIGHUP' HUP
    trap 'signal_handler EXIT' EXIT
}

# Signal handler function
# Arguments:
#   $1 - Signal name (SIGINT, SIGTERM, SIGHUP, EXIT)
# Returns: None
signal_handler() {
    local signal="${1:-EXIT}"
    local exit_status=$?
    
    if [[ "$signal" == "EXIT" ]]; then
        if [[ "$exit_status" -ne 0 ]]; then
            log_message "WARNING" "Received EXIT with non-zero status. Cleaning up."
            cleanup_function "WARNING"
        else
            cleanup_function ""
        fi
    else
        log_message "INFO" "Received signal: $signal. Cleaning up."
        cleanup_function "INFO"
    fi
}

# Cleanup function to remove temporary files and directories
# Arguments:
#   $1 - Log level to use for cleanup messages (optional)
# Returns: None
cleanup_function() {
    local log_level="$1"
    
    if [[ -n "$log_level" ]]; then
        log_message "$log_level" "Performing cleanup."
    fi
    
    if [[ -d "$TEMP_DIR" ]]; then
        if ! rm -rf "$TEMP_DIR"; then
            log_message "WARNING" "Failed to remove temp directory: $TEMP_DIR."
        fi
    fi
}

###############################################################################
# SYSTEM CHECKS
###############################################################################

# Check if all required commands are available and system is properly configured
# Arguments: None
# Returns:
#   0 if all requirements are met, 1 otherwise
check_system_requirements() {
    local missing=()
    
    # Check for required commands
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_message "ERROR" "Missing required commands: ${missing[*]}."
        return 1
    fi
    
    # Check if home directory is writable
    if [[ ! -w "$HOME" ]]; then
        log_message "ERROR" "Home directory ($HOME) is not writable."
        return 1
    fi
    
    return 0
}

###############################################################################
# VM MANAGEMENT FUNCTIONS
###############################################################################

# Cache VM information to improve performance
# Arguments: None
# Returns:
#   0 on success, 1 on failure
cache_vms() {
    # Always refresh the cache in test mode to ensure we have the latest VM data
    if [[ "${QEMATE_TEST_MODE:-0}" -eq 1 ]]; then
        unset VM_CACHE
        declare -gA VM_CACHE
    else
        local now
        # Get current timestamp with error handling
        if ! now=$(date +%s); then
            log_message "ERROR" "Failed to get timestamp."
            return 1
        fi
        
        # Skip caching if cache is still fresh (less than 30 seconds old)
        if [[ -n "${VM_CACHE_TIMESTAMP:-}" && $((now - VM_CACHE_TIMESTAMP)) -lt 30 ]]; then
            return 0
        fi
        
        # Clear existing cache
        unset VM_CACHE
        declare -gA VM_CACHE
    fi
    
    # Force a directory list refresh by using a direct glob instead of find
    # This is more reliable in test environments
    local vm_dirs=()
    for dir in "$VM_DIR"/*; do
        [[ -d "$dir" ]] && vm_dirs+=("$dir")
    done
    
    # Process each VM directory
    local counter=1
    for vm_path in "${vm_dirs[@]}"; do
        # Skip the logs directory
        [[ "$vm_path" == "$LOG_DIR" ]] && continue
        
        local config_file="$vm_path/config"
        [[ ! -f "$config_file" ]] && continue
        
        local vm_name
        if ! vm_name=$(basename "$vm_path"); then
            continue
        fi
        
        # Add to cache with index as value
        VM_CACHE["$vm_name"]="$counter"
        ((counter++))
    done
    
    # Update cache timestamp
    VM_CACHE_TIMESTAMP="$(date +%s)"
    return 0
}


# Get VM information by name or ID
# Arguments:
#   $1 - Mode ("name_from_id" or "id_from_name")
#   $2 - Value to lookup
# Returns:
#   The requested information on success, 1 on failure
get_vm_info() {
    local mode="$1" value="$2"
    
    # Ensure cache is populated
    [[ -z "${VM_CACHE[*]}" ]] && cache_vms
    
    case "$mode" in
        name_from_id)
            # Check if value is a number (likely an ID)
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                # Try to find VM with this ID
                for vm_name in "${!VM_CACHE[@]}"; do
                    [[ "${VM_CACHE[$vm_name]}" == "$value" ]] && {
                        printf "%s" "$vm_name"
                        return 0
                    }
                done
                
                # Fall back to checking all config files for this ID
                for config in "$VM_DIR"/*/config; do
                    [[ -f "$config" ]] || continue
                    if source "$config" && [[ "${ID:-}" == "$value" ]]; then
                        printf "%s" "$NAME"
                        return 0
                    fi
                done
                
                log_message "ERROR" "No VM found with ID: $value."
                return 1
            else
                # If not a number, treat as a name directly
                if [[ -n "${VM_CACHE[$value]}" ]]; then
                    printf "%s" "$value"
                    return 0
                fi
                
                # Check if VM directory exists
                if [[ -d "$VM_DIR/$value" && -f "$VM_DIR/$value/config" ]]; then
                    printf "%s" "$value"
                    return 0
                fi
                
                log_message "ERROR" "VM not found: $value."
                return 1
            fi
            ;;
            
        id_from_name)
            # Try cache first
            if [[ -n "${VM_CACHE[$value]}" ]]; then
                printf "%s" "${VM_CACHE[$value]}"
                return 0
            fi
            
            # Fall back to checking specific config file
            local config="$VM_DIR/$value/config"
            [[ -f "$config" ]] || {
                log_message "ERROR" "VM not found: $value."
                return 1
            }
            
            if source "$config"; then
                printf "%s" "${ID:-}"
                return 0
            fi
            
            log_message "ERROR" "Failed to source config for $value."
            return 1
            ;;
            
        *)
            log_message "ERROR" "Invalid mode: $mode."
            return 1
            ;;
    esac
}

###############################################################################
# CONFIG FILE MANAGEMENT
###############################################################################

# Safe handling of config file updates
# Arguments:
#   $1 - Path to config file
#   $2 - Callback function to modify the config
# Returns:
#   0 on success, 1 on failure
with_config_file() {
    local config_file="$1" callback="$2" temp_config
    
    # Create temporary file
    if ! temp_config=$(mktemp -t "qemate_config.XXXXXX"); then
        log_message "ERROR" "Failed to create temp config."
        return 1
    fi
    
    # Copy original config to temp file
    if ! cp "$config_file" "$temp_config"; then
        log_message "ERROR" "Failed to copy config to $temp_config."
        rm -f "$temp_config"
        return 1
    fi
    
    # Apply the callback function to modify the temp config
    if ! "$callback" "$temp_config"; then
        rm -f "$temp_config"
        return 1
    fi
    
    # Replace original with modified config
    if ! mv "$temp_config" "$config_file" || ! chmod 600 "$config_file"; then
        log_message "ERROR" "Failed to update config file: $config_file."
        return 1
    fi
    
    return 0
}

###############################################################################
# LOCK MANAGEMENT
###############################################################################

# Acquire a lock to prevent concurrent operations
# Arguments:
#   $1 - Lock directory path
#   $2 - Lock timeout in seconds (optional, default: 3600)
# Returns:
#   0 on success, 1 on failure, 2 if lock is held by another process
acquire_lock() {
    local lock_dir="$1" timeout="${2:-3600}"
    
    # Create lock directory
    if ! mkdir -p "$lock_dir"; then
        log_message "ERROR" "Failed to create lock directory: $lock_dir."
        return 1
    fi
    
    # Try to acquire lock using flock
    (
        if ! flock -n 9; then
            if [[ -f "$lock_dir/pid" && -f "$lock_dir/time" ]]; then
                local pid lock_time
                
                # Read PID and lock time
                if ! read -r pid <"$lock_dir/pid"; then
                    return 1
                fi
                
                if ! read -r lock_time <"$lock_dir/time"; then
                    return 1
                fi
                
                # Check if process still exists
                if kill -0 "$pid" 2>/dev/null; then
                    # Check if lock has expired
                    if [[ $(($(date +%s) - lock_time)) -gt "$timeout" ]]; then
                        log_message "WARNING" "Removing stale lock (PID $pid, > $timeout seconds)."
                    else
                        log_message "ERROR" "Lock held by PID $pid."
                        return 2
                    fi
                else
                    log_message "WARNING" "Removing stale lock for PID $pid (process not running)."
                fi
            else
                log_message "ERROR" "Failed to acquire lock: $lock_dir."
                return 1
            fi
        fi
        
        # Write PID and timestamp to lock files
        if ! echo "$$" >"$lock_dir/pid"; then
            return 1
        fi
        
        if ! date +%s >"$lock_dir/time"; then
            return 1
        fi
        
        return 0
    ) 9>"$lock_dir/lock"
    
    return $?
}

# Release a previously acquired lock
# Arguments:
#   $1 - Lock directory path
# Returns:
#   0 on success, 1 on failure
release_lock() {
    local lock_dir="$1"
    
    if [[ -d "$lock_dir" ]]; then
        if ! rm -rf "$lock_dir"; then
            log_message "WARNING" "Failed to release lock: $lock_dir."
            return 1
        fi
    fi
    
    return 0
}

###############################################################################
# VALIDATION FUNCTIONS
###############################################################################

# Check if a VM name is valid
# Arguments:
#   $1 - Name to validate
# Returns:
#   0 if valid, 1 if invalid
is_valid_name() {
    [[ -n "$1" && "${#1}" -le 64 && "$1" =~ ^[a-zA-Z0-9_-]+$ && "$1" != *".."* ]]
}

# Validate command arguments
# Arguments:
#   $1 - Context (vm, net_port, net_set, net_model)
#   $2 - Subcommand
#   $@ - Command arguments to validate
# Returns:
#   0 if valid, 1 if invalid
validate_arguments() {
    local context="$1" subcommand="$2"
    shift 2
    
    case "$context" in
        vm)
            case "$subcommand" in
                create)
                    [[ $# -lt 1 ]] && {
                        log_message "ERROR" "Missing VM name for 'create'."
                        return 1
                    }
                    is_valid_name "$1" || {
                        log_message "ERROR" "Invalid VM name: $1."
                        return 1
                    }
                    shift
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --memory | --cores | --disk-size | --machine | --iso)
                                [[ -n "${2:-}" ]] || {
                                    log_message "ERROR" "Option $1 requires a value."
                                    return 1
                                }
                                shift 2
                                ;;
                            *)
                                log_message "ERROR" "Unknown option for 'create': $1."
                                return 1
                                ;;
                        esac
                    done
                    ;;
                start)
                    [[ $# -lt 1 ]] && {
                        log_message "ERROR" "Missing NAME_OR_ID for 'start'."
                        return 1
                    }
                    shift
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --iso | --extra-args)
                                [[ -n "${2:-}" ]] || {
                                    log_message "ERROR" "Option $1 requires a value."
                                    return 1
                                }
                                shift 2
                                ;;
                            --headless) 
                                shift 
                                ;;
                            *)
                                log_message "ERROR" "Unknown option for 'start': $1."
                                return 1
                                ;;
                        esac
                    done
                    ;;
                stop | status | delete | edit)
                    [[ $# -lt 1 ]] && {
                        log_message "ERROR" "Missing NAME_OR_ID for '$subcommand'."
                        return 1
                    }
                    # Handle --force option
                    if [[ "$subcommand" == "stop" || "$subcommand" == "delete" ]]; then
                        [[ $# -gt 1 && "$1" == "--force" ]] && shift # If --force is first (unlikely)
                        [[ $# -gt 1 && "$2" == "--force" ]] && shift # If --force is second
                    fi
                    ;;
                list | wizard) 
                    # No validation needed
                    ;;
                *)
                    log_message "ERROR" "Unknown VM subcommand: $subcommand."
                    return 1
                    ;;
            esac
            ;;
        net_port)
            case "$subcommand" in
                add)
                    [[ $# -lt 1 ]] && {
                        log_message "ERROR" "Missing NAME_OR_ID for 'port add'."
                        return 1
                    }
                    shift
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            --host | --guest | --proto)
                                [[ -n "${2:-}" ]] || {
                                    log_message "ERROR" "Option $1 requires a value."
                                    return 1
                                }
                                shift 2
                                ;;
                            *)
                                log_message "ERROR" "Unknown option for 'port add': $1."
                                return 1
                                ;;
                        esac
                    done
                    ;;
                remove | list)
                    [[ $# -lt 1 ]] && {
                        log_message "ERROR" "Missing NAME_OR_ID for 'port $subcommand'."
                        return 1
                    }
                    ;;
                *)
                    log_message "ERROR" "Unknown port subcommand: $subcommand."
                    return 1
                    ;;
            esac
            ;;
        net_set)
            [[ $# -lt 2 ]] && {
                log_message "ERROR" "Missing NAME_OR_ID or type for 'set'."
                return 1
            }
            [[ "$2" =~ ^(nat|user|none)$ ]] || {
                log_message "ERROR" "Invalid network type: $2."
                return 1
            }
            ;;
        net_model)
            [[ $# -lt 1 ]] && {
                log_message "ERROR" "Missing NAME_OR_ID for 'model'."
                return 1
            }
            [[ $# -gt 1 && ! "$2" =~ ^(e1000|virtio-net-pci)$ ]] && {
                log_message "ERROR" "Invalid network model: $2."
                return 1
            }
            ;;
        *)
            log_message "ERROR" "Unknown validation context: $context."
            return 1
            ;;
    esac
    
    return 0
}

# Validate a VM identifier (name or ID)
# Arguments:
#   $1 - VM identifier (name or ID)
#   $2 - Error context for meaningful error messages
# Returns:
#   0 if valid, 1 if invalid
validate_vm_identifier() {
    local identifier="$1" error_context="$2"
    
    # Check if identifier is a numeric ID
    if [[ "$identifier" =~ ^[0-9]+$ ]]; then
        # Try to find VM name from ID
        if ! get_vm_info "name_from_id" "$identifier" >/dev/null; then
            log_message "ERROR" "No VM found with ID: $identifier ($error_context)."
            return 1
        fi
    else
        # Validate name format
        if ! is_valid_name "$identifier"; then
            log_message "ERROR" "Invalid VM_NAME '$identifier' (use a-z, A-Z, 0-9, _, -) ($error_context)."
            return 1
        fi
        
        # Check if VM exists
        if [[ ! -d "$VM_DIR/$identifier" ]]; then
            log_message "ERROR" "VM '$identifier' does not exist ($error_context)."
            return 1
        fi
    fi
    
    return 0
}

###############################################################################
# UTILITY FUNCTIONS
###############################################################################

# Dispatch commands based on command tables
# Arguments:
#   $1 - Command table name
#   $2 - Command to dispatch
#   $@ - Additional arguments for the command
# Returns:
#   Command's return value or 1 on failure
dispatch() {
    local table="$1" cmd="$2"
    shift 2
    
    # Get reference to command table
    local -n cmd_table="$table"
    local help_func="show_${table/_COMMANDS/}_help"
    
    # Check if command exists in table
    if [[ -z "${cmd_table[$cmd]+x}" ]]; then
        log_message "ERROR" "Unknown command in $table: $cmd."
        
        # Show help if available
        if declare -f "$help_func" >/dev/null 2>&1; then
            "$help_func"
        fi
        
        return 1
    fi
    
    # Execute command
    "${cmd_table[$cmd]}" "$@"
}

# Generate a random MAC address in the QEMU/KVM range (52:54:00:XX:XX:XX)
# Arguments: None
# Returns:
#   MAC address on success, 1 on failure
generate_mac() {
    # Use timestamp and RANDOM to generate a unique seed
    local timestamp
    if ! timestamp=$(date +%s); then
        log_message "ERROR" "Failed to get timestamp for MAC generation."
        return 1
    fi
    
    local seed=$((RANDOM + timestamp))
    RANDOM=$seed
    
    # Generate MAC address with QEMU OUI prefix
    local mac
    mac=$(printf "52:54:00:%02x:%02x:%02x" $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
    
    # Validate MAC format
    if [[ ! "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]]; then
        log_message "ERROR" "Failed to generate valid MAC address: $mac"
        return 1
    fi
    
    echo "$mac"
    return 0
}