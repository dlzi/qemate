#!/bin/bash
# Qemate Uninstallation Script

set -e

# Default installation paths (must match install.sh)
PREFIX="${PREFIX:-/usr/local}"
BINDIR="${BINDIR:-$PREFIX/bin}"
LIBDIR="${LIBDIR:-$PREFIX/share/qemate}"
DOCDIR="${DOCDIR:-$PREFIX/share/doc/qemate}"
MANDIR="${MANDIR:-$PREFIX/share/man/man1}"
COMPLETIONDIR="${COMPLETIONDIR:-$PREFIX/share/bash-completion/completions}"

# Print header
echo "=== Qemate Uninstallation ==="
echo "Removing from:"
echo "  Binary:      $BINDIR"
echo "  Docs:        $DOCDIR"
echo "  Man Page:    $MANDIR"
echo "  Completion:  $COMPLETIONDIR"
echo ""

# Remove the script
echo "Removing the script..."
[ -f "$BINDIR/qemate" ] && rm -f "$BINDIR/qemate" || echo "Main script not found at $BINDIR/qemate, skipping."

# Remove documentation
echo "Removing documentation..."
[ -d "$DOCDIR" ] && rm -rf "$DOCDIR" || echo "Documentation directory not found at $DOCDIR, skipping."

# Remove man page
echo "Removing man page..."
[ -f "$MANDIR/qemate.1" ] && rm -f "$MANDIR/qemate.1" || echo "Man page not found at $MANDIR/qemate.1, skipping."

# Remove bash completion
echo "Removing bash completion..."
[ -f "$COMPLETIONDIR/qemate" ] && rm -f "$COMPLETIONDIR/qemate" || echo "Bash completion not found at $COMPLETIONDIR/qemate, skipping."

echo ""
echo "Uninstallation complete!"
echo "Qemate has been removed from your system."
