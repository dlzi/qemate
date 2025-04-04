# Qemate Makefile

# Default installation paths
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/share/qemate
DOCDIR ?= $(PREFIX)/share/doc/qemate
MANDIR ?= $(PREFIX)/share/man/man1
COMPLETIONDIR ?= $(PREFIX)/share/bash-completion/completions

# No build step needed for Bash scripts
all:
	@echo "Nothing to build. Use 'make install' to install Qemate."

install:
	@echo "Installing Qemate..."
	@install -d $(DESTDIR)$(BINDIR)
	@install -d $(DESTDIR)$(LIBDIR)
	@install -d $(DESTDIR)$(DOCDIR)
	@install -d $(DESTDIR)$(MANDIR)
	@install -d $(DESTDIR)$(COMPLETIONDIR)
	
	# Install main script
	@install -m 755 src/qemate.sh $(DESTD IR)$(BINDIR)/qemate
	
	# Install library files
	@for lib in src/lib/*.sh; do \
		install -m 644 $$lib $(DESTDIR)$(LIBDIR)/; \
	done
	
	# Install documentation
	@install -m 644 README.md $(DESTDIR)$(DOCDIR)/
	@install -m 644 CHANGELOG.md $(DESTDIR)$(DOCDIR)/
	@install -m 644 LICENSE $(DESTDIR)$(DOCDIR)/
	@install -m 644 docs/man/qemate.1 $(DESTDIR)$(MANDIR)/
	
	# Install bash completion
	@install -m 644 completion/bash/qemate $(DESTDIR)$(COMPLETIONDIR)/

uninstall:
	@echo "Running uninstall script..."
	@./uninstall.sh

test:
	@echo "Running tests..."
	@./tests/run_tests.sh

clean:
	@echo "Nothing to clean."

.PHONY: all install uninstall test clean
