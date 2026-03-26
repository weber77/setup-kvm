#!/usr/bin/env bash
set -e

usage() {
  cat <<'EOF'
Join libvirt worker VMs to an existing kubeadm control plane.

For each worker VM matching PREFIX-w-[a-z], runs:
  kubeadm reset -f  (clean slate)
  kubeadm join ...   (fresh token from the control plane)

Run from the KVM host (same as cluster.sh). Requires virsh, ssh, sshpass.

Usage:
  ./join-workers.sh [options]

Options:
  -p, --prefix <name>           VM name prefix (default: k8s)
  --control-plane-vm <name>     Control plane domain name (default: PREFIX-cp-a)
  --control-plane-ip <addr>     API server / kubeadm join address (also used for SSH
                                when fetching a join command from the CP)
  --apiserver-port <port>       Kubernetes API port for kubeadm join (default: 6443)
  -t, --token <token>           kubeadm bootstrap token (with --dtch, builds join locally)
  --discovery-token-ca-cert-hash <hash>
  --dtch <hash>                 Short for --discovery-token-ca-cert-hash (sha256:... or hex)
  --join-command 'kubeadm ...'  Full join line (mutually exclusive with --token/--dtch)
  -y, --yes                     Skip confirmation before changing nodes

Join command source (pick one):
  • --token and (--dtch or --discovery-token-ca-cert-hash): build
      kubeadm join CP_IP:PORT --token ... --discovery-token-ca-cert-hash sha256:...
    Requires --control-plane-ip or a resolvable PREFIX-a (or --control-plane-vm) on this host.
  • --join-command: use that exact command on workers.
  • Neither: SSH to the control plane and run kubeadm token create --print-join-command

Examples:
  ./join-workers.sh -p k8s --control-plane-ip 192.168.122.10 \\
      --token abcdef.0123456789abcdef --dtch sha256:0123...
  ./join-workers.sh --control-plane-vm k8s-cp-a --token ... --discovery-token-ca-cert-hash ...
  ./join-workers.sh -p k8s
  ./join-workers.sh --join-command 'kubeadm join 10.0.0.1:6443 --token ... --discovery-token-ca-cert-hash ...'
EOF
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
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10"

PREFIX="k8s"
CONTROL_PLANE_VM=""
CONTROL_PLANE_IP=""
APISERVER_PORT="6443"
BOOTSTRAP_TOKEN=""
DISCOVERY_HASH=""
JOIN_CMD_OVERRIDE=""
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)
      [[ -z "${2:-}" ]] && { echo "Error: --prefix requires a value" >&2; exit 1; }
      PREFIX="$2"
      shift 2
      ;;
    --control-plane-vm)
      [[ -z "${2:-}" ]] && { echo "Error: --control-plane-vm requires a value" >&2; exit 1; }
      CONTROL_PLANE_VM="$2"
      shift 2
      ;;
    --control-plane-ip)
      [[ -z "${2:-}" ]] && { echo "Error: --control-plane-ip requires a value" >&2; exit 1; }
      CONTROL_PLANE_IP="$2"
      shift 2
      ;;
    --apiserver-port)
      [[ -z "${2:-}" ]] && { echo "Error: --apiserver-port requires a value" >&2; exit 1; }
      APISERVER_PORT="$2"
      shift 2
      ;;
    -t|--token)
      [[ -z "${2:-}" ]] && { echo "Error: --token requires a value" >&2; exit 1; }
      BOOTSTRAP_TOKEN="$2"
      shift 2
      ;;
    --discovery-token-ca-cert-hash|--dtch)
      [[ -z "${2:-}" ]] && { echo "Error: $1 requires a value" >&2; exit 1; }
      DISCOVERY_HASH="$2"
      shift 2
      ;;
    --join-command)
      [[ -z "${2:-}" ]] && { echo "Error: --join-command requires a value" >&2; exit 1; }
      JOIN_CMD_OVERRIDE="$2"
      shift 2
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$JOIN_CMD_OVERRIDE" ]] && { [[ -n "$BOOTSTRAP_TOKEN" ]] || [[ -n "$DISCOVERY_HASH" ]]; }; then
  echo "Error: use either --join-command or --token with --dtch/--discovery-token-ca-cert-hash, not both." >&2
  exit 1
fi

if [[ -n "$BOOTSTRAP_TOKEN" ]] && [[ -z "$DISCOVERY_HASH" ]]; then
  echo "Error: --token requires --discovery-token-ca-cert-hash (or --dtch)." >&2
  exit 1
fi

if [[ -n "$DISCOVERY_HASH" ]] && [[ -z "$BOOTSTRAP_TOKEN" ]]; then
  echo "Error: --discovery-token-ca-cert-hash (--dtch) requires --token." >&2
  exit 1
fi

if [[ -z "$CONTROL_PLANE_VM" ]]; then
  CONTROL_PLANE_VM="${PREFIX}-cp-a"
fi

if ! command -v virsh >/dev/null 2>&1; then
  echo "virsh not found; install libvirt-clients." >&2
  exit 1
fi

resolve_vm_ip() {
  local vm="$1"
  local vm_mac vm_ip
  vm_mac=$(virsh dumpxml "$vm" | awk -F\' '/mac address/ {print $2; exit}')
  if [[ -z "$vm_mac" ]]; then
    echo ""
    return 1
  fi
  vm_ip=""
  local tries=0
  while [[ -z "$vm_ip" ]] && [[ $tries -lt 90 ]]; do
    vm_ip=$(virsh net-dhcp-leases default 2>/dev/null \
      | grep -i "$vm_mac" \
      | awk '{for(i=1;i<=NF;i++) if($i ~ /\//) print $i}' \
      | cut -d/ -f1)
    if [[ -z "$vm_ip" ]]; then
      sleep 2
      tries=$((tries + 1))
    fi
  done
  echo "$vm_ip"
}

ensure_vm_running() {
  local vm="$1"
  local state
  state=$(virsh domstate "$vm" 2>/dev/null || echo "missing")
  if [[ "$state" == "missing" ]]; then
    echo "Error: domain not found: $vm" >&2
    return 1
  fi
  if [[ "$state" == "running" ]]; then
    return 0
  fi
  echo "Starting $vm (was: $state)..."
  virsh start "$vm"
  sleep 5
}

list_worker_domains() {
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "$PREFIX"-w-[a-z] ]]; then
      echo "$name"
    fi
  done < <(virsh list --all --name 2>/dev/null || true) | sort
}

ensure_sshpass

WORKERS=()
while IFS= read -r w; do
  [[ -n "$w" ]] && WORKERS+=("$w")
done < <(list_worker_domains)

if [[ ${#WORKERS[@]} -eq 0 ]]; then
  echo "No worker VMs found (expected ${PREFIX}-w-<letter> domains)." >&2
  exit 1
fi

if [[ -z "$CONTROL_PLANE_IP" ]]; then
  if ! virsh dominfo "$CONTROL_PLANE_VM" &>/dev/null; then
    echo "Control plane VM not found: $CONTROL_PLANE_VM (set --control-plane-ip for the API address)." >&2
    exit 1
  fi
  ensure_vm_running "$CONTROL_PLANE_VM"
  echo "Resolving IP for control plane $CONTROL_PLANE_VM..."
  CONTROL_PLANE_IP=$(resolve_vm_ip "$CONTROL_PLANE_VM")
  if [[ -z "$CONTROL_PLANE_IP" ]]; then
    echo "Could not resolve DHCP lease for $CONTROL_PLANE_VM; set --control-plane-ip." >&2
    exit 1
  fi
fi

if [[ -n "$JOIN_CMD_OVERRIDE" ]]; then
  JOIN_CMD="$JOIN_CMD_OVERRIDE"
elif [[ -n "$BOOTSTRAP_TOKEN" ]] && [[ -n "$DISCOVERY_HASH" ]]; then
  HASH="$DISCOVERY_HASH"
  if [[ "$HASH" != sha256:* ]]; then
    HASH="sha256:${HASH}"
  fi
  JOIN_CMD="kubeadm join ${CONTROL_PLANE_IP}:${APISERVER_PORT} --token ${BOOTSTRAP_TOKEN} --discovery-token-ca-cert-hash ${HASH}"
  echo "Using join command built from --control-plane-ip, --token, and --dtch."
else
  echo "Fetching join command from control plane at $CONTROL_PLANE_IP..."
  until sshpass -p "$SSH_PASS" ssh $SSH_OPTS "ubuntu@${CONTROL_PLANE_IP}" "echo ok" &>/dev/null; do
    echo "  waiting for SSH on control plane..."
    sleep 3
  done
  JOIN_CMD=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "ubuntu@${CONTROL_PLANE_IP}" \
    "sudo kubeadm token create --print-join-command")
fi

if [[ -z "$JOIN_CMD" ]]; then
  echo "Join command is empty." >&2
  exit 1
fi

echo "======================================"
echo "Join workers to cluster"
echo "Control plane: $CONTROL_PLANE_VM @ $CONTROL_PLANE_IP"
echo "Workers: ${WORKERS[*]}"
echo "======================================"

if [[ "$YES" != true ]]; then
  read -r -p "Reset each worker and run kubeadm join? [y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

for vm in "${WORKERS[@]}"; do
  echo "----- $vm -----"
  ensure_vm_running "$vm"
  ip=$(resolve_vm_ip "$vm")
  if [[ -z "$ip" ]]; then
    echo "Error: no DHCP lease for $vm; skipping." >&2
    continue
  fi
  echo "IP: $ip"

  until sshpass -p "$SSH_PASS" ssh $SSH_OPTS "ubuntu@$ip" "echo ok" &>/dev/null; do
    echo "  waiting for SSH..."
    sleep 3
  done

  sshpass -p "$SSH_PASS" ssh $SSH_OPTS "ubuntu@$ip" bash -s <<EOF
set -e
cloud-init status --wait 2>/dev/null || true

echo "Resetting Kubernetes state on \$(hostname)..."
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/kubelet/pki 2>/dev/null || true
sudo systemctl restart kubelet
sleep 3

echo "Joining cluster..."
sudo $JOIN_CMD
EOF

  echo "$vm joined."
  echo
done

echo "Done. On the control plane: kubectl get nodes"
