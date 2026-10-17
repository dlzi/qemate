# qemate Makefile
# Default installation paths
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DOCDIR ?= $(PREFIX)/share/doc/qemate
MANDIR ?= $(PREFIX)/share/man/man1

SCRIPT_SRC := src/qemate.sh
MAN_SRC := docs/man/qemate.1
DOCS := $(wildcard README.md CHANGELOG.md LICENSE)

# No build step needed for Bash scripts
all:
	@echo "Nothing to build. Use 'make install' to install qemate."

install:
	@echo "Installing qemate..."
	@test -f $(SCRIPT_SRC) || { echo "qemate.sh not found"; exit 1; }
	@install -d $(DESTDIR)$(BINDIR)
	@install -d $(DESTDIR)$(DOCDIR)
	@install -d $(DESTDIR)$(MANDIR)
	@install -m 755 $(SCRIPT_SRC) $(DESTDIR)$(BINDIR)/qemate
	@for doc in $(DOCS); do install -m 644 $$doc $(DESTDIR)$(DOCDIR)/; done
	@test -f $(MAN_SRC) || { echo "docs/man/qemate.1 not found"; exit 1; }
	@install -m 644 $(MAN_SRC) $(DESTDIR)$(MANDIR)/qemate.1
	@echo "Installation complete!"

uninstall:
	@echo "Uninstalling qemate..."
	@rm -f $(DESTDIR)$(BINDIR)/qemate
	@rm -f $(DESTDIR)$(MANDIR)/qemate.1
	@rm -rf $(DESTDIR)$(DOCDIR)
	@echo "Uninstall complete!"

clean:
	@echo "Cleaning up build artifacts..."
	@rm -f *~ *.bak
	@echo "Clean complete!"

# For makepkg/pacman package building cleanup
pkgclean:
	@echo "Cleaning up package build artifacts..."
	@rm -rf src/qemate-* pkg
	@rm -f *.pkg.tar.zst *.pkg.tar.xz
	@echo "Package clean complete!"

distclean: clean pkgclean
	@echo "Deep clean complete!"

.PHONY: all install uninstall clean pkgclean distclean
