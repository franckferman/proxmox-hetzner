#!/usr/bin/env bash
#
# proxmox-hetzner — Automated Proxmox VE installer for Hetzner dedicated servers
# ----------------------------------------------------------------------------
# Installs Proxmox VE on a Hetzner dedicated server from the Rescue System,
# using the official Proxmox ISO + the official automated-install answer file,
# driven through a temporary QEMU/KVM virtual machine that targets the real disks.
#
# Improved fork of ariadata/proxmox-hetzner. Key improvements:
#   * Dual mode: fully INTERACTIVE prompts OR scriptable via --flags.
#   * Correct NIC handling (rescue name vs Proxmox predictable name).
#   * Wipes pre-existing mdadm/LVM/partitions first (no "ghost RAID").
#   * Configurable RAID level, filesystem and disk set (N disks).
#   * Injects an SSH public key for root (key-based login from first boot).
#   * Network config generated inline (no runtime dependency on GitHub).
#
# Usage:  ./pve-install.sh [--flag value ...]   (run with --help for the list)
#
set -euo pipefail

VERSION="2.1.0"

# --------------------------------------------------------------------------- #
#  Pretty output                                                              #
# --------------------------------------------------------------------------- #
if [[ -t 1 ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_B=$'\033[1;34m'; C_0=$'\033[0m'
else
  C_R=""; C_G=""; C_Y=""; C_B=""; C_0=""
fi
log()  { echo -e "${C_B}[*]${C_0} $*"; }
ok()   { echo -e "${C_G}[+]${C_0} $*"; }
warn() { echo -e "${C_Y}[!]${C_0} $*" >&2; }
err()  { echo -e "${C_R}[x]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }

# --------------------------------------------------------------------------- #
#  Defaults (overridable by flags / prompts)                                  #
# --------------------------------------------------------------------------- #
HOSTNAME_=""
FQDN=""
TIMEZONE=""
EMAIL=""
PRIVATE_SUBNET="192.168.42.0/24"
FILESYSTEM="zfs"
ZFS_RAID="raid1"            # raid0|raid1|raid10|raidz1|raidz2|raidz3
DISKS=""                   # comma-separated; empty => auto-detect NVMe (then any disk)
INTERFACE=""               # target Proxmox NIC name; empty => auto-detect
ROOT_PASSWORD=""
ROOT_PASSWORD_HASHED=""
GEN_PASSWORD="no"
SSH_KEY=""
SSH_KEY_FILE=""
COUNTRY="us"
KEYBOARD="en-us"
NON_INTERACTIVE="no"
ASSUME_YES="no"
DO_REBOOT="ask"            # ask|yes|no
WIPE="yes"
WIPE_FOREIGN="ask"         # ask|yes|no — wipe NON-target disks carrying a stale bootloader/RAID
WORKDIR="/root/proxmox-hetzner"

usage() {
  cat <<EOF
proxmox-hetzner installer v${VERSION}

Run with no flags for an interactive install, or pass flags to script it.
Any flag left out is asked interactively (unless --non-interactive).

Identity / locale:
  --hostname NAME            Short hostname (e.g. pve)
  --fqdn FQDN                Fully-qualified name (e.g. pve.example.com)
  --timezone TZ              e.g. Europe/Paris            (default: UTC)
  --email ADDR               Notifications address (root@pam mailto)
  --country CC               2-letter country            (default: us)
  --keyboard LAYOUT          Console keymap              (default: en-us)

Storage:
  --filesystem FS            zfs|ext4|xfs|btrfs          (default: zfs)
  --zfs-raid LEVEL           raid0|raid1|raid10|raidz1.. (default: raid1)
  --disks LIST               Comma list, e.g. /dev/nvme0n1,/dev/nvme1n1
                             (default: auto-detect NVMe, else all disks)
  --no-wipe                  Do NOT erase target disks first (not recommended)
  --wipe-foreign             Also neutralise NON-target disks holding a stale
                             bootloader/RAID (prevents BIOS boot-order hijack)
  --keep-foreign             Never touch non-target disks

Network:
  --interface NAME           Proxmox NIC name            (default: auto-detect)
  --private-subnet CIDR      Internal NAT subnet (vmbr1) (default: 192.168.42.0/24)

Credentials:
  --root-password PASS       Root password (plaintext)
  --root-password-hashed H   Pre-hashed root password
  --gen-password             Generate a random root password and print it
  --ssh-key "KEY"            Root authorized SSH public key (inline)
  --ssh-key-file PATH        Read the SSH public key from a file

Behaviour:
  --non-interactive, -y      Never prompt; use flags/defaults (fail if required missing)
  --assume-yes               Skip the final destructive confirmation
  --reboot ask|yes|no        Reboot into Proxmox at the end (default: ask)
  -h, --help                 This help
EOF
}

# --------------------------------------------------------------------------- #
#  Argument parsing                                                           #
# --------------------------------------------------------------------------- #
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hostname)             HOSTNAME_="$2"; shift 2;;
    --fqdn)                 FQDN="$2"; shift 2;;
    --timezone)             TIMEZONE="$2"; shift 2;;
    --email)                EMAIL="$2"; shift 2;;
    --country)              COUNTRY="$2"; shift 2;;
    --keyboard)             KEYBOARD="$2"; shift 2;;
    --filesystem)           FILESYSTEM="$2"; shift 2;;
    --zfs-raid)             ZFS_RAID="$2"; shift 2;;
    --disks)                DISKS="$2"; shift 2;;
    --no-wipe)              WIPE="no"; shift;;
    --wipe-foreign)         WIPE_FOREIGN="yes"; shift;;
    --keep-foreign)         WIPE_FOREIGN="no"; shift;;
    --interface)            INTERFACE="$2"; shift 2;;
    --private-subnet)       PRIVATE_SUBNET="$2"; shift 2;;
    --root-password)        ROOT_PASSWORD="$2"; shift 2;;
    --root-password-hashed) ROOT_PASSWORD_HASHED="$2"; shift 2;;
    --gen-password)         GEN_PASSWORD="yes"; shift;;
    --ssh-key)              SSH_KEY="$2"; shift 2;;
    --ssh-key-file)         SSH_KEY_FILE="$2"; shift 2;;
    --non-interactive|-y|--yes) NON_INTERACTIVE="yes"; shift;;
    --assume-yes)           ASSUME_YES="yes"; shift;;
    --reboot)               DO_REBOOT="$2"; shift 2;;
    -h|--help)              usage; exit 0;;
    *) die "Unknown argument: $1  (try --help)";;
  esac
done

# --------------------------------------------------------------------------- #
#  Pre-flight checks                                                          #
# --------------------------------------------------------------------------- #
[[ $EUID -eq 0 ]] || die "Run this script as root."
command -v ip >/dev/null || die "'ip' not found - run from the Hetzner Rescue System."
[[ -e /dev/kvm ]] || die "/dev/kvm missing - KVM is required (run on the bare-metal rescue)."
grep -qi rescue /etc/hostname 2>/dev/null || warn "This does not look like the Hetzner Rescue System - continue at your own risk."

mkdir -p "$WORKDIR"; cd "$WORKDIR"

# --------------------------------------------------------------------------- #
#  Detection helpers                                                          #
# --------------------------------------------------------------------------- #
RESCUE_NIC="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n $RESCUE_NIC ]] || die "Could not detect the active network interface."

detect_target_nic() {
  # Name the installed Proxmox will use (systemd predictable naming),
  # which usually differs from the rescue's 'eth0'.
  local out onb path
  out="$(udevadm test-builtin net_id "/sys/class/net/$RESCUE_NIC" 2>/dev/null || true)"
  onb="$(sed -n 's/^ID_NET_NAME_ONBOARD=//p' <<<"$out" | head -1)"
  path="$(sed -n 's/^ID_NET_NAME_PATH=//p' <<<"$out" | head -1)"
  echo "${onb:-${path:-$RESCUE_NIC}}"
}

MAIN_IPV4_CIDR="$(ip -4 -o addr show "$RESCUE_NIC" | awk '{print $4; exit}')"
MAIN_IPV4="${MAIN_IPV4_CIDR%/*}"
MAIN_IPV4_GW="$(ip -4 route show default | awk '{print $3; exit}')"
MAC_ADDRESS="$(cat "/sys/class/net/$RESCUE_NIC/address")"
IPV6_CIDR="$(ip -6 -o addr show "$RESCUE_NIC" scope global | awk '{print $4; exit}')"
MAIN_IPV6="${IPV6_CIDR%/*}"
[[ -n $MAIN_IPV4_CIDR ]] || die "Could not detect the IPv4 address on $RESCUE_NIC."

# IPv6 for the private bridge (derive a /80 from the first 4 groups), if IPv6 present
FIRST_IPV6_CIDR=""
if [[ -n $IPV6_CIDR ]]; then
  FIRST_IPV6_CIDR="$(cut -d/ -f1 <<<"$IPV6_CIDR" | cut -d: -f1-4):1::1/80"
fi

# --------------------------------------------------------------------------- #
#  Resolve interactive values                                                 #
# --------------------------------------------------------------------------- #
resolve() {  # $1 var, $2 prompt, $3 default
  local __v=$1 __t=$2 __d=$3
  [[ -n ${!__v} ]] && return 0
  if [[ $NON_INTERACTIVE == yes ]]; then printf -v "$__v" '%s' "$__d"; return 0; fi
  local __in; read -e -r -p "$__t [${__d}]: " __in || true
  printf -v "$__v" '%s' "${__in:-$__d}"
}

[[ -z $INTERFACE ]] && INTERFACE="$(detect_target_nic)"
resolve INTERFACE      "Proxmox interface name"           "$INTERFACE"
resolve HOSTNAME_      "Hostname"                          "pve"
resolve FQDN           "FQDN"                              "${HOSTNAME_}.local"
resolve TIMEZONE       "Timezone"                          "UTC"
resolve EMAIL          "Notification email"                "admin@${FQDN}"
resolve PRIVATE_SUBNET "Private NAT subnet (vmbr1)"        "$PRIVATE_SUBNET"
resolve FILESYSTEM     "Filesystem (zfs/ext4/xfs/btrfs)"   "$FILESYSTEM"
[[ $FILESYSTEM == zfs ]] && resolve ZFS_RAID "ZFS RAID level" "$ZFS_RAID"

# Private subnet -> gateway (.1) + mask
PRIV_NET="${PRIVATE_SUBNET%/*}"; PRIV_MASK="${PRIVATE_SUBNET#*/}"
PRIV_GW="${PRIV_NET%.*}.1"
PRIV_GW_CIDR="${PRIV_GW}/${PRIV_MASK}"

# --------------------------------------------------------------------------- #
#  Root password                                                              #
# --------------------------------------------------------------------------- #
GENERATED_PW=""
if [[ $GEN_PASSWORD == yes && -z $ROOT_PASSWORD && -z $ROOT_PASSWORD_HASHED ]]; then
  ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  GENERATED_PW="$ROOT_PASSWORD"
fi
if [[ -z $ROOT_PASSWORD && -z $ROOT_PASSWORD_HASHED ]]; then
  [[ $NON_INTERACTIVE == yes ]] && die "Need --root-password / --root-password-hashed / --gen-password."
  read -rsp "Root password: " ROOT_PASSWORD; echo
  [[ -n $ROOT_PASSWORD ]] || die "Empty password."
fi

# --------------------------------------------------------------------------- #
#  SSH key                                                                    #
# --------------------------------------------------------------------------- #
if [[ -n $SSH_KEY_FILE ]]; then
  [[ -r $SSH_KEY_FILE ]] || die "Cannot read --ssh-key-file: $SSH_KEY_FILE"
  SSH_KEY="$(< "$SSH_KEY_FILE")"
fi

# --------------------------------------------------------------------------- #
#  Resolve disks                                                              #
# --------------------------------------------------------------------------- #
declare -a DISK_ARR
if [[ -n $DISKS ]]; then
  IFS=',' read -ra DISK_ARR <<<"$DISKS"
else
  mapfile -t DISK_ARR < <(lsblk -dpno NAME,TYPE | awk '$2=="disk" && $1 ~ /nvme/ {print $1}')
  [[ ${#DISK_ARR[@]} -gt 0 ]] || mapfile -t DISK_ARR < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')
fi
[[ ${#DISK_ARR[@]} -gt 0 ]] || die "No target disks found."
for d in "${DISK_ARR[@]}"; do [[ -b $d ]] || die "Not a block device: $d"; done

# --------------------------------------------------------------------------- #
#  Summary + confirmation                                                     #
# --------------------------------------------------------------------------- #
echo
echo -e "${C_Y}================ INSTALL SUMMARY ================${C_0}"
printf "  Hostname / FQDN : %s / %s\n"  "$HOSTNAME_" "$FQDN"
printf "  Timezone / Mail : %s / %s\n"  "$TIMEZONE" "$EMAIL"
printf "  Proxmox NIC     : %s (rescue sees: %s)\n" "$INTERFACE" "$RESCUE_NIC"
printf "  Public IPv4     : %s  gw %s\n" "$MAIN_IPV4_CIDR" "$MAIN_IPV4_GW"
printf "  Public IPv6     : %s\n"        "${IPV6_CIDR:-none}"
printf "  Private (vmbr1) : %s  gw %s\n" "$PRIVATE_SUBNET" "$PRIV_GW_CIDR"
printf "  Filesystem      : %s%s\n"      "$FILESYSTEM" "$([[ $FILESYSTEM == zfs ]] && echo " ($ZFS_RAID)")"
printf "  Target disks    : %s\n"        "${DISK_ARR[*]}"
printf "  Wipe disks      : %s\n"        "$WIPE"
printf "  SSH key         : %s\n"        "$([[ -n $SSH_KEY ]] && echo "yes" || echo "no")"
echo -e "${C_Y}================================================${C_0}"
warn "ALL DATA on the target disks will be DESTROYED."
if [[ $ASSUME_YES != yes && $NON_INTERACTIVE != yes ]]; then
  read -r -p "Type 'yes' to proceed: " c; [[ $c == yes ]] || die "Aborted."
fi

# --------------------------------------------------------------------------- #
#  Wipe pre-existing arrays / LVM / signatures (prevents 'ghost RAID')        #
# --------------------------------------------------------------------------- #
wipe_disks() {
  log "Tearing down existing mdadm/LVM and wiping target disks ..."
  swapoff -a 2>/dev/null || true
  vgchange -an 2>/dev/null || true
  for md in /dev/md*; do [[ -b $md ]] && mdadm --stop "$md" 2>/dev/null || true; done
  for d in "${DISK_ARR[@]}"; do
    wipefs -a "$d" 2>/dev/null || true
    sgdisk --zap-all "$d" 2>/dev/null || true
    blkdiscard -f "$d" 2>/dev/null || true
  done
  partprobe 2>/dev/null || true
  ok "Disks wiped."
}

# Non-target disks that still carry a bootloader / RAID metadata can hijack the
# (legacy) BIOS boot order and prevent the freshly installed system from booting.
# This is THE failure mode seen in practice: an old GRUB left on a data disk.
handle_foreign_boot() {
  local -A is_target=(); local d reason f; local -a foreign=()
  for d in "${DISK_ARR[@]}"; do is_target["$d"]=1; done
  while read -r d; do
    [[ -n ${is_target[$d]:-} ]] && continue
    reason=""
    dd if="$d" bs=512 count=1 2>/dev/null | grep -qa GRUB && reason="MBR bootloader"
    lsblk -no FSTYPE "$d" 2>/dev/null | grep -q linux_raid_member && reason="${reason:+$reason + }mdadm member"
    [[ -n $reason ]] && foreign+=("$d|$reason")
  done < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}')

  [[ ${#foreign[@]} -eq 0 ]] && { ok "No competing bootloader on other disks."; return 0; }

  warn "Non-target disks carry a bootloader / RAID metadata:"
  for f in "${foreign[@]}"; do warn "    - ${f%%|*}  (${f#*|})"; done
  warn "On legacy BIOS these can HIJACK the boot order and stop Proxmox from booting."

  local act="$WIPE_FOREIGN"
  if [[ $act == ask ]]; then
    if [[ $NON_INTERACTIVE == yes ]]; then act=no
    else read -r -p "Wipe these disks too? (recommended unless they hold data you keep) [y/N]: " a
         [[ ${a,,} == y* ]] && act=yes || act=no; fi
  fi
  if [[ $act == yes ]]; then
    for md in /dev/md*; do [[ -b $md ]] && mdadm --stop "$md" 2>/dev/null || true; done
    for f in "${foreign[@]}"; do
      d="${f%%|*}"
      mdadm --zero-superblock "${d}"* 2>/dev/null || true
      wipefs -a "$d" 2>/dev/null || true
      sgdisk --zap-all "$d" 2>/dev/null || true
      dd if=/dev/zero of="$d" bs=1M count=20 conv=fsync 2>/dev/null || true
      ok "Neutralised foreign disk: $d"
    done
    partprobe 2>/dev/null || true
  else
    warn "Leaving them as-is. If the server fails to boot after reboot, this is the most likely cause."
  fi
}

[[ $WIPE == yes ]] && wipe_disks || warn "Skipping disk wipe (--no-wipe)."
handle_foreign_boot

# --------------------------------------------------------------------------- #
#  Packages + ISO                                                             #
# --------------------------------------------------------------------------- #
log "Installing helper packages ..."
echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >/etc/apt/sources.list.d/pve.list
curl -fsSL -o /etc/apt/trusted.gpg.d/proxmox-release-bookworm.gpg \
  https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg
apt-get -qq update
DEBIAN_FRONTEND=noninteractive apt-get -qq install -y \
  proxmox-auto-install-assistant xorriso ovmf wget sshpass netcat-openbsd >/dev/null
ok "Packages installed."

if [[ ! -f pve.iso ]]; then
  log "Fetching latest Proxmox VE ISO ..."
  ISO_URL="$(curl -fsSL https://enterprise.proxmox.com/iso/ \
    | grep -oP 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -1)"
  [[ -n $ISO_URL ]] || die "Could not find a Proxmox ISO."
  wget -q --show-progress -O pve.iso "https://enterprise.proxmox.com/iso/${ISO_URL}"
  ok "Downloaded ${ISO_URL}."
else
  warn "pve.iso already present - reusing it."
fi

# --------------------------------------------------------------------------- #
#  answer.toml (dynamic disk list + chosen raid/fs + ssh key)                 #
# --------------------------------------------------------------------------- #
log "Generating answer.toml ..."
letters=({a..z})
disk_list_toml=""; qemu_drives=()
for i in "${!DISK_ARR[@]}"; do
  disk_list_toml+="\"/dev/vd${letters[$i]}\", "
  qemu_drives+=( -drive "file=${DISK_ARR[$i]},format=raw,media=disk,if=virtio" )
done
disk_list_toml="${disk_list_toml%, }"

{
  echo "[global]"
  echo "    keyboard = \"$KEYBOARD\""
  echo "    country = \"$COUNTRY\""
  echo "    fqdn = \"$FQDN\""
  echo "    mailto = \"$EMAIL\""
  echo "    timezone = \"$TIMEZONE\""
  if [[ -n $ROOT_PASSWORD_HASHED ]]; then
    echo "    root_password_hashed = \"$ROOT_PASSWORD_HASHED\""
  else
    echo "    root_password = \"$ROOT_PASSWORD\""
  fi
  echo "    reboot_on_error = false"
  [[ -n $SSH_KEY ]] && echo "    root_ssh_keys = [\"$SSH_KEY\"]"
  echo
  echo "[network]"
  echo "    source = \"from-dhcp\""
  echo
  echo "[disk-setup]"
  echo "    filesystem = \"$FILESYSTEM\""
  [[ $FILESYSTEM == zfs ]] && echo "    zfs.raid = \"$ZFS_RAID\""
  echo "    disk_list = [$disk_list_toml]"
} > answer.toml

log "Building the auto-install ISO ..."
proxmox-auto-install-assistant prepare-iso pve.iso \
  --fetch-from iso --answer-file answer.toml --output pve-autoinstall.iso >/dev/null
ok "Auto-install ISO ready."

# --------------------------------------------------------------------------- #
#  Run the installer inside QEMU (writes to the real disks)                   #
# --------------------------------------------------------------------------- #
UEFI_OPTS=(); [[ -d /sys/firmware/efi ]] && UEFI_OPTS=(-bios /usr/share/ovmf/OVMF.fd)
VCPUS=$(( $(nproc) > 8 ? 8 : $(nproc) )); VMEM=4096

log "Installing Proxmox VE (QEMU) - this takes ~5-10 min, please wait ..."
qemu-system-x86_64 -enable-kvm "${UEFI_OPTS[@]}" -cpu host -smp "$VCPUS" -m "$VMEM" \
  -boot d -cdrom ./pve-autoinstall.iso "${qemu_drives[@]}" \
  -no-reboot -display none -serial null >/dev/null 2>&1 || die "Installer VM failed."
ok "Base installation finished."

# --------------------------------------------------------------------------- #
#  Boot the installed system + post-install configuration over SSH            #
# --------------------------------------------------------------------------- #
log "Booting installed system for post-install config ..."
nohup qemu-system-x86_64 -enable-kvm "${UEFI_OPTS[@]}" -cpu host -smp "$VCPUS" -m "$VMEM" \
  -device e1000,netdev=n0 -netdev user,id=n0,hostfwd=tcp::5555-:22 \
  "${qemu_drives[@]}" -display none >qemu_boot.log 2>&1 &
QEMU_PID=$!

for i in $(seq 1 60); do
  nc -z localhost 5555 && break
  [[ $i -eq 60 ]] && die "Installed system did not come up on SSH."
  sleep 5
done
ok "Installed system is up."

# Build the network/host config inline, then push it in.
cat > interfaces <<EOF
# Generated by proxmox-hetzner
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
iface lo inet6 loopback

iface ${INTERFACE} inet manual

auto vmbr0
iface vmbr0 inet static
    address ${MAIN_IPV4_CIDR}
    gateway ${MAIN_IPV4_GW}
    bridge-ports ${INTERFACE}
    bridge-stp off
    bridge-fd 1
    bridge-vlan-aware yes
    bridge-vids 2-4094
    pointopoint ${MAIN_IPV4_GW}
    up sysctl -p
EOF
if [[ -n $IPV6_CIDR ]]; then
cat >> interfaces <<EOF

iface vmbr0 inet6 static
    address ${IPV6_CIDR}
    gateway fe80::1
EOF
fi
cat >> interfaces <<EOF

auto vmbr1
iface vmbr1 inet static
    address ${PRIV_GW_CIDR}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '${PRIVATE_SUBNET}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${PRIVATE_SUBNET}' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF
[[ -n $FIRST_IPV6_CIDR ]] && printf '\niface vmbr1 inet6 static\n    address %s\n' "$FIRST_IPV6_CIDR" >> interfaces

cat > hosts <<EOF
127.0.0.1 localhost.localdomain localhost
${MAIN_IPV4} ${FQDN} ${HOSTNAME_}
${MAIN_IPV6:-::1} ${FQDN} ${HOSTNAME_}

::1 ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

cat > 99-proxmox.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

SSHP=(sshpass -p "$ROOT_PASSWORD")
SOPT=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
ssh-keygen -R "[localhost]:5555" -f /root/.ssh/known_hosts >/dev/null 2>&1 || true

"${SSHP[@]}" scp -P 5555 "${SOPT[@]}" interfaces     root@localhost:/etc/network/interfaces
"${SSHP[@]}" scp -P 5555 "${SOPT[@]}" hosts          root@localhost:/etc/hosts
"${SSHP[@]}" scp -P 5555 "${SOPT[@]}" 99-proxmox.conf root@localhost:/etc/sysctl.d/99-proxmox.conf
"${SSHP[@]}" ssh -p 5555 "${SOPT[@]}" root@localhost \
  "echo '$HOSTNAME_' >/etc/hostname; \
   printf 'nameserver 185.12.64.1\nnameserver 185.12.64.2\nnameserver 1.1.1.1\n' >/etc/resolv.conf; \
   systemctl disable --now rpcbind rpcbind.socket 2>/dev/null || true; \
   [ -f /etc/apt/sources.list ] && mv /etc/apt/sources.list /etc/apt/sources.list.bak || true"
ok "Post-install configuration applied."

log "Powering off helper VM ..."
"${SSHP[@]}" ssh -p 5555 "${SOPT[@]}" root@localhost poweroff 2>/dev/null || true
wait "$QEMU_PID" 2>/dev/null || true
ok "Helper VM stopped."

# --------------------------------------------------------------------------- #
#  Done                                                                       #
# --------------------------------------------------------------------------- #
echo
ok "Proxmox VE installed. Web UI will be at: https://${MAIN_IPV4}:8006"
[[ -n $GENERATED_PW ]] && warn "Generated root password: ${GENERATED_PW}  (change it after first login)"

do_reboot() { log "Rebooting into Proxmox ..."; reboot; }
case "$DO_REBOOT" in
  yes) do_reboot;;
  no)  ok "Not rebooting. Run 'reboot' when ready.";;
  *)   if [[ $NON_INTERACTIVE == yes ]]; then ok "Not rebooting (non-interactive). Run 'reboot' when ready.";
       else read -r -p "Reboot into Proxmox now? [y/N]: " r; [[ ${r,,} == y* ]] && do_reboot || ok "Run 'reboot' when ready."; fi;;
esac
