# Workload and Scheduling Exercises

## 1) Create a deployment with 2 replicas (nginx), then scale to 4

Create the deployment:

```sh
kubectl create deployment demo-nginx --image=nginx --replicas=2
```

Verify:

```sh
kubectl get deployment demo-nginx
kubectl get pods -l app=demo-nginx
```

Scale it to 4 replicas:

```sh
kubectl scale deployment demo-nginx --replicas=4
kubectl get pods -l app=demo-nginx
```

## 2) Expose deployment as NodePort service on port 8080

```sh
kubectl expose deployment demo-nginx --type=NodePort --name=demo-nginx-svc --port=8080 --target-port=80
kubectl get svc demo-nginx-svc
```

Optional: print the allocated NodePort only

```sh
kubectl get svc demo-nginx-svc -o jsonpath='{.spec.ports[0].nodePort}{"\n"}'
```

## 3) Get pods with label env=demo and write pod names to pod.txt

If pods are not already labeled, add the label first:

```sh
kubectl label pods -l app=demo-nginx env=demo --overwrite
```

Save matching pod names to `pod.txt`:

```sh
kubectl get pods -l env=demo -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' > pod.txt
cat pod.txt
```

## 4) Create nginx pod, then add an init container

Create pod:

```sh
kubectl run nginx-pod --image=nginx --restart=Never
kubectl get pod nginx-pod
```

Export pod YAML, add init container, then re-apply:

```sh
kubectl get pod nginx-pod -o yaml > nginx-pod.yaml
kubectl delete pod nginx-pod
```

Edit `nginx-pod.yaml` and add this under `spec:`:

```yaml
initContainers:
  - name: init-busybox
    image: busybox
    command: ["sh", "-c", "sleep 10; echo 'hello world'"]
```

Apply and verify:

```sh
kubectl apply -f nginx-pod.yaml
kubectl get pod nginx-pod
kubectl logs nginx-pod -c init-busybox
```

## 5) Create a pod and force schedule on worker node 01

First, find the exact node name:

```sh
kubectl get nodes -o wide
```

Create `node-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: worker01-pod
spec:
  nodeName: worker-node-01
  containers:
    - name: nginx
      image: nginx
```

Apply and verify placement:

```sh
kubectl apply -f node-pod.yaml
kubectl get pod worker01-pod -o wide
```

Note: Replace `worker-node-01` with your cluster's actual node name if different.

## 6) Create a multi-container pod (redis + memcached)

Create `multi-container-pod.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: cache-pod
spec:
  containers:
    - name: redis
      image: redis
    - name: memcached
      image: memcached
```

Apply and verify:

```sh
kubectl apply -f multi-container-pod.yaml
kubectl get pod cache-pod
kubectl describe pod cache-pod
```
