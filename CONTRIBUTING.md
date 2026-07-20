# Contributing to qemate

Thank you for your interest in contributing to qemate! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and considerate of others when contributing to this project.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/dlzi/qemate.git`
3. Create a new branch: `git checkout -b feature/your-feature-name`

## Development Environment

To set up your development environment, ensure the following packages are installed:
- **Required**: `bash>=5.0`, `qemu>=10.0.0` (includes `qemu-system-x86_64` and `qemu-img`), `util-linux`, and OpenBSD netcat.
- **Optional**: `pipewire` (preferred for audio), `pulseaudio`, `alsa-utils`, `samba` (for Windows folder sharing), `coreutils` (for `realpath`), `iproute2` (for `ss`), `net-tools` (for `netstat`).

## Coding Guidelines

- Follow the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
- Use 4-space indentation.
- Add comments for complex operations.
- Include error handling for all functions.
- Preserve the validated multi-share behavior for VirtIO-FS and the documented single-share limitation for SMB.

## Pull Request Process

1. Update the `README.md` with details of user-facing changes.
2. Update the `CHANGELOG.md` with a detailed description of changes.
3. Update the version in `src/qemate.sh`, `PKGBUILD`, the man page, and changelog following [SemVer](http://semver.org/).
4. Update `docs/man/qemate.1` to reflect new commands or options.
5. Create a Pull Request with a clear title and description.
6. Wait for review and address any comments.

## Documentation

Please update the documentation when necessary:
- Update `README.md` for user-facing changes.
- Update `docs/man/qemate.1` for detailed command documentation.
- Add examples for new features in `README.md` when useful.

## License

By contributing to qemate, you agree that your contributions will be licensed under the project's MIT License.
