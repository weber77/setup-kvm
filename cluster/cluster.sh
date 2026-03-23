#!/usr/bin/env bash
set -e

print_manual() {
  echo "Manual:"
  echo "  ./cluster.sh --control-plane --workers 2"
  echo "  ./cluster.sh --workers 2"
  echo "  ./cluster.sh --workers 2 --worker-only"
  echo "  ./cluster.sh --prepare-image"
  echo "  ./cluster.sh --base-image <path>"
}

BASE_IMAGE="/var/lib/libvirt/images/k8s-base.qcow2"
WORKERS=0
WORKER_ONLY=false
CONTROL_PLANE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_manual
      exit 0
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --worker-only)
      WORKER_ONLY=true
      CONTROL_PLANE=false
      shift
      ;;
    --control-plane)
      CONTROL_PLANE=true
      shift
      ;;
    --prepare-image)
      ./prepare-image.sh
      exit 0
      ;;
    --base-image)
      BASE_IMAGE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [ ! -f "$BASE_IMAGE" ]; then
  echo "Base image not found. Preparing..."
  ./prepare-image.sh --output "$BASE_IMAGE"
else
  echo "Using existing base image: $BASE_IMAGE"
fi

TOTAL=$WORKERS
if [ "$CONTROL_PLANE" = true ]; then
  TOTAL=$((WORKERS + 1))
fi

echo "Creating $TOTAL VMs..."
BASE_IMAGE_OVERRIDE="$BASE_IMAGE" ./create-vms.sh "$TOTAL"

echo "Waiting for VMs to get IPs..."
sleep 10

IPS=()

for vm in $(virsh list --name | grep k8s); do
  ip=$(virsh net-dhcp-leases default \
    | awk -v name="$vm" '$6 == name {print $5}' \
    | cut -d/ -f1)

  if [ -z "$ip" ]; then
    echo "Failed to get IP for $vm"
    exit 1
  fi

  IPS+=("$ip")
done

CONTROL_IP=""
WORKER_IPS=()

if [ "$CONTROL_PLANE" = true ]; then
  CONTROL_IP=${IPS[0]}
  WORKER_IPS=("${IPS[@]:1}")
else
  WORKER_IPS=("${IPS[@]}")
fi

if [ "$CONTROL_PLANE" = true ]; then
  echo "Waiting for SSH on control plane..."

  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$CONTROL_IP "echo ok" 2>/dev/null; do
    sleep 3
  done

  echo "Initializing control plane..."

  ssh -o StrictHostKeyChecking=no ubuntu@$CONTROL_IP 'bash -s' <<'EOF'
cloud-init status --wait

sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v1.33.0 \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml

kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

kubeadm token create --print-join-command > /tmp/join.sh
EOF

  JOIN_CMD=$(ssh -o StrictHostKeyChecking=no ubuntu@$CONTROL_IP "cat /tmp/join.sh")
fi

for ip in "${WORKER_IPS[@]}"; do
  echo "Waiting for SSH on worker $ip..."

  until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ubuntu@$ip "echo ok" 2>/dev/null; do
    sleep 3
  done

  echo "Joining worker $ip"
  ssh -o StrictHostKeyChecking=no ubuntu@$ip "cloud-init status --wait && sudo $JOIN_CMD"
done

echo "Cluster ready 🚀"