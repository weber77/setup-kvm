# Network Policy Test Steps

Use these steps to validate that only the `backend` pod can access MySQL (`db-svc:3306`), while the `frontend` pod is blocked.

## 1) Apply resources

Run from this folder:

```sh
cd "/k8s/concepts/Network Policies"
kubectl apply -f pods.yaml
kubectl apply -f networkPolicy.yaml
```

## 2) Verify pods, service, and policy are ready

```sh
kubectl get pods -o wide
kubectl get svc
kubectl get networkpolicy
kubectl describe networkpolicy db-test
```

Expected:

- Pods `frontend`, `backend`, and `mysql` are in `Running` state.
- Service `db-svc` exists and listens on port `3306`.
- NetworkPolicy `db-test` is present.

## 3) Install curl inside frontend and backend pods (one-time for testing)

These pods use `nginx`, so install curl before testing:

```sh
kubectl exec -it frontend -- sh -c "apt-get update && apt-get install -y curl" #netcat-openbsd
kubectl exec -it backend -- sh -c "apt-get update && apt-get install -y curl"
```

## 4) Test from frontend pod (should fail)

```sh
kubectl exec -it frontend -- sh -c "curl -m 5 -v db-svc:3306"
```

Expected:

- Connection should fail or timeout (for example: `Connection timed out`, `Connection refused`, or `Operation timed out`).
- This confirms ingress to MySQL is blocked for non-backend pods.

## 5) Test from backend pod (should succeed)

```sh
kubectl exec -it backend -- sh -c "curl -m 5 -v db-svc:3306" # "nc -vz db-svc 3306"
```

Expected:

- TCP connection to `db-svc:3306` is successful.
- You may see non-HTTP output or an empty response (this is normal for MySQL port checks); the key point is that the connection is established.

## 6) If results are not as expected, check Calico health

```sh
kubectl get pods -n kube-system | grep -E "calico|coredns"
kubectl get daemonset -n kube-system calico-node
kubectl logs -n kube-system -l k8s-app=calico-node --tail=100
kubectl get felixconfiguration default -o yaml
```

Also re-check:

- Pod labels match policy selectors:
  - MySQL pod label: `name: mysql`
  - Backend pod label: `role: backend`
- Network policy was applied in the same namespace as the pods.
