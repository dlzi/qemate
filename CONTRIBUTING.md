# Contributing to Qemate

Thank you for your interest in contributing to Qemate! This document provides guidelines and instructions for contributing.

## Code of Conduct

Please be respectful and considerate of others when contributing to this project.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/dlzi/qemate.git`
3. Create a new branch: `git checkout -b feature/your-feature-name`

## Development Environment

To set up your development environment, ensure the following packages are installed:
- **Required**: `bash>=5.0`, `qemu>=9.0.0` (includes `qemu-system-x86_64` and `qemu-img`).
- **Optional**: `pipewire` (preferred for audio), `pulseaudio`, `alsa-utils`, `samba` (for Windows folder sharing), `coreutils` (for `realpath`), `iproute2` (for `ss`), `net-tools` (for `netstat`).

## Coding Guidelines

- Follow the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html).
- Use 4-space indentation.
- Add comments for complex operations.
- Include error handling for all functions.
- Ensure shared folder functionality supports only one folder per VM, as per the current implementation.

## Pull Request Process

1. Update the `README.md` with details of user-facing changes.
2. Update the `CHANGELOG.md` with a detailed description of changes.
3. Update the version number in the `VERSION` file following [SemVer](http://semver.org/).
4. Update `docs/man/qemate.1` and `completion/bash/qemate` to reflect new commands or options.
5. Create a Pull Request with a clear title and description.
6. Wait for review and address any comments.

## Documentation

Please update the documentation when necessary:
- Update `README.md` for user-facing changes.
- Update `docs/man/qemate.1` for detailed command documentation.
- Update `completion/bash/qemate` for bash completion support.
- Add examples for new features in `README.md` and `docs/examples/`.

## License

By contributing to Qemate, you agree that your contributions will be licensed under the project's MIT License.