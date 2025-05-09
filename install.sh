#!/bin/bash
# Qemate Installation Script

set -e

# Default installation paths
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
LIBDIR="${LIBDIR:-$PREFIX/share/qemate}"
DOCDIR="${DOCDIR:-$PREFIX/share/doc/qemate}"
MANDIR="${MANDIR:-$PREFIX/share/man/man1}"
COMPLETIONDIR="${COMPLETIONDIR:-$PREFIX/share/bash-completion/completions}"

# Print header
echo "=== Qemate Installation ==="
echo "Installing to:"
echo "  Binary:      $BINDIR"
echo "  Docs:        $DOCDIR"
echo "  Man Page:    $MANDIR"
echo "  Completion:  $COMPLETIONDIR"
echo ""

# Create directories with error checking
echo "Creating directories..."
for dir in "$BINDIR" "$DOCDIR" "$MANDIR" "$COMPLETIONDIR"; do
    mkdir -p "$dir" || {
        echo "Failed to create $dir"
        exit 1
    }
done

# Install the script
echo "Installing the script..."
install -m 755 src/qemate.sh "$BINDIR/qemate" || {
    echo "Failed to install qemate.sh"
    exit 1
}

# Install documentation
echo "Installing documentation..."
for doc in README.md CHANGELOG.md LICENSE; do
    [ -f "$doc" ] && install -m 644 "$doc" "$DOCDIR/" || {
        echo "Failed to install $doc"
        exit 1
    }
done
[ -f docs/man/qemate.1 ] && install -m 644 docs/man/qemate.1 "$MANDIR/" || {
    echo "Failed to install man page"
    exit 1
}

# Install bash completion
echo "Installing bash completion..."
[ -f completion/bash/qemate ] && install -m 644 completion/bash/qemate "$COMPLETIONDIR/" || {
    echo "Failed to install bash completion"
    exit 1
}

echo ""
echo "Installation complete!"
echo "Run 'qemate help' to get started."
