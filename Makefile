# Qemate Makefile
# Default installation paths
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DOCDIR ?= $(PREFIX)/share/doc/qemate
MANDIR ?= $(PREFIX)/share/man/man1

SCRIPT_SRC := $(if $(wildcard src/qemate.sh),src/qemate.sh,qemate.sh)
MAN_SRC := $(if $(wildcard docs/man/qemate.1),docs/man/qemate.1,qemate.1)
DOCS := $(wildcard README.md CHANGELOG.md LICENSE)

# No build step needed for Bash scripts
all:
	@echo "Nothing to build. Use 'make install' to install Qemate."

install:
	@echo "Installing Qemate..."
	@test -f $(SCRIPT_SRC) || { echo "qemate.sh not found"; exit 1; }
	@install -d $(DESTDIR)$(BINDIR)
	@install -d $(DESTDIR)$(DOCDIR)
	@install -d $(DESTDIR)$(MANDIR)
	@install -m 755 $(SCRIPT_SRC) $(DESTDIR)$(BINDIR)/qemate
	@for doc in $(DOCS); do install -m 644 $$doc $(DESTDIR)$(DOCDIR)/; done
	@if [ -f $(MAN_SRC) ]; then install -m 644 $(MAN_SRC) $(DESTDIR)$(MANDIR)/qemate.1; else echo "Warning: man page not found; skipping."; fi
	@echo "Installation complete!"

uninstall:
	@echo "Uninstalling Qemate..."
	@rm -f $(DESTDIR)$(BINDIR)/qemate
	@rm -f $(DESTDIR)$(MANDIR)/qemate.1
	@rm -rf $(DESTDIR)$(DOCDIR)
	@echo "Uninstall complete!"

clean:
	@echo "Cleaning up build artifacts..."
	@rm -f *~ *.bak *.log *.tar.gz
	@rm -rf dist build __pycache__
	@echo "Clean complete!"

# For makepkg/pacman package building cleanup
pkgclean:
	@echo "Cleaning up package build artifacts..."
	@rm -rf src/qemate-* pkg
	@rm -f *.pkg.tar.zst *.pkg.tar.xz
	@echo "Package clean complete!"

distclean: clean pkgclean
	@echo "Performing deep clean..."
	@rm -rf .venv .cache
	@echo "Deep clean complete!"

.PHONY: all install uninstall clean pkgclean distclean
