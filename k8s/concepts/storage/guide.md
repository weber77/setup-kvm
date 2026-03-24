# Plan: Kubernetes Component Communication Ports

This guide is split into two parts:

1. Commands relevant to our self-hosted setup (first priority)
2. AWS Security Group implementation (second section)

## Section 1: Our Setup (Self-Hosted / VM / Bare Metal)

### 1) Required traffic matrix

- Admin/Client -> Control Plane: TCP `22`, `6443`
- Control Plane <-> Control Plane: TCP `2379-2380`, `10257`, `10259`
- Control Plane -> Worker: TCP `10250`, optional `30000-32767`
- Worker -> Control Plane: TCP `6443`
- Worker <-> Worker: optional TCP `10250`, `30000-32767`

### 2) Verify services are listening

Run on each node:

```bash
sudo ss -lntp | rg '(:22|:6443|:2379|:2380|:10250|:10257|:10259)'
```

### 3) Connectivity checks between nodes

Run from control plane:

```bash
nc -zv <worker-private-ip> 10250
nc -zv <control-plane-peer-ip> 2379
nc -zv <control-plane-peer-ip> 2380
```

Run from worker:

```bash
nc -zv <api-server-ip> 6443
```

### 4) Kubernetes-level validation

```bash
kubectl get nodes -o wide
kubectl cluster-info

# etcd health (control plane)
ETCDCTL_API=3 etcdctl endpoint health
ETCDCTL_API=3 etcdctl member list
```

### 5) Optional NodePort validation

```bash
kubectl create deployment np-test --image=nginx --port=80
kubectl expose deployment np-test --type=NodePort --port=80
kubectl get svc np-test
curl -I http://<worker-private-ip>:<nodeport>
```

### 6) Host firewall examples (if using UFW)

On control plane:

```bash
sudo ufw allow from <admin-cidr> to any port 22 proto tcp
sudo ufw allow from <admin-cidr> to any port 6443 proto tcp
sudo ufw allow from <control-plane-cidr> to any port 2379:2380 proto tcp
sudo ufw allow from <control-plane-cidr> to any port 10257 proto tcp
sudo ufw allow from <control-plane-cidr> to any port 10259 proto tcp
sudo ufw allow from <worker-cidr> to any port 6443 proto tcp
```

On worker:

```bash
sudo ufw allow from <control-plane-cidr> to any port 10250 proto tcp
sudo ufw allow from <worker-cidr> to any port 30000:32767 proto tcp
```

Use CIDRs or specific IPs according to your actual node network.

## Section 2: AWS Security Group Mapping

Use this only if the same cluster is deployed in AWS.

### 1) Set AWS variables

```bash
export AWS_REGION="us-east-1"
export CONTROL_PLANE_SG_ID="sg-xxxxxxxxxxxxxxxxx"
export WORKER_SG_ID="sg-yyyyyyyyyyyyyyyyy"
export ADMIN_CIDR="203.0.113.10/32"
```

### 2) Apply SG rules

```bash
# Admin -> Control plane
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --protocol tcp --port 22 --cidr "$ADMIN_CIDR"
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --protocol tcp --port 6443 --cidr "$ADMIN_CIDR"

# Control plane internal
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --source-group "$CONTROL_PLANE_SG_ID" --protocol tcp --port 2379-2380
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --source-group "$CONTROL_PLANE_SG_ID" --protocol tcp --port 10257
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --source-group "$CONTROL_PLANE_SG_ID" --protocol tcp --port 10259

# Control plane -> Worker
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$WORKER_SG_ID" --source-group "$CONTROL_PLANE_SG_ID" --protocol tcp --port 10250
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$WORKER_SG_ID" --source-group "$CONTROL_PLANE_SG_ID" --protocol tcp --port 30000-32767

# Worker -> Control plane
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --source-group "$WORKER_SG_ID" --protocol tcp --port 6443

# Worker <-> Worker
aws ec2 authorize-security-group-ingress --region "$AWS_REGION" --group-id "$WORKER_SG_ID" --source-group "$WORKER_SG_ID" --protocol tcp --port 30000-32767
```

### 3) Audit and harden

```bash
aws ec2 describe-security-groups --region "$AWS_REGION" --group-ids "$CONTROL_PLANE_SG_ID" "$WORKER_SG_ID"
aws ec2 revoke-security-group-ingress --region "$AWS_REGION" --group-id "$CONTROL_PLANE_SG_ID" --protocol tcp --port 6443 --cidr 0.0.0.0/0
```

## Notes

- Keep `30000-32767` open only when NodePort services are needed.
- Prefer least privilege (IP/CIDR or source SG), never broad open access.
- Re-validate connectivity after every firewall or SG change.
