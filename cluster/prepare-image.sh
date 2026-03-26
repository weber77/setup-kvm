#!/usr/bin/env bash
set -e

TARGET_IMAGE="${BASE_IMAGE_OVERRIDE:-/var/lib/libvirt/images/k8s-base.qcow2}"
VM_NAME="tmp-a"
SSH_PASS="ubuntu"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

echo "=== Creating temp VM ==="
./create-vms.sh --prefix tmp 1

echo "=== Getting IP ==="

VM_MAC=$(virsh dumpxml "$VM_NAME" | awk -F\' '/mac address/ {print $2}')
VM_IP=""

while [ -z "$VM_IP" ]; do
  VM_IP=$(virsh net-dhcp-leases default \
    | grep -i "$VM_MAC" \
    | awk '{print $5}' | cut -d/ -f1)
  sleep 2
done

echo "VM IP: $VM_IP"

echo "=== Waiting for SSH ==="
until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "echo ok" 2>/dev/null; do
  sleep 3
done

echo "=== Waiting for cloud-init ==="
sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "cloud-init status --wait"

echo "=== Installing Kubernetes base ==="
sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP 'bash -s' < k8s-node.sh

echo "=== Cleaning system for image ==="

sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP <<'EOF'
set -e

# Stop services cleanly
sudo systemctl stop kubelet || true

# Clean cloud-init
sudo cloud-init clean

# Remove machine-id (CRITICAL)
sudo truncate -s 0 /etc/machine-id

# Remove SSH host keys (regen on boot)
sudo rm -f /etc/ssh/ssh_host_*

# Clean logs
sudo rm -rf /var/log/*

# Clean apt
sudo apt-get clean

sync
EOF

echo "=== Shutdown VM ==="
sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "sudo systemctl poweroff" || true

# Wait for VM to actually shut down (with timeout)
TIMEOUT=60
ELAPSED=0
while true; do
  STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "shut off")
  [[ "$STATE" == "shut off" ]] && break
  sleep 3
  ELAPSED=$((ELAPSED+3))
  if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
    echo "VM did not shut down in $TIMEOUT seconds. Forcing via virsh destroy..."
    virsh destroy "$VM_NAME"
    break
  fi
done

echo "=== Convert to base image ==="
sudo qemu-img convert -f qcow2 -O qcow2 "/var/lib/libvirt/images/${VM_NAME}.qcow2" "${TARGET_IMAGE}.tmp"
sudo rm -f "/var/lib/libvirt/images/${VM_NAME}.qcow2"
sudo mv "${TARGET_IMAGE}.tmp" "$TARGET_IMAGE"

echo "=== Cleanup ==="
sudo virsh undefine "$VM_NAME"
sudo rm -f "/var/lib/libvirt/images/${VM_NAME}-seed.iso"

echo "✅ Base image ready: $TARGET_IMAGE"