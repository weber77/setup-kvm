# Kubernetes Ports Reference (Control Plane and Worker)

This file captures the port requirements shown in your provided tables.

## Table 14-1: Ports needed in control plane (master node)

| Protocol | Direction | Port Range | Purpose | Used By |
|---|---|---|---|---|
| TCP | Inbound | 6443 | Kubernetes API Server | All |
| TCP | Inbound | 2379-2380 | ETCD server client API | kube-API Server, ETCD |
| TCP | Inbound | 10250 | Kubelet API | Self, control plane |
| TCP | Inbound | 10259 | kube-scheduler | Self |
| TCP | Inbound | 10257 | kube-controller-manager | Self |
| TCP | Inbound/Outbound | 179 | Calico networking | All |

## Table 14-2: Ports needed in worker nodes

| Protocol | Direction | Port Range | Purpose | Used By |
|---|---|---|---|---|
| TCP | Inbound | 10250 | Kubelet API | Self, control plane |
| TCP | Inbound | 10256 | kube-proxy | Self, load balancers |
| TCP | Inbound | 30000-32767 | NodePort services | All |
| TCP | Inbound/Outbound | 179 | Calico networking | All |

## Quick checks (self-hosted)

```bash
# Run on each node to confirm listening ports
sudo ss -lntp | rg '(:6443|:2379|:2380|:10250|:10256|:10257|:10259|:179)'
```

```bash
# From worker to API server
nc -zv <api-server-ip> 6443

# Between control-plane nodes (etcd)
nc -zv <control-plane-peer-ip> 2379
nc -zv <control-plane-peer-ip> 2380

# From control-plane to worker (kubelet)
nc -zv <worker-private-ip> 10250
```
