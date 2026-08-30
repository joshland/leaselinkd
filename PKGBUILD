# Maintainer: Joshua Schmidlkofer <joshua@joshuainnovates.us>
# URL: https://github.com/joshland/leaselinkd
pkgname=leaselinkd
pkgver=2.0.0
pkgrel=1
arch=('x86_64')
url="https://github.com/joshland/leaselinkd"
license=('MIT')
depends=('ca-certificates' 'kea' 'openssl' 'python' 'python-psycopg' 'python-typer' 'sqlite' 'systemd')
makedepends=('zig')
checkdepends=('python')
backup=('etc/leaselinkd/config.json'
        'etc/leaselinkd/secrets.json'
        'etc/kea-dns-mgr/config.json')
build() {
    cd "$startdir"
    zig build -Doptimize=ReleaseSmall
}
check() {
    cd "$startdir"
    zig build test -Doptimize=ReleaseSafe
}
package() {
    install -Dm755 "$startdir/zig-out/bin/leaselinkd" "$pkgdir/usr/bin/leaselinkd"
    install -Dm755 "$startdir/zig-out/bin/kea-leaselink" "$pkgdir/usr/share/kea/scripts/kea-leaselink"
    install -Dm755 "$startdir/packaging/fetch-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/fetch-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/trust-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/trust-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/check-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/check-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/check-kea-config.py" "$pkgdir/usr/share/leaselinkd/check-kea-config.py"
    install -Dm755 "$startdir/packaging/leaselinkd-sync" "$pkgdir/usr/share/leaselinkd/leaselinkd-sync"
    install -Dm755 "$startdir/packaging/provision-opnsense-leaselinkd.php" "$pkgdir/usr/share/leaselinkd/provision-opnsense-leaselinkd.php"
    install -Dm644 "$startdir/examples/config.json" "$pkgdir/etc/leaselinkd/config.json"
    install -Dm600 "$startdir/examples/secrets.json" "$pkgdir/etc/leaselinkd/secrets.json"
    install -Dm644 "$startdir/examples/kea-hook-config.json" "$pkgdir/etc/kea-dns-mgr/config.json"
    install -Dm644 "$startdir/packaging/leaselinkd.service" "$pkgdir/usr/lib/systemd/system/leaselinkd.service"
    install -Dm644 "$startdir/packaging/leaselinkd.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/leaselinkd.conf"
    install -Dm644 "$startdir/packaging/leaselinkd.sysusers" "$pkgdir/usr/lib/sysusers.d/leaselinkd.conf"
}
