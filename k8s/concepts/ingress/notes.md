## Ingress (Kubernetes) — quick guide

### What Ingress is (and what it is not)
- **Ingress**: a set of L7 (HTTP/HTTPS) routing rules (host/path based) that send traffic to Services inside the cluster.
- **Ingress controller**: the actual reverse proxy/load balancer implementation that reads Ingress objects and makes them real (for example, **ingress-nginx**).
- **Important**: creating an `Ingress` resource alone does nothing unless an Ingress controller is installed and running.

### When to use Ingress vs Service types
- **ClusterIP Service**: internal-only stable IP/port; usually what your apps use behind Ingress.
- **NodePort Service**: opens a port on every node; simple but not as nice for many apps/domains.
- **LoadBalancer Service**: asks cloud (or MetalLB in homelab) for an external IP; often used to expose the Ingress controller itself.
- **Ingress**: one external entry point (IP/hostname), many apps behind it via host/path routing, plus TLS termination.

### Prerequisite: install an Ingress controller (nginx)
Install `ingress-nginx` (recommended for learning/homelab):

```bash
helm upgrade --install ingress-nginx ingress-nginx \
  --repo https://kubernetes.github.io/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

Alternative (raw manifest):

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml
```

Verify the controller is running:

```bash
kubectl -n ingress-nginx get pods
kubectl -n ingress-nginx get svc
```

### Key fields you’ll see in Ingress YAML
- **`spec.ingressClassName: nginx`**: tells Kubernetes *which controller* should handle this Ingress.
- **`spec.rules[].host`**: the hostname to match (SNI/Host header).
- **`spec.rules[].http.paths[]`**: path prefixes and where they route (to a Service + port).
- **Annotations (nginx-specific)**:
  - **`nginx.ingress.kubernetes.io/rewrite-target: /`**: rewrites the incoming path before proxying (handy for path-based routing like `/app1` → `/` on the backend).

### Common patterns (examples in this folder)
#### Single host → single Service
See `ingressSingleService.yaml`.

Apply:

```bash
kubectl apply -f ingressSingleService.yaml
kubectl get ingress
```

#### Single host → multiple Services by path
See `ingressMultiService.yaml` (routes `/app1` and `/app2`).

This is where `rewrite-target: /` is often used so the app doesn’t need to know it’s mounted under `/app1`.

#### Multiple hosts → different Services
See `ingressMultiDomain.yaml` (e.g. `foo.example.com` vs `bar.example.com`).

Structure reminder for each rule:

```yaml
rules:
  - host: foo.example.com
    http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: foo-service
              port:
                number: 80
```

### Making hostnames work locally (homelab)
Ingress host routing depends on the **Host header**.

Options:
- **DNS**: point `*.example.com` (or specific names) at the external IP of the Ingress controller.
- **Quick local test**: add entries to `/etc/hosts` mapping the hostname(s) to the controller’s external IP.

Find the controller IP:

```bash
kubectl -n ingress-nginx get svc ingress-nginx-controller
```

### Testing
- **Via curl with Host header** (works even without DNS):

```bash
curl -H "Host: basic.example.com" http://<INGRESS_IP>/app1
curl -H "Host: basic.example.com" http://<INGRESS_IP>/app2
```

### Troubleshooting checklist
- **Ingress exists?**

```bash
kubectl get ingress
kubectl describe ingress <name>
```

- **Controller installed and watching the right class?**
  - Your Ingress uses `ingressClassName: nginx`, so `ingress-nginx` must be running.
- **Service/Endpoints healthy?**

```bash
kubectl get svc
kubectl get endpoints
kubectl get pods -o wide
```

- **Controller logs** (often the fastest signal):

```bash
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller
```
