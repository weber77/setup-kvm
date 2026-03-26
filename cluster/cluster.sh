#!/usr/bin/env bash
set -e

print_manual() {
  echo "Manual:"
  echo "  ./cluster.sh -cp 1 -w 2"
  echo "  ./cluster.sh --control-planes 2 --workers 2"
  echo "  ./cluster.sh -w 2"
  echo "  ./cluster.sh -cp 1"
  echo "  ./cluster.sh --prepare-image"
  echo "  ./cluster.sh --base-image <path>"
  echo "  ./cluster.sh -bi <path>"
  echo "  sudo ./purge-cluster.sh   # tear down VMs (see purge-cluster.sh --help)"
  echo "  ./join-workers.sh       # reset + join worker VMs by prefix (see join-workers.sh --help)"
}

ensure_sshpass() {
  if command -v sshpass >/dev/null 2>&1; then
    return 0
  fi
  echo "sshpass not found; installing..."
  case "$(uname -s)" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install sshpass on macOS." >&2
        exit 1
      fi
      if ! brew install hudochenkov/sshpass/sshpass 2>/dev/null; then
        brew tap esolitos/ipa >/dev/null 2>&1 || true
        brew install esolitos/ipa/sshpass || {
          echo "Could not install sshpass via Homebrew." >&2
          exit 1
        }
      fi
      ;;
    Linux)
      if [ -f /etc/debian_version ]; then
        sudo apt-get update -qq && sudo apt-get install -y sshpass
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm sshpass
      else
        echo "Could not detect package manager; install sshpass manually." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported OS; install sshpass manually." >&2
      exit 1
      ;;
  esac
  command -v sshpass >/dev/null 2>&1 || {
    echo "sshpass install failed." >&2
    exit 1
  }
}
SSH_PASS="ubuntu"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

BASE_IMAGE="/var/lib/libvirt/images/k8s-base.qcow2"
CONTROL_PLANES=0
WORKERS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_manual
      exit 0
      ;;
    -w|--workers)
      WORKERS="${2:-}"
      shift 2
      ;;
    -cp|--control-planes|--controle-planes)
      CONTROL_PLANES="${2:-}"
      shift 2
      ;;
    --prepare-image)
      ensure_sshpass
      ./prepare-image.sh
      exit 0
      ;;
    -bi|--base-image)
      BASE_IMAGE="${2:-}"
      shift 2
      ;;
    # Back-compat flags
    --control-plane)
      CONTROL_PLANES=1
      shift
      ;;
    --worker-only)
      CONTROL_PLANES=0
      shift
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${WORKERS:-}" ]]; then WORKERS=0; fi
if [[ -z "${CONTROL_PLANES:-}" ]]; then CONTROL_PLANES=0; fi
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then echo "Error: --workers must be a non-negative integer" >&2; exit 1; fi
if ! [[ "$CONTROL_PLANES" =~ ^[0-9]+$ ]]; then echo "Error: --control-planes must be a non-negative integer" >&2; exit 1; fi

TOTAL=$((WORKERS + CONTROL_PLANES))
if [[ "$TOTAL" -le 0 ]]; then
  echo "Nothing to do (0 control planes, 0 workers)."
  print_manual
  exit 1
fi

if [ ! -f "$BASE_IMAGE" ]; then
  echo "Base image not found. Preparing..."
  ensure_sshpass
  BASE_IMAGE_OVERRIDE="$BASE_IMAGE" ./prepare-image.sh
else
  echo "Using existing base image: $BASE_IMAGE"
fi

echo "Creating $TOTAL VMs..."
PREFIX="k8s"
CP_ROLE="cp"
W_ROLE="w"

if [[ "$CONTROL_PLANES" -gt 0 ]]; then
  echo "Creating $CONTROL_PLANES control-plane VM(s) (${CP_ROLE})..."
  BASE_IMAGE_OVERRIDE="$BASE_IMAGE" ./create-vms.sh --prefix "$PREFIX" --role "$CP_ROLE" "$CONTROL_PLANES"
fi
if [[ "$WORKERS" -gt 0 ]]; then
  echo "Creating $WORKERS worker VM(s) (${W_ROLE})..."
  BASE_IMAGE_OVERRIDE="$BASE_IMAGE" ./create-vms.sh --prefix "$PREFIX" --role "$W_ROLE" "$WORKERS"
fi

echo "Waiting for VMs to get IPs..."
sleep 10

echo "Waiting for VMs to get IPs..."

resolve_ip() {
  local vm_name="$1"
  local vm_mac vm_ip
  vm_mac=$(virsh dumpxml "$vm_name" | awk -F\' '/mac address/ {print $2; exit}')
  vm_ip=""
  while [ -z "$vm_ip" ]; do
    vm_ip=$(virsh net-dhcp-leases default \
      | grep -i "$vm_mac" \
      | awk '{for(i=1;i<=NF;i++) if($i ~ /\//) print $i}' \
      | cut -d/ -f1)
    if [ -z "$vm_ip" ]; then
      echo "  waiting for DHCP..."
      sleep 2
    fi
  done
  echo "$vm_ip"
}

CONTROL_VMS=()
WORKER_VMS=()
if [[ "$CONTROL_PLANES" -gt 0 ]]; then
  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    if [[ "$vm" == "${PREFIX}-${CP_ROLE}-"[a-z] ]]; then
      CONTROL_VMS+=("$vm")
    fi
  done < <(virsh list --all --name 2>/dev/null | sort)
fi
if [[ "$WORKERS" -gt 0 ]]; then
  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    if [[ "$vm" == "${PREFIX}-${W_ROLE}-"[a-z] ]]; then
      WORKER_VMS+=("$vm")
    fi
  done < <(virsh list --all --name 2>/dev/null | sort)
fi

if [[ "${#CONTROL_VMS[@]}" -lt "$CONTROL_PLANES" ]]; then
  echo "Warning: expected $CONTROL_PLANES control-plane VM(s) but found ${#CONTROL_VMS[@]} (${PREFIX}-${CP_ROLE}-<letter>)." >&2
fi
if [[ "${#WORKER_VMS[@]}" -lt "$WORKERS" ]]; then
  echo "Warning: expected $WORKERS worker VM(s) but found ${#WORKER_VMS[@]} (${PREFIX}-${W_ROLE}-<letter>)." >&2
fi

CONTROL_IPS=()
WORKER_IPS=()

for vm in "${CONTROL_VMS[@]}"; do
  echo "Resolving IP for $vm..."
  ip=$(resolve_ip "$vm")
  echo "$vm IP: $ip"
  CONTROL_IPS+=("$ip")
done

for vm in "${WORKER_VMS[@]}"; do
  echo "Resolving IP for $vm..."
  ip=$(resolve_ip "$vm")
  echo "$vm IP: $ip"
  WORKER_IPS+=("$ip")
done

ensure_sshpass

if [[ "$CONTROL_PLANES" -gt 0 ]]; then
  PRIMARY_CONTROL_IP="${CONTROL_IPS[0]}"

  echo "Waiting for SSH on primary control plane..."
  until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$PRIMARY_CONTROL_IP" "echo ok" 2>/dev/null; do
    sleep 3
  done

  echo "Initializing primary control plane..."
  sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$PRIMARY_CONTROL_IP" 'bash -s' <<'EOF'
cloud-init status --wait

sudo systemctl restart containerd
sudo systemctl restart kubelet

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
EOF

  WORKER_JOIN_CMD=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$PRIMARY_CONTROL_IP" "sudo kubeadm token create --print-join-command")
  CERT_KEY=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$PRIMARY_CONTROL_IP" "sudo kubeadm init phase upload-certs --upload-certs | tail -n 1")
  CONTROL_JOIN_CMD="${WORKER_JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}"

  if [[ "$CONTROL_PLANES" -gt 1 ]]; then
    for ip in "${CONTROL_IPS[@]:1}"; do
      echo "Waiting for SSH on additional control plane $ip..."
      until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$ip" "echo ok" 2>/dev/null; do
        sleep 3
      done
      echo "Joining control plane $ip"
      sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$ip" "cloud-init status --wait && sudo $CONTROL_JOIN_CMD"
    done
  fi
else
  WORKER_JOIN_CMD=""
fi

if [[ "$WORKERS" -gt 0 ]]; then
  if [[ -z "${WORKER_JOIN_CMD:-}" ]]; then
    echo "Error: cannot join workers without at least one control plane." >&2
    exit 1
  fi
  for ip in "${WORKER_IPS[@]}"; do
    echo "Waiting for SSH on worker $ip..."
    until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$ip" "echo ok" 2>/dev/null; do
      sleep 3
    done
    echo "Joining worker $ip"
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@"$ip" "cloud-init status --wait && sudo $WORKER_JOIN_CMD"
  done
fi

echo "Cluster ready 🚀"