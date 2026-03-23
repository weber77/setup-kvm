## Exercise: Namespaces + cross-namespace DNS

### Goal
Prove these behaviors:

- **Pod-to-pod traffic works across namespaces** (by Pod IP).
- **Service VIP works across namespaces** (by Service ClusterIP).
- **Short service names do *not* resolve across namespaces** (e.g. `svc-ns2` from `ns1`).
- **FQDN resolves across namespaces** (e.g. `svc-ns2.ns2.svc.cluster.local` from `ns1`).

### Imperative (lab / debugging)

```bash
# Namespaces
kubectl create namespace ns1
kubectl create namespace ns2

# Deployments (start with 1 replica)
kubectl create deployment deploy-ns1 --image=nginx -n ns1
kubectl create deployment deploy-ns2 --image=nginx -n ns2

# Wait for pods
kubectl rollout status deploy/deploy-ns1 -n ns1
kubectl rollout status deploy/deploy-ns2 -n ns2

# Create a small "client" pod in each namespace for curl tests
# (the nginx image does not include curl)
kubectl run curl -n ns1 --image=curlimages/curl --restart=Never -- sleep 3600
kubectl run curl -n ns2 --image=curlimages/curl --restart=Never -- sleep 3600
kubectl wait -n ns1 --for=condition=Ready pod/curl --timeout=120s
kubectl wait -n ns2 --for=condition=Ready pod/curl --timeout=120s

# Pod IPs (note the IPs)
kubectl get pods -o wide -n ns1
kubectl get pods -o wide -n ns2
```

#### 1) Pod-to-pod curl (across namespaces)

```bash
# Pick a "client" pod in ns1, and a pod IP in ns2
CLIENT_NS1="curl"
PODIP_NS2="$(kubectl get pod -n ns2 -l app=deploy-ns2 -o jsonpath='{.items[0].status.podIP}')"

# Curl the ns2 pod IP from inside ns1
kubectl exec -n ns1 "$CLIENT_NS1" -- curl -sS "http://$PODIP_NS2"
```

You should get the NGINX welcome HTML back.

#### 2) Scale both deployments to 3 replicas

```bash
kubectl scale deploy deploy-ns1 --replicas=3 -n ns1
kubectl scale deploy deploy-ns2 --replicas=3 -n ns2

kubectl rollout status deploy/deploy-ns1 -n ns1
kubectl rollout status deploy/deploy-ns2 -n ns2
```

#### 3) Create Services and test cross-namespace access

```bash
# Services (selector/labels are auto-wired by kubectl expose)
kubectl expose deploy deploy-ns1 --name=svc-ns1 --port=80 -n ns1
kubectl expose deploy deploy-ns2 --name=svc-ns2 --port=80 -n ns2

# Grab the service ClusterIPs
SVCIP_NS1="$(kubectl get svc svc-ns1 -n ns1 -o jsonpath='{.spec.clusterIP}')"
SVCIP_NS2="$(kubectl get svc svc-ns2 -n ns2 -o jsonpath='{.spec.clusterIP}')"

# Client pods
CLIENT_NS1="curl"
CLIENT_NS2="curl"

# Cross-namespace by Service IP (should work)
kubectl exec -n ns1 "$CLIENT_NS1" -- curl -sS "http://$SVCIP_NS2"
kubectl exec -n ns2 "$CLIENT_NS2" -- curl -sS "http://$SVCIP_NS1"
```

#### 4) Cross-namespace by Service name (expected to fail)

Service names are only automatically searchable within the **same** namespace (due to DNS search domains).

```bash
kubectl exec -n ns1 "$CLIENT_NS1" -- curl -sS "http://svc-ns2" || true
```

You should see a DNS error (e.g. “Could not resolve host”).

#### 5) Cross-namespace by Service FQDN (should work)

```bash
kubectl exec -n ns1 "$CLIENT_NS1" -- curl -sS "http://svc-ns2.ns2.svc.cluster.local"
```

### Declarative (team / repeatable)

Save as `namespace-exercise.yaml` and apply it.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ns1
---
apiVersion: v1
kind: Namespace
metadata:
  name: ns2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-ns1
  namespace: ns1
spec:
  replicas: 3
  selector:
    matchLabels:
      app: deploy-ns1
  template:
    metadata:
      labels:
        app: deploy-ns1
    spec:
      containers:
        - name: nginx
          image: nginx
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: svc-ns1
  namespace: ns1
spec:
  selector:
    app: deploy-ns1
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deploy-ns2
  namespace: ns2
spec:
  replicas: 3
  selector:
    matchLabels:
      app: deploy-ns2
  template:
    metadata:
      labels:
        app: deploy-ns2
    spec:
      containers:
        - name: nginx
          image: nginx
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: svc-ns2
  namespace: ns2
spec:
  selector:
    app: deploy-ns2
  ports:
    - port: 80
      targetPort: 80
```

Apply:

```bash
kubectl apply -f namespace-exercise.yaml
```

### Cleanup

Deleting the namespaces deletes everything inside them.

```bash
kubectl delete namespace ns1 ns2
```
