# Storage Review Questions

- Create a PersistentVolumeClaim (PVC) named mysql in
  the mysql namespace with the following specifications:
- Access mode: ReadWrite Once
- Storage: 250Mi
- You must use the existing, retained
  PersistentVolume (PV)
- Update the deployment to use the PVC you created
  in the previous step
- Create a PV with 1Gi capacity and mode
  readWriteOnce and no StorageClass; create a PVC with
  500Mi storage and mode as readWriteOnce; it should
  be bounded with the PV. Create a pod that utilizes this
  PVC and use a mount path /data.
- Create a PVC with 10Mi, mount this PVC to the pod at
  /var/new-vol. Now, edit the PVC and increase the size
  from 10Mi to 50Mi.
- Create a sample StorageClass and update it to become
  the default storage class.

# Storage Review Approach

This guide is a practical way to approach common Kubernetes storage review questions. It focuses on how to think through the task, what fields matter, and how to verify that the objects are working.

## Core checks before starting

Run these first so you know what already exists in the cluster:

```bash
kubectl get pv
kubectl get pvc -A
kubectl get sc
kubectl get deploy -A
kubectl get pods -A
```

When a question says "use the existing PV", always inspect the PV first:

```bash
kubectl describe pv <pv-name>
```

Look for:

- capacity
- `accessModes`
- `storageClassName`
- reclaim policy
- current phase such as `Available`, `Bound`, or `Released`
- `claimRef` if it was already used before

## 1. PVC `mysql` in namespace `mysql` using an existing retained PV

### How to approach it

1. Confirm the namespace exists. If not, create it.
2. Find the retained PV that is intended for reuse.
3. Make the PVC match that PV closely:
   - same or smaller requested size
   - compatible `accessModes`
   - matching `storageClassName`
4. If the PV is retained and previously bound, check whether it still has a `claimRef`. A retained PV often cannot be rebound until it is made available again.
5. Create the PVC in the `mysql` namespace with name `mysql`.
6. Verify the claim becomes `Bound`.

### Example PVC

Adjust `storageClassName` only if the target PV uses one.

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql
  namespace: mysql
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 250Mi
  volumeName: <existing-pv-name>
  storageClassName: ""
```

### Verify

```bash
kubectl get pvc -n mysql
kubectl describe pvc mysql -n mysql
kubectl get pv
```

If the PVC stays `Pending`, the most common reasons are:

- size mismatch
- access mode mismatch
- wrong `storageClassName`
- target PV is not actually reusable yet

## 2. Update the deployment to use the PVC

### How to approach it

Once the PVC exists, patch or edit the deployment so that:

- a volume references the claim
- the container mounts that volume at the path your app expects

For a MySQL-style deployment, the mount path is commonly `/var/lib/mysql`.

### Deployment pattern

```yaml
spec:
  template:
    spec:
      containers:
        - name: mysql
          volumeMounts:
            - name: mysql-storage
              mountPath: /var/lib/mysql
      volumes:
        - name: mysql-storage
          persistentVolumeClaim:
            claimName: mysql
```

### Verify

```bash
kubectl rollout status deploy/<deployment-name> -n mysql
kubectl describe pod -n mysql <pod-name>
```

Check that the pod is running and the volume section shows the `mysql` claim.

## 3. Create a PV, matching PVC, and a Pod mounted at `/data`

### How to approach it

This is a static provisioning exercise:

1. Create a PV with:
   - `1Gi`
   - `ReadWriteOnce`
   - no StorageClass
2. Create a PVC with:
   - `500Mi`
   - `ReadWriteOnce`
   - no StorageClass
3. Create a Pod that mounts the PVC at `/data`.

The PVC can bind because its request is less than or equal to the PV capacity and the access mode matches.

### Example manifest

This matches the pattern already shown in `persistentStorage.yaml`.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: review-pv
spec:
  capacity:
    storage: 1Gi
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  hostPath:
    path: /tmp/review-pv
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: review-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  resources:
    requests:
      storage: 500Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: review-pod
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - name: review-storage
          mountPath: /data
  volumes:
    - name: review-storage
      persistentVolumeClaim:
        claimName: review-pvc
```

### Verify

```bash
kubectl apply -f <file>.yaml
kubectl get pv,pvc,pod
kubectl exec -it review-pod -- sh
```

Inside the pod:

```bash
df -h /data
touch /data/test-file
ls -l /data
```

## 4. Create a 10Mi PVC, mount it at `/var/new-vol`, then expand it to 50Mi

### How to approach it

This question is about volume expansion. Before creating the claim, confirm the StorageClass allows expansion:

```bash
kubectl get sc
kubectl describe sc <storage-class-name>
```

You need:

- `allowVolumeExpansion: true`

Then:

1. Create the PVC requesting `10Mi`.
2. Mount it into a Pod at `/var/new-vol`.
3. Edit the PVC and change the request from `10Mi` to `50Mi`.
4. Watch the resize complete.

### Example PVC and Pod

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: expand-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Mi
  storageClassName: standard
---
apiVersion: v1
kind: Pod
metadata:
  name: expand-pod
spec:
  containers:
    - name: app
      image: nginx
      volumeMounts:
        - name: expand-vol
          mountPath: /var/new-vol
  volumes:
    - name: expand-vol
      persistentVolumeClaim:
        claimName: expand-pvc
```

### Resize command

```bash
kubectl edit pvc expand-pvc
```

Change:

```yaml
resources:
  requests:
    storage: 50Mi
```

### Verify

```bash
kubectl get pvc expand-pvc -w
kubectl describe pvc expand-pvc
kubectl describe pv <bound-pv-name>
```

If the size does not change, check:

- StorageClass does not allow expansion
- backend provisioner does not support expansion
- filesystem resize is still pending

## 5. Create a sample StorageClass and make it the default

### How to approach it

Create the StorageClass first, then add the default-class annotation.

In this repo, `storageClass.yaml` already shows a local-path example:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
provisioner: rancher.io/local-path
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

To make a class default, use this annotation:

```yaml
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

### Example

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
reclaimPolicy: Retain
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
```

### Verify

```bash
kubectl apply -f storageClass.yaml
kubectl get sc
kubectl describe sc standard
```

If another StorageClass is already default, remove its default annotation first or you may end up with multiple defaults.

## Fast problem-solving checklist

When a storage task is not working, check these in order:

1. Does the namespace exist?
2. Do PV and PVC sizes match?
3. Do access modes match exactly?
4. Does `storageClassName` match on both sides?
5. Is the PV in `Available` state?
6. Is the PVC in the correct namespace?
7. Does the pod reference the correct `claimName`?
8. Does the StorageClass support expansion if resize is required?

## Useful commands during review

```bash
kubectl get pv
kubectl get pvc -A
kubectl get sc
kubectl describe pv <pv-name>
kubectl describe pvc <pvc-name> -n <namespace>
kubectl describe pod <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace>
```
