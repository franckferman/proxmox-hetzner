#!/usr/bin/env bash
#
# post-install.sh — run ON the Proxmox VE host after the first boot.
# ----------------------------------------------------------------------------
# Optional optimizations: system upgrade, useful utilities, remove the
# "no valid subscription" nag, tune ZFS ARC memory, and conntrack sysctls.
#
# Everything is idempotent and individually toggleable. Run with --help.
#
set -euo pipefail
VERSION="1.1.0"

if [[ -t 1 ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[1;34m'; C_0=$'\033[0m'
else C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""; fi
log()  { echo -e "${C_B}[*]${C_0} $*"; }
ok()   { echo -e "${C_G}[+]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*" >&2; }
die()  { echo -e "${C_R}[x]${C_0} $*" >&2; exit 1; }

# Defaults
DO_UPGRADE=yes
DO_REPOFIX=yes
DO_UTILS=yes
DO_SUBNAG=yes
DO_ARC=yes
ARC_MIN_GB=6
ARC_MAX_GB=12
DO_CONNTRACK=yes
DO_REBOOT=ask

usage() {
  cat <<EOF
proxmox-hetzner post-install v${VERSION}  (run on the Proxmox host)

  --no-upgrade        Skip apt dist-upgrade / pveam update
  --no-repo-fix       Keep APT repos as-is (default: disable enterprise repos
                      and enable pve-no-subscription)
  --no-utils          Skip installing utilities (curl, libguestfs-tools, unzip,
                      iptables-persistent, net-tools)
  --no-sub-nag        Keep the "no valid subscription" popup
  --no-arc            Do not tune ZFS ARC
  --arc-min GB        ZFS ARC minimum in GiB        (default: ${ARC_MIN_GB})
  --arc-max GB        ZFS ARC maximum in GiB        (default: ${ARC_MAX_GB})
  --no-conntrack      Skip nf_conntrack tuning
  --reboot ask|yes|no Reboot at the end if needed   (default: ask)
  -h, --help          This help

Note: on a high-RAM host you may want a larger --arc-max (default 12 GiB is
conservative; ZFS default is ~50% of RAM). Pick based on how much RAM you
want to leave for VMs/CTs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-upgrade)   DO_UPGRADE=no; shift;;
    --no-repo-fix)  DO_REPOFIX=no; shift;;
    --no-utils)     DO_UTILS=no; shift;;
    --no-sub-nag)   DO_SUBNAG=no; shift;;
    --no-arc)       DO_ARC=no; shift;;
    --arc-min)      ARC_MIN_GB="$2"; shift 2;;
    --arc-max)      ARC_MAX_GB="$2"; shift 2;;
    --no-conntrack) DO_CONNTRACK=no; shift;;
    --reboot)       DO_REBOOT="$2"; shift 2;;
    -h|--help)      usage; exit 0;;
    *) die "Unknown argument: $1 (try --help)";;
  esac
done

[[ $EUID -eq 0 ]] || die "Run as root."
command -v pveversion >/dev/null || die "This is not a Proxmox VE host (run it on the installed system)."

NEED_REBOOT=0

# 0) Repositories: disable enterprise (401 without a subscription), ensure
#    pve-no-subscription. Handles deb822 (.sources, PVE 9) and legacy (.list).
fix_repos() {
  log "Setting no-subscription repositories ..."
  . /etc/os-release 2>/dev/null || true
  local cn="${VERSION_CODENAME:-trixie}" f
  rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.list
  for f in /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.list; do
    [[ -f $f ]] && grep -qi 'enterprise.proxmox.com' "$f" && { rm -f "$f"; warn "Removed enterprise Ceph repo ($f); re-add a no-subscription Ceph repo if you use Ceph."; }
  done
  if ! grep -rqs 'pve-no-subscription' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null; then
    cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${cn}
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
    ok "Added pve-no-subscription."
  fi
}
[[ $DO_REPOFIX == yes ]] && fix_repos

# 1) System upgrade --------------------------------------------------------- #
if [[ $DO_UPGRADE == yes ]]; then
  log "Updating and upgrading the system ..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get -y -qq dist-upgrade
  apt-get -y -qq autoremove
  pveam update >/dev/null 2>&1 || true
  ok "System up to date."
fi

# 2) Useful utilities ------------------------------------------------------- #
if [[ $DO_UTILS == yes ]]; then
  log "Installing utilities ..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    curl libguestfs-tools unzip iptables-persistent net-tools
  ok "Utilities installed."
fi

# 3) Remove subscription nag ------------------------------------------------ #
if [[ $DO_SUBNAG == yes ]]; then
  JS=/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
  if [[ -f $JS ]]; then
    log "Removing 'no valid subscription' notice ..."
    sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" "$JS"
    systemctl restart pveproxy.service || true
    ok "Subscription notice patched (backup: ${JS}.bak)."
  else
    warn "proxmoxlib.js not found - skipping (path/version may have changed)."
  fi
fi

# 4) ZFS ARC tuning --------------------------------------------------------- #
if [[ $DO_ARC == yes ]]; then
  log "Tuning ZFS ARC (min=${ARC_MIN_GB}G max=${ARC_MAX_GB}G) ..."
  local_min=$(( ARC_MIN_GB * 1024*1024*1024 ))
  local_max=$(( ARC_MAX_GB * 1024*1024*1024 ))
  rm -f /etc/modprobe.d/zfs.conf
  {
    echo "options zfs zfs_arc_min=${local_min}"
    echo "options zfs zfs_arc_max=${local_max}"
  } > /etc/modprobe.d/99-zfs.conf
  # apply live where possible (max can be lowered/raised at runtime)
  echo "$local_max" > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
  update-initramfs -u -k all >/dev/null 2>&1 || update-initramfs -u >/dev/null 2>&1 || true
  NEED_REBOOT=1
  ok "ZFS ARC configured (full effect after reboot)."
fi

# 5) conntrack tuning ------------------------------------------------------- #
if [[ $DO_CONNTRACK == yes ]]; then
  log "Tuning nf_conntrack ..."
  grep -qx "nf_conntrack" /etc/modules || echo "nf_conntrack" >> /etc/modules
  SC=/etc/sysctl.d/99-proxmox.conf; touch "$SC"
  grep -q "nf_conntrack_max" "$SC"                  || echo "net.netfilter.nf_conntrack_max=1048576" >> "$SC"
  grep -q "nf_conntrack_tcp_timeout_established" "$SC" || echo "net.netfilter.nf_conntrack_tcp_timeout_established=28800" >> "$SC"
  modprobe nf_conntrack 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  ok "conntrack tuned."
fi

# 6) Reboot ----------------------------------------------------------------- #
echo
if [[ $NEED_REBOOT -eq 1 ]]; then
  warn "A reboot is recommended (initramfs/ARC changes)."
  case "$DO_REBOOT" in
    yes) log "Rebooting ..."; reboot;;
    no)  ok "Run 'reboot' when ready.";;
    *)   read -r -p "Reboot now? [y/N]: " r; [[ ${r,,} == y* ]] && reboot || ok "Run 'reboot' when ready.";;
  esac
else
  ok "Done. No reboot required."
fi
