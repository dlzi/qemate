# Maintainer: Daniel Zilli <zilli.daniel@gmail.com>
pkgname=qemate
pkgver=5.1.1
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/dlzi/qemate"
license=('MIT')
depends=('bash>=5.0' 'qemu>=10.0.0' 'util-linux' 'openbsd-netcat')
optdepends=('coreutils: for realpath utility'
    'iproute2: for TAP networking (ip command)'
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
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
    cd "$srcdir/$pkgname-$pkgver"

    local script_src man_src
    if [[ -f src/qemate.sh ]]; then
        script_src="src/qemate.sh"
    else
        script_src="qemate.sh"
    fi

    if [[ -f docs/man/qemate.1 ]]; then
        man_src="docs/man/qemate.1"
    else
        man_src="qemate.1"
    fi

    install -Dm755 "$script_src" "$pkgdir/usr/bin/qemate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/qemate/README.md"
    install -Dm644 CHANGELOG.md "$pkgdir/usr/share/doc/qemate/CHANGELOG.md"
    [[ -f LICENSE ]] && install -Dm644 LICENSE "$pkgdir/usr/share/doc/qemate/LICENSE"
    [[ -f "$man_src" ]] && install -Dm644 "$man_src" "$pkgdir/usr/share/man/man1/qemate.1"
}
