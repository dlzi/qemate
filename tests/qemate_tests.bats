#!/usr/bin/env bats

setup() {
  export QEMATE_TEST_MODE=1
  export HOME="$BATS_TMPDIR/home"
  export VM_DIR="$HOME/QVMs"
  export LOG_DIR="$HOME/QVMs/logs"
  export TEMP_DIR="$HOME/QVMs/tmp"

  rm -rf "$HOME" "$BATS_TEST_DIRNAME/mocks" 2>/dev/null
  mkdir -p "$VM_DIR" "$LOG_DIR" "$TEMP_DIR"
  mkdir -p "$BATS_TEST_DIRNAME/mocks"

  # Mock qemu-system-x86_64
  cat << 'EOF' > "$BATS_TEST_DIRNAME/mocks/qemu-system-x86_64"
#!/bin/bash
echo "qemu-system-x86_64 mock called with $@"
vm_name=$(echo "$@" | grep -o "guest=[^,]*" | cut -d"=" -f2)
[[ -n "$vm_name" ]] || vm_name="testvm"
mkdir -p "$TEMP_DIR/qemu-$vm_name.lock"
echo $$ > "$TEMP_DIR/qemu-$vm_name.lock/pid"
touch "$TEMP_DIR/qemu_running_$vm_name"
touch "$TEMP_DIR/qemu-$vm_name.started"
mkdir -p "$VM_DIR/$vm_name"
cat << 'CONFIG' > "$VM_DIR/$vm_name/config"
ID=1
NAME="$vm_name"
MACHINE_TYPE="q35"
CORES=2
MEMORY="2G"
CPU_TYPE="host"
ENABLE_KVM=1
NETWORK_TYPE="user"
NETWORK_MODEL="virtio-net-pci"
MAC_ADDRESS="52:54:00:12:34:56"
QEMU_ARGS="-machine type=q35,accel=kvm -cpu host,migratable=off -smp cores=2,threads=1 -m 2G"
CONFIG
chmod 600 "$VM_DIR/$vm_name/config"
echo "virtual size: 20G" > "$VM_DIR/$vm_name/disk.qcow2.info"
exit 0
EOF
  chmod +x "$BATS_TEST_DIRNAME/mocks/qemu-system-x86_64"

  # Mock pgrep
  cat << 'EOF' > "$BATS_TEST_DIRNAME/mocks/pgrep"
#!/bin/bash
if [[ "$1" == "-f" ]]; then
  pattern="$2"
  vm_name=$(echo "$pattern" | grep -o "guest=[^,]*" | cut -d"=" -f2)
  [[ -n "$vm_name" ]] || vm_name="testvm"
  if [[ -f "$TEMP_DIR/qemu_running_$vm_name" ]]; then
    echo 1234
    exit 0
  else
    exit 1
  fi
fi
EOF
  chmod +x "$BATS_TEST_DIRNAME/mocks/pgrep"

  # Mock qemu-img
  cat << 'EOF' > "$BATS_TEST_DIRNAME/mocks/qemu-img"
#!/bin/bash
if [[ "$1" == "create" ]]; then
  touch "$4"
  exit 0
elif [[ "$1" == "check" ]]; then
  exit 0
elif [[ "$1" == "info" ]]; then
  echo "virtual size: 20G (21474836480 bytes)"
  echo "disk size: 196K"
  exit 0
fi
EOF
  chmod +x "$BATS_TEST_DIRNAME/mocks/qemu-img"

  # Mock ss
  cat << 'EOF' > "$BATS_TEST_DIRNAME/mocks/ss"
#!/bin/bash
exit 0
EOF
  chmod +x "$BATS_TEST_DIRNAME/mocks/ss"

  # Mock xset
  cat << 'EOF' > "$BATS_TEST_DIRNAME/mocks/xset"
#!/bin/bash
exit 1
EOF
  chmod +x "$BATS_TEST_DIRNAME/mocks/xset"

  function kill() {
    local signal="$1"
    local pid="$2"
    if [[ "$signal" == "-0" ]]; then
      [ -f "$TEMP_DIR/qemu_running_testvm" ] && return 0 || return 1
    else
      echo "Mock kill called with $@" >&2
      rm -f "$TEMP_DIR/qemu_running_testvm"
      return 0
    fi
  }
  export -f kill

  export PATH="$BATS_TEST_DIRNAME/mocks:$PATH"
  export SCRIPT_DIR="$BATS_TEST_DIRNAME/.."
  export LIB_DIR="$SCRIPT_DIR/src/lib"
}

teardown() {
  unset QEMATE_TEST_MODE HOME VM_DIR LOG_DIR TEMP_DIR SCRIPT_DIR LIB_DIR
  rm -rf "$BATS_TEST_DIRNAME/mocks" "$HOME"
}

load_utils() {
  for file in "$LIB_DIR/qemate_utils.sh" "$LIB_DIR/qemate_net.sh" "$LIB_DIR/qemate_vm.sh"; do
    [ -f "$file" ] || { echo "Error: $file not found" >&2; exit 1; }
    source "$file"
  done
}

@test "vm_create creates a VM with default settings" {
  load_utils
  run vm_create "testvm"
  [ "$status" -eq 0 ]
  [ -d "$VM_DIR/testvm" ]
  [ -f "$VM_DIR/testvm/config" ]
  [ -f "$VM_DIR/testvm/disk.qcow2" ]
  grep -q "MACHINE_TYPE=\"q35\"" "$VM_DIR/testvm/config"
  grep -q "CORES=2" "$VM_DIR/testvm/config"
  grep -q "MEMORY=\"2G\"" "$VM_DIR/testvm/config"
}

@test "vm_create fails with invalid name" {
  load_utils
  run vm_create "invalid;name"
  [ "$status" -eq 1 ]
  [ ! -d "$VM_DIR/invalid;name" ]
  [[ "$output" =~ "Invalid VM name" ]]
}

@test "vm_create with custom options" {
  load_utils
  run vm_create "testvm" --memory 4G --cores 4 --disk-size 40G
  [ "$status" -eq 0 ]
  [ -d "$VM_DIR/testvm" ]
  [ -f "$VM_DIR/testvm/disk.qcow2" ]
  grep -q "MEMORY=\"4G\"" "$VM_DIR/testvm/config"
  grep -q "CORES=4" "$VM_DIR/testvm/config"
}

@test "vm_start starts a VM" {
  load_utils
  vm_create "testvm"
  run vm_start "testvm" --headless
  echo "Output: $output" >&2
  [ "$status" -eq 0 ]
  [ -f "$TEMP_DIR/qemu-testvm.started" ]
  [ -f "$TEMP_DIR/qemu-testvm.lock/pid" ]
  run pgrep -f "guest=testvm,process=qemu-testvm"
  [ "$status" -eq 0 ]
  [[ "$output" =~ 1234 ]]
}

@test "vm_start fails if VM already running" {
  load_utils
  vm_create "testvm"
  vm_start "testvm" --headless
  run vm_start "testvm" --headless
  [ "$status" -eq 1 ]
  [[ "$output" =~ "already running" ]]
}

@test "vm_stop stops a running VM" {
  load_utils
  vm_create "testvm"
  vm_start "testvm" --headless
  [ -f "$TEMP_DIR/qemu_running_testvm" ]
  run vm_stop "testvm"
  [ "$status" -eq 0 ]
  [ ! -f "$TEMP_DIR/qemu_running_testvm" ]
}

@test "vm_stop does nothing if VM not running" {
  load_utils
  vm_create "testvm"
  run vm_stop "testvm"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "not running" ]]
}

@test "vm_delete removes a stopped VM" {
  load_utils
  vm_create "testvm"
  run bash -c "source $LIB_DIR/qemate_utils.sh; source $LIB_DIR/qemate_vm.sh; vm_delete 'testvm' --force"
  [ "$status" -eq 0 ]
  [ ! -d "$VM_DIR/testvm" ]
}

@test "vm_delete fails if VM is running without force" {
  load_utils
  vm_create "testvm"
  vm_start "testvm" --headless
  run bash -c "source $LIB_DIR/qemate_utils.sh; source $LIB_DIR/qemate_vm.sh; vm_delete 'testvm'"
  [ "$status" -eq 1 ]
  [ -d "$VM_DIR/testvm" ]
  [[ "$output" =~ "is running" ]]
}

@test "vm_list shows VMs" {
  load_utils
  vm_create "testvm1"
  vm_create "testvm2"
  run vm_list
  [ "$status" -eq 0 ]
  [[ "$output" =~ "testvm1" ]]
  [[ "$output" =~ "testvm2" ]]
}

@test "vm_status shows VM details" {
  load_utils
  vm_create "testvm"
  run vm_status "testvm"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "VM Status: testvm" ]]
  [[ "$output" =~ "stopped" ]]
}

@test "net_port_add adds a port forward" {
  load_utils
  vm_create "testvm"
  run net_port_add "testvm" --host 8080 --guest 80
  [ "$status" -eq 0 ]
  grep -q "PORT_FORWARDING_ENABLED=1" "$VM_DIR/testvm/config"
  grep -q "PORT_FORWARDS=\"8080:80:tcp\"" "$VM_DIR/testvm/config"
}

@test "net_port_add fails if VM is running" {
  load_utils
  vm_create "testvm"
  vm_start "testvm" --headless
  run net_port_add "testvm" --host 8080 --guest 80
  [ "$status" -eq 1 ]
  [[ "$output" =~ "is running" ]]
}

@test "net_port_remove removes a port forward" {
  load_utils
  vm_create "testvm"
  net_port_add "testvm" --host 8080 --guest 80
  run net_port_remove "testvm" "8080"
  [ "$status" -eq 0 ]
  ! grep -q "PORT_FORWARDS=" "$VM_DIR/testvm/config"
}

@test "net_type_set changes network type" {
  load_utils
  vm_create "testvm"
  run net_type_set "testvm" "nat"
  [ "$status" -eq 0 ]
  grep -q "NETWORK_TYPE=\"nat\"" "$VM_DIR/testvm/config"
}

@test "net_model_set changes network model" {
  load_utils
  vm_create "testvm"
  run net_model_set "testvm" "virtio-net-pci"
  [ "$status" -eq 0 ]
  grep -q "NETWORK_MODEL=\"virtio-net-pci\"" "$VM_DIR/testvm/config"
}

@test "net_port_list shows port forwards" {
  load_utils
  vm_create "testvm"
  net_port_add "testvm" --host 8080 --guest 80
  run net_port_list "testvm"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "8080" ]]
  [[ "$output" =~ "80" ]]
  [[ "$output" =~ "tcp" ]]
}