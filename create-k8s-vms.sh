#!/usr/bin/env bash
set -e

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <num_vms> <kvm_setup_script>"
  exit 1
fi

VM_COUNT=$1
KVM_SETUP_SCRIPT=$2

BASE_IMAGE="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
IMAGE_DIR="/var/lib/libvirt/images"
WORKDIR="$HOME/cloudinit-k8s"

MEMORY=2048
VCPUS=2
DISK_SIZE=20G

echo "== Running KVM setup script =="
bash "$KVM_SETUP_SCRIPT"

echo "== Preparing workspace =="
mkdir -p "$WORKDIR"
cd "$WORKDIR"

if [ ! -f "$BASE_IMAGE" ]; then
  echo "❌ Base image not found: $BASE_IMAGE"
  exit 1
fi

echo "== Creating $VM_COUNT VMs =="

for ((i=0;i<VM_COUNT;i++)); do
  LETTER=$(printf "\\$(printf '%03o' $((97+i)))")
  VM_NAME="k8s-$LETTER"

  echo "---- Creating $VM_NAME ----"

  VM_DISK="$IMAGE_DIR/${VM_NAME}.qcow2"
  SEED_ISO="$IMAGE_DIR/seed-${VM_NAME}.iso"

  # disk clone
  sudo qemu-img create -f qcow2 -b "$BASE_IMAGE" "$VM_DISK" "$DISK_SIZE"

  # cloud-init files
  cat <<EOF > user-data
#cloud-config
hostname: $VM_NAME
manage_etc_hosts: true

users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    shell: /bin/bash
    lock_passwd: false
    passwd: \$6\$rounds=4096\$abc123\$wqjvKQyYkQ1k0QxHcZ1jZ3uZr9Jx8Q5yR5n0GvVJm8r9lA6G7JkJkF6T8F8l9PzJYkZ8vJ1cQGZ5n7H0Jg0k1/

ssh_pwauth: true
disable_root: false

package_update: true
packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable qemu-guest-agent
  - systemctl start qemu-guest-agent
EOF

  cat <<EOF > meta-data
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  cloud-localds "seed-${VM_NAME}.iso" user-data meta-data
  sudo mv "seed-${VM_NAME}.iso" "$SEED_ISO"

  virt-install \
    --name "$VM_NAME" \
    --memory $MEMORY \
    --vcpus $VCPUS \
    --disk path="$VM_DISK",format=qcow2 \
    --disk path="$SEED_ISO",device=cdrom \
    --import \
    --network network=default \
    --graphics none \
    --osinfo ubuntu22.04 \
    --noautoconsole

done

echo
echo "✅ All VMs created"
echo
echo "Check IPs:"
echo "  virsh net-dhcp-leases default"
echo
echo "SSH:"
echo "  ssh ubuntu@<vm-ip>"
