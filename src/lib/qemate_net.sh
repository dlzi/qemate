#!/bin/bash
################################################################################
# Qemate Network Module                                                        #
#                                                                              #
# Description: Networking functions for QEMU VMs in Qemate.                    #
# Author: Daniel Zilli                                                         #
# Version: 1.1.1                                                               #
# License: BSD 3-Clause License                                                #
# Date: March 2025                                                             #
################################################################################

################################################################################
# INITIALIZATION                                                               #
################################################################################

# Ensure SCRIPT_DIR is set by the parent script
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    echo "Error: SCRIPT_DIR not set." >&2
    exit 1
fi

# Network constants
readonly VALID_NETWORK_TYPES=("nat" "user" "none")
readonly VALID_NETWORK_MODELS=("e1000" "virtio-net-pci")

################################################################################
# NETWORK CONFIGURATION FUNCTIONS                                              #
################################################################################

#######################################
# Builds network command-line arguments for QEMU
# Arguments:
#   $1: VM name
# Outputs:
#   QEMU network arguments (to stdout)
# Returns:
#   0 on success, 1 on failure
#######################################
build_network_args() {
    local name="$1"
    local config_file="${VM_DIR}/${name}/config"
    
    # Validate VM exists
    validate_vm_identifier "$name" "build_network_args" || return 1
    
    # Check config file exists
    if [[ ! -f "$config_file" ]]; then
        log_message "ERROR" "Config file for '${name}' not found."
        return 1
    fi
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to source config for '${name}'."
        return 1
    fi

    # Prepare network arguments
    local net_type="${NETWORK_TYPE:-user}" 
    local args=()
    
    case "$net_type" in
        nat | user)
            local netdev_arg="user,id=net0"
            
            # Add port forwarding if enabled
            if [[ "$net_type" == "nat" && "${PORT_FORWARDING_ENABLED:-0}" -eq 1 && -n "${PORT_FORWARDS:-}" ]]; then
                local forwards=""
                while IFS=':' read -r host guest proto; do
                    [[ -z "$host" ]] && continue
                    forwards+=",hostfwd=${proto:-tcp}::${host}-:${guest}"
                done < <(echo "${PORT_FORWARDS}" | tr ',' '\n')
                netdev_arg+="$forwards"
            fi
            
            # Add network device arguments
            args+=("-netdev" "$netdev_arg" "-device" "${NETWORK_MODEL:-virtio-net-pci},netdev=net0,mac=${MAC_ADDRESS:-$(generate_mac)}")
            ;;
        none)
            # No network device needed
            return 0
            ;;
        *)
            log_message "ERROR" "Unsupported network type: ${net_type}."
            return 1
            ;;
    esac
    
    # Output arguments
    printf '%s\n' "${args[@]}"
}

#######################################
# Sets the network type for a VM
# Arguments:
#   $1: VM name or ID
#   $2: Network type (nat, user, none)
# Returns:
#   0 on success, 1 on failure
#######################################
net_type_set() {
    local name_or_id="$1" 
    local net_type="$2"
    local vm_name
    
    # Get VM name from ID if needed
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: ${name_or_id}."
        return 1
    }
    
    # Validate VM identifier
    validate_vm_identifier "$vm_name" "net_type_set" || return 1

    # Check for required arguments
    if [[ -z "$net_type" ]]; then
        log_message "ERROR" "Network type required (nat, user, none)."
        return 1
    fi
    
    # Validate network type
    local valid=0
    for type in "${VALID_NETWORK_TYPES[@]}"; do
        if [[ "$net_type" == "$type" ]]; then
            valid=1
            break
        fi
    done
    
    if [[ "$valid" -eq 0 ]]; then
        log_message "ERROR" "Invalid network type: ${net_type} (use nat, user, none)."
        return 1
    fi

    local config_file="${VM_DIR}/${vm_name}/config"
    
    # Check if VM is running
    if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" >/dev/null; then
        log_message "ERROR" "Cannot modify network type while VM '${vm_name}' is running."
        return 1
    fi
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to read config for '${vm_name}'."
        return 1
    fi

    # Define update function for with_config_file
    update_net_type() {
        local temp_config="$1"
        if grep -q "^NETWORK_TYPE=" "$temp_config"; then
            sed -i "s/^NETWORK_TYPE=.*/NETWORK_TYPE=\"${net_type}\"/" "$temp_config"
        else
            echo "NETWORK_TYPE=\"${net_type}\"" >>"$temp_config"
        fi
    }
    
    # Update configuration
    with_config_file "$config_file" update_net_type || return 1
    log_message "SUCCESS" "Set network type for '${vm_name}' to '${net_type}'."
}

#######################################
# Sets the network model for a VM
# Arguments:
#   $1: VM name or ID
#   $2: Network model (e1000, virtio-net-pci)
# Returns:
#   0 on success, 1 on failure
#######################################
net_model_set() {
    local name_or_id="$1" 
    local net_model="${2:-virtio-net-pci}"
    local vm_name
    
    # Get VM name from ID if needed
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: ${name_or_id}."
        return 1
    }
    
    # Validate VM identifier
    validate_vm_identifier "$vm_name" "net_model_set" || return 1

    # Validate network model
    local valid=0
    for model in "${VALID_NETWORK_MODELS[@]}"; do
        if [[ "$net_model" == "$model" ]]; then
            valid=1
            break
        fi
    done
    
    if [[ "$valid" -eq 0 ]]; then
        log_message "ERROR" "Invalid network model: ${net_model} (use e1000, virtio-net-pci)."
        return 1
    fi

    local config_file="${VM_DIR}/${vm_name}/config"
    
    # Check if VM is running
    if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" >/dev/null; then
        log_message "ERROR" "Cannot modify network model while VM '${vm_name}' is running."
        return 1
    fi
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to read config for '${vm_name}'."
        return 1
    fi

    # Define update function for with_config_file
    update_net_model() {
        local temp_config="$1"
        if grep -q "^NETWORK_MODEL=" "$temp_config"; then
            sed -i "s/^NETWORK_MODEL=.*/NETWORK_MODEL=\"${net_model}\"/" "$temp_config"
        else
            echo "NETWORK_MODEL=\"${net_model}\"" >>"$temp_config"
        fi
    }
    
    # Update configuration
    with_config_file "$config_file" update_net_model || return 1
    log_message "SUCCESS" "Set network model for '${vm_name}' to '${net_model}'."
}

################################################################################
# PORT FORWARDING MANAGEMENT FUNCTIONS                                         #
################################################################################

#######################################
# Lists port forwards for a VM
# Arguments:
#   $1: VM name or ID
# Returns:
#   0 on success, 1 on failure
#######################################
net_port_list() {
    local name_or_id="$1"
    local vm_name
    
    # Validate VM identifier
    validate_vm_identifier "$name_or_id" "net_port_list" || return 1
    
    # Get VM name from ID if needed
    if [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
        vm_name=$(get_vm_info "name_from_id" "$name_or_id") || {
            log_message "ERROR" "Failed to resolve ID '${name_or_id}' to a VM name."
            return 1
        }
    else
        vm_name="$name_or_id"
    fi

    local config_file="${VM_DIR}/${vm_name}/config"
    
    # Clear any existing variables
    unset PORT_FORWARDING_ENABLED PORT_FORWARDS
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to read config for '${vm_name}'."
        return 1
    fi
    
    # Check network type supports port forwarding
    if [[ "${NETWORK_TYPE:-user}" != "user" && "${NETWORK_TYPE:-user}" != "nat" ]]; then
        log_message "ERROR" "VM '${vm_name}' not configured for 'user' or 'nat' networking."
        return 1
    fi

    # Display port forwards
    printf "Port Forwards for VM '%s':\n" "$vm_name"
    printf "=======================================\n"
    printf "%-15s %-15s %-10s\n" "HOST PORT" "GUEST PORT" "PROTOCOL"
    printf -- "---------------------------------------\n"
    
    if [[ "${PORT_FORWARDING_ENABLED:-0}" -eq 1 && -n "${PORT_FORWARDS:-}" ]]; then
        echo "${PORT_FORWARDS}" | tr ',' '\n' | while IFS=':' read -r host guest proto; do
            [[ -z "$host" ]] && continue
            printf "%-15s %-15s %-10s\n" "$host" "$guest" "${proto:-tcp}"
        done
    else
        printf "No port forwards configured.\n"
    fi
}

#######################################
# Adds a port forward to a VM
# Arguments:
#   $1: VM name or ID
#   Additional arguments:
#     --host HOST_PORT: Port on host to forward
#     --guest GUEST_PORT: Port on guest to receive traffic
#     --proto PROTOCOL: Protocol (tcp/udp)
# Returns:
#   0 on success, 1 on failure
#######################################
net_port_add() {
    local name_or_id="$1" host="" guest="" proto="tcp"
    shift
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                host="$2"
                shift 2
                ;;
            --guest)
                guest="$2"
                shift 2
                ;;
            --proto)
                proto="$2"
                shift 2
                ;;
            *)
                log_message "ERROR" "Unknown option for 'port add': $1."
                return 1
                ;;
        esac
    done

    # Validate arguments
    if [[ -z "$host" || -z "$guest" ]]; then
        log_message "ERROR" "Both --host and --guest ports are required."
        return 1
    fi
    
    if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
        log_message "ERROR" "Invalid protocol: ${proto} (use tcp or udp)."
        return 1
    fi
    
    if [[ ! "$host" =~ ^[0-9]+$ || ! "$guest" =~ ^[0-9]+$ || 
          "$host" -lt 1 || "$host" -gt 65535 || 
          "$guest" -lt 1 || "$guest" -gt 65535 ]]; then
        log_message "ERROR" "Ports must be numeric and between 1-65535."
        return 1
    fi

    local vm_name
    
    # Get VM name from ID if needed
    vm_name=$(get_vm_info "name_from_id" "$name_or_id" 2>/dev/null || echo "$name_or_id") || {
        log_message "ERROR" "No VM found: ${name_or_id}."
        return 1
    }
    
    # Validate VM identifier
    validate_vm_identifier "$vm_name" "net_port_add" || return 1

    local config_file="${VM_DIR}/${vm_name}/config"
    
    # Check if VM is running
    if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" >/dev/null; then
        log_message "ERROR" "Cannot modify ports while VM '${vm_name}' is running."
        return 1
    fi
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to read config for '${vm_name}'."
        return 1
    fi
    
    # Check network type supports port forwarding
    if [[ "${NETWORK_TYPE:-user}" != "user" && "${NETWORK_TYPE:-user}" != "nat" ]]; then
        log_message "ERROR" "Port forwarding requires 'user' or 'nat' network type."
        return 1
    fi

    # Check for port conflicts
    if [[ -n "${PORT_FORWARDS:-}" ]]; then
        while IFS=':' read -r existing_host existing_guest existing_proto; do
            [[ -z "$existing_host" ]] && continue
            if [[ "$existing_host" == "$host" && "${existing_proto:-tcp}" == "$proto" ]]; then
                log_message "ERROR" "Port forward ${host} (${proto}) already exists."
                return 1
            fi
            if [[ "$existing_guest" == "$guest" && "${existing_proto:-tcp}" == "$proto" ]]; then
                log_message "ERROR" "Guest port ${guest} (${proto}) already in use."
                return 1
            fi
        done < <(echo "${PORT_FORWARDS}" | tr ',' '\n')
    fi

    # Define update function for with_config_file
    update_port_add() {
        local temp_config="$1"
        if grep -q "^PORT_FORWARDING_ENABLED=" "$temp_config"; then
            sed -i "s/^PORT_FORWARDING_ENABLED=.*/PORT_FORWARDING_ENABLED=1/" "$temp_config"
        else
            echo "PORT_FORWARDING_ENABLED=1" >>"$temp_config"
        fi
        if grep -q "^PORT_FORWARDS=" "$temp_config"; then
            sed -i "/^PORT_FORWARDS=/ s/\"$/,${host}:${guest}:${proto}\"/" "$temp_config"
        else
            echo "PORT_FORWARDS=\"${host}:${guest}:${proto}\"" >>"$temp_config"
        fi
    }
    
    # Update configuration
    with_config_file "$config_file" update_port_add || return 1
    log_message "SUCCESS" "Added port forward for '${vm_name}': ${host} -> ${guest} (${proto})."
}

#######################################
# Removes a port forward from a VM
# Arguments:
#   $1: VM name or ID
#   $2: Port specification (e.g., 8080 or 8080:tcp)
# Returns:
#   0 on success, 1 on failure
#######################################
net_port_remove() {
    local name_or_id="$1" port_spec="$2"
    local vm_name
    
    # Validate VM identifier
    validate_vm_identifier "$name_or_id" "net_port_list" || return 1
    
    # Get VM name from ID if needed
    if [[ "$name_or_id" =~ ^[0-9]+$ ]]; then
        vm_name=$(get_vm_info "name_from_id" "$name_or_id") || {
            log_message "ERROR" "Failed to resolve ID '${name_or_id}' to a VM name."
            return 1
        }
    else
        vm_name="$name_or_id"
    fi

    # Check for required port specification
    if [[ -z "$port_spec" ]]; then
        log_message "ERROR" "Port specification (e.g., 8080 or 8080:proto) required."
        return 1
    fi
    
    # Parse port and protocol
    local port proto="tcp"
    if [[ "$port_spec" =~ : ]]; then
        IFS=':' read -r port proto <<<"$port_spec"
    else
        port="$port_spec"
    fi
    
    # Validate port and protocol
    if [[ ! "$port" =~ ^[0-9]+$ || "$port" -lt 1 || "$port" -gt 65535 ]]; then
        log_message "ERROR" "Port must be numeric and between 1-65535."
        return 1
    fi
    
    if [[ ! "$proto" =~ ^(tcp|udp)$ ]]; then
        log_message "ERROR" "Invalid protocol: ${proto} (use tcp or udp)."
        return 1
    fi

    local config_file="${VM_DIR}/${vm_name}/config"
    
    # Check if VM is running
    if pgrep -f "guest=${vm_name},process=qemu-${vm_name}" >/dev/null; then
        log_message "ERROR" "Cannot modify ports while VM '${vm_name}' is running."
        return 1
    fi
    
    # Source VM configuration
    if ! source "$config_file"; then
        log_message "ERROR" "Failed to read config for '${vm_name}'."
        return 1
    fi
    
    # Check network type supports port forwarding
    if [[ "${NETWORK_TYPE:-user}" != "user" && "${NETWORK_TYPE:-user}" != "nat" ]]; then
        log_message "ERROR" "Port forwarding requires 'user' or 'nat' network type."
        return 1
    fi
    
    # Check if port forwarding is enabled
    if [[ "${PORT_FORWARDING_ENABLED:-0}" -ne 1 || -z "${PORT_FORWARDS:-}" ]]; then
        log_message "ERROR" "No port forwards configured for '${vm_name}'."
        return 1
    fi

    # Scan for matching ports
    local new_forwards="" found=0 match_type="" ambiguous=0 temp_forwards=""
    while IFS=':' read -r host guest existing_proto; do
        [[ -z "$host" ]] && continue
        local proto_match=$([[ "${existing_proto:-tcp}" == "$proto" ]] && echo 1 || echo 0)
        
        if [[ "$host" == "$port" && "$proto_match" -eq 1 ]]; then
            found=1
            match_type="host"
        elif [[ "$guest" == "$port" && "$proto_match" -eq 1 ]]; then
            found=1
            match_type="guest"
        elif [[ "$host" == "$port" || "$guest" == "$port" ]] && [[ "$proto_match" -eq 0 ]]; then
            ambiguous=1
            temp_forwards+="${host}:${guest}:${existing_proto:-tcp},"
        else
            [[ -n "$new_forwards" ]] && new_forwards+=","
            new_forwards+="${host}:${guest}:${existing_proto:-tcp}"
        fi
    done < <(echo "${PORT_FORWARDS}" | tr ',' '\n')

    # Handle port match outcomes
    if [[ "$found" -eq 0 && "$ambiguous" -eq 1 ]]; then
        log_message "ERROR" "Port ${port} matches multiple protocols (tcp/udp). Specify with ${port}:proto."
        return 1
    elif [[ "$found" -eq 0 ]]; then
        log_message "ERROR" "Port forward ${port} (${proto}) not found in host or guest mappings."
        return 1
    fi

    # Rebuild port forwards list excluding the matched entry
    new_forwards=""
    while IFS=':' read -r host guest existing_proto; do
        [[ -z "$host" ]] && continue
        local proto_match=$([[ "${existing_proto:-tcp}" == "$proto" ]] && echo 1 || echo 0)
        
        if [[ "$match_type" == "host" && "$host" == "$port" && "$proto_match" -eq 1 ]] || \
           [[ "$match_type" == "guest" && "$guest" == "$port" && "$proto_match" -eq 1 ]]; then
            continue
        fi
        
        [[ -n "$new_forwards" ]] && new_forwards+=","
        new_forwards+="${host}:${guest}:${existing_proto:-tcp}"
    done < <(echo "${PORT_FORWARDS}" | tr ',' '\n')

    # Define update function for with_config_file
    update_port_remove() {
        local temp_config="$1"
        if [[ -z "$new_forwards" ]]; then
            sed -i "s/^PORT_FORWARDING_ENABLED=.*/PORT_FORWARDING_ENABLED=0/" "$temp_config"
            sed -i "s/^PORT_FORWARDS=.*/PORT_FORWARDS=\"\"/" "$temp_config"
        else
            sed -i "s/^PORT_FORWARDS=.*/PORT_FORWARDS=\"${new_forwards}\"/" "$temp_config"
        fi
    }
    
    # Update configuration
    with_config_file "$config_file" update_port_remove || return 1
    log_message "SUCCESS" "Removed port forward for '${vm_name}': ${port} (${proto}) from ${match_type} port."
}