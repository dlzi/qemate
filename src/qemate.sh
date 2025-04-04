#!/bin/bash
################################################################################
# Qemate - QEMU Virtual Machine Manager                                        #
#                                                                              #
# Description: A streamlined command-line tool for managing QEMU virtual       #
#              machines with support for creation, control, and networking.    #
# Author: Daniel Zilli                                                         #
# Version: 1.1.0                                                               #
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
    printf "%bQemate %s - QEMU Virtual Machine Manager%b\n\n" "${COLOR_INFO}" "${VERSION}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate COMMAND [SUBCOMMAND] [OPTIONS]\n\n"
    printf "%bCommands:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %bvm%b      Manage virtual machines.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %bnet%b     Configure networking.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %bhelp%b    Show this help or command-specific help.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %bversion%b Show the program version.\n\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "%bExamples:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate vm create myvm --memory 4G --cores 4\n"
    printf "  qemate net port add myvm --host 8080 --guest 80\n\n"
    printf "Run '%bqemate COMMAND help%b' for more details.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
}

# VM command help display
show_vm_help() {
    printf "%bQemate VM Command Help%b\n\n" "${COLOR_INFO}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate vm SUBCOMMAND [OPTIONS]\n\n"
    printf "%bSubcommands:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "create" "${COLOR_RESET}" "NAME [OPTIONS]" "Create a new VM."
    printf "    %bOptions:%b --memory VALUE, --cores VALUE, --disk-size VALUE, --machine VALUE, --iso PATH\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "start" "${COLOR_RESET}" "NAME_OR_ID [OPTIONS]" "Start an existing VM."
    printf "    %bOptions:%b --iso PATH, --headless, --extra-args \"QEMU_OPTIONS\"\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "stop" "${COLOR_RESET}" "NAME_OR_ID [--force]" "Stop a running VM."
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "status" "${COLOR_RESET}" "NAME_OR_ID" "Display VM status."
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "delete" "${COLOR_RESET}" "NAME_OR_ID [--force]" "Delete a VM."
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "list" "${COLOR_RESET}" "" "List all VMs."
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "wizard" "${COLOR_RESET}" "" "Interactive VM creation."
    printf "  %b%-10s%b %-25s %s\n" "${COLOR_SUCCESS}" "edit" "${COLOR_RESET}" "NAME_OR_ID" "Edit VM configuration."
    printf "\n%bExamples:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %-45s %s\n" "qemate vm create myvm --memory 4G --cores 4" "Create a VM with custom settings."
    printf "  %-45s %s\n" "qemate vm start myvm --iso /path/to/install.iso --headless" "Start VM in headless mode."
    printf "  %-45s %s\n" "qemate vm start myvm --extra-args \"-cpu host,+avx512\"" "Start VM with custom QEMU args."
}

# Network command help display
show_net_help() {
    printf "%bQemate Net Command Help%b\n\n" "${COLOR_INFO}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate net SUBCOMMAND [OPTIONS]\n\n"
    printf "%bSubcommands:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %bport%b    Configure port forwards (VM must be stopped).\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "    %bSubcommands:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "      %badd%b     NAME_OR_ID         Add a port forward.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "        %bOptions:%b --host PORT, --guest PORT, --proto PROTO\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "      %bremove%b  NAME_OR_ID PORT[:PROTO]  Remove a port forward.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "      %blist%b    NAME_OR_ID         List all port forwards.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %bset%b     NAME_OR_ID {nat|user|none}  Set the network type.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %bmodel%b   NAME_OR_ID [{e1000|virtio-net-pci}]  Set the network device model.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "\n%bExamples:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate net port add myvm --host 8080 --guest 80    Add a port forward.\n"
    printf "  qemate net set myvm nat                            Set network type to NAT.\n"
    printf "  qemate net model myvm virtio-net-pci               Set network model to virtio.\n"
}

# Network port help display
show_net_port_help() {
    printf "%bQemate Net Port Command Help%b\n\n" "${COLOR_INFO}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate net port SUBCOMMAND [OPTIONS]\n\n"
    printf "%bDescription:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  Manage port forwards for a VM (VM must be stopped).\n\n"
    printf "%bSubcommands:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %badd%b     NAME_OR_ID         Add a port forward.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "    %bOptions:%b --host PORT, --guest PORT, --proto PROTO\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  %bremove%b  NAME_OR_ID PORT[:PROTO]  Remove a port forward.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
    printf "  %blist%b    NAME_OR_ID         List all port forwards.\n" "${COLOR_SUCCESS}" "${COLOR_RESET}"
}

# Network set help display
show_net_set_help() {
    printf "%bQemate Net Set Command Help%b\n\n" "${COLOR_INFO}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate net set NAME_OR_ID {nat|user|none}\n\n"
    printf "%bDescription:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  Set the network type for a VM.\n\n"
    printf "%bOptions:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  NAME_OR_ID         The name or ID of the VM.\n"
    printf "  {nat|user|none}    Network type (default: user).\n"
}

# Network model help display
show_net_model_help() {
    printf "%bQemate Net Model Command Help%b\n\n" "${COLOR_INFO}" "${COLOR_RESET}"
    printf "%bUsage:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  qemate net model NAME_OR_ID [{e1000|virtio-net-pci}]\n\n"
    printf "%bDescription:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  Set the network device model for a VM.\n\n"
    printf "%bOptions:%b\n" "${COLOR_WARNING}" "${COLOR_RESET}"
    printf "  NAME_OR_ID             The name or ID of the VM.\n"
    printf "  [{e1000|virtio-net-pci}]  Network model (default: virtio-net-pci).\n"
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