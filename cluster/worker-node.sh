#!/usr/bin/env bash
set -e

echo "=== Kubernetes Node Preparation ==="

# Wait for apt locks
while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
while sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do sleep 2; done

echo "[1] Install dependencies"
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

echo "[2] Disable swap permanently"
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
sudo systemctl mask swap.target

echo "[3] Kernel modules + sysctl"
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

echo "[4] Install containerd"

if ! command -v containerd >/dev/null; then
  sudo mkdir -p /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \
  "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -y
  sudo apt-get install -y containerd.io
fi

echo "[5] Configure containerd"
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null

# Fix cgroup driver (CRITICAL)
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml

sudo systemctl daemon-reexec
sudo systemctl enable containerd
sudo systemctl restart containerd

echo "[6] Install Kubernetes components"

sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key \
  | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /" \
| sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update -y
sudo apt-get install -y \
  kubelet=1.33.0-1.1 \
  kubeadm=1.33.0-1.1 \
  kubectl=1.33.0-1.1

sudo apt-mark hold kubelet kubeadm kubectl

sudo systemctl enable kubelet

echo "[7] Pre-pull images"
sudo kubeadm config images pull \
  --cri-socket unix:///run/containerd/containerd.sock \
  --kubernetes-version v1.33.0

echo "✅ Node ready for kubeadm"