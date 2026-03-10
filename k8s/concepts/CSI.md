# Container Storage Interface (CSI)

## What is CSI?

The Container Storage Interface (CSI) is a standard that lets Kubernetes use external storage systems (block, file, or object) without changing Kubernetes.

## Main concepts

- **CSI driver**: A sidecar (or DaemonSet) that runs in the cluster and implements the CSI gRPC API (CreateVolume, DeleteVolume, ControllerPublishVolume, NodeStageVolume, NodePublishVolume, etc.).
- **Volume lifecycle**: Provision → Attach (optional for some drivers) → Mount. The control plane (provisioner, attacher) and the node (node plugin) work together.
- **StorageClass**: Defines a "class" of storage (e.g. SSD, replicated). It often points to a CSI driver via `provisioner: <driver-name>`.
- **PersistentVolume (PV) / PersistentVolumeClaim (PVC)**: User asks for storage with a PVC; the CSI provisioner creates a PV and binds it to the PVC.

## Steps to use CSI storage (high level)

1. **Install the CSI driver**  
   Deploy the driver’s manifests (e.g. DaemonSet for node plugin, Deployment for controller). The exact steps depend on the driver (e.g. hostpath-csi, ceph-csi, ebs-csi).

2. **Create a StorageClass** (if the driver supports dynamic provisioning)
   - Set `provisioner` to the driver name (e.g. `driver-name.csi.vendor.io`).
   - Add any driver-specific parameters.

3. **Create a PVC**
   - Reference the StorageClass in `spec.storageClassName`.
   - Set `spec.resources.requests.storage` and optionally `spec.accessModes`.

4. **Use the volume in a Pod**
   - In `spec.volumes`, add a `persistentVolumeClaim` volume with `claimName: <pvc-name>`.
   - Mount that volume in `spec.containers[].volumeMounts`.

5. **Verify**
   - `kubectl get pv,pvc` — PVC should be Bound, PV should exist.
   - `kubectl describe pvc <name>` — check events and volume name.
   - `kubectl get pods -o wide` and on the node: `lsblk` / `mount` to see the device and mount.

## Useful commands

- List StorageClasses:  
  `kubectl get storageclass`

- List PVs and PVCs:  
  `kubectl get pv`  
  `kubectl get pvc -A`

- Inspect PVC (events, volume name):  
  `kubectl describe pvc <pvc-name> -n <namespace>`

- Check if CSI driver pods are running:  
  `kubectl get pods -n kube-system | grep csi`

- On a node where the volume is mounted:  
  `lsblk`  
  `mount | grep <volume-path>`

## Troubleshooting

- PVC stuck "Pending": check StorageClass, provisioner name, and CSI controller logs.
- Mount errors: check node plugin (DaemonSet) logs and that the node has the required kernel modules or tools (e.g. for NFS, iSCSI).
- Detach/attach issues: check controller logs and cloud/storage provider permissions (e.g. IAM for EBS CSI).

---

## Create a Service for a pod (SVC)

Expose a pod via a stable ClusterIP (or other type) by creating a Service that selects the pod with labels.

### Steps

1. **See which pods exist and their labels**  
   ```bash
   kubectl get pods --show-labels
   ```

2. **Label the pod so the Service can select it** (if not already labeled)  
   ```bash
   kubectl label pod <pod-name> app=shared
   ```
   Use the same key/value in the Service’s `selector` below.

3. **Create the Service manifest**  
   ```bash
   cat > svc.yaml <<EOF
   apiVersion: v1
   kind: Service
   metadata:
     name: shared-service
   spec:
     selector:
       app: shared
     ports:
       - protocol: TCP
         port: 80
         targetPort: 80
   EOF
   ```

4. **Apply and verify**  
   ```bash
   kubectl apply -f svc.yaml
   kubectl get svc
   kubectl get endpointslice
   kubectl get pods -o wide   # pod IP should appear as endpoint for the service
   ```

5. **Optional: see how kube-proxy programs iptables**  
   - Get the Service ClusterIP: `kubectl get svc`  
   - List NAT rules for the service chain:  
     `sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers | grep <service-ip>`  
   - Inspect the chain that forwards to the pod (replace with the chain name from the output):  
     `sudo iptables -t nat -L <TARGET-SERVICE-CHAIN> -n --line-numbers`  
   - See the DNAT rule to the pod:  
     `sudo iptables -t nat -S <TARGET-POD-CHAIN>`

kube-proxy can use iptables, nftables, or ipvs depending on cluster configuration.
