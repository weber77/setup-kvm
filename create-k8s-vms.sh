#!/usr/bin/env bash
set -e

VM_COUNT="$1"
KVM_SETUP_SCRIPT="$2"

if [ -z "$VM_COUNT" ] || [ -z "$KVM_SETUP_SCRIPT" ]; then
  echo "Usage: $0 <number_of_vms> <path_to_kvm_setup_script>"
  exit 1
fi

# Run KVM setup first
echo "=== Running KVM setup script ==="
bash "$KVM_SETUP_SCRIPT"

BASE_IMAGE="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"

echo "=== Checking Ubuntu cloud image ==="
if [ ! -f "$BASE_IMAGE" ]; then
  echo "Downloading Ubuntu cloud image..."
  sudo wget -O "$BASE_IMAGE" "$IMAGE_URL"
fi

echo "=== Creating VMs ==="

for i in $(seq 0 $((VM_COUNT-1))); do

  LETTER=$(printf "\\$(printf '%03o' $((97+i)))")
  VM_NAME="k8s-$LETTER"

  DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  SEED="/var/lib/libvirt/images/${VM_NAME}-seed.iso"
  WORKDIR="/tmp/${VM_NAME}-cloudinit"

  echo "---- Creating $VM_NAME ----"

  mkdir -p "$WORKDIR"

  cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: $VM_NAME
users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: \$6\$rounds=4096\$example\$examplehashedpassword
ssh_pwauth: true
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  cat > "$WORKDIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"
  sudo mv "$WORKDIR/seed.iso" "$SEED"

  sudo qemu-img create -f qcow2 -b "$BASE_IMAGE" "$DISK"

  virt-install \
    --name "$VM_NAME" \
    --memory 2048 \
    --vcpus 2 \
    --disk path="$DISK",format=qcow2 \
    --disk path="$SEED",device=cdrom \
    --import \
    --network network=default \
    --graphics none \
    --osinfo ubuntu22.04 \
    --noautoconsole

  echo "$VM_NAME created"

done

echo "=== All VMs created ==="
echo "Get IPs:"
echo "virsh net-dhcp-leases default"
