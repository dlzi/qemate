#!/bin/bash
# qemate Installation Script

set -euo pipefail

PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

for arg in "$@"; do
    case "$arg" in
        PREFIX=*) PREFIX="${arg#PREFIX=}" ;;
        BINDIR=*) BINDIR="${arg#BINDIR=}" ;;
        DOCDIR=*) DOCDIR="${arg#DOCDIR=}" ;;
        MANDIR=*) MANDIR="${arg#MANDIR=}" ;;
        *) echo "Error: unknown argument '$arg'. Use PREFIX=, BINDIR=, DOCDIR=, or MANDIR=."; exit 1 ;;
    esac
done

# Bash 5 is required to install. QEMU and the lifecycle tools are required to
# run VMs, but list/status and a source checkout should still install without them.
warn_install() {
    echo "Warning: $*"
}

if [[ "${BASH_VERSION%%.*}" -lt 5 ]]; then
    echo "Error: Bash 5.0 or higher is required. Current version: $BASH_VERSION"
    exit 1
fi

check_qemu() {
    local qemu_command="$1" qemu_version_output
    if ! command -v "$qemu_command" >/dev/null 2>&1; then
        warn_install "$qemu_command not found. Install QEMU 11.0 or higher before creating or starting VMs."
        return 0
    fi
    qemu_version_output=$("$qemu_command" --version 2>/dev/null || true)
    if [[ ! "$qemu_version_output" =~ version[[:space:]]+([0-9]+)(\.[0-9]+)? ]] ||
       (( BASH_REMATCH[1] < 11 )); then
        warn_install "$qemu_command is older than QEMU 11.0. Upgrade before creating or starting VMs."
    fi
}

check_qemu qemu-system-x86_64
check_qemu qemu-img

if ! command -v flock >/dev/null 2>&1 || ! command -v setsid >/dev/null 2>&1; then
    warn_install "flock and setsid (util-linux) are required for VM lifecycle commands."
fi

if ! command -v nc >/dev/null 2>&1 || ! nc -h 2>&1 | grep -q -- '-U'; then
    warn_install "OpenBSD netcat with Unix-socket support (nc -U) is required for graceful VM control."
fi

# Default installation paths
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
DOCDIR="${DOCDIR:-$PREFIX/share/doc/qemate}"
MANDIR="${MANDIR:-$PREFIX/share/man/man1}"

SCRIPT_SRC="$PROJECT_ROOT/src/qemate.sh"
MAN_SRC="$PROJECT_ROOT/docs/man/qemate.1"
if [[ ! -f "$SCRIPT_SRC" ]]; then
    echo "Error: src/qemate.sh not found."
    exit 1
fi
if [[ ! -f "$MAN_SRC" ]]; then
    echo "Error: docs/man/qemate.1 not found."
    exit 1
fi

# Print header
echo "=== qemate Installation ==="
echo "Installing to:"
echo "  Binary:      $BINDIR"
echo "  Docs:        $DOCDIR"
echo "  Man Page:    $MANDIR"
echo ""

# Create directories with error checking
echo "Creating directories..."
for dir in "$BINDIR" "$DOCDIR" "$MANDIR"; do
    mkdir -p "$dir" || {
        echo "Failed to create $dir"
        exit 1
    }
done

# Install the script
echo "Installing the script..."
install -m 755 "$SCRIPT_SRC" "$BINDIR/qemate" || {
    echo "Failed to install $SCRIPT_SRC"
    exit 1
}

# Install documentation
echo "Installing documentation..."
for doc in README.md CHANGELOG.md LICENSE; do
    if [[ -f "$PROJECT_ROOT/$doc" ]]; then
        install -m 644 "$PROJECT_ROOT/$doc" "$DOCDIR/" || {
            echo "Failed to install $doc"
            exit 1
        }
    fi
done

install -m 644 "$MAN_SRC" "$MANDIR/qemate.1" || {
    echo "Failed to install man page"
    exit 1
}

echo ""
echo "Installation complete!"
echo "Run 'qemate --help' to get started."
