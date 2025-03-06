#!/bin/bash
################################################################################
#                                   Qemate                                     #
#                        QEMU Virtual Machine Manager                          #
################################################################################
# Description:                                                                 #
# A streamlined command-line tool for managing QEMU virtual machines.          #
#                                                                              #
# Author: Daniel Zilli                                                         #
# License: BSD 3-Clause License                                                #
# Version: 1.0.0                                                               #
#                                                                              #
################################################################################

# Enable strict error handling and safe pipeline execution
set -euo pipefail
IFS=$'\n\t'

#==============================================================================
# 1. INITIALIZATION AND CONFIGURATION
#==============================================================================

readonly SCRIPT_VERSION="1.0.0"

# Ensure XDG paths are properly set with fallbacks
readonly XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
readonly XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
readonly XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"

# Global mutex file for critical operations
readonly GLOBAL_LOCK_FILE="/tmp/qemate.lock"
readonly LOCK_TIMEOUT=30

# Security constants
readonly SECURE_PERMISSIONS=0600
readonly SECURE_DIR_PERMISSIONS=0700

# Declare configuration with secure defaults
declare -A CONFIG=(
	[VM_DIR]="$XDG_DATA_HOME/qemate/vms"
	[LOG_DIR]="$XDG_DATA_HOME/qemate/logs"
	[TEMP_DIR]="$XDG_CACHE_HOME/qemate/temp"
	[CONFIG_DIR]="$XDG_CONFIG_HOME/qemate"
	[DEFAULT_MEMORY]=2048
	[DEFAULT_CORES]=2
	[DEFAULT_DISK_SIZE]="20G"
	[DEFAULT_NETWORK_TYPE]="user"
	[DEFAULT_BRIDGE_NAME]="br0"
	[MAX_VMS]=50
	[MAX_PORTS_PER_VM]=20
	[MAX_SHARES_PER_VM]=10
	[MAX_USB_DEVICES]=10
	[VM_SHUTDOWN_TIMEOUT]=30
	[DEBUG]=0
)

# ANSI color codes for formatted output
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r NC='\033[0m'

# Logging level definitions
declare -r LOG_INFO="INFO"
declare -r LOG_SUCCESS="SUCCESS"
declare -r LOG_WARN="WARN"
declare -r LOG_ERROR="ERROR"
declare -r LOG_DEBUG="DEBUG"

# Global arrays for resource tracking
declare -a TEMP_RESOURCES=()
declare -a ACTIVE_LOCKS=()

# VM configuration storage
declare -A VM_CONFIG

# List of reserved system usernames (for security)
declare -a RESERVED_USERS=(
	"root" "daemon" "bin" "sys" "sync" "games" "man" "lp" "mail" "news"
	"uucp" "proxy" "www-data" "backup" "list" "irc" "gnats" "nobody"
	"systemd" "systemd-network" "systemd-resolve" "messagebus" "syslog"
)

# Error trap for debugging and cleanup
trap 'error_handler ${LINENO} $?' ERR
trap 'cleanup_handler' EXIT
trap 'interrupt_handler' INT TERM

#==============================================================================
# 2. CORE HELPER FUNCTIONS
#==============================================================================

# Enhanced error handler with debug information
error_handler() {
	local line=$1
	local error_code=${2:-1}
	local command="${BASH_COMMAND:-unknown}"
	local func="${FUNCNAME[1]:-main}"

	# Format timestamp (fixed SC2155)
	local timestamp
	timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	# Build error message
	local error_msg="Error in $func() at line $line"
	error_msg+="\nCommand: $command"
	error_msg+="\nExit code: $error_code"

	# Add call stack if debug enabled
	if [[ "${CONFIG[DEBUG]:-0}" == "1" ]]; then
		local i=0
		error_msg+="\n\nCall stack:"
		while caller $i > /dev/null 2>&1; do
			# Fixed SC2207 using read -a
			local frame
			IFS=' ' read -r -a frame <<< "$(caller $i)"
			error_msg+="\n  ${frame[2]}() at line ${frame[0]} in ${frame[1]}"
			((i++))
		done
	fi

	# Log error
	log "$LOG_ERROR" "$error_msg"

	# Write to error log if configured
	if [[ -n "${CONFIG[LOG_DIR]:-}" && -d "${CONFIG[LOG_DIR]}" ]]; then
		echo -e "$timestamp ERROR: $error_msg" >> "${CONFIG[LOG_DIR]}/error.log"
	fi

	cleanup_handler

	return "$error_code"
}

# Cleanup handler for graceful exit
cleanup_handler() {
	local error=$?

	# Release all held locks
	for lock in "${ACTIVE_LOCKS[@]}"; do
		release_lock "$lock" 2> /dev/null || true
	done

	# Remove temporary resources
	for resource in "${TEMP_RESOURCES[@]}"; do
		if [[ -e "$resource" ]]; then
			rm -rf "$resource" 2> /dev/null || true
		fi
	done

	# Reset arrays
	TEMP_RESOURCES=()
	ACTIVE_LOCKS=()

	return "$error"
}

# Interrupt handler for graceful termination
interrupt_handler() {
	log "$LOG_WARN" "Operation interrupted by user"
	cleanup_handler
	exit 130
}

# Enhanced logging function with timestamps and process info
log() {
	local level="$1"
	local message="$2"
	local is_debug="${3:-0}"

	# Format the log message
	local formatted_message
	case "$level" in
		"$LOG_INFO") formatted_message="${GREEN}[INFO]${NC} $message" ;;
		"$LOG_SUCCESS") formatted_message="${GREEN}[SUCCESS]${NC} $message" ;;
		"$LOG_WARN") formatted_message="${YELLOW}[WARN]${NC} $message" ;;
		"$LOG_ERROR") formatted_message="${RED}[ERROR]${NC} $message" ;;
		"$LOG_DEBUG")
			if [[ "${CONFIG[DEBUG]}" == "1" ]]; then
				formatted_message="[DEBUG] $message"
			else
				return 0
			fi
			;;
		*) formatted_message="$message" ;;
	esac

	# For debug logging, include timestamp and PID
	if [[ "$is_debug" -eq 1 || "${CONFIG[DEBUG]}" == "1" ]]; then
		local timestamp
		timestamp=$(date '+%Y-%m-%d %H:%M:%S')
		local pid
		pid=$$
		echo -e "${timestamp} [${pid}] ${formatted_message}"
	else
		# For regular user messages, just show the formatted message
		echo -e "${formatted_message}"
	fi

	# Log to file if enabled
	if [[ -n "${CONFIG[LOG_DIR]:-}" && -d "${CONFIG[LOG_DIR]}" ]]; then
		local timestamp
		timestamp=$(date '+%Y-%m-%d %H:%M:%S')
		local pid
		pid=$$
		echo "${timestamp} [${pid}] ${level}: ${message}" >> "${CONFIG[LOG_DIR]}/qemate.log"
	fi
}

# Check if script is running as root
check_root() {
	if [[ $EUID -ne 0 ]]; then
		log "$LOG_ERROR" "This operation requires root privileges"
		return 1
	fi
	return 0
}

# Secure random string generator
generate_secure_string() {
	local length=${1:-32}
	if command -v openssl > /dev/null 2>&1; then
		openssl rand -hex $((length / 2))
	else
		head -c "$length" /dev/urandom | xxd -p
	fi
}

# Secure path validation
validate_path() {
	local path=$1
	local allow_symlinks=${2:-0}

	# Convert to absolute path
	local abs_path
	abs_path=$(readlink -f "$path" 2> /dev/null) || return 1

	# Check if path exists
	if [[ ! -e "$abs_path" ]]; then
		return 1
	fi

	# Check for symlinks if not allowed
	if [[ "$allow_symlinks" -eq 0 && -L "$path" ]]; then
		return 1
	fi

	# Check for suspicious paths
	if [[ "$abs_path" =~ ^(/dev|/proc|/sys|/run) ]]; then
		return 1
	fi

	echo "$abs_path"
	return 0
}

# Helper function to validate IP addresses
validate_ip() {
	local ip=$1

	# Check if the IP matches the basic pattern: three dots, numbers between them
	if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
		return 1
	fi

	# Use IFS and read -ra for safer array splitting, with -r to prevent backslash interpretation
	local IFS='.'
	local -a octets
	read -ra octets <<< "$ip"

	# Validate each octet is between 0 and 255
	for octet in "${octets[@]}"; do
		if ((octet < 0 || octet > 255)); then
			return 1
		fi
	done

	return 0
}

# Modified validate_vm_name function that doesn't echo output
validate_vm_name() {
	local name=$1
	local max_length=${2:-64}
	# shellcheck disable=SC2034
	local -n result=${3:-_unused_} # Use reference parameter if provided

	# First do basic format validation
	if [[ ! "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
		log "$LOG_ERROR" "Invalid VM name format. Use alphanumeric characters, underscore, or hyphen"
		return 1
	fi

	# Check length
	if ((${#name} > max_length)); then
		log "$LOG_ERROR" "VM name too long (max $max_length characters)"
		return 1
	fi

	# Additional sanitization - strip any potentially dangerous characters
	name=$(echo "$name" | tr -cd '[:alnum:]_-')

	# Check against reserved names
	local name_lower
	name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
	for reserved in "${RESERVED_USERS[@]}"; do
		if [[ "$name_lower" == "$reserved" ]]; then
			log "$LOG_ERROR" "VM name '$name' is reserved and cannot be used"
			return 1
		fi
	done

	# Set the result in the reference variable if provided
	# shellcheck disable=SC2034
	result="$name"
	return 0
}

# Validate port number
validate_port() {
	local port=$1
	local is_host_port=${2:-0} # Flag to indicate if this is the host-side port

	# Check if port is a valid number
	if ! [[ "$port" =~ ^[0-9]+$ ]]; then
		log "$LOG_ERROR" "Invalid port number: $port"
		return 1
	fi

	# Check port range (valid ports are 1-65535)
	if ((port < 1 || port > 65535)); then
		log "$LOG_ERROR" "Port number out of range (1-65535): $port"
		return 1
	fi

	# For host ports, check if port is in use
	if [[ "$is_host_port" -eq 1 ]]; then
		if command -v ss > /dev/null 2>&1; then
			if ss -tuln | grep -q ":$port "; then
				log "$LOG_WARN" "Port $port is already in use on the host"
				return 1
			fi
		elif command -v netstat > /dev/null 2>&1; then
			if netstat -tuln | grep -q ":$port "; then
				log "$LOG_WARN" "Port $port is already in use on the host"
				return 1
			fi
		fi
	fi

	return 0
}

# Configuration validation for SMB shares
validate_smb_config() {
	local name=$1
	local config_file="${CONFIG[VM_DIR]}/${name}/config"
	local error=0

	# Check if Samba is installed
	if ! command -v smbd &> /dev/null; then
		log "$LOG_ERROR" "Samba server (smbd) not found. Please install samba package"
		error=1
	fi

	# Verify Samba service is running
	if ! systemctl is-active --quiet smbd; then
		log "$LOG_ERROR" "Samba service (smbd) is not running"
		error=1
	fi

	# Check SMB configuration exists
	if [[ ! -f "/etc/samba/smb.conf" ]]; then
		log "$LOG_ERROR" "Samba configuration file not found"
		error=1
	fi

	return $error
}

# Verify if a VM exists by checking its configuration file
check_vm_exists() {
	local name=$1
	local config_file="${CONFIG[VM_DIR]}/${name}/config"
	local validated_name

	# Validate input
	if [[ -z "$name" ]]; then
		log "$LOG_ERROR" "VM name cannot be empty"
		return 1
	fi

	# Validate VM name
	if ! validate_vm_name "$name" 64 validated_name; then
		return 1
	fi

	# Check if VM directory exists
	if [[ ! -d "${CONFIG[VM_DIR]}/${validated_name}" ]]; then
		log "$LOG_ERROR" "VM '$validated_name' not found"
		return 1
	fi

	# Check config file exists and is readable
	if [[ ! -f "$config_file" ]] || [[ ! -r "$config_file" ]]; then
		log "$LOG_ERROR" "VM '$validated_name' configuration not accessible"
		return 1
	fi

	# Validate config file has required fields
	if ! grep -q "^NAME=" "$config_file"; then
		log "$LOG_ERROR" "VM '$validated_name' has invalid configuration"
		return 1
	fi

	return 0
}

# Check if a VM is currently running
check_vm_running() {
	local name=$1
	local pattern="guest=${name},process=qemu-${name}"

	# Validate input
	if [[ -z "$name" ]]; then
		log "$LOG_ERROR" "VM name cannot be empty"
		return 1
	fi

	# First verify VM exists
	if ! check_vm_exists "$name"; then
		return 1
	fi

	# Check for running process with exact name pattern
	if pgrep -f "$pattern" > /dev/null 2>&1; then
		return 0
	fi

	return 1
}

# Secure temporary file creation
create_temp_file() {
	local prefix=${1:-"qemate"}
	local temp_dir="${CONFIG[TEMP_DIR]}"

	# Ensure temp directory exists with proper permissions
	if [[ ! -d "$temp_dir" ]]; then
		mkdir -p "$temp_dir"
		chmod "$SECURE_DIR_PERMISSIONS" "$temp_dir"
	fi

	# Create temporary file with secure permissions
	local temp_file
	temp_file=$(mktemp "${temp_dir}/${prefix}.XXXXXXXXXX")
	chmod "$SECURE_PERMISSIONS" "$temp_file"

	# Track for cleanup
	TEMP_RESOURCES+=("$temp_file")
	echo "$temp_file"
}

# Secure file locking mechanism
acquire_lock() {
	local lock_file=$1
	local timeout=${2:-$LOCK_TIMEOUT}
	local start_time=$SECONDS
	local pid=$$

	# First, ensure the parent directory exists with correct permissions
	local lock_dir
	lock_dir=$(dirname "$lock_file")
	if [[ ! -d "$lock_dir" ]]; then
		mkdir -p "$lock_dir" 2> /dev/null || {
			log "$LOG_ERROR" "Cannot create lock directory: $lock_dir"
			return 1
		}
	fi

	# Add debug logging
	log "$LOG_DEBUG" "Attempting to acquire lock: $lock_file"

	while true; do
		if mkdir "$lock_file" 2> /dev/null; then
			echo "$pid" > "$lock_file/pid" || {
				rmdir "$lock_file" 2> /dev/null
				log "$LOG_ERROR" "Cannot write PID file"
				return 1
			}
			ACTIVE_LOCKS+=("$lock_file")
			log "$LOG_DEBUG" "Lock acquired successfully"
			return 0
		fi

		# Check for stale lock
		if [[ -f "$lock_file/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$lock_file/pid" 2> /dev/null)
			if ! kill -0 "$lock_pid" 2> /dev/null; then
				log "$LOG_DEBUG" "Removing stale lock from PID $lock_pid"
				rm -rf "$lock_file"
				continue
			fi
		fi

		# Check timeout
		if ((SECONDS - start_time > timeout)); then
			log "$LOG_ERROR" "Lock acquisition timed out after $timeout seconds"
			return 1
		fi

		sleep 0.1
	done
}

# Release acquired lock
release_lock() {
	local lock_file=$1

	if [[ -d "$lock_file" && -f "$lock_file/pid" ]]; then
		local pid
		pid=$(cat "$lock_file/pid" 2> /dev/null)
		if [[ "$pid" == "$$" ]]; then
			rm -rf "$lock_file"
			ACTIVE_LOCKS=("${ACTIVE_LOCKS[@]/$lock_file/}")
			return 0
		fi
	fi
	return 1
}

# Modified read_vm_config function
read_vm_config() {
	local name=$1
	local config_file="${CONFIG[VM_DIR]}/${name}/config"
	local error=0
	local validated_name

	# Validate input using new method
	if ! validate_vm_name "$name" 64 validated_name; then
		return 1
	fi

	# Check config file exists and is secure
	if [[ ! -f "$config_file" ]]; then
		log "$LOG_ERROR" "VM configuration not found: $validated_name"
		return 1
	fi

	# Validate file permissions
	local file_perms
	file_perms=$(stat -c "%a" "$config_file")
	if [[ "$file_perms" != "600" ]]; then
		log "$LOG_ERROR" "Insecure permissions on config file: $config_file"
		return 1
	fi

	# Clear previous configuration
	declare -g -A VM_CONFIG=()

	# Read and validate configuration
	while IFS='=' read -r key value; do
		# Skip comments and empty lines
		[[ "$key" =~ ^[[:space:]]*# ]] && continue
		[[ -z "$key" ]] && continue

		# Clean input
		key=$(echo "$key" | tr -d '[:space:]')
		value=$(echo "$value" | tr -d '"' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

		# Skip empty keys
		[[ -z "$key" ]] && continue

		# Store in VM_CONFIG
		VM_CONFIG[$key]=$value

	done < "$config_file"

	# Validate required fields
	local -a required_fields=(NAME MEMORY CORES MACHINE_TYPE)
	for field in "${required_fields[@]}"; do
		if [[ -z "${VM_CONFIG[$field]:-}" ]]; then
			log "$LOG_ERROR" "Missing required field: $field"
			error=1
		fi
	done

	return $error
}

#==============================================================================
# 3. PARSE FUNCTIONS
#==============================================================================

parse_vm_command() {
	local subcommand=$1
	shift

	case "$subcommand" in
		create)
			local name="" memory="${CONFIG[DEFAULT_MEMORY]}" cores="${CONFIG[DEFAULT_CORES]}" disk_size="${CONFIG[DEFAULT_DISK_SIZE]}"
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
					--disk)
						disk_size="$2"
						shift 2
						;;
					*)
						if [[ -z "$name" ]]; then
							name="$1"
						fi
						shift
						;;
				esac
			done
			create_vm "$name" "$memory" "$cores" "$disk_size"
			;;
		start)
			local name_or_id="" iso="" headless=0
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--iso)
						if [[ -n "$2" ]]; then
							iso="$2"
							shift 2
						else
							log "$LOG_ERROR" "Missing ISO file path"
							return 1
						fi
						;;
					--headless)
						headless=1
						shift
						;;
					*)
						if [[ -z "$name_or_id" ]]; then
							name_or_id="$1"
							shift
						else
							shift
						fi
						;;
				esac
			done
			if [[ -z "$name_or_id" ]]; then
				log "$LOG_ERROR" "VM name or ID is required"
				echo "Usage: qemate vm start NAME|ID [--iso PATH] [--headless]"
				return 1
			fi
			start_vm "$name_or_id" "$iso" "$headless"
			;;
		stop)
			local name_or_id="" force=0
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--force)
						force=1
						shift
						;;
					*)
						if [[ -z "$name_or_id" ]]; then
							name_or_id="$1"
							shift
						else
							shift
						fi
						;;
				esac
			done
			if [[ -z "$name_or_id" ]]; then
				log "$LOG_ERROR" "VM name or ID is required"
				echo "Usage: qemate vm stop NAME|ID [--force]"
				return 1
			fi
			stop_vm "$name_or_id" "$force"
			;;
		remove)
			local name_or_id="" force=0
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--force)
						force=1
						shift
						;;
					*)
						name_or_id="$1"
						shift
						;;
				esac
			done

			if [[ -z "$name_or_id" ]]; then
				log "$LOG_ERROR" "VM name or ID is required"
				echo "Usage: qemate vm remove NAME|ID [--force]"
				return 1
			fi

			# Convert ID to name if necessary
			if [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
				local vm_name
				if ! vm_name=$(get_vm_info "name_from_id" "$name_or_id") || [ -z "$vm_name" ]; then
					log    "$LOG_ERROR" "No VM found with ID: $name_or_id"
					return    1
				fi
				name_or_id="$vm_name"
			fi

			delete_vm "$name_or_id" "$force"
			;;
		list)
			list_vms
			;;
		status)
			local name_or_id=${1:-""}

			if [[ -z "$name_or_id" ]]; then
				log "$LOG_ERROR" "VM name or ID is required"
				echo "Usage: qemate vm status NAME|ID"
				return 1
			fi

			# Convert ID to name if necessary
			if [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
				local vm_name
				if ! vm_name=$(get_vm_info "name_from_id" "$name_or_id") || [ -z "$vm_name" ]; then
					log    "$LOG_ERROR" "No VM found with ID: $name_or_id"
					return    1
				fi
				name_or_id="$vm_name"
			fi

			show_vm_status "$name_or_id"
			;;
		*)
			log "$LOG_ERROR" "Unknown vm command: $subcommand"
			echo "Valid commands: create, start, stop, remove, list, status"
			return 1
			;;
	esac
}

parse_net_command() {
	local subcommand=$1
	shift

	log "$LOG_DEBUG" "parse_net_command called with subcommand: $subcommand, args: $*"

	case "$subcommand" in
		set)
			# This part handles network type setting
			local name="" type=""
			log "$LOG_DEBUG" "Processing network set command"
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--type)
						if [[ -n "$2" ]]; then
							type="$2"
							log "$LOG_DEBUG" "Found network type: $type"
							shift 2
						else
							log "$LOG_ERROR" "Missing network type"
							return 1
						fi
						;;
					*)
						if [[ -z "$name" ]]; then
							name="$1"
							log "$LOG_DEBUG" "Found VM name: $name"
						fi
						shift
						;;
				esac
			done

			if [[ -z "$name" ]]; then
				log "$LOG_ERROR" "VM name is required"
				echo "Usage: qemate net set NAME --type TYPE"
				return 1
			fi

			if [[ -z "$type" ]]; then
				log "$LOG_ERROR" "Network type is required"
				echo "Usage: qemate net set NAME --type TYPE"
				return 1
			fi

			log "$LOG_DEBUG" "Calling setup_network with: $name $type"
			setup_network "$name" "$type"
			;;

		port)
			local subcmd=$1
			shift
			log "$LOG_DEBUG" "Processing port subcommand: $subcmd"

			case "$subcmd" in
				add)
					local name="" host="" guest="" proto="tcp"
					log "$LOG_DEBUG" "Processing port add command"

					# Get VM name first
					if [[ $# -lt 1 ]]; then
						log "$LOG_ERROR" "VM name is required"
						echo "Usage: qemate net port add NAME --host PORT --guest PORT [--proto PROTO]"
						return 1
					fi
					name="$1"
					shift

					# Validate VM exists and check running state
					if ! check_vm_exists "$name"; then
						return 1
					fi

					if check_vm_running "$name"; then
						log "$LOG_ERROR" "Cannot modify port forwards while VM is running"
						log "$LOG_INFO" "Please stop the VM first"
						return 1
					fi

					# Process remaining arguments
					while [[ $# -gt 0 ]]; do
						case "$1" in
							--host)
								if [[ -n "$2" ]]; then
									host="$2"
									log "$LOG_DEBUG" "Found host port: $host"
									if ! validate_port "$host" 1; then
										return 1
									fi
									shift 2
								else
									log "$LOG_ERROR" "Missing host port"
									return 1
								fi
								;;
							--guest)
								if [[ -n "$2" ]]; then
									guest="$2"
									log "$LOG_DEBUG" "Found guest port: $guest"
									if ! validate_port "$guest" 0; then
										return 1
									fi
									shift 2
								else
									log "$LOG_ERROR" "Missing guest port"
									return 1
								fi
								;;
							--proto)
								if [[ -n "$2" ]]; then
									proto="$2"
									log "$LOG_DEBUG" "Found protocol: $proto"
									if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
										log "$LOG_ERROR" "Invalid protocol. Use tcp or udp"
										return 1
									fi
									shift 2
								else
									log "$LOG_ERROR" "Missing protocol"
									return 1
								fi
								;;
							*)
								log "$LOG_ERROR" "Unknown option: $1"
								echo "Usage: qemate net port add NAME --host PORT --guest PORT [--proto PROTO]"
								return 1
								;;
						esac
					done

					if [[ -z "$host" || -z "$guest" ]]; then
						log "$LOG_ERROR" "Missing required parameters"
						log "$LOG_DEBUG" "name=$name host=$host guest=$guest proto=$proto"
						echo "Usage: qemate net port add NAME --host PORT --guest PORT [--proto PROTO]"
						return 1
					fi

					log "$LOG_DEBUG" "Calling setup_network add-port with args: $name add-port $host:$guest:$proto"
					setup_network "$name" "add-port" "$host:$guest:$proto"
					return $?
					;;

				remove)
					local name="" port="" proto="tcp"
					log "$LOG_DEBUG" "Processing port remove command"

					# Get VM name first
					if [[ $# -lt 1 ]]; then
						log "$LOG_ERROR" "VM name is required"
						echo "Usage: qemate net port remove NAME --port PORT [--proto PROTO]"
						return 1
					fi
					name="$1"
					shift

					# Validate VM exists and check running state
					if ! check_vm_exists "$name"; then
						return 1
					fi

					if check_vm_running "$name"; then
						log "$LOG_ERROR" "Cannot modify port forwards while VM is running"
						log "$LOG_INFO" "Please stop the VM first"
						return 1
					fi

					# Process remaining arguments
					while [[ $# -gt 0 ]]; do
						case "$1" in
							--port)
								if [[ -n "$2" ]]; then
									port="$2"
									log "$LOG_DEBUG" "Found port: $port"
									if ! validate_port "$port" 1; then
										return 1
									fi
									shift 2
								else
									log "$LOG_ERROR" "Missing port number"
									return 1
								fi
								;;
							--proto)
								if [[ -n "$2" ]]; then
									proto="$2"
									log "$LOG_DEBUG" "Found protocol: $proto"
									if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
										log "$LOG_ERROR" "Invalid protocol. Use tcp or udp"
										return 1
									fi
									shift 2
								else
									log "$LOG_ERROR" "Missing protocol"
									return 1
								fi
								;;
							*)
								log "$LOG_ERROR" "Unknown option: $1"
								echo "Usage: qemate net port remove NAME --port PORT [--proto PROTO]"
								return 1
								;;
						esac
					done

					if [[ -z "$port" ]]; then
						log "$LOG_ERROR" "Missing required --port parameter"
						echo "Usage: qemate net port remove NAME --port PORT [--proto PROTO]"
						return 1
					fi

					log "$LOG_DEBUG" "Calling setup_network remove-port with args: $name remove-port $port:$proto"
					setup_network "$name" "remove-port" "$port:$proto"
					return $?
					;;

				list)
					if [[ $# -lt 1 ]]; then
						log "$LOG_ERROR" "VM name is required"
						echo "Usage: qemate net port list NAME"
						return 1
					fi
					local name="$1"
					log "$LOG_DEBUG" "Listing ports for VM: $name"
					list_port_forwards "$name"
					return $?
					;;

				*)
					log "$LOG_ERROR" "Unknown port subcommand: $subcmd"
					echo "Valid subcommands: add, remove, list"
					return 1
					;;
			esac
			;;

		*)
			log "$LOG_ERROR" "Unknown network subcommand: $subcommand"
			echo "Valid subcommands: set, port"
			return 1
			;;
	esac
}

parse_shared_command() {
	local subcommand=${1:-""}
	shift || true

	case "$subcommand" in
		add)
			local name path share_name type readonly=0 uid=0 gid=0
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--path)
						path="$2"
						shift 2
						;;
					--name)
						share_name="$2"
						shift 2
						;;
					--type)
						type="$2"
						shift 2
						;;
					--readonly)
						readonly=1
						shift
						;;
					--uid)
						uid="$2"
						shift 2
						;;
					--gid)
						gid="$2"
						shift 2
						;;
					*)
						name="$1"
						shift
						;;
				esac
			done

			if [[ -z "$name" || -z "$path" || -z "$share_name" || -z "$type" ]]; then
				log "$LOG_ERROR" "Missing required parameters"
				echo "Usage: qemate shared add VM_NAME --path PATH --name SHARE_NAME --type TYPE [--readonly] [--uid UID] [--gid GID]"
				return 1
			fi

			add_shared_folder "$name" "$path" "$share_name" "$type" "$readonly" "$uid" "$gid"
			;;
		remove)
			local name share_name
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--name)
						share_name="$2"
						shift 2
						;;
					*)
						name="$1"
						shift
						;;
				esac
			done

			remove_shared_folder "$name" "$share_name"
			;;
		list)
			if [[ $# -lt 1 ]]; then
				log "$LOG_ERROR" "VM name required"
				echo "Usage: qemate shared list VM_NAME"
				return 1
			fi
			list_shared_folders "$1"
			;;
		*)
			log "$LOG_ERROR" "Unknown subcommand: $subcommand"
			echo "Usage: qemate shared [add|remove|list] [options]"
			return 1
			;;
	esac
}

parse_usb_command() {
	local subcommand=${1:-""}
	shift || true

	case "$subcommand" in
		add)
			local name num temp=0
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--num)
						num="$2"
						shift 2
						;;
					--temp)
						temp=1
						shift
						;;
					*)
						name="$1"
						shift
						;;
				esac
			done
			add_usb_device "$name" "$num" "$temp"
			;;
		remove)
			local name num
			while [[ $# -gt 0 ]]; do
				case "$1" in
					--num)
						num="$2"
						shift 2
						;;
					*)
						name="$1"
						shift
						;;
				esac
			done
			remove_usb_device "$name" "$num"
			;;
		list)
			list_usb_devices
			;;
		query)
			local id=${1:-""}

			if [[ -z "$id" ]]; then
				log "$LOG_ERROR" "USB ID is required"
				echo "Usage: qemate usb query ID"
				return 1
			fi

			query_usb_device "$1"
			;;
		*)
			log "$LOG_ERROR" "Unknown subcommand: $subcommand"
			echo "Usage: qemate usb [add|remove|list|query] [options]"
			return 1
			;;
	esac
}

parse_help_command() {
	local command=$1

	case "$command" in
		vm)
			show_vm_help
			;;
		net | network)
			show_network_help
			;;
		shared)
			show_shared_help
			;;
		usb)
			show_usb_help
			;;
		*)
			show_help
			;;
	esac
}

#==============================================================================
# 3. CORE VM OPERATIONS
#==============================================================================

# Function to get VM information
get_vm_info() {
	local  mode=$1
	local  value=$2
	local  vm_dir="${CONFIG[VM_DIR]}"
	local  current_id=0

	if  [[ "$mode" == "name_from_id" ]]; then
		[[ ! "$value" =~ ^[0-9]+$     ]] && return 1
		# Use a command substitution with a here-string to avoid subshell
		mapfile     -t vm_dirs < <(find "$vm_dir" -mindepth 1 -maxdepth 1 -type d | sort)
		for vm_path in     "${vm_dirs[@]}"; do
			[[ ! -d "$vm_path"        ]] || [[ ! -f "$vm_path/config" ]] && continue
			((current_id++))
			if        [[ "$current_id" -eq "$value" ]]; then
				basename           "$vm_path"
				return           0
			fi
		done
	elif  [[ "$mode" == "id_from_name" ]]; then
		mapfile     -t vm_dirs < <(find "$vm_dir" -mindepth 1 -maxdepth 1 -type d | sort)
		for vm_path in     "${vm_dirs[@]}"; do
			((current_id++))
			[[ "$(       basename "$vm_path")" == "$value" ]] && {
				echo           "$current_id"
				return           0
			}
		done
	else
		return     1
	fi
	return  1
}

# Create new VM with built-in optimizations
create_vm() {
	local name=$1 memory=${2:-${CONFIG[DEFAULT_MEMORY]}} cores=${3:-${CONFIG[DEFAULT_CORES]}} disk_size=${4:-${CONFIG[DEFAULT_DISK_SIZE]}}
	local vm_path="${CONFIG[VM_DIR]}/${name}" mac_address mac_suffix cpu_list

	acquire_lock "$GLOBAL_LOCK_FILE" || {
		log "$LOG_ERROR" "Failed to acquire lock"
		return 1
	}

	validate_vm_name "$name" || {
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}

	# Handle GB memory input (convert to MB)
	if [[ "$memory" =~ ^[0-9]+GB$ ]]; then
		# Extract numeric part and multiply by 1024 to convert GB to MB
		memory=$( echo "$memory" | sed 's/GB$//' | awk '{print $1 * 1024}')
	elif [[ "$memory" =~ ^[0-9]+G$ ]]; then
		# Also accept format like "4G"
		memory=$( echo "$memory" | sed 's/G$//' | awk '{print $1 * 1024}')
	fi

	# Now validate the memory value
	[[ ! "$memory" =~ ^[0-9]+$ ]] || [ "$memory" -lt 128 ] && {
		log  "$LOG_ERROR" "Invalid memory size. Use a number in MB or add GB suffix (e.g., 4GB)"
		release_lock  "$GLOBAL_LOCK_FILE"
		return  1
	}

	[[ ! "$cores" =~ ^[0-9]+$ ]] || [ "$cores" -lt 1 ] && {
		log "$LOG_ERROR" "Invalid number of cores"
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}

	# Format disk size for qemu-img compatibility
	if  [[ "$disk_size" =~ ^[0-9]+GB$ ]]; then
		# Convert "60GB" to "60G" for qemu-img
		disk_size=${disk_size//GB/G}
	elif  [[ "$disk_size" =~ ^[0-9]+MB$ ]]; then
		# Convert "500MB" to "500M" for qemu-img
		disk_size=${disk_size//MB/M}
	elif  [[ "$disk_size" =~ ^[0-9]+TB$ ]]; then
		# Convert "1TB" to "1T" for qemu-img
		disk_size=${disk_size//TB/T}
	fi

	# Validate disk size format for qemu-img
	[[ ! "$disk_size" =~ ^[0-9]+[MGT]$  ]] && {
		log     "$LOG_ERROR" "Invalid disk size format. Use format like '60G' or '500M'"
		release_lock     "$GLOBAL_LOCK_FILE"
		return     1
	}

	[[ $(find "${CONFIG[VM_DIR]}" -mindepth 1 -maxdepth 1 -type d | wc -l) -ge "${CONFIG[MAX_VMS]}" ]] && {
		log "$LOG_ERROR" "Max VMs reached"
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}
	[[ -e "$vm_path" ]] && {
		log "$LOG_ERROR" "VM '$name' exists"
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}

	if ! mkdir -p "$vm_path"; then
		log "$LOG_ERROR" "Failed to create VM directory"
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	fi

	if ! chmod 700 "$vm_path"; then
		log "$LOG_ERROR" "Failed to set permissions on VM directory"
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	fi
	TEMP_RESOURCES+=("$vm_path")

	mac_suffix=$(generate_secure_string 6 | sed 's/\(..\)/\1:/g; s/:$//')
	mac_address="52:54:00:${mac_suffix}"

	# Initialize cpu_list as an empty string
	cpu_list=""
	for ((i = 1; i < cores + 1; i++)); do
		[[ -n "$cpu_list"  ]] && cpu_list+=","
		cpu_list+="$i"
	done

	cat > "${vm_path}/config" << EOF
# VM Configuration
# Created: $(date -Iseconds)
# Version: ${SCRIPT_VERSION}

NAME="$name"
MEMORY=$memory
CORES=$cores
MACHINE_TYPE="q35"
NETWORK_TYPE="${CONFIG[DEFAULT_NETWORK_TYPE]}"
MAC_ADDRESS="$mac_address"
CPU_TYPE="host"
ENABLE_KVM=1
ENABLE_ACPI=1
ENABLE_IO_THREADS=1
DISK_CACHE="writeback"
DISK_IO="native"
DISK_DISCARD="unmap"
ENABLE_VIRTIO=1
MACHINE_OPTIONS="accel=kvm"
PCI_BUS="pcie.0"
VIDEO_TYPE="virtio"
NETWORK_MODEL="virtio-net-pci"
DISK_INTERFACE="virtio-blk-pci"
MEMORY_PREALLOC=0
MEMORY_SHARE=1
EOF

	chmod 600 "${vm_path}/config" || {
		log "$LOG_ERROR" "Failed to create config"
		cleanup_handler
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}

	qemu-img create -f qcow2 -o cluster_size=128K,lazy_refcounts=on,preallocation=metadata "${vm_path}/disk.qcow2" "$disk_size" || {
		log "$LOG_ERROR" "Failed to create disk"
		cleanup_handler
		release_lock "$GLOBAL_LOCK_FILE"
		return 1
	}
	chmod 600 "${vm_path}/disk.qcow2"

	TEMP_RESOURCES=()
	release_lock "$GLOBAL_LOCK_FILE"
	log "$LOG_SUCCESS" "VM '$name' created successfully with optimizations"
	log "$LOG_INFO" "Configuration: ${memory}MB RAM, ${cores} cores, ${disk_size} disk"
	return 0
}

# Start VM with enhanced security
start_vm() {
	local name_or_id="$1" iso_file="$2" headless="${3:-0}"
	local vm_name
	# Determine if input is an ID (numeric) or name
	if  [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
		vm_name=$(    get_vm_info "name_from_id" "$name_or_id" 2> /dev/null) || {
			log        "$LOG_ERROR" "No VM found with ID '$name_or_id'"
			return        1
		}
	else
		vm_name="$name_or_id"
	fi

	local vm_lock="${CONFIG[TEMP_DIR]}/qemu-${vm_name}.lock"
	local log_file

	# Check if VM exists and isn’t already running
	check_vm_exists "$vm_name" || return 1
	if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" > /dev/null; then
		log "$LOG_ERROR" "VM '$vm_name' is already running"
		return 1
	fi

	# Verify network prerequisites
	check_network_prereqs "$vm_name" || return 1

	# Check for X display if not headless
	if [[ "$headless" -eq 0 && -z "$DISPLAY" && ! $(xset q &> /dev/null) ]]; then
		log "$LOG_ERROR" "No X display detected. Use --headless"
		return 1
	fi

	# Acquire lock
	acquire_lock "$vm_lock" || {
		log "$LOG_ERROR" "Failed to acquire VM lock"
		return 1
	}

	# Read VM config
	read_vm_config "$vm_name" || {
		release_lock "$vm_lock"
		return 1
	}

	# Set up log file
	log_file="${CONFIG[LOG_DIR]}/${vm_name}_$(date +%Y%m%d_%H%M%S).log"
	if ! touch "$log_file" || ! chmod "$SECURE_PERMISSIONS" "$log_file"; then
		log "$LOG_ERROR" "Failed to create log file"
		release_lock "$vm_lock"
		return 1
	fi
	TEMP_RESOURCES+=("$log_file")

	# Build QEMU arguments
	local -a qemu_args=(
		"qemu-system-x86_64"
		"-name" "guest=${vm_name},process=qemu-${vm_name}"
		"-machine" "type=${VM_CONFIG[MACHINE_TYPE]},accel=kvm"
		"-cpu" "host,migratable=off"
		"-smp" "cores=${VM_CONFIG[CORES]},threads=1"
		"-m" "${VM_CONFIG[MEMORY]}"
	)
	if [[ "$headless" -eq 1 ]]; then
		qemu_args+=("-display" "none" "-nographic")
	else
		qemu_args+=("-device" "virtio-vga" "-display" "gtk")
	fi

	# Check disk existence
	if [[ ! -f "${CONFIG[VM_DIR]}/${vm_name}/disk.qcow2" ]]; then
		log "$LOG_ERROR" "Disk not found"
		release_lock "$vm_lock"
		return 1
	fi
	qemu_args+=("-drive" "if=virtio,file=${CONFIG[VM_DIR]}/${vm_name}/disk.qcow2,format=qcow2,aio=io_uring,cache=none")

	# Add ISO if provided
	if [[ -n "$iso_file" ]]; then
		if ! validate_path "$iso_file"; then
			log "$LOG_ERROR" "Invalid ISO path"
			release_lock "$vm_lock"
			return 1
		fi
		qemu_args+=(
			"-drive" "if=virtio,file=${iso_file},format=raw,readonly=on,media=cdrom"
			"-boot" "order=d,once=d"
		)
	fi

	# Add network and shared folder arguments
	mapfile -t -O "${#qemu_args[@]}" qemu_args < <(build_network_args "$vm_name")
	if [[ "${VM_CONFIG[SHARED_FOLDERS_ENABLED]:-0}" -eq 1 ]]; then
		mapfile -t -O "${#qemu_args[@]}" qemu_args < <(build_share_args "$vm_name")
	fi

	# Launch QEMU
	"${qemu_args[@]}" >> "$log_file" 2>&1 < /dev/null &
	local pid=$!
	echo "$pid" > "$vm_lock/pid"

	# Verify process started
	sleep 1
	if kill -0 "$pid" 2> /dev/null; then
		log "$LOG_SUCCESS" "VM '$vm_name' started (PID: $pid)"
		reconnect_usb_devices "$vm_name"
		release_lock "$vm_lock"
		return 0
	else
		log "$LOG_ERROR" "Failed to start VM"
		cat "$log_file"
		release_lock "$vm_lock"
		return 1
	fi
}

# Stop VM with enhanced safety checks
stop_vm() {
	local name_or_id=$1 force=${2:-0} timeout=${CONFIG[VM_SHUTDOWN_TIMEOUT]}
	local vm_name
	# Determine if input is an ID (numeric) or name
	if  [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
		vm_name=$(    get_vm_info "name_from_id" "$name_or_id" 2> /dev/null) || {
			log        "$LOG_ERROR" "No VM found with ID '$name_or_id'"
			return        1
		}
	else
		vm_name="$name_or_id"
	fi

	local vm_lock="/tmp/qemu-${vm_name}.lock"
	local pid

	check_vm_running "$vm_name" || {
		log "$LOG_INFO" "VM '$vm_name' not running"
		return 0
	}
	pid=$(pgrep -f "guest=${vm_name},process=qemu-${vm_name}") || {
		log "$LOG_ERROR" "VM process not found"
		return 1
	}

	[[ "$force" -eq 0 ]] && {
		log "$LOG_INFO" "Attempting graceful shutdown"
		kill -SIGTERM "$pid"
		local start_time=$SECONDS
		while kill -0 "$pid" 2> /dev/null; do
			((SECONDS - start_time >= timeout)) && {
				log "$LOG_WARN" "Graceful shutdown timed out, forcing stop"
				force=1
				break
			}
			sleep 1
		done
	}

	[[ "$force" -eq 1 ]] && {
		log "$LOG_WARN" "Force stopping VM '$vm_name'"
		kill -9 "$pid"
		sleep 2
		kill -0 "$pid" 2> /dev/null && {
			log "$LOG_ERROR" "Failed to force stop VM"
			return 1
		}
	}

	cleanup_network "$vm_name"
	rm -f "$vm_lock/pid" "${CONFIG[VM_DIR]}/${vm_name}/disk.qcow2.lock"
	log "$LOG_SUCCESS" "VM '$vm_name' stopped"
	return 0
}

# Delete VM with secure cleanup
delete_vm() {
	local name_or_id=$1 force=${2:-0}
	local vm_name
	vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2> /dev/null || echo "$name_or_id")
	local vm_path="${CONFIG[VM_DIR]}/${vm_name}"
	local vm_lock="/tmp/qemu-${vm_name}.lock"

	check_vm_exists "$vm_name" || return 1

	if check_vm_running "$vm_name"; then
		if [[ "$force" -eq 1 ]]; then
			stop_vm "$vm_name" 1 || {
				log "$LOG_ERROR" "Failed to stop VM '$vm_name'"
				return 1
			}
		else
			log "$LOG_ERROR" "VM running. Stop it first or use -f"
			return 1
		fi
	fi

	acquire_lock "$GLOBAL_LOCK_FILE" || {
		log "$LOG_ERROR" "Failed to acquire lock"
		return 1
	}

	local -a files_to_delete=("$vm_path" "${CONFIG[LOG_DIR]}/${vm_name}_*.log")

	[[ $(compgen -G "${files_to_delete[@]}") ]] || {
		log "$LOG_WARN" "No files to delete"
		release_lock "$GLOBAL_LOCK_FILE"
		return 0
	}

	[[ "$force" -eq 0 ]] && {
		local response
		read -r -p "Are you sure you want to delete VM '$vm_name'? [y/N] " response
		[[ ! "$response" =~ ^[Yy]$ ]] && {
			log "$LOG_INFO" "Deletion cancelled"
			release_lock "$GLOBAL_LOCK_FILE"
			return 0
		}
	}

	local error=0
	for item in "${files_to_delete[@]}"; do
		if [[ $(compgen -G "$item") ]]; then
			if ! rm -rf "$item"; then
				log "$LOG_ERROR" "Failed to delete: $item"
				error=1
			fi
		fi
	done

	rm -f "$vm_lock"
	release_lock "$GLOBAL_LOCK_FILE"

	if [[ "$error" -eq 0 ]]; then
		log "$LOG_SUCCESS" "VM '$vm_name' deleted"
	else
		log "$LOG_ERROR" "Some files could not be deleted"
		return 1
	fi
}

# List all virtual machines and their status
list_vms() {
	local  vm_dir="${CONFIG[VM_DIR]}"
	# Validate VM directory exists and is accessible
	if  [[ ! -d "$vm_dir" ]]; then
		log     "$LOG_ERROR" "VM directory not found: $vm_dir"
		return     1
	fi

	# Define colors for VM status
	# local VM_RED VM_GREEN VM_NC
	# VM_RED=$(tput setaf 1)
	# VM_GREEN=$(tput setaf 2)
	# VM_NC=$(tput sgr0)

	# Print header
	printf  "\n"
	printf  "%-4s %-15s %-10s %-10s %-10s %-12s\n" \
		"ID"     "NAME" "STATUS" "MEMORY" "CORES" "DISK SIZE"
	printf  "%s\n" "======================================================================"

	# Track VMs found for summary
	local  found_vms=0
	declare  -A vm_ids

	# First pass: collect VM names and assign IDs
	while  IFS= read -r vm_path; do
		if     [[ ! -d "$vm_path" ]] || [[ ! -f "$vm_path/config" ]]; then
			continue
		fi
		local     vm
		vm=$(    basename "$vm_path")
		found_vms=$((found_vms + 1))
		vm_ids["$vm"]=$found_vms
	done  < <(find "$vm_dir" -mindepth 1 -maxdepth 1 -type d | sort)

	# Second pass: display VM information with IDs
	while  IFS= read -r vm_path; do
		# Skip if not a directory or no config file
		if     [[ ! -d "$vm_path" ]] || [[ ! -f "$vm_path/config" ]]; then
			continue
		fi
		local     vm
		vm=$(    basename "$vm_path")
		local     vm_id=${vm_ids["$vm"]}
		local     status_raw="stopped"

		# Check VM running status
		if     check_vm_running "$vm"; then
			status_raw="running"
		else
			status_raw="stopped"
		fi

		# Set color based on status
		status_color="${RED}"
		if     [[ "$status_raw" == "running" ]]; then
			status_color="${GREEN}"
		fi

		# Load VM configuration
		if     ! read_vm_config "$vm"; then
			log        "$LOG_WARN" "Failed to load config for VM: $vm"
			continue
		fi

		local     memory="${VM_CONFIG[MEMORY]}"
		local     cores="${VM_CONFIG[CORES]}"

		# Get disk size
		local     disk_size="N/A"
		local     disk_path="${vm_path}/disk.qcow2"
		if     [[ -f "$disk_path" ]]; then
			local        disk_info=""
			# Use -U flag when VM is running to avoid locks
			if        [[ "$status_raw" == "running" ]]; then
				disk_info=$(          qemu-img info -U "$disk_path" 2> /dev/null | grep "virtual size:")
			fi
			# Try without -U if previous attempt failed or VM is stopped
			if        [[ -z "$disk_info" ]]; then
				disk_info=$(          qemu-img info "$disk_path" 2> /dev/null | grep "virtual size:")
			fi
			# Parse disk size information
			if        [[ $disk_info =~ virtual[[:space:]]size:[[:space:]]([0-9.]+)[[:space:]]([KMGT]iB|[KMGT]B) ]]; then
				local           size="${BASH_REMATCH[1]}"
				local           unit="${BASH_REMATCH[2]}"
				unit=${unit/iB/B}           # Normalize units
				disk_size="${size}${unit}"
			fi
		fi

		# Format memory for display
		if     [[ "$memory" =~ ^[0-9]+$ ]]; then
			if        ((memory >= 1024)); then
				memory="$((memory / 1024))GB"
			else
				memory="${memory}MB"
			fi
		fi

		# Print VM information with ID
		printf     "%-4d %-15s ${status_color}%-10s${NC} %-10s %-10s %-12s\n" \
			"$vm_id" \
			"$vm" \
			"$status_raw" \
			"$memory" \
			"$cores" \
			"$disk_size"

	done  < <(find "$vm_dir" -mindepth 1 -maxdepth 1 -type d | sort)

	# Print summary
	printf  "\n"
	if  ((found_vms == 0)); then
		log     "$LOG_INFO" "No VMs found"
	fi
	return  0
}

# Show VM status with ID
show_vm_status() {
	local name_or_id=$1
	local vm_name
	vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2> /dev/null || echo "$name_or_id")
	local config_file="${CONFIG[VM_DIR]}/${vm_name}/config"
	local disk_path="${CONFIG[VM_DIR]}/${vm_name}/disk.qcow2"
	local disk_size="unknown"
	local disk_usage="unknown"

	check_vm_exists "$vm_name" || return 1
	read_vm_config "$vm_name" || return 1

	local status_symbol="⭘"
	local status_text="stopped"
	check_vm_running "$vm_name" && {
		status_symbol="⬤"
		status_text="running"
	}

	[[ -f "$disk_path" ]] && {
		local disk_info
		[[ "$status_text" == "running" ]] && disk_info=$(qemu-img info -U "$disk_path" 2> /dev/null) || disk_info=$(qemu-img info "$disk_path" 2> /dev/null)
		[[ -n "$disk_info" ]] && {
			disk_size=$(echo "$disk_info" | grep "virtual size:" | sed -E 's/.*\(([0-9.]+) ([MGT]iB)\).*/\1\2/')
			disk_usage=$(echo "$disk_info" | grep "disk size:" | awk '{print $3$4}')
		}
	}

	local network_type=${VM_CONFIG[NETWORK_TYPE]:-${CONFIG[DEFAULT_NETWORK_TYPE]}}
	local mac_address=${VM_CONFIG[MAC_ADDRESS]:-"not set"}
	local vm_id
	vm_id=$(get_vm_info "id_from_name" "$vm_name")

	echo "VM Status: $vm_name (ID: $vm_id)"
	echo "============================================"
	[[ "$status_text" == "running" ]] && printf "State:           ${GREEN}%s %s${NC}\n" "$status_symbol" "$status_text" || printf "State:           ${RED}%s %s${NC}\n" "$status_symbol" "$status_text"
	printf "Memory:          %s MB\n" "${VM_CONFIG[MEMORY]}"
	printf "CPU Cores:       %s\n" "${VM_CONFIG[CORES]}"
	printf "Disk Size:       %s\n" "$disk_size"
	printf "Disk Usage:      %s\n" "$disk_usage"
	printf "Network Type:    %s\n" "$network_type"
	printf "MAC Address:     %s\n" "$mac_address"

	[[ ("$network_type" == "user" || "$network_type" == "nat") && "${VM_CONFIG[PORT_FORWARDING_ENABLED]:-0}" == "1" ]] && {
		echo
		echo "Port Forwards:"
		echo "${VM_CONFIG[PORT_FORWARDS]:-}" | tr ',' '\n' | while IFS=':' read -r host guest proto; do printf "  %s → %s (%s)\n" "$host" "$guest" "${proto:-tcp}"; done
	}

	[[ "${VM_CONFIG[SHARED_FOLDERS_ENABLED]:-0}" == "1" ]] && {
		echo
		echo "Shared Folders:"
		grep "^SHARED_FOLDER_.*_PATH=" "$config_file" | while IFS= read -r line; do
			[[ $line =~ ^SHARED_FOLDER_.*_PATH= ]] || continue

			local share_name
			local path

			share_name=${line#SHARED_FOLDER_}
			share_name=${share_name%_PATH=*}

			path=$(echo "$line" | cut -d'"' -f2)

			printf "  %s → %s\n" "$share_name" "$path"
		done
	}

	return 0
}

#==============================================================================
# 4. NETWORK MANAGEMENT
#==============================================================================

# Function to check if a network type is valid
validate_network_type() {
	local net_type=$1

	case "$net_type" in
		nat | none)
			return 0
			;;
		*)
			log "$LOG_ERROR" "Invalid network type: $net_type"
			return 1
			;;
	esac
}

# Function to build network arguments for QEMU command
build_network_args() {
	local  name=$1
	local  net_type=${VM_CONFIG[NETWORK_TYPE]:-${CONFIG[DEFAULT_NETWORK_TYPE]}}

	case "$net_type" in
		nat | user)  # Add 'user' as a valid type
			local    netdev_arg="user,id=net0"
			if    [[ "${VM_CONFIG[PORT_FORWARDING_ENABLED]:-0}" -eq 1 && -n "${VM_CONFIG[PORT_FORWARDS]:-}" ]]; then
				local       forwards
				IFS=','       read -ra forwards <<< "${VM_CONFIG[PORT_FORWARDS]}"
				for forward in       "${forwards[@]}"; do
					IFS=':'          read -r host guest proto <<< "$forward"
					netdev_arg+=",hostfwd=${proto:-tcp}::${host}-:${guest}"
				done
			fi
			printf    '%s\n' "-netdev" "$netdev_arg"
			;;
		none)
			return    0
			;;
		*)
			log    "$LOG_ERROR" "Invalid network type: $net_type" >&2
			return    1
			;;
	esac

	local  model=${VM_CONFIG[NETWORK_MODEL]:-"virtio-net-pci"}
	local  mac=${VM_CONFIG[MAC_ADDRESS]:-$(generate_vm_mac "$name")}
	printf  '%s\n' "-device" "${model},netdev=net0,mac=${mac}"

	return  0
}

# Function to setup network configuration
setup_network() {
	local name=$1
	local network_type=$2
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	log "$LOG_DEBUG" "setup_network called with: name=$name, type=$network_type, arg3=${3:-unset}"
	log "$LOG_DEBUG" "Config file: $config_file"

	# Validate VM exists
	if ! check_vm_exists "$name"; then
		log "$LOG_DEBUG" "VM check failed: $name does not exist"
		log "$LOG_ERROR" "VM '$name' does not exist"
		return 1
	fi

	# Check if VM is running and provide clear warning
	if check_vm_running "$name"; then
		case "$network_type" in
			add-port | remove-port)
				log "$LOG_ERROR" "Cannot modify port forwards while VM is running"
				log "$LOG_INFO" "Please stop the VM first"
				return 1
				;;
		esac
	fi

	# Create temporary config
	local temp_config
	temp_config=$(create_temp_file "config")
	if ! create_temp_file "config"; then
		log "$LOG_DEBUG" "Failed to create temp config file"
		return 1
	fi
	log "$LOG_DEBUG" "Created temp config at: $temp_config"

	# Copy existing config
	cp "$config_file" "$temp_config"
	if ! cp "$config_file" "$temp_config"; then
		log "$LOG_DEBUG" "Failed to copy config file"
		rm -f "$temp_config"
		return 1
	fi

	# Read current config
	log "$LOG_DEBUG" "Current config content:"
	while read -r line; do
		log "$LOG_DEBUG" "  $line"
	done < "$temp_config"

	case "$network_type" in
		add-port)
			local port_spec=$3
			local host guest proto
			IFS=':' read -r host guest proto <<< "$port_spec"
			proto=${proto:-tcp}

			log "$LOG_DEBUG" "Processing add-port: host=$host guest=$guest proto=$proto"

			# Read current VM configuration
			if ! read_vm_config "$name"; then
				log "$LOG_DEBUG" "Failed to read VM config"
				rm -f "$temp_config"
				return 1
			fi

			# Check network type
			if [[ "${VM_CONFIG[NETWORK_TYPE]:-nat}" != "nat" ]]; then
				log "$LOG_DEBUG" "Invalid network type: ${VM_CONFIG[NETWORK_TYPE]:-nat}"
				log "$LOG_ERROR" "Port forwarding requires NAT networking"
				rm -f "$temp_config"
				return 1
			fi

			# Check for duplicate ports
			log "$LOG_DEBUG" "Current port forwards: ${VM_CONFIG[PORT_FORWARDS]:-none}"
			while IFS=':' read -r existing_host existing_guest existing_proto; do
				[[ -z "$existing_host" ]] && continue
				log "$LOG_DEBUG" "Checking existing forward: $existing_host:$existing_guest:${existing_proto:-tcp}"
				if [[ "$existing_host" == "$host" && "${existing_proto:-tcp}" == "${proto:-tcp}" ]]; then
					log "$LOG_ERROR" "Port forward already exists: host port $host (${proto:-tcp})"
					rm -f "$temp_config"
					return 1
				fi
			done < <(echo "${VM_CONFIG[PORT_FORWARDS]:-}" | tr ',' '\n')

			# Enable port forwarding
			if ! grep -q "^PORT_FORWARDING_ENABLED=" "$temp_config"; then
				log "$LOG_DEBUG" "Adding PORT_FORWARDING_ENABLED=1"
				echo "PORT_FORWARDING_ENABLED=1" >> "$temp_config"
			else
				log "$LOG_DEBUG" "Updating existing PORT_FORWARDING_ENABLED"
				sed -i "s/^PORT_FORWARDING_ENABLED=.*/PORT_FORWARDING_ENABLED=1/" "$temp_config"
			fi

			# Add port forward
			if ! grep -q "^PORT_FORWARDS=" "$temp_config"; then
				echo "PORT_FORWARDS=\"$host:$guest:$proto\"" >> "$temp_config"
			else
				sed -i "/^PORT_FORWARDS=/ s/\"$/,$host:$guest:$proto\"/" "$temp_config"  # Removed space before $host
			fi

			# Verify changes
			if ! grep -q "$host:$guest:$proto" "$temp_config"; then
				log "$LOG_DEBUG" "Verification failed: port forward not found in config"
				log "$LOG_ERROR" "Failed to add port forward"
				rm -f "$temp_config"
				return 1
			fi

			log "$LOG_SUCCESS" "Successfully added port forward: $host -> $guest ($proto)"
			;;

		remove-port)
			local port_spec=$3
			local port proto
			IFS=':' read -r port proto <<< "$port_spec"
			proto=${proto:-tcp}

			log "$LOG_DEBUG" "Processing remove-port: port=$port proto=$proto"

			# Read current VM configuration
			if ! read_vm_config "$name"; then
				log "$LOG_DEBUG" "Failed to read VM config"
				rm -f "$temp_config"
				return 1
			fi

			# Check network type
			if [[ "${VM_CONFIG[NETWORK_TYPE]:-nat}" != "nat" ]]; then
				log "$LOG_ERROR" "VM is not configured for NAT networking"
				rm -f "$temp_config"
				return 1
			fi

			# Check if port forwarding is enabled
			if [[ "${VM_CONFIG[PORT_FORWARDING_ENABLED]:-0}" != "1" ]] || [[ -z "${VM_CONFIG[PORT_FORWARDS]:-}" ]]; then
				log "$LOG_ERROR" "No port forwards configured for VM '$name'"
				rm -f "$temp_config"
				return 1
			fi

			log "$LOG_DEBUG" "Current port forwards: ${VM_CONFIG[PORT_FORWARDS]}"

			# Remove the port forward
			local found=0
			local new_forwards=""
			while IFS=':' read -r host guest existing_proto; do
				host=$(echo "$host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')  # Trim spaces
				[[ -z "$host" ]] && continue
				if [[ "$host" == "$port" && "${existing_proto:-tcp}" == "$proto" ]]; then
					found=1
					log    "$LOG_DEBUG" "Found matching port forward to remove"
					continue
				fi
				[[ -n "$new_forwards" ]] && new_forwards+=","
				new_forwards+="$host:$guest:${existing_proto:-tcp}"
			done < <(echo "${VM_CONFIG[PORT_FORWARDS]}" | tr ',' '\n')

			if [[ "$found" -eq 0 ]]; then
				log "$LOG_ERROR" "Port forward not found: $port ($proto)"
				rm -f "$temp_config"
				return 1
			fi

			# Update configuration
			if [[ -n "$new_forwards" ]]; then
				log "$LOG_DEBUG" "Updating port forwards to: $new_forwards"
				sed -i "s/^PORT_FORWARDS=.*/PORT_FORWARDS=\"$new_forwards\"/" "$temp_config"
			else
				# No more port forwards, remove the configuration
				log "$LOG_DEBUG" "Removing port forwarding configuration"
				sed -i '/^PORT_FORWARDS=/d' "$temp_config"
				sed -i '/^PORT_FORWARDING_ENABLED=/d' "$temp_config"
			fi

			log "$LOG_SUCCESS" "Successfully removed port forward: $port ($proto)"
			;;

		nat | none)
			# Update network type
			log "$LOG_DEBUG" "Setting network type to: $network_type"
			case "$network_type" in
				nat)
					log "$LOG_DEBUG" "Configuring NAT networking"
					sed -i "s/^NETWORK_TYPE=.*/NETWORK_TYPE=\"nat\"/" "$temp_config"
					# Keep existing port forwards if any
					log "$LOG_SUCCESS" "Network type set to NAT"
					;;

				none)
					log "$LOG_DEBUG" "Disabling networking"
					sed -i "s/^NETWORK_TYPE=.*/NETWORK_TYPE=\"none\"/" "$temp_config"
					# Remove all network-related configuration
					sed -i '/^PORT_FORWARDS=/d' "$temp_config"
					sed -i '/^PORT_FORWARDING_ENABLED=/d' "$temp_config"
					log "$LOG_SUCCESS" "Networking disabled"
					log "$LOG_INFO" "All network configuration has been removed"
					;;
			esac
			;;

		*)
			log "$LOG_ERROR" "Invalid network command: $network_type"
			rm -f "$temp_config"
			return 1
			;;
	esac

	# Show final config for debugging
	log "$LOG_DEBUG" "Final config content:"
	while read -r line; do
		log "$LOG_DEBUG" "  $line"
	done < "$temp_config"

	# Update config atomically
	log "$LOG_DEBUG" "Moving temp config to final location"
	if ! mv "$temp_config" "$config_file"; then
		log "$LOG_ERROR" "Failed to update configuration"
		rm -f "$temp_config"
		return 1
	fi

	chmod "$SECURE_PERMISSIONS" "$config_file"
	log "$LOG_DEBUG" "Configuration update completed successfully"

	return 0
}

# Helper function for port forward listing
list_port_forwards() {
	local name=$1
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	log "$LOG_DEBUG" "Listing port forwards for VM: $name"

	# Validate VM exists
	if ! check_vm_exists "$name"; then
		return 1
	fi

	# Load VM configuration
	if ! read_vm_config "$name"; then
		return 1
	fi

	# Check network type
	if [[ "${VM_CONFIG[NETWORK_TYPE]:-}" != "nat" ]]; then
		log "$LOG_ERROR" "VM '$name' is not configured for NAT networking"
		return 1
	fi

	# Display port forwards
	echo "Port Forwards for VM '$name':"
	echo "======================================="
	printf "%-15s %-15s %-10s\n" "HOST PORT" "GUEST PORT" "PROTOCOL"
	echo "---------------------------------------"

	if [[ "${VM_CONFIG[PORT_FORWARDING_ENABLED]:-0}" == "1" ]] && [[ -n "${VM_CONFIG[PORT_FORWARDS]:-}" ]]; then
		log "$LOG_DEBUG" "Processing port forwards: ${VM_CONFIG[PORT_FORWARDS]}"
		echo "${VM_CONFIG[PORT_FORWARDS]}" | tr ',' '\n' | while IFS=':' read -r host guest proto; do
			[[ -z "$host" ]] && continue
			printf "%-15s %-15s %-10s\n" "$host" "$guest" "${proto:-tcp}"
		done
	else
		log "$LOG_DEBUG" "No port forwards configured"
	fi

	return 0
}

# Function to check network prerequisites
check_network_prereqs() {
	local name=$1
	local net_type=${VM_CONFIG[NETWORK_TYPE]:-${CONFIG[DEFAULT_NETWORK_TYPE]}}

	case "$net_type" in
		nat)
			# Check if port forwarding is properly configured
			if [[ "${VM_CONFIG[PORT_FORWARDING_ENABLED]:-0}" -eq 1 ]]; then
				local forwards
				IFS=',' read -ra forwards <<< "${VM_CONFIG[PORT_FORWARDS]:-}"
				for forward in "${forwards[@]}"; do
					IFS=':' read -r host guest _ <<< "$forward"
					if ss -tuln | grep -q ":$host "; then
						log "$LOG_WARN" "Host port $host is already in use"
					fi
				done
			fi
			;;
	esac

	return 0
}

# Network cleanup on VM shutdown
cleanup_network() {
	local name=$1
	local net_type=${VM_CONFIG[NETWORK_TYPE]:-${CONFIG[DEFAULT_NETWORK_TYPE]}}

	case "$net_type" in
		nat)
			# No specific cleanup needed for NAT
			return 0
			;;
	esac
}

#==============================================================================
# 5. SHARED FOLDER MANAGEMENT
#==============================================================================

# Build shared folder arguments for QEMU command
build_share_args() {
	local name=$1
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	# Check if shared folders are enabled
	if [[ "${VM_CONFIG[SHARED_FOLDERS_ENABLED]:-0}" != "1" ]]; then
		return 0
	fi

	# Get share type
	local share_type=${VM_CONFIG[SHARED_FOLDER_TYPE]:-}

	case "$share_type" in
		virtio-9p)
			# Process each shared folder configuration
			while IFS= read -r line; do
				if [[ $line =~ ^SHARED_FOLDER_(.*)_PATH= ]]; then
					local share_name="${BASH_REMATCH[1]}"
					local path
					path=$(echo "$line" | cut -d'"' -f2)
					local tag="virtfs_${share_name,,}"

					# Separate read and assignment to avoid SC2094 warning
					local readonly_flag="0" # Default to "0"
					# Search for the corresponding readonly setting
					while IFS= read -r config_line; do
						if [[ "$config_line" =~ ^SHARED_FOLDER_${share_name}_READONLY= ]]; then
							readonly_flag=$(echo "$config_line" | cut -d'=' -f2)
							break
						fi
					done < "$config_file"

					# Build fsdev options
					local fsdev_opts="local,path=${path},security_model=mapped"
					fsdev_opts+=",id=fs_${share_name,,}"

					# Add readonly if enabled
					[[ "$readonly_flag" == "1" ]] && fsdev_opts+=",readonly"

					# Output the device arguments
					echo "-fsdev"
					echo "$fsdev_opts"
					echo "-device"
					echo "virtio-9p-pci,fsdev=fs_${share_name,,},mount_tag=${tag}"
				fi
			done < "$config_file"
			;;
		smb)
			# Process each shared folder configuration for SMB
			while IFS= read -r line; do
				if [[ $line =~ ^SHARED_FOLDER_(.*)_PATH= ]]; then
					local share_name="${BASH_REMATCH[1]}"
					local path
					path=$(echo "$line" | cut -d'"' -f2)
					local smb_opts="id=smb_${share_name,,},smb=${path}"

					# Output the device arguments using smb_opts
					echo "-netdev"
					echo "user,id=net0,smb=${path}"
					echo "-device"
					echo "virtio-net-pci,netdev=net0"
					echo "$smb_opts" # Use smb_opts here
				fi
			done < "$config_file"
			;;
	esac
	return 0
}

# Add a shared folder to the VM configuration
add_shared_folder() {
	local name=$1
	local host_path=$2
	local share_name=$3
	local share_type=$4
	local readonly=${5:-0}
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	# Validate inputs
	if ! validate_vm_name "$name" \
		|| [ -z "$host_path" ] \
		|| [ -z "$share_name" ] \
		|| ! [[ "$share_type" =~ ^(linux|windows)$ ]]; then
		log "$LOG_ERROR" "Invalid parameters"
		return 1
	fi

	# Validate VM state
	if ! check_vm_exists "$name" \
		|| check_vm_running "$name"; then
		return 1
	fi

	# Validate share path
	local validated_path
	validated_path=$(validate_path "$host_path") || {
		log "$LOG_ERROR" "Invalid share path"
		return 1
	}

	# Create temporary config
	local temp_config
	temp_config=$(create_temp_file "config") || return 1

	# Copy existing config
	cp "$config_file" "$temp_config" || return 1

	# Enable shared folders if needed
	if ! grep -q "^SHARED_FOLDERS_ENABLED=1" "$temp_config"; then
		{
			echo "SHARED_FOLDERS_ENABLED=1"
			echo "SHARED_FOLDER_TYPE=\"$([ "$share_type" = "linux" ] && echo "virtio-9p" || echo "smb")\""
		} >> "$temp_config"
	fi

	# Add share configuration
	{
		echo "SHARED_FOLDER_${share_name}_PATH=\"$validated_path\""
		echo "SHARED_FOLDER_${share_name}_TAG=\"$share_name\""
		echo "SHARED_FOLDER_${share_name}_READONLY=$readonly"
	} >> "$temp_config"

	# Update config atomically
	mv "$temp_config" "$config_file" || return 1
	chmod 600 "$config_file"

	log "$LOG_SUCCESS" "Added shared folder '$share_name'"
	return 0
}

# Remove a shared folder from the VM configuration
remove_shared_folder() {
	local name=$1
	local share_name=$2
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	# Validate VM state
	if ! check_vm_exists "$name"; then
		return 1
	fi

	if check_vm_running "$name"; then
		log "$LOG_ERROR" "VM must be stopped to remove shares"
		return 1
	fi

	# Verify share exists
	if ! grep -q "^SHARED_FOLDER_${share_name}_" "$config_file"; then
		log "$LOG_ERROR" "Share '$share_name' not found"
		return 1
	fi

	# Create temporary config
	local temp_config
	temp_config=$(create_temp_file "config") || return 1

	# Remove share entries
	grep -v "^SHARED_FOLDER_${share_name}_" "$config_file" > "$temp_config"

	# Check if this was the last share
	if ! grep -q "^SHARED_FOLDER_.*_PATH=" "$temp_config"; then
		# Remove global sharing configuration
		sed -i '/^SHARED_FOLDERS_ENABLED=/d' "$temp_config"
		sed -i '/^SHARED_FOLDER_TYPE=/d' "$temp_config"
	fi

	# Update config atomically
	mv "$temp_config" "$config_file" || return 1
	chmod 600 "$config_file"

	log "$LOG_SUCCESS" "Share '$share_name' removed"
	return 0
}

# List all shared folders for a VM
list_shared_folders() {
	local name_or_id="$1"
	local vm_name
	# Determine if input is an ID (numeric) or name
	if  [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
		vm_name=$(    get_vm_info "name_from_id" "$name_or_id" 2> /dev/null) || {
			log        "$LOG_ERROR" "No VM found with ID '$name_or_id'"
			return        1
		}
	else
		vm_name="$name_or_id"
	fi

	local  config_file="${CONFIG[VM_DIR]}/${vm_name}/config"

	# Check if VM exists and isn’t already running
	check_vm_exists "$vm_name" || return 1
	if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" > /dev/null; then
		log "$LOG_ERROR" "VM '$vm_name' is already running"
		return 1
	fi

	# Check if shared folders are enabled
	if ! grep -q "^SHARED_FOLDERS_ENABLED=1" "$config_file"; then
		log "$LOG_INFO" "No shared folders configured for VM '$vm_name'"
		return 0
	fi

	# Get share type
	local share_type
	share_type=$(grep "^SHARED_FOLDER_TYPE=" "$config_file" | cut -d'=' -f2 | tr -d '"')

	echo "Shared Folder Configuration for VM: '$vm_name'"
	echo "============================================"
	echo "Sharing Type: $([[ "$share_type" == "smb" ]] && echo "Windows (SMB)" || echo "Linux (virtio-9p)")"
	echo

	# Display shares
	grep "SHARED_FOLDER_.*_PATH=" "$config_file" | while read -r line; do
		local share_name="${line#SHARED_FOLDER_}"
		share_name="${share_name%%_*}"

		# Separate declaration and assignment for 'path'
		local path
		path=$(echo "$line" | cut -d'"' -f2)

		# Use a different name for the 'readonly' flag
		local readonly_flag
		readonly_flag=$(grep "^SHARED_FOLDER_${share_name}_READONLY=" "$config_file" | cut -d'=' -f2 || echo "0")

		echo "Share Name: $share_name"
		echo "Path: $path"
		echo "Read-Only: $([[ "$readonly_flag" == "1" ]] && echo "yes" || echo "no")"
		echo "--------------------------------------------"
	done

	return 0
}

#==============================================================================
# 6. USB MANAGEMENT
#==============================================================================

# Store USB device state for persistence
store_usb_device_state() {
	local name=$1
	local vendor_id=$2
	local product_id=$3
	local serial=${4:-""}
	local state_file="${CONFIG[VM_DIR]}/${name}/.usb_devices"

	mkdir -p "$(dirname "$state_file")"
	touch "$state_file"
	chmod "$SECURE_PERMISSIONS" "$state_file"

	if ! grep -q "^${vendor_id}:${product_id}" "$state_file"; then
		echo "${vendor_id}:${product_id}${serial:+:$serial}" >> "$state_file"
	fi
}

# Remove USB device state
remove_usb_device_state() {
	local name=$1
	local vendor_id=$2
	local product_id=$3
	local state_file="${CONFIG[VM_DIR]}/${name}/.usb_devices"

	if [[ -f "$state_file" ]]; then
		sed -i "/^${vendor_id}:${product_id}/d" "$state_file"
	fi
}

# Get device serial number if available
get_device_serial() {
	local vendor_id=$1
	local product_id=$2
	local serial

	serial=$(lsusb -d "${vendor_id}:${product_id}" -v 2> /dev/null \
		| grep -i "iSerial.*" | awk '{print $3}' | head -n1)

	echo "${serial:-""}"
}

# Enhanced function to detect only physical external USB ports
get_physical_usb_ports() {
	# First, let's identify external USB ports by checking port attributes
	for usb_ctrl in /sys/bus/usb/devices/usb*; do
		[[ ! -d "$usb_ctrl" ]] && continue

		local bus_num
		bus_num=$(basename "$usb_ctrl" | tr -cd '0-9')

		[[ -z "$bus_num" ]] && continue

		# Look for ports with specific attributes that indicate external ports
		for port_path in "$usb_ctrl/"*; do
			[[ ! -d "$port_path" ]] && continue

			# Skip if this is clearly an internal device (like built-in webcam)
			if [[ -f "$port_path/product" ]]; then
				local product
				product=$(cat "$port_path/product" 2>/dev/null)

				if [[ "$product" =~ (Camera|Webcam|Bluetooth|Internal|Hub) ]]; then
					continue
				fi
			fi

			# Check for removable attribute - external ports are typically removable
			local removable=0
			if [[ -f "$port_path/removable" ]]; then
				removable=$(cat "$port_path/removable" 2>/dev/null)
			fi

			# Get port number if this looks like an external port
			if [[ "$removable" == "1" ]] || [[ ! -f "$port_path/product" ]]; then
				local port_num=""
				if [[ -f "$port_path/port" ]]; then
					port_num=$(cat "$port_path/port" 2>/dev/null)
				elif [[ $(basename "$port_path") =~ ^[0-9]+[-][0-9]+$ ]]; then
					port_num=$(basename "$port_path" | cut -d'-' -f2)
				fi

				if [[ -n "$port_num" ]]; then
					echo "$bus_num:$port_num"
				fi
			fi
		done
	done | sort -u
}

# List USB devices
list_usb_devices() {

	# Create temporary file for device mapping
 	local map_file
	map_file=$(create_temp_file "usb_map")

	echo
	echo "Available USB Ports and Devices:"
	echo "================================================"
	printf "%-4s %-10s %-10s %-15s %s\n" "NUM" "VENDOR" "PRODUCT" "BUS:PORT" "DESCRIPTION"
	echo "------------------------------------------------"

	local device_num=1
	declare -A occupied_ports=()
	declare -A all_ports=()

	while read -r port_key; do
		all_ports["$port_key"]=1
	done < <(get_physical_usb_ports)

	local -a internal_vendors=("8087" "04ca" "1d6b" "0000" "0001")

	while IFS= read -r line; do
		if [[ $line =~ Bus\ ([0-9]+)\ Device\ ([0-9]+):\ ID\ ([0-9a-f]+):([0-9a-f]+)\ (.*) ]]; then
			local bus="${BASH_REMATCH[1]}"
			local device="${BASH_REMATCH[2]}"
			local vendor="${BASH_REMATCH[3]}"
			local product="${BASH_REMATCH[4]}"
			local description="${BASH_REMATCH[5]}"

			local skip=0
			for internal_vendor in "${internal_vendors[@]}"; do
				if [[ "$vendor" = "$internal_vendor" ]]; then
					skip=1
					break
				fi
			done

			if [[ "$description" =~ (Camera|Hub|root|Root|Bluetooth|Internal) ]] || [ "$skip" -eq 1 ]; then
				continue
			fi

			local port_num=""
			local dev_path="/sys/bus/usb/devices/${bus}-${device}"

			if [[ -L "$dev_path" ]]; then
				# Separate declaration and assignment for 'real_path'
				local real_path
				real_path=$(readlink -f "$dev_path")

				if [[ -f "$real_path/port" ]]; then
					port_num=$(cat "$real_path/port" 2> /dev/null)
				elif [[ $real_path =~ /([0-9]+)-[0-9]+$ ]]; then
					port_num="${BASH_REMATCH[1]}"
				fi
			fi

			port_num=${port_num:-$device}
			local port_key="$bus:$port_num"

			echo "${device_num}:${vendor}:${product}" >> "$map_file"
			printf "%-4s %-10s %-10s %-15s %s\n" "[$device_num]" "$vendor" "$product" "$port_key" "$description"

			occupied_ports["$port_key"]=1
			((device_num++))
		fi
	done < <(lsusb)

	for port_key in $(printf '%s\n' "${!all_ports[@]}" | sort -t: -k1n -k2n); do
		if [[ -z "${occupied_ports[$port_key]:-}" ]]; then
			printf "%-4s %-10s %-10s %-15s %s\n" "[$device_num]" "-" "-" "$port_key" "<empty port>"
			echo "${device_num}:-:-" >> "$map_file"
			((device_num++))
		fi
	done

	if ! mv "$map_file" "${CONFIG[VM_DIR]}/.usb_map" 2> /dev/null; then
		log "$LOG_WARN" "Failed to save device mapping file"
		rm -f "$map_file"
	else
		chmod 600 "${CONFIG[VM_DIR]}/.usb_map"
	fi

	return 0
}

# Query USB device
query_usb_device() {
	local device_num=$1
	local map_file="${CONFIG[VM_DIR]}/.usb_map"

	if ! [[ "$device_num" =~ ^[0-9]+$ ]]; then
		log "$LOG_ERROR" "Invalid device number"
		return 1
	fi

	if [ ! -f "$map_file" ]; then
		log "$LOG_ERROR" "No USB device list found. Run 'usb list' first"
		return 1
	fi

	local device_id
	device_id=$(sed -n "${device_num}p" "$map_file" | cut -d: -f2,3)
	if [ -z "$device_id" ]; then
		log "$LOG_ERROR" "Device number $device_num not found"
		return 1
	fi

	local vendor_id="${device_id%:*}"
	local product_id="${device_id#*:}"

	echo "USB Device Information:"
	echo "======================="
	echo "Device Number: $device_num"
	echo "Vendor ID:     $vendor_id"
	echo "Product ID:    $product_id"

	if command -v lsusb > /dev/null 2>&1; then
		echo
		echo "Device Details:"
		lsusb -d "$vendor_id:$product_id" -v 2> /dev/null \
			| grep -E "^  \w|^\s+\w" \
			| sed 's/^  */  /'
	fi

	return 0
}

# Add USB device to VM
add_usb_device() {
	local name=$1
	local device_num=$2
	local temp=${3:-0}
	local map_file="${CONFIG[VM_DIR]}/.usb_map"
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	if ! validate_vm_name "$name" \
		|| ! [[ "$device_num" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ ! -f "$map_file" ]]; then
		log "$LOG_ERROR" "No USB device list found. Run 'usb list' first"
		return 1
	fi

	local device_id
	device_id=$(sed -n "${device_num}p" "$map_file" | cut -d: -f2,3)
	if [[ -z "$device_id" ]]; then
		log "$LOG_ERROR" "Invalid device number: $device_num"
		return 1
	fi

	local vendor_id="${device_id%:*}"
	local product_id="${device_id#*:}"

	if [[ "$temp" -eq 1 ]]; then
		if ! check_vm_running "$name"; then
			log "$LOG_ERROR" "VM must be running for temporary USB connection"
			return 1
		fi

		local monitor_socket="/tmp/qemu-monitor-${name}"
		if ! echo "device_add usb-host,vendorid=0x${vendor_id},productid=0x${product_id}" \
			| socat - "UNIX-CONNECT:$monitor_socket" 2> /dev/null; then
			log "$LOG_ERROR" "Failed to connect USB device"
			return 1
		fi

		log "$LOG_SUCCESS" "Temporarily connected USB device ${vendor_id}:${product_id}"
	else
		if check_vm_running "$name"; then
			log "$LOG_ERROR" "VM must be stopped for permanent USB configuration"
			return 1
		fi

		local current_devices
		current_devices=$(grep -c "^USB_DEVICE_" "$config_file" || echo "0")
		if ((current_devices >= CONFIG[MAX_USB_DEVICES])); then
			log "$LOG_ERROR" "Maximum number of USB devices reached"
			return 1
		fi

		local serial
		serial=$(get_device_serial "$vendor_id" "$product_id")

		store_usb_device_state "$name" "$vendor_id" "$product_id" "$serial"

		local temp_config
		temp_config=$(create_temp_file "config") || return 1

		cp "$config_file" "$temp_config" || return 1

		if ! grep -q "^USB_DEVICES=" "$temp_config"; then
			echo "USB_DEVICES=\"${vendor_id}:${product_id}${serial:+:$serial}\"" >> "$temp_config"
		else
			if grep -q "${vendor_id}:${product_id}" "$temp_config"; then
				log "$LOG_ERROR" "Device already configured"
				return 1
			fi
			sed -i "/^USB_DEVICES=/ s/\"$/, ${vendor_id}:${product_id}${serial:+:$serial}\"/" "$temp_config"
		fi

		mv "$temp_config" "$config_file" || return 1
		chmod "$SECURE_PERMISSIONS" "$config_file"

		log "$LOG_SUCCESS" "Added USB device ${vendor_id}:${product_id} to configuration"
		check_vm_running "$name" && log "$LOG_INFO" "Restart VM to apply changes"
	fi

	return 0
}

# Remove USB device from VM
remove_usb_device() {
	local name=$1
	local device_num=$2
	local map_file="${CONFIG[VM_DIR]}/.usb_map"
	local config_file="${CONFIG[VM_DIR]}/${name}/config"

	if ! validate_vm_name "$name" \
		|| ! [[ "$device_num" =~ ^[0-9]+$ ]]; then
		return 1
	fi

	if [[ ! -f "$map_file" ]]; then
		log "$LOG_ERROR" "No USB device list found. Run 'usb list' first"
		return 1
	fi

	local device_id
	device_id=$(sed -n "${device_num}p" "$map_file" | cut -d: -f2,3)
	if [[ -z "$device_id" ]]; then
		log "$LOG_ERROR" "Invalid device number: $device_num"
		return 1
	fi

	local vendor_id="${device_id%:*}"
	local product_id="${device_id#*:}"

	if check_vm_running "$name"; then
		local monitor_socket="/tmp/qemu-monitor-${name}"
		local device_list
		device_list=$(echo "info usb" | socat - "UNIX-CONNECT:$monitor_socket" 2> /dev/null)

		if echo "$device_list" | grep -q "vendor=0x${vendor_id},product=0x${product_id}"; then
			local qemu_id
			qemu_id=$(echo "$device_list" | grep "vendor=0x${vendor_id}" | awk '{print $1}')

			if ! echo "device_del $qemu_id" | socat - "UNIX-CONNECT:$monitor_socket" 2> /dev/null; then
				log "$LOG_ERROR" "Failed to remove USB device"
				return 1
			fi
			log "$LOG_SUCCESS" "Removed USB device from running VM"
		fi
	fi

	remove_usb_device_state "$name" "$vendor_id" "$product_id"

	if grep -q "${vendor_id}:${product_id}" "$config_file"; then
		local temp_config
		temp_config=$(create_temp_file "config") || return 1

		cp "$config_file" "$temp_config" || return 1

		sed -i "s/${vendor_id}:${product_id}[^,\"]*,\?//" "$temp_config"
		sed -i '/^USB_DEVICES=""/d' "$temp_config"
		sed -i 's/,"/"/g' "$temp_config"

		mv "$temp_config" "$config_file" || return 1
		chmod "$SECURE_PERMISSIONS" "$config_file"

		log "$LOG_SUCCESS" "Removed USB device from configuration"
	fi

	return 0
}

# Reconnect persistent USB devices
reconnect_usb_devices() {
	local name=$1
	local state_file="${CONFIG[VM_DIR]}/${name}/.usb_devices"
	local monitor_socket="/tmp/qemu-monitor-${name}"

	if ! check_vm_running "$name"; then
		return 0
	fi

	if [[ ! -f "$state_file" ]]; then
		return 0
	fi

	log "$LOG_INFO" "Reconnecting persistent USB devices..."

	while IFS=: read -r vendor_id product_id serial; do
		[[ -z "$vendor_id" ]] && continue

		if ! lsusb -d "${vendor_id}:${product_id}" > /dev/null 2>&1; then
			log "$LOG_WARN" "USB device ${vendor_id}:${product_id} not found"
			continue
		fi

		local connect_cmd="device_add usb-host,vendorid=0x${vendor_id},productid=0x${product_id}"
		[[ -n "$serial" ]] && connect_cmd+=",serial=$serial"

		if ! echo "$connect_cmd" | socat - "UNIX-CONNECT:$monitor_socket" 2> /dev/null; then
			log "$LOG_ERROR" "Failed to reconnect USB device ${vendor_id}:${product_id}"
			continue
		fi

		log "$LOG_SUCCESS" "Reconnected USB device ${vendor_id}:${product_id}"
	done < "$state_file"
}

#==============================================================================
# 7. MAIN PROGRAM EXECUTION
#==============================================================================

# Display help information
show_help() {
	cat << EOF
Qemate ${SCRIPT_VERSION} - QEMU Virtual Machine Manager
====================================================

A streamlined command-line tool for managing QEMU virtual machines.

Basic Usage:
    qemate COMMAND SUBCOMMAND [OPTIONS]
    qemate COMMAND help (show detailed help for a command)

Commands:
  VM Management:
    vm create NAME              Create a new virtual machine
    vm start NAME               Start a virtual machine
    vm stop NAME                Stop a running virtual machine
    vm remove NAME              Delete a virtual machine
    vm list                     Show all VMs and their status
    vm status NAME              Show detailed VM information

  Network Configuration:
    net set NAME                Configure network type (nat/none)
    net port add NAME           Add port forwarding rule
    net port remove NAME        Remove port forwarding
    net port list NAME          Show port forwarding rules

  Shared Folders:
    shared add NAME             Add a new shared folder (Linux/Windows)
    shared remove NAME          Remove a shared folder
    shared list NAME            Show configured shares

  USB Devices:
    usb add NAME                Add a USB device to VM
    usb remove NAME             Remove a USB device
    usb list                    List available USB devices
    usb query NUMBER            Show detailed device information

Use 'qemate COMMAND help' for detailed information about specific commands.
EOF
}

# Show detailed help for VM management commands
# VM-specific help with network options
show_vm_help() {
	cat << EOF
VM Management Commands
====================

CREATE:   qemate vm create NAME [--memory MB] [--cores N] [--disk SIZE]
START:    qemate vm start NAME [--iso PATH] [--headless]
STOP:     qemate vm stop NAME [--force]
REMOVE:   qemate vm remove NAME [--force]
LIST:     qemate vm list
STATUS:   qemate vm status NAME

Examples:
  qemate vm create ubuntu-server --memory 4096 --cores 4 --disk 40G
  qemate vm start ubuntu-server --iso ubuntu.iso
  qemate vm start ubuntu-server --headless
  qemate vm stop ubuntu-server --force
  qemate vm remove ubuntu-server --force
  qemate vm list
  qemate vm status ubuntu-server
EOF
}

# Show detailed help for network management commands
show_network_help() {
	cat << EOF
Network Management Commands
=========================

SET:          qemate net set NAME --type (nat|none)
PORT ADD:     qemate net port add NAME --host PORT --guest PORT [--proto (tcp|udp)]
PORT REMOVE:  qemate net port remove NAME --port PORT [--proto (tcp|udp)]
PORT LIST:    qemate net port list NAME

Examples:
  qemate net set ubuntu-server --type nat
  qemate net port add ubuntu-server --host 8080 --guest 80
  qemate net port remove ubuntu-server --port 8080
  qemate net port list ubuntu-server

NOTES:
  - NAT supports port forwarding; VM must be stopped to modify rules.
  - Host ports must be available; max ${CONFIG[MAX_PORTS_PER_VM]} forwards per VM.
EOF
}

# Show detailed help for shared folder commands
show_shared_help() {
	cat << EOF
Shared Folder Management Commands
===============================

ADD:    qemate shared add NAME --path PATH --name SHARE_NAME [--type (linux|windows)] [--readonly] [--uid UID] [--gid GID]
REMOVE: qemate shared remove NAME --name SHARE_NAME
LIST:   qemate shared list NAME

Examples:
  qemate shared add myvm --path /data --name shared --type linux
  qemate shared add myvm --path /data --name shared --type windows --readonly
  qemate shared remove myvm --name shared
  qemate shared list myvm

NOTES:
  - Max ${CONFIG[MAX_SHARES_PER_VM]} shares per VM
  - Linux: Supports UID/GID mapping, read-only mode (virtio-9p)
  - Windows: Requires QEMU guest agent, accessed as \\10.0.2.4\sharename (SMB)
  - VM must be stopped to modify shares
  - Paths must exist, be accessible, and have secure permissions
EOF
}

# Show detailed help for USB device commands
show_usb_help() {
	cat << EOF
USB Device Management Commands
============================

LIST:   qemate usb list
ADD:    qemate usb add NAME NUMBER [--temp]
REMOVE: qemate usb remove NAME NUMBER
QUERY:  qemate usb query NUMBER

Examples:
  qemate usb list
  qemate usb add ubuntu-vm 1
  qemate usb add ubuntu-vm 2 --temp
  qemate usb remove ubuntu-vm 1
  qemate usb query 1

NOTES:
  - Max ${CONFIG[MAX_USB_DEVICES]} devices per VM
  - Only external physical USB ports detected
  - Permanent devices persist after VM reboot; VM must be stopped to configure
  - Temporary devices require running VM; lost after shutdown
  - Devices identified by vendor/product IDs; hot-plug supported
EOF
}

# Main Command Parser
main() {
	local command=${1:-}

	if [[ -z "$command" ]]; then
		show_help
		exit 0
	fi

	shift

	case "$command" in
		vm)
			[[ $# -eq 0 || "$1" == "help" ]] && {
				show_vm_help
				exit 0
			}
			parse_vm_command "$@"
			;;
		net)
			[[ $# -eq 0 || "$1" == "help" ]] && {
				show_network_help
				exit 0
			}
			parse_net_command "$@"
			;;
		shared)
			[[ $# -eq 0 || "$1" == "help" ]] && {
				show_shared_help
				exit 0
			}
			parse_shared_command "$@"
			;;
		usb)
			[[ $# -eq 0 || "$1" == "help" ]] && {
				show_usb_help
				exit 0
			}
			parse_usb_command "$@"
			;;
		help)
			parse_help_command "${2:-}"
			;;
		version)
			echo "qemate version $SCRIPT_VERSION"
			;;
		*)
			echo "Unknown command: $command"
			show_help
			exit 1
			;;
	esac
}

# Execute main only if the script is run directly
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	# Set up signal traps
	trap 'interrupt_handler' INT TERM
	trap 'error_handler ${LINENO} $?' ERR
	trap 'cleanup_handler' EXIT

	# Execute main with all arguments
	main "$@"
fi
