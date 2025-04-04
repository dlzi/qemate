#!/bin/bash
################################################################################
# Qemate - QEMU Virtual Machine Manager                                        #
#                                                                              #
# Description: A streamlined command-line tool for managing QEMU virtual       #
#              machines with support for creation, control, and networking.    #
# Author: Daniel Zilli                                                         #
# Version: 1.1.1                                                               #
# License: BSD 3-Clause License                                                #
# Date: April 2025                                                             #
################################################################################

# Exit on error, undefined variable, or pipe failure
set -euo pipefail

###############################################################################
# INITIALIZATION AND CONFIGURATION
###############################################################################

# Script location determination - using safe path resolution
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || {
    echo "Error: Failed to determine script directory." >&2
    exit 1
}

# Version detection from file or fallback to hardcoded value
readonly VERSION=$([[ -r "${SCRIPT_DIR}/../VERSION" ]] && cat "${SCRIPT_DIR}/../VERSION" || echo "1.1.0")
[[ ! -r "${SCRIPT_DIR}/../VERSION" ]] && echo "Warning: VERSION file not found, using default ${VERSION}" >&2

# Load required library files
declare -a LIBRARIES=("qemate_utils.sh" "qemate_net.sh" "qemate_vm.sh")
for lib in "${LIBRARIES[@]}"; do
    lib_path="${SCRIPT_DIR}/lib/${lib}"
    # Check if library exists and is readable
    [[ ! -f "${lib_path}" || ! -r "${lib_path}" ]] && {
        echo "Error: Required library '${lib}' not found or not readable at ${lib_path}" >&2
        exit 1
    }
    # Source library with error handling
    source "${lib_path}" || {
        echo "Error: Failed to source ${lib}" >&2
        exit 1
    }
done

# Perform system requirement validation
check_system_requirements || {
    echo "Error: System requirements not met" >&2
    exit 1
}

# Set up signal handlers for clean termination
setup_signal_handlers

###############################################################################
# COMMAND DISPATCH TABLES
###############################################################################

# Main command dispatch table
declare -A COMMANDS=(
    [vm]="handle_vm"
    [net]="handle_net"
    [help]="show_main_help"
    [version]="show_version"
)

# VM subcommand dispatch table
declare -A VM_COMMANDS=(
    [create]="vm_create"
    [start]="vm_start"
    [stop]="vm_stop"
    [status]="vm_status"
    [delete]="vm_delete"
    [list]="vm_list"
    [wizard]="vm_wizard"
    [edit]="vm_edit"
)

# Network port subcommand dispatch table
declare -A NET_PORT_COMMANDS=(
    [list]="net_port_list"
    [add]="net_port_add"
    [remove]="net_port_remove"
)

# Network type command dispatch table
declare -A NET_TYPE_COMMANDS=(
    [set]="net_type_set"
)

# Network model command dispatch table
declare -A NET_MODEL_COMMANDS=(
    [model]="net_model_set"
)

###############################################################################
# HELP FUNCTIONS
###############################################################################

# Main help display function
show_main_help() {
    cat <<EOF
Qemate ${VERSION} - QEMU Virtual Machine Manager

Usage:
  qemate COMMAND [SUBCOMMAND] [OPTIONS]

Commands:
  vm        Manage virtual machines.
  net       Configure networking.
  help      Show this help or command-specific help.
  version   Show the program version.

Examples:
  qemate vm create myvm --memory 4G --cores 4
  qemate net port add myvm --host 8080 --guest 80

Run 'qemate COMMAND help' for more details.
EOF
}


# VM command help display
show_vm_help() {
    cat <<EOF
Qemate VM Command Help

Usage:
  qemate vm SUBCOMMAND [OPTIONS]

Subcommands:
  create NAME [--memory VALUE] [--cores VALUE] [--disk-size VALUE] [--machine VALUE] [--iso PATH]
  start  NAME_OR_ID [--iso PATH] [--headless] [--extra-args "QEMU_OPTIONS"]
  stop   NAME_OR_ID [--force]
  status NAME_OR_ID
  delete NAME_OR_ID [--force]
  list
  wizard
  edit   NAME_OR_ID

Options:
  --memory VALUE       Memory size in MB or GB (default 2048)
  --cores VALUE        CPU cores (default 2)
  --disk-size VALUE    Disk size in GB (default 20)
  --machine VALUE      QEMU machine type (optional)
  --iso PATH           Path to ISO file for installation
  --headless           Run without GUI for start
  --extra-args STRING  Extra QEMU options
  --force              Force stop or delete operation

Examples:
  qemate vm create myvm --memory 4096 --cores 4
  qemate vm start myvm --iso /path/to/install.iso --headless
  qemate vm start myvm --extra-args "-cpu host,+avx512"
EOF
}

# Network command help display
show_net_help() {
    cat <<EOF
Qemate Net Command Help

Usage:
  qemate net SUBCOMMAND [OPTIONS]

Subcommands:
  port                Configure port forwards (VM must be stopped)
    add     NAME_OR_ID         Add a port forward
    remove  NAME_OR_ID PORT[:PROTO]  Remove a port forward
    list    NAME_OR_ID         List all port forwards

  set     NAME_OR_ID {nat|user|none}     Set the network type
  model   NAME_OR_ID [{e1000|virtio-net-pci}]  Set the network device model

Options:
  --host PORT         Host port to forward
  --guest PORT        Guest port to map to
  --proto PROTO       Protocol (default tcp)

Examples:
  qemate net port add myvm --host 8080 --guest 80
  qemate net set myvm nat
  qemate net model myvm virtio-net-pci
EOF
}


# Network port help display
show_net_port_help() {
    cat <<EOF
Qemate Net Port Command Help

Usage:
  qemate net port SUBCOMMAND [OPTIONS]

Description:
  Manage port forwards for a VM (VM must be stopped)

Subcommands:
  add     NAME_OR_ID         Add a port forward
  remove  NAME_OR_ID PORT[:PROTO]  Remove a port forward
  list    NAME_OR_ID         List all port forwards

Options:
  --host PORT         Host port to forward
  --guest PORT        Guest port to map to
  --proto PROTO       Protocol (default tcp)
EOF
}


# Network set help display
show_net_set_help() {
    cat <<EOF
Qemate Net Set Command Help

Usage:
  qemate net set NAME_OR_ID {nat|user|none}

Description:
  Set the network type for a VM

Options:
  NAME_OR_ID         The name or ID of the VM
  {nat|user|none}    Network type (default: user)
EOF
}


# Network model help display
show_net_model_help() {
    cat <<EOF
Qemate Net Model Command Help

Usage:
  qemate net model NAME_OR_ID [{e1000|virtio-net-pci}]

Description:
  Set the network device model for a VM

Options:
  NAME_OR_ID               The name or ID of the VM
  {e1000|virtio-net-pci}   Network model (default: virtio-net-pci)
EOF
}

###############################################################################
# COMMAND HANDLERS
###############################################################################

# Display version information and exit
show_version() {
    printf "Qemate %s\n" "${VERSION}"
    exit 0
}

# Handle VM commands
handle_vm() {
    # Display help if no arguments or help requested
    [[ $# -eq 0 || "$1" == "help" ]] && {
        show_vm_help
        exit 0
    }
    
    local subcommand="$1"
    shift
    
    # Validate command arguments before execution
    validate_arguments "vm" "${subcommand}" "$@" || exit 1
    
    # Dispatch to appropriate VM handler function
    dispatch "VM_COMMANDS" "${subcommand}" "$@" || {
        log_message "ERROR" "Failed to execute vm ${subcommand}"
        exit 1
    }
}

# Handle networking commands
handle_net() {
    # Display help if no arguments or help requested
    [[ $# -eq 0 || "$1" == "help" ]] && {
        show_net_help
        exit 0
    }
    
    local subcommand="$1"
    shift
    
    # Route to appropriate networking subcommand handler
    case "${subcommand}" in
        port) handle_net_port "$@" ;;
        set) handle_net_set "$@" ;;
        model) handle_net_model "$@" ;;
        *)
            log_message "ERROR" "Unknown net subcommand: ${subcommand}"
            show_net_help
            exit 1
            ;;
    esac
}

# Handle networking port commands
handle_net_port() {
    # Display help if no arguments or help requested
    [[ $# -eq 0 || "$1" == "help" ]] && {
        show_net_port_help
        exit 0
    }
    
    local subcommand="$1"
    shift
    
    # Validate command arguments before execution
    validate_arguments "net_port" "${subcommand}" "$@" || exit 1
    
    # Dispatch to appropriate port handler function
    dispatch "NET_PORT_COMMANDS" "${subcommand}" "$@" || {
        log_message "ERROR" "Failed to execute net port ${subcommand}"
        exit 1
    }
}

# Handle network type setting
handle_net_set() {
    # Display help if no arguments or help requested
    [[ $# -eq 0 || "$1" == "help" ]] && {
        show_net_set_help
        exit 0
    }
    
    # Validate command arguments before execution
    validate_arguments "net_set" "set" "$@" || exit 1
    
    # Dispatch to network type set function
    dispatch "NET_TYPE_COMMANDS" "set" "$@" || {
        log_message "ERROR" "Failed to set network type"
        exit 1
    }
}

# Handle network model setting
handle_net_model() {
    # Display help if no arguments or help requested
    [[ $# -eq 0 || "$1" == "help" ]] && {
        show_net_model_help
        exit 0
    }
    
    # Validate command arguments before execution
    validate_arguments "net_model" "model" "$@" || exit 1
    
    # Dispatch to network model set function
    dispatch "NET_MODEL_COMMANDS" "model" "$@" || {
        log_message "ERROR" "Failed to set network model"
        exit 1
    }
}

###############################################################################
# MAIN FUNCTION
###############################################################################

# Main entry point for the script
main() {
    # Load VM cache for faster operation
    cache_vms
    
    # Get the command or default to empty
    local cmd="${1:-}"
    shift || true
    
    # Display help if no command provided
    [[ -z "${cmd}" ]] && {
        show_main_help
        exit 0
    }
    
    # Check if command exists
    [[ -z "${COMMANDS[${cmd}]+x}" ]] && {
        log_message "ERROR" "Unknown command: ${cmd}"
        show_main_help
        exit 1
    }
    
    # Dispatch to appropriate command handler
    "${COMMANDS[${cmd}]}" "$@"
}

# Execute the main function with all script arguments
main "$@"