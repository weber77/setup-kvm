#!/usr/bin/env bash
set -e

echo "=== Installing KVM and virtualization packages ==="

sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  bridge-utils \
  cloud-image-utils \
  qemu-utils

echo "=== Enabling libvirt ==="
sudo systemctl enable --now libvirtd

echo "=== Adding user to libvirt group ==="
sudo usermod -aG libvirt "$USER"
sudo usermod -aG kvm "$USER"

echo "=== Fixing possible container runtime network conflicts ==="

# Recreate default libvirt network if broken
if ! sudo virsh net-info default &>/dev/null; then
  echo "Recreating default libvirt network..."
  sudo virsh net-define /usr/share/libvirt/networks/default.xml
fi

sudo virsh net-autostart default || true
sudo virsh net-start default || true

echo "=== Ensuring storage directory exists ==="
sudo mkdir -p /var/lib/libvirt/images
sudo chown root:libvirt /var/lib/libvirt/images
sudo chmod 2770 /var/lib/libvirt/images

echo "=== KVM setup complete ==="
echo "Reboot if libvirt permissions fail."
