# Maintainer: Your Name <your.email@example.com>
pkgname=qemate
pkgver=1.1.0
pkgrel=1
pkgdesc="A streamlined command-line utility for managing QEMU virtual machines"
arch=('any')
url="https://github.com/yourusername/qemate"  # Replace with actual URL
license=('BSD')
depends=('bash>=4.0' 'qemu>=9.0.0')
optdepends=('bash-completion: for command-line completion')
source=("file://$PWD/../qemate-$pkgver.tar.gz")  # Adjust if using a real tarball
sha256sums=('SKIP')  # Replace with actual checksum if distributing

package() {
    cd "$srcdir/$pkgname-$pkgver"  # Adjust if source structure differs

    # Install main script
    install -Dm755 src/qemate.sh "$pkgdir/usr/bin/qemate"

    # Install library files
    install -d "$pkgdir/usr/share/qemate"
    for lib in src/lib/*.sh; do
        install -Dm644 "$lib" "$pkgdir/usr/share/qemate/"
    done

    # Install documentation
    install -d "$pkgdir/usr/share/doc/qemate"
    install -Dm644 README.md "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 CHANGELOG.md "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 LICENSE "$pkgdir/usr/share/doc/qemate/"
    install -Dm644 docs/man/qemate.1 "$pkgdir/usr/share/man/man1/qemate.1"

    # Install bash completion
    install -Dm644 completion/bash/qemate "$pkgdir/usr/share/bash-completion/completions/qemate"
}