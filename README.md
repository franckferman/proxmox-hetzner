# proxmox-hetzner

Automated **Proxmox VE** installer for **Hetzner dedicated servers**, driven entirely from the Hetzner Rescue System — no KVM/console needed.

It boots the **official Proxmox ISO** inside a temporary QEMU/KVM VM that targets the real disks, using Proxmox's official *automated installation* answer file. You get a stock Proxmox install (ZFS-on-root supported) without touching a physical console.

> Improved fork of [`ariadata/proxmox-hetzner`](https://github.com/ariadata/proxmox-hetzner). All credit for the original approach goes to the upstream authors.

## What's improved in this fork

- **Dual mode** — fully **interactive** prompts *or* **scriptable** via `--flags` (`--non-interactive` for zero prompts).
- **Correct NIC handling** — detects the rescue interface (e.g. `eth0`) for address discovery **and** computes the name the installed Proxmox will actually use (e.g. `eno1`, via `udevadm net_id`). This avoids the classic "no network after reboot" trap.
- **Clean disks first** — stops any pre-existing `mdadm` arrays, deactivates LVM and wipes signatures (`wipefs` / `sgdisk --zap-all` / `blkdiscard`) before installing. Prevents stale "ghost RAID" metadata from breaking the boot.
- **Boot-order safety** — also detects and (optionally) neutralises a stale bootloader/RAID left on **non-target** disks. On legacy BIOS such a leftover bootloader hijacks the boot order and stops Proxmox from booting (`--wipe-foreign` / `--keep-foreign`).
- **Configurable storage** — choose the **filesystem** (`zfs`/`ext4`/`xfs`/`btrfs`), the **RAID level** (`raid0`/`raid1`/`raid10`/`raidz…`) and the **disk set** (any number of disks).
- **SSH key from first boot** — injects a root authorized key via the answer file (`root_ssh_keys`).
- **Self-contained networking** — the `vmbr0` (public) + `vmbr1` (private NAT) config is generated inline, with no runtime dependency on this repo.
- **Safer bash** — `set -euo pipefail`, input validation (root/rescue/KVM/disks), and an explicit destructive-action confirmation.

## Requirements

- A Hetzner dedicated server booted into the **Rescue System** (Linux 64-bit).
- Hardware virtualization (`/dev/kvm`) — always available on bare metal.

## Usage

From the rescue shell:

```bash
curl -fsSL https://raw.githubusercontent.com/franckferman/proxmox-hetzner/main/pve-install.sh -o pve-install.sh
# review it, then:
bash pve-install.sh
```

### Interactive (default)

Run with no flags and answer the prompts (sensible auto-detected defaults are offered).

### Non-interactive / scripted

```bash
bash pve-install.sh \
  --hostname pve --fqdn pve.example.com \
  --timezone Europe/Paris --email admin@example.com \
  --filesystem zfs --zfs-raid raid1 \
  --disks /dev/nvme0n1,/dev/nvme1n1 \
  --private-subnet 192.168.42.0/24 \
  --ssh-key-file ~/.ssh/id_ed25519.pub \
  --gen-password --reboot no --non-interactive --assume-yes
```

Run `bash pve-install.sh --help` for the full flag list.

> ⚠️ **`--zfs-raid raid0` has no redundancy.** A single disk failure destroys the whole hypervisor and all VMs. Use it only with solid, regular backups.

## After install

The script configures host networking (public `vmbr0` + NAT `vmbr1`). Typical next steps:

- **Add a data pool** for ISOs / templates / backups, e.g. a separate disk:
  ```bash
  zpool create -o ashift=12 tank /dev/disk/by-id/<your-disk>
  ```
  then *Datacenter → Storage → Add → ZFS*.
- **Expose VM services** with DNAT rules (the script only sets up outbound NAT/masquerade).
- **Schedule `vzdump` backups** to your data pool (essential if root is `raid0`).

## Post-install optimizations (optional)

After the host has booted, run `post-install.sh` **on the Proxmox host** for common tweaks (all idempotent and toggleable):

```bash
curl -fsSL https://raw.githubusercontent.com/franckferman/proxmox-hetzner/main/post-install.sh -o post-install.sh
bash post-install.sh                 # interactive defaults
# or scripted, e.g.:
bash post-install.sh --arc-max 16 --reboot no
```

It can: `apt dist-upgrade` + `pveam update`, install utilities (curl, libguestfs-tools, unzip, iptables-persistent, net-tools), remove the "no valid subscription" popup, tune **ZFS ARC** (`--arc-min`/`--arc-max`, default 6/12 GiB — raise it on high-RAM hosts), and tune `nf_conntrack`. Run `post-install.sh --help` for flags.

## Troubleshooting

**Server doesn't come back after the first reboot (no ping, no SSH).** On a legacy-BIOS server the firmware may be booting a *different* disk that still carries an old bootloader (e.g. a former install on a data disk), which drops to `grub rescue>` and hangs. Re-activate the Hetzner **Rescue System**, then wipe the offending disk's boot sector so the BIOS falls through to the freshly installed disk:

```bash
wipefs -a /dev/sdX && sgdisk --zap-all /dev/sdX && dd if=/dev/zero of=/dev/sdX bs=1M count=20
```

The installer now does this automatically via `--wipe-foreign` (see *Boot-order safety* above).

## Networking model (single public IP)

Hetzner gives one public IP bound to the host MAC, and filters MACs at the switch. VMs therefore sit on the private `vmbr1` (`192.168.x.0/24`) and reach the internet via NAT/masquerade through `vmbr0`. To give a VM its own public IP, order an additional IP with a dedicated MAC (bridged) or a routed subnet.

## Credits

- Upstream: [`ariadata/proxmox-hetzner`](https://github.com/ariadata/proxmox-hetzner)
- Built on Proxmox's official [automated installation](https://pve.proxmox.com/wiki/Automated_Installation).

## License

See [`LICENSE`](./LICENSE).
