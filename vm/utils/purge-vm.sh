#!/usr/bin/env bash
set -e

if [ $# -lt 1 ]; then
  echo "ERROR: no VM name(s) provided"
  echo "Usage: $0 <vm-name> [<vm-name> ...]"
  exit 1
fi

IMG_DIR="/var/lib/libvirt/images"

purge_one() {
  local VM_NAME="$1"
  local CLOUD_DIR="$HOME/cloudinit-$VM_NAME"

  echo "=== Purging VM: $VM_NAME ==="

  if ! virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "ERROR: VM '$VM_NAME' does not exist."
    return 1
  fi

  echo "Destroying existing VM..."
  virsh destroy "$VM_NAME" 2>/dev/null || true
  virsh undefine "$VM_NAME"

  echo "Removing old images..."
  sudo rm -f "$IMG_DIR/"*"$VM_NAME"*

  rm -rf "$CLOUD_DIR"

  echo "=== $VM_NAME purged successfully === ✅"
}

failed=0
for VM_NAME in "$@"; do
  if ! purge_one "$VM_NAME"; then
    failed=1
  fi
done

exit "$failed"
