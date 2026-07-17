#!/bin/bash
# Qemate Installation Script

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

# Check dependencies
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo "Error: qemu-system-x86_64 not found. Please install QEMU version 10.0 or higher."
    exit 1
fi

if ! command -v qemu-img &> /dev/null; then
    echo "Error: qemu-img not found. Please install QEMU version 10.0 or higher."
    exit 1
fi

if ! command -v flock &> /dev/null; then
    echo "Error: flock not found. Please install util-linux."
    exit 1
fi

if ! command -v nc &> /dev/null || ! nc -h 2>&1 | grep -q -- '-U'; then
    echo "Error: OpenBSD netcat with Unix-socket support (nc -U) is required for graceful VM control."
    exit 1
fi

if [[ "${BASH_VERSION%%.*}" -lt 5 ]]; then
    echo "Error: Bash 5.0 or higher is required. Current version: $BASH_VERSION"
    exit 1
fi

for qemu_command in qemu-system-x86_64 qemu-img; do
    qemu_version_output=$("$qemu_command" --version 2>/dev/null || true)
    if [[ ! "$qemu_version_output" =~ version[[:space:]]+([0-9]+)(\.[0-9]+)? ]] ||
       (( BASH_REMATCH[1] < 10 )); then
        echo "Error: $qemu_command from QEMU 10.0 or higher is required. Please upgrade QEMU."
        exit 1
    fi
done

# Default installation paths
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
DOCDIR="${DOCDIR:-$PREFIX/share/doc/qemate}"
MANDIR="${MANDIR:-$PREFIX/share/man/man1}"

SCRIPT_SRC=""
if [[ -f "$PROJECT_ROOT/src/qemate.sh" ]]; then
    SCRIPT_SRC="$PROJECT_ROOT/src/qemate.sh"
elif [[ -f "$PROJECT_ROOT/qemate.sh" ]]; then
    SCRIPT_SRC="$PROJECT_ROOT/qemate.sh"
else
    echo "Error: qemate.sh not found next to install.sh or under src/."
    exit 1
fi

MAN_SRC=""
if [[ -f "$PROJECT_ROOT/docs/man/qemate.1" ]]; then
    MAN_SRC="$PROJECT_ROOT/docs/man/qemate.1"
elif [[ -f "$PROJECT_ROOT/qemate.1" ]]; then
    MAN_SRC="$PROJECT_ROOT/qemate.1"
fi

# Print header
echo "=== Qemate Installation ==="
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

if [[ -n "$MAN_SRC" ]]; then
    install -m 644 "$MAN_SRC" "$MANDIR/qemate.1" || {
        echo "Failed to install man page"
        exit 1
    }
else
    echo "Warning: man page not found; skipping."
fi

echo ""
echo "Installation complete!"
echo "Run 'qemate --help' to get started."
