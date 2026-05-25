# Maintainer: Daniel Zilli <zilli.daniel@gmail.com>
pkgname=qemate
pkgver=4.2.2
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/dlzi/qemate"
license=('MIT')
depends=('bash>=5.0' 'qemu>=9.0.0')
optdepends=('coreutils: for realpath utility'
    'iproute2: for TAP networking (ip command)'
    'edk2-ovmf: UEFI firmware for VMs with ENABLE_UEFI=1'
    'swtpm: TPM 2.0 emulation'
    'swtpm-tools: TPM initialisation (swtpm_setup)'
    'virtiofsd: high-performance VirtIO-FS shared folders'
    'samba: SMB shared folders (smbd)'
    'passt: unprivileged network backend'
    'virt-viewer: SPICE display client (remote-viewer)')
source=("$pkgname-$pkgver.tar.gz::$url/archive/refs/tags/v$pkgver.tar.gz")
sha256sums=('SKIP')

package() {
    cd "$srcdir/$pkgname-$pkgver"

    # Install main script
    install -Dm755 src/qemate.sh "$pkgdir/usr/bin/qemate"
    # Install documentation
    install -d "$pkgdir/usr/share/doc/qemate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 CHANGELOG.md "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 LICENSE "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 docs/man/qemate.1 "$pkgdir/usr/share/man/man1/qemate.1"
}
