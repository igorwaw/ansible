#!/usr/bin/env bash
# Unlocks and mounts the Btrfs RAID1 pool and all SnapRAID member disks
# using a single password. Meant to be run manually over SSH after boot,
# not wired into the boot process itself.
set -euo pipefail

# --- Configuration -------------------------------------------------------
# Fill in real UUIDs with `blkid` or `lsblk -o NAME,UUID`.
# Add/remove/reorder entries here when disks change - nothing below
# this block needs editing.

# Btrfs RAID1 pool: 2 disks, LUKS individually, btrfs handles the mirroring
BTRFS_RAID1_UUIDS=(
  "de3657d0-4493-49cd-93ba-0aef8110492f"
  "485a4b4f-8631-413d-b9ea-4d9548592c08"
)
BTRFS_MAPPER_PREFIX="luks-btrfs"

# Subvolumes on that pool: "name:mountpoint" (empty mountpoint = don't mount)
BTRFS_SUBVOLUMES=(
  "othervol:/data/other"
  "noshare:/data/noshare"
)

# SnapRAID members (parity + data disks), each independently encrypted
# format: "UUID:mapper_name:mountpoint:fstype"
SNAPRAID_DISKS=(
   "62ed79f4-9c9a-4b33-912f-c950ede76a9d:snapraid-parity1:/data/parity1:ext4"
   "6c76b2d5-0c09-4dac-a95b-423536754b9f:snapraid-filmy:/data/filmy:ext4"
   "427cf683-ffb9-443f-b4f1-977cd7aa6323:snapraid-video2:/data/video2:ext4"
   "da6a70cd-3913-4642-b169-4ad9d3705af9:snapraid-seriale:/data/seriale:ext4"
)

KEYFILE_ENC="/root/master.key.gpg"
KEYFILE_TMP="/dev/shm/master.key"

# --- Cleanup ---------------------------------------------------------------
cleanup() {
  [ -f "$KEYFILE_TMP" ] && shred -u "$KEYFILE_TMP"
}
trap cleanup EXIT

# --- One password unlocks the shared keyfile --------------------------------
read -r -s -p "Password: " PASSPHRASE
echo
echo -n "$PASSPHRASE" | gpg --batch --yes --passphrase-fd 0 --decrypt "$KEYFILE_ENC" > "$KEYFILE_TMP"
unset PASSPHRASE
chmod 600 "$KEYFILE_TMP"

# --- Unlock and assemble the Btrfs RAID1 pool -------------------------------
btrfs_mapper_devices=()
i=1
for uuid in "${BTRFS_RAID1_UUIDS[@]}"; do
  name="${BTRFS_MAPPER_PREFIX}${i}"
  cryptsetup luksOpen "/dev/disk/by-uuid/$uuid" "$name" --key-file "$KEYFILE_TMP"
  btrfs_mapper_devices+=("/dev/mapper/$name")
  i=$((i + 1))
done

btrfs device scan

for entry in "${BTRFS_SUBVOLUMES[@]}"; do
  subvol="${entry%%:*}"
  mountpoint="${entry#*:}"
  [ -z "$mountpoint" ] && continue
  mkdir -p "$mountpoint"
  mount -o "subvol=${subvol},nodev,noexec,noatime" "${btrfs_mapper_devices[0]}" "$mountpoint"
done

# --- Unlock and mount each SnapRAID member disk -----------------------------
for entry in "${SNAPRAID_DISKS[@]}"; do
  IFS=':' read -r uuid mapper_name mountpoint fstype <<< "$entry"
  cryptsetup luksOpen "/dev/disk/by-uuid/$uuid" "$mapper_name" --key-file "$KEYFILE_TMP"
  mkdir -p "$mountpoint"
  mount -t "$fstype" -o nodev,noexec,noatime "/dev/mapper/$mapper_name" "$mountpoint"
done

echo "All volumes unlocked and mounted."

# --- Start dependent services now that data is available -------------------
SYSTEMD_SERVICES=(
  "docker.service"
  "syncthing@igor.service"
  "smbd.service"
)
DOCKER_CONTAINERS=(
  "grafana"
  "jellyfin"
)

for service in "${SYSTEMD_SERVICES[@]}"; do
  systemctl start "$service"
done

for container in "${DOCKER_CONTAINERS[@]}"; do
  docker start "$container"
done
