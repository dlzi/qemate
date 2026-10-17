#!/usr/bin/env bash
# Regression checks for the 6.0.1 fixes. Sources qemate; does not boot a VM.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export QEMATE_VM_DIR="$tmp/vms"
export QEMATE_OSX_KVM_CACHE="$tmp/cache"
# shellcheck disable=SC1091
source "$root/src/qemate.sh"
# log_message in the sourced script reads this flag.
# shellcheck disable=SC2034
QEMATE_SUPPRESS_FILE_LOG=1

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ "$(bytes_to_disk_size 1073741824)" == "1G" ]] || fail "1073741824 should be 1G"
[[ "$(bytes_to_disk_size 1048576)" == "1M" ]] || fail "1048576 should be 1M"
[[ "$(bytes_to_disk_size 1)" == "1M" ]] || fail "1 byte should round up to 1M"
if bytes_to_disk_size 0 >/dev/null 2>&1; then
    fail "0 bytes should be rejected"
fi

declare -A VM=()
VM[SPICE_ENABLED]=1
VM[VIDEO_TYPE]=qxl-vga
VM[NAME]=t
VM[VRAM_SIZE_MB]=64
VM[ENABLE_VIRTIO]=1
cmd=()
configure_display VM cmd 1 >/dev/null
printf '%s\n' "${cmd[@]}" > "$tmp/spice.txt"
grep -qx -- "-spice" "$tmp/spice.txt" || fail "headless SPICE did not attach -spice"
grep -qx -- "-display" "$tmp/spice.txt" || fail "headless SPICE missing -display"
grep -qx -- "none" "$tmp/spice.txt" || fail "headless SPICE missing display none"

VM[SPICE_ENABLED]=0
[[ "${VM[SPICE_ENABLED]}" == "0" && "${VM[VIDEO_TYPE]}" == "qxl-vga" ]] || fail "display fixture"
cmd=()
configure_display VM cmd 1 >/dev/null
[[ "${#cmd[@]}" -eq 2 && "${cmd[0]}" == "-display" && "${cmd[1]}" == "none" ]] || \
    fail "headless without SPICE should be only -display none, got: ${cmd[*]}"

declare -A MAC=()
MAC[OS_TYPE]=macos
MAC[SHARE_BACKEND]=virtiofs
MAC[SHARED_FOLDERS]="a:/tmp,b:/var/tmp"
MAC[NAME]=mac
out=$(resolve_share_backend MAC)
[[ "$out" == "smb" ]] || fail "macOS multi-share backend should be smb, got: $out"

declare -A LIN=()
LIN[OS_TYPE]=linux
LIN[SHARE_BACKEND]=smb
LIN[SHARED_FOLDERS]="a:/tmp,b:/var/tmp"
LIN[NAME]=lin
[[ "${LIN[NAME]}" == "lin" && "${LIN[SHARE_BACKEND]}" == "smb" ]] || fail "linux share fixture"
out=$(resolve_share_backend LIN)
[[ "$out" == *"virtiofs"* ]] || fail "Linux SMB with two shares should fall back to virtiofs, got: $out"

status=0
macos_note_ignored_settings mac MAC >/dev/null || status=$?
[[ "$status" -eq 0 ]] || fail "macos_note_ignored_settings returned $status"
MAC[ENABLE_TPM]=1
MAC[ENABLE_AUDIO]=0
MAC[SPICE_ENABLED]=0
MAC[DISK_INTERFACE]=sata
MAC[VIDEO_TYPE]=vmware
MAC[CPU_TYPE]=host
MAC[HIDE_KVM]=0
MAC[ENABLE_UEFI]=1
[[ "${MAC[ENABLE_TPM]}" == "1" && "${MAC[ENABLE_AUDIO]}" == "0" ]] || fail "macOS ignore fixture"
note_out=$(macos_note_ignored_settings mac MAC)
[[ "$note_out" == *"ENABLE_TPM=1"* ]] || fail "missing TPM warning: $note_out"
[[ "$note_out" != *"ENABLE_AUDIO"* ]] || fail "ENABLE_AUDIO=0 should not warn on macOS"

mkdir -p "$tmp/cache" "$QEMATE_VM_DIR/wt/macos"
git -C "$tmp/cache" init -q
git -C "$tmp/cache" config user.email "qemate-test@example.com"
git -C "$tmp/cache" config user.name "qemate-test"
echo marker > "$tmp/cache/marker"
git -C "$tmp/cache" add marker
git -C "$tmp/cache" commit -qm init
git -C "$tmp/cache" worktree add --detach "$QEMATE_VM_DIR/wt/macos/OSX-KVM" HEAD >/dev/null
[[ -f "$QEMATE_VM_DIR/wt/macos/OSX-KVM/.git" && ! -d "$QEMATE_VM_DIR/wt/macos/OSX-KVM/.git" ]] || \
    fail "worktree .git should be a file"
info=$(macos_repo_info wt)
[[ "$info" == repository=* ]] || fail "macos_repo_info missed the worktree: $info"
remove_osx_kvm_checkout "$QEMATE_VM_DIR/wt/macos/OSX-KVM"
[[ ! -e "$QEMATE_VM_DIR/wt/macos/OSX-KVM" ]] || fail "checkout was not removed"
git -C "$tmp/cache" worktree add --detach "$QEMATE_VM_DIR/wt/macos/OSX-KVM" HEAD >/dev/null
[[ -e "$QEMATE_VM_DIR/wt/macos/OSX-KVM/.git" ]] || fail "worktree add failed after removal"
remove_osx_kvm_checkout "$QEMATE_VM_DIR/does-not-exist"
[[ ! -e "$QEMATE_VM_DIR/does-not-exist" ]] || fail "missing checkout path should stay missing"

mkdir -p "$QEMATE_VM_DIR/macdoc/logs"
declare -A DOC=()
apply_os_defaults macos DOC
DOC[NAME]=macdoc
DOC[OS_TYPE]=macos
DOC[MACOS_VERSION]=sonoma
DOC[MAC_ADDRESS]="52:54:00:12:34:56"
DOC[MACHINE_OPTIONS]="accel=kvm"
DOC[LOCKED]=0
DOC[ENABLE_AUDIO]=0
DOC[ENABLE_TPM]=1
DOC[SPICE_ENABLED]=1
[[ "${DOC[OS_TYPE]}" == "macos" && "${DOC[SPICE_ENABLED]}" == "1" ]] || fail "macOS config fixture"
save_vm_config macdoc DOC
row=$(list | awk '$1 == "macdoc"')
[[ "$row" == *"macos"* ]] || fail "list missed macdoc: $row"
# NAME STATUS LOCKED OS AUDIO TPM SPICE
read -r _name _stat _lock _os audio tpm spice <<< "$row"
[[ "$audio" == "on" && "$tpm" == "off" && "$spice" == "off" ]] || \
    fail "macOS list columns should be audio=on tpm=off spice=off, got: $audio $tpm $spice"

exec {hold_fd}>"$QEMATE_VM_DIR/macdoc/qemu.pid.lock"
flock -n "$hold_fd"
row=$(list | awk '$1 == "macdoc"')
read -r _name stat _rest <<< "$row"
[[ "$stat" == "busy" ]] || fail "held lifecycle lock should list as busy, got: $stat"
flock -u "$hold_fd"
exec {hold_fd}>&-

if command -v qemu-system-x86_64 >/dev/null 2>&1 && command -v qemu-img >/dev/null 2>&1; then
    set +e
    doctor_out=$(macos_doctor macdoc 2>&1)
    doctor_status=$?
    set -e
    [[ "$doctor_status" -ne 0 ]] || fail "incomplete macOS doctor should fail"
    missing_count=$(grep -c "Missing:" <<< "$doctor_out" || true)
    [[ "$missing_count" -ge 3 ]] || fail "doctor stopped early; Missing count=$missing_count output=$doctor_out"

    set +e
    resize_out=$(resize_disk macdoc --force 1G 2>&1)
    resize_status=$?
    set -e
    [[ "$resize_status" -ne 0 ]] || fail "resize of a VM without a disk should fail"
    [[ "$resize_out" == *"--force does not resize"* ]] || fail "resize did not accept --force: $resize_out"
    [[ "$resize_out" != *"Invalid size: '--force'"* ]] || fail "--force was parsed as the size"
fi

echo "OK"
