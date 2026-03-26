## High Availability — Stacked Control Plane (kube-vip)

A runbook for **this repo** (`Self-Hosted-Kubernetes-/`) to build a
**stacked-etcd HA control plane** with kubeadm on libvirt/KVM VMs.

Every control-plane node runs `kube-apiserver`, `controller-manager`,
`scheduler`, **and** a local `etcd` member.
A floating VIP managed by **kube-vip** gives clients a single stable
`<VIP>:6443` endpoint — when the node holding the VIP goes down, another
control plane takes it over automatically.

> **Not ready for full HA?**
> `cluster/cluster.sh --control-planes 3 --workers 2` creates a
> multi-control-plane cluster in one shot, but its API endpoint is pinned
> to the first CP (no VIP, no failover). This guide adds the VIP layer.

---

## Prerequisites

| Requirement     | Detail                                                                                                                         |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| **Host**        | Linux with KVM/libvirt (`virsh`, `virt-install`)                                                                               |
| **Base image**  | Built by `cluster/prepare-image.sh` → `/var/lib/libvirt/images/k8s-base.qcow2` (containerd, kubeadm, kubelet, kubectl v1.33.0) |
| **VMs**         | 3 control planes (odd for etcd quorum) + any number of workers                                                                 |
| **Credentials** | `ubuntu` / `ubuntu` (default from this repo)                                                                                   |
| **Network**     | All VMs on the same L2 segment (libvirt `default` NAT `192.168.122.0/24`)                                                      |

Ports required between nodes:

- `6443/tcp` — Kubernetes API
- `2379-2380/tcp` — etcd
- `10250/tcp` — kubelet
- CNI traffic (Calico VXLAN/IPIP)

---

## Variables — decide before you start

```
CP_COUNT=3
W_COUNT=2
VIP=192.168.122.50       # must be unused in the subnet
POD_CIDR=10.244.0.0/16   # must NOT overlap the VM subnet
```

---

## Step 0 — Prepare the base image

On the KVM host, from `Self-Hosted-Kubernetes-/cluster/`:

```bash
chmod +x prepare-image.sh create-vms.sh
./prepare-image.sh
```

This builds `/var/lib/libvirt/images/k8s-base.qcow2`.
Every VM cloned afterward inherits the Kubernetes tooling.

---

## Step 1 — Create the VMs

Create VMs only — do **not** run `cluster.sh` (we need manual control over
`kubeadm init` to set `--control-plane-endpoint`):

```bash
./create-vms.sh --prefix k8s --role cp 3
./create-vms.sh --prefix k8s --role w  2
```

Get the IPs:

```bash
virsh net-dhcp-leases default
```

Record `CP1_IP`, `CP2_IP`, `CP3_IP`, and the worker IPs.
Confirm that `192.168.122.50` (our VIP) is **not** assigned to any VM.

---

## Step 2 — Bootstrap the first control plane

SSH into `k8s-cp-a`.

### 2a — Detect the network interface

```bash
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(ens|enp|eth)' | head -n1)
echo "Interface: $IFACE"
```

### 2b — Temporarily bind the VIP

kube-vip starts **after** `kubeadm init` (it needs `/etc/kubernetes/admin.conf`).
To let `kubeadm init` reach the VIP endpoint during its own health checks, we
temporarily add it to this node's interface:

```bash
export VIP=192.168.122.50

sudo ip addr add "${VIP}/32" dev "${IFACE}" || true
ip addr show "${IFACE}" | grep -F "${VIP}"
```

### 2c — kubeadm init

```bash
sudo kubeadm init \
  --control-plane-endpoint "${VIP}:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v1.33.0 \
  --cri-socket unix:///run/containerd/containerd.sock
```

Set up kubectl:

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

**Save the output** — you'll need the `kubeadm join` command and `--certificate-key` later.

> **If init fails** with `context deadline exceeded` on the VIP, the VIP
> wasn't reachable. Reset and retry:
>
> ```bash
> sudo kubeadm reset -f
> sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d "$HOME/.kube"
> sudo systemctl restart containerd
> ```
>
> Re-add the VIP (step 2b) and run init again.

### 2d — Create a localhost kubeconfig for kube-vip

kube-vip needs a kubeconfig to do leader election via the Kubernetes API.
Two things must be right:

1. **Point to `127.0.0.1:6443`** (the local apiserver), not the VIP.
   Otherwise kube-vip can't reach the API when the VIP is down — deadlock.
2. **Use `super-admin.conf`** as the base on CP1.
   Starting with K8s 1.29, `admin.conf` credentials depend on RBAC bindings
   that may not be fully ready when kube-vip first starts.
   `super-admin.conf` uses the `system:masters` group which always has access.

```bash
sudo cp /etc/kubernetes/super-admin.conf /etc/kubernetes/kube-vip.conf
sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' /etc/kubernetes/kube-vip.conf
sudo chmod 600 /etc/kubernetes/kube-vip.conf
```

### 2e — Deploy kube-vip as a static pod

```bash
sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:latest
      imagePullPolicy: Always
      args:
        - manager
      env:
        - name: KUBECONFIG
          value: /etc/kubernetes/kube-vip.conf
        - name: address
          value: "${VIP}"
        - name: port
          value: "6443"
        - name: vip_arp
          value: "true"
        - name: vip_interface
          value: "${IFACE}"
        - name: vip_subnet
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: svc_enable
          value: "false"
        - name: vip_ddns
          value: "false"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW", "SYS_TIME"]
      volumeMounts:
        - name: kubeconfig
          mountPath: /etc/kubernetes/kube-vip.conf
          readOnly: true
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/kube-vip.conf
        type: File
EOF
```

Wait ~30 seconds for kubelet to start the static pod, then verify kube-vip
owns the VIP. It should say `Running`, **not** `Completed`:

```bash
kubectl -n kube-system get pods | grep kube-vip
ip addr show "${IFACE}" | grep -F "${VIP}"
```

### 2f — Remove the temporary VIP

kube-vip now manages the VIP. Remove the manual assignment:

```bash
sudo ip addr del "${VIP}/32" dev "${IFACE}" || true
```

Confirm kube-vip re-advertises it (the VIP should still appear):

```bash
ip addr show "${IFACE}" | grep -F "${VIP}"
```

### 2g — Install the CNI (Calico)

```bash
curl -fsSLO https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/calico.yaml
sed -i 's#value: "192\\.168\\.0\\.0/16"#value: "10.244.0.0/16"#' calico.yaml
kubectl apply -f calico.yaml
```

Optional — allow workloads on control planes in the lab:

```bash
kubectl taint nodes "$(hostname)" node-role.kubernetes.io/control-plane:NoSchedule-
```

---

## Step 3 — Join the remaining control planes

### 3a — Get join credentials (on CP1)

```bash
JOIN_CMD=$(sudo kubeadm token create --print-join-command)
CERT_KEY=$(sudo kubeadm init phase upload-certs --upload-certs 2>/dev/null | tail -1)
echo "${JOIN_CMD} --control-plane --certificate-key ${CERT_KEY}"
```

Copy the full command printed above.

### 3b — On each additional CP (CP2, then CP3)

SSH in and run the steps below **in this order**.

**1) Join the cluster:**

```bash
sudo kubeadm join 192.168.122.50:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>
```

**2) Set up kubectl:**

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
kubectl get nodes
```

**3) Create the localhost kubeconfig and deploy kube-vip:**

On joined CPs, `admin.conf` is fine (RBAC bindings exist by now).
`super-admin.conf` is only generated on the first CP.

```bash
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(ens|enp|eth)' | head -n1)
export VIP=192.168.122.50

sudo cp /etc/kubernetes/admin.conf /etc/kubernetes/kube-vip.conf
sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' /etc/kubernetes/kube-vip.conf
sudo chmod 600 /etc/kubernetes/kube-vip.conf

sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: kube-vip
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
    - name: kube-vip
      image: ghcr.io/kube-vip/kube-vip:latest
      imagePullPolicy: Always
      args:
        - manager
      env:
        - name: KUBECONFIG
          value: /etc/kubernetes/kube-vip.conf
        - name: address
          value: "${VIP}"
        - name: port
          value: "6443"
        - name: vip_arp
          value: "true"
        - name: vip_interface
          value: "${IFACE}"
        - name: vip_subnet
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: svc_enable
          value: "false"
        - name: vip_ddns
          value: "false"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
      securityContext:
        capabilities:
          add: ["NET_ADMIN", "NET_RAW", "SYS_TIME"]
      volumeMounts:
        - name: kubeconfig
          mountPath: /etc/kubernetes/kube-vip.conf
          readOnly: true
  volumes:
    - name: kubeconfig
      hostPath:
        path: /etc/kubernetes/kube-vip.conf
        type: File
EOF
```

**4) Verify kube-vip is running:**

```bash
kubectl -n kube-system get pods -o wide | grep kube-vip
```

You should see one `kube-vip` pod per control-plane node, all `Running`.

---

## Step 4 — Join workers

On each worker node:

```bash
sudo kubeadm join 192.168.122.50:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Step 5 — Verify HA

### Cluster health (from any CP)

```bash
kubectl get nodes -o wide
kubectl -n kube-system get pods -o wide | grep -E 'kube-vip|etcd|apiserver'
```

### Find which node holds the VIP

From the KVM host:

```bash
for vm in k8s-cp-a k8s-cp-b k8s-cp-c; do
  ip=$(virsh domifaddr "$vm" 2>/dev/null | awk '/ipv4/{print $4}' | cut -d/ -f1)
  echo -n "$vm ($ip): "
  sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
    "ip addr show | grep -qF 192.168.122.50 && echo 'HOLDS VIP' || echo '-'" 2>/dev/null
done
```

### Test failover

1. Power off the node that holds the VIP (e.g. CP1):

```bash
virsh destroy k8s-cp-a
```

1. Wait ~10 seconds, then from **another** CP:

```bash
kubectl get nodes
```

If it works, the VIP migrated and your API endpoint is HA.

1. Bring CP1 back:

```bash
virsh start k8s-cp-a
```

After ~60 seconds it should rejoin the cluster (verify with `kubectl get nodes`).

---

## Troubleshooting

### `kubectl` on CP2/CP3 says `localhost:8080 was refused`

The node is missing a kubeconfig. Quick fix:

```bash
sudo KUBECONFIG=/etc/kubernetes/admin.conf kubectl get nodes
```

Or properly set it up:

```bash
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u)":"$(id -g)" "$HOME/.kube/config"
```

### VIP didn't move after CP1 went down

Check on a surviving CP:

```bash
# Is kube-vip running?
kubectl -n kube-system get pods -o wide | grep kube-vip

# Does the kube-vip kubeconfig point to localhost (NOT the VIP)?
sudo grep server /etc/kubernetes/kube-vip.conf
# Expected: server: https://127.0.0.1:6443

# kube-vip logs
kubectl -n kube-system logs kube-vip-$(hostname)

# Is the VIP on this node's interface?
ip addr show | grep -F 192.168.122.50
```

Common causes:

| Symptom                                  | Cause                                                                     | Fix                                                          |
| ---------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------ |
| kube-vip `Completed` (exits immediately) | Wrong env var names in manifest (e.g. `vip_address` instead of `address`) | Regenerate the manifest with correct env vars (step 2e)      |
| kube-vip `Completed` on CP1              | `admin.conf` lacks permissions (K8s 1.29+)                                | Use `super-admin.conf` as base for `kube-vip.conf` (step 2d) |
| kube-vip only on CP1                     | Manifest missing on CP2/CP3                                               | Deploy the static pod on every CP (step 3b)                  |
| kube-vip `CrashLoopBackOff`              | `/etc/kubernetes/kube-vip.conf` missing or wrong                          | Recreate it (step 2d)                                        |
| VIP never moves                          | `kube-vip.conf` points to VIP instead of `127.0.0.1`                      | Fix the server URL in `kube-vip.conf`                        |
| Wrong interface                          | `vip_interface` doesn't match actual NIC                                  | Check with `ip link show`, update the manifest               |

### After restarting a CP, it can't reach the cluster

If a CP was hard-killed (e.g. `virsh destroy`), etcd and kubelet will recover
automatically on reboot. Just wait ~60 seconds. If it still fails:

```bash
sudo systemctl restart kubelet
kubectl get nodes
```

---

## Recovery notes

**Reset a node** (before rejoining):

```bash
sudo kubeadm reset -f
sudo rm -rf ~/.kube /etc/cni/net.d /var/lib/cni /var/lib/kubelet /etc/kubernetes
sudo systemctl restart containerd
```

**Re-issue a join token** (from any working CP):

```bash
sudo kubeadm token create --print-join-command
```

**Re-upload certs** (for adding control planes later):

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

**Re-join workers in bulk** (from the KVM host):

```bash
cd Self-Hosted-Kubernetes-/cluster
./join-workers.sh --control-plane-ip 192.168.122.50
```

---

## Alternative: HAProxy load balancer

If you prefer a classic TCP load balancer instead of a floating VIP, you can
create one extra VM running HAProxy that forwards `:6443` to all three CPs.
The trade-off is an extra VM to manage, but it's easy to reason about and
doesn't require kube-vip at all.

High-level steps:

1. Create a `k8s-lb-a` VM and give it a stable IP (e.g. `192.168.122.60`)
2. Install HAProxy: `sudo apt-get install -y haproxy`
3. Configure `/etc/haproxy/haproxy.cfg` to listen on `:6443` and forward to
   `CP1_IP:6443`, `CP2_IP:6443`, `CP3_IP:6443` (mode tcp, balance roundrobin)
4. Use that LB IP as the `--control-plane-endpoint` in `kubeadm init`
5. Join additional CPs and workers against the LB IP
