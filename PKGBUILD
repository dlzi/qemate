# Maintainer: Daniel Zilli <zilli.daniel@gmail.com>
pkgname=qemate
pkgver=6.0.1
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/dlzi/qemate"
license=('MIT')
depends=('bash>=5.0' 'qemu>=11.0.0' 'util-linux' 'openbsd-netcat')
optdepends=('coreutils: for realpath utility'
    'iproute2: TAP networking (ip) and host port checks (ss)'
    'edk2-ovmf: UEFI firmware for VMs with ENABLE_UEFI=1'
    'swtpm: TPM 2.0 emulation'
    'swtpm-tools: TPM initialisation (swtpm_setup)'
    'virtiofsd: high-performance VirtIO-FS shared folders'
    'samba: SMB shared folders (smbd)'
    'passt: unprivileged network backend'
    'virt-viewer: SPICE display client (remote-viewer)'
    'git: clone OSX-KVM for macOS support'
    'python: download macOS recovery metadata'
    'dmg2img: convert the Apple recovery DMG for macOS installation')
# Package this working tree. A GitHub tag tarball is not fetched, so there is
# no checksum to invent, and makepkg does not extract beside src/qemate.sh.

package() {
    cd "$startdir"

    install -Dm755 src/qemate.sh "$pkgdir/usr/bin/qemate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/qemate/README.md"
    install -Dm644 CHANGELOG.md "$pkgdir/usr/share/doc/qemate/CHANGELOG.md"
    install -Dm644 LICENSE "$pkgdir/usr/share/doc/qemate/LICENSE"
    install -Dm644 docs/man/qemate.1 "$pkgdir/usr/share/man/man1/qemate.1"
}
