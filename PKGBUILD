# Maintainer: Joshua Schmidlkofer <joshua@joshuainnovates.us>
# URL: https://github.com/joshland/leaselinkd
pkgname=leaselinkd
pkgver=2.1.0
pkgrel=7
install=leaselinkd.install
arch=('x86_64')
url="https://github.com/joshland/leaselinkd"
license=('MIT')
depends=('ca-certificates' 'kea' 'openssl' 'python' 'python-psycopg' 'python-typer' 'sqlite' 'systemd')
makedepends=('zig')
checkdepends=('python')
backup=('etc/leaselinkd/config.json'
        'etc/leaselinkd/secrets.json'
        'etc/leaselinkd/hook.json')
build() {
    cd "$startdir"
    zig build -Doptimize=ReleaseSmall
}
check() {
    cd "$startdir"
    zig build test -Doptimize=ReleaseSafe
}
package() {
    install -d -m750 "$pkgdir/etc/leaselinkd"
    install -Dm644 "$startdir/README.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/README.md"
    install -Dm644 "$startdir/project/ARCHITECTURE.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/ARCHITECTURE.md"
    install -Dm644 "$startdir/project/CONFIGS.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/CONFIGS.md"
    install -Dm644 "$startdir/project/OPNsense_Manual_Provisioning.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/OPNsense_Manual_Provisioning.md"
    install -Dm644 "$startdir/project/OPNsense_Unbound_HOWTO.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/OPNsense_Unbound_HOWTO.md"
    install -Dm644 "$startdir/project/OPNsense_Unbound.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/OPNsense_Unbound.md"
    install -Dm644 "$startdir/project/OVERVIEW.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/OVERVIEW.md"
    install -Dm644 "$startdir/project/PROCESSES.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/PROCESSES.md"
    install -Dm644 "$startdir/project/SERVERS.md" "$pkgdir/usr/share/doc/$pkgname-$pkgver/SERVERS.md"
    install -Dm755 "$startdir/zig-out/bin/leaselinkd" "$pkgdir/usr/bin/leaselinkd"
    install -Dm755 "$startdir/zig-out/bin/kea-leaselink" "$pkgdir/usr/share/kea/scripts/kea-leaselink"
    install -Dm755 "$startdir/packaging/fetch-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/fetch-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/trust-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/trust-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/check-firewall-certificate.sh" "$pkgdir/usr/share/leaselinkd/check-firewall-certificate.sh"
    install -Dm755 "$startdir/packaging/check-kea-config.py" "$pkgdir/usr/share/leaselinkd/check-kea-config.py"
    install -Dm755 "$startdir/packaging/keadb-leaselinkd-sync" "$pkgdir/usr/share/leaselinkd/keadb-leaselinkd-sync"
    install -Dm755 "$startdir/packaging/provision-opnsense-leaselinkd.php" "$pkgdir/usr/share/leaselinkd/provision-opnsense-leaselinkd.php"
    install -Dm644 "$startdir/examples/config.json" "$pkgdir/etc/leaselinkd/config.json"
    install -Dm600 "$startdir/examples/secrets.json" "$pkgdir/etc/leaselinkd/secrets.json"
    install -Dm640 "$startdir/examples/hook.json" "$pkgdir/etc/leaselinkd/hook.json"
    install -Dm644 "$startdir/packaging/leaselinkd.service" "$pkgdir/usr/lib/systemd/system/leaselinkd.service"
    install -Dm644 "$startdir/packaging/leaselinkd.tmpfiles" "$pkgdir/usr/lib/tmpfiles.d/leaselinkd.conf"
    install -Dm644 "$startdir/packaging/leaselinkd.sysusers" "$pkgdir/usr/lib/sysusers.d/leaselinkd.conf"
}
