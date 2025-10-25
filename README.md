# cluster-autoinstall

One-command installer for:
- K3s (embedded etcd)
- Longhorn (3 replicas, default StorageClass)
- Traefik (bundled in K3s)
- Portainer (NodePort 9443)
- Prometheus + Grafana (NodePorts 9090/3000)

## Usage

**On the first node (master):**
```bash
curl -fsSL https://raw.githubusercontent.com/niclaf25/cluster-autoinstall/main/autoinstall.sh | sudo bash -- --role master
