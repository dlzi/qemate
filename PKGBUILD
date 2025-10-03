# Maintainer: Daniel Zilli <zilli.daniel@gmail.com>
pkgname=qemate
pkgver=3.0.2
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/dlzi/qemate"
license=('MIT')
depends=('bash>=5.0' 'qemu>=9.0.0')
optdepends=('bash-completion: for command-line completion'
    'samba: for sharing folder with a Windows guest'
    'pipewire: for audio support (preferred)'
    'pulseaudio: for audio support'
    'alsa-utils: for audio support'
    'coreutils: for realpath utility'
    'iproute2: for ss utility'
    'net-tools: for netstat utility')
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
    # Install bash completion
    install -Dm644 completion/bash/qemate "$pkgdir/usr/share/bash-completion/completions/qemate"
}
