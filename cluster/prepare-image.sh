#!/usr/bin/env bash
set -e

TARGET_IMAGE="${BASE_IMAGE_OVERRIDE:-/var/lib/libvirt/images/k8s-base.qcow2}"
VM_NAME="tmp-a"
SSH_PASS="ubuntu"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

echo "======================================"
echo "Creating temporary VM..."
echo "======================================"

./create-vms.sh --prefix tmp 1

echo "Waiting for VM MAC address..."

# Get the MAC from virsh
VM_MAC=$(virsh dumpxml "$VM_NAME" | awk -F\' '/mac address/ {print $2}')
VM_IP=""

echo "Waiting for VM IP..."
while [ -z "$VM_IP" ]; do
  VM_IP=$(virsh net-dhcp-leases default \
    | grep -i "$VM_MAC" \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /\//) print $i}' \
    | cut -d/ -f1)
  
  if [ -z "$VM_IP" ]; then
    echo "  IP not yet assigned for $VM_MAC, retrying..."
    sleep 2
  fi
done

echo "VM IP: $VM_IP"

echo "Waiting for SSH..."
until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "echo ok" 2>/dev/null; do
  sleep 3
done

echo "Waiting for cloud-init..."
MAX_WAIT=300
WAITED=0
until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "cloud-init status 2>/dev/null | grep -q done"; do
  sleep 5
  WAITED=$((WAITED+5))
  if [ "$WAITED" -ge "$MAX_WAIT" ]; then
    echo "Timeout waiting for cloud-init"
    exit 1
  fi
done

echo "Running Kubernetes setup..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP 'bash -s' < worker-node.sh

echo "Shutting down VM..."
sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$VM_IP "sudo shutdown now" || true

echo "Waiting for VM to shut down..."

while true; do
  STATE=$(virsh domstate "$VM_NAME" 2>/dev/null || echo "shut off")

  if [[ "$STATE" == "shut off" ]]; then
    break
  fi

  echo "  still running..."
  sleep 3
done

echo "VM is fully stopped ✅"

echo "Cleaning up temporary VM..."
sudo virsh undefine "$VM_NAME"
sudo rm -f "/var/lib/libvirt/images/${VM_NAME}.qcow2"
sudo rm -f "/var/lib/libvirt/images/${VM_NAME}-seed.iso"