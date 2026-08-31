#!/usr/bin/env bash
set -euo pipefail
usage(){ printf '%s\n' 'Usage: cleanup-leaselinkd-permissions.sh --yes [--purge-state]'; }
yes=0; purge=0; while (($#)); do case "$1" in --yes)yes=1;;--purge-state)purge=1;;-h|--help)usage;exit 0;;*)usage >&2;exit 64;;esac;shift;done
((yes)) || { printf '%s\n' 'Refusing without --yes.' >&2; exit 64; }
if systemctl is-active --quiet leaselinkd.service; then printf '%s\n' 'Stop leaselinkd before removing its account.' >&2; exit 1; fi
sudo gpasswd -d kea leaselinkd 2>/dev/null || true
if getent passwd leaselinkd >/dev/null; then sudo userdel leaselinkd; fi
if getent group leaselinkd >/dev/null; then sudo groupdel leaselinkd; fi
if ((purge)); then sudo rm -rf /run/leaselinkd /var/lib/leaselinkd; fi
printf '%s\n' 'Removed the leaselinkd account and group. Package sysusers policy will recreate them if the package remains installed or is reinstalled.'
