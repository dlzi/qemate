# Maintainer: Your Name <your.email@example.com>
pkgname=qemate
pkgver=2.0.0
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/dlzi/qemate"
license=('MIT')
depends=('bash>=4.0' 'qemu>=9.0.0')
optdepends=('bash-completion: for command-line completion')
source=("git+$url.git#tag=v$pkgver")
sha256sums=('SKIP')

package() {
    cd "$srcdir/$pkgname-$pkgver" # Adjust if source structure differs

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
