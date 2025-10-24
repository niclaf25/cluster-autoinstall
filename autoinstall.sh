#!/usr/bin/env bash
set -euo pipefail

# ============== CONFIG LOADING ==============
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${REPO_DIR}/config.env"
LOCAL_STATE="/etc/cluster-autoinstall"
LOCAL_CFG="${LOCAL_STATE}/local.env"
mkdir -p "${LOCAL_STATE}"

[[ -f "${CFG}" ]] && source "${CFG}" || true
[[ -f "${LOCAL_CFG}" ]] && source "${LOCAL_CFG}" || true

ROLE="${1:-worker}"  # default worker; use: ./autoinstall.sh --role master
if [[ "${ROLE}" == "--role" ]]; then ROLE="${2:-worker}"; fi

# Defaults if not set in config.env
: "${WG_ENABLE:=false}"             # set true in config.env to enable WireGuard auto-setup
: "${WG_PORT:=51820}"
: "${WG_NET:=10.100.0.0/16}"
: "${WG_SELF:=${WG_SELF:-}}"        # set dynamically on install
: "${MASTER_URL:=${MASTER_URL:-}}"  # e.g., https://10.0.0.81:6443 (LAN) or https://10.100.0.1:6443 (WG)
: "${MASTER_PUBLIC_IP:=${MASTER_PUBLIC_IP:-}}"  # only if you enable WG server on master behind NAT
: "${K3S_TOKEN:=${K3S_TOKEN:-}}"    # will be created on first master

# ============== PREREQS ==============
echo ">> Installing base dependencies…"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -y
sudo apt-get install -y \
  curl ca-certificates gnupg lsb-release apt-transport-https \
  net-tools iproute2 iptables nftables \
  jq git coreutils sed grep awk openssl \
  socat conntrack ipset ebtables ethtool \
  helm # helm used for kube-prometheus-stack

# Optional editors (nice to have, not required)
sudo apt-get install -y nano || true

# ============== DISCOVER HOST INFO ==============
HOSTNAME="$(hostname)"
LAN_IFACE="$(ip -o -4 route show to default | awk '{print $5}' | head -n1)"
LAN_IP="$(ip -o -4 addr show ${LAN_IFACE} | awk '{print $4}' | cut -d/ -f1 | head -n1)"
SUBNET_CIDR="$(ip -o -f inet addr show ${LAN_IFACE} | awk '{print $4}' | head -n1)"
GATEWAY="$(ip route | awk '/default/ {print $3; exit}')"

echo ">> Host: ${HOSTNAME}  LAN: ${LAN_IP} (${SUBNET_CIDR}), GW: ${GATEWAY}"

# ============== OPTIONAL: WIREGUARD ==============
if [[ "${WG_ENABLE}" == "true" ]]; then
  if ! command -v wg >/dev/null 2>&1; then
    echo ">> Installing WireGuard…"
    sudo apt-get install -y wireguard
  fi

  # derive wg self IP deterministically from hostname (simple hash to /16)
  if [[ -z "${WG_SELF}" ]]; then
    # Map hostname hash to 10.100.X.Y
    HHEX=$(echo -n "${HOSTNAME}" | sha1sum | cut -c1-4)
    X=$(( 0x${HHEX:0:2} )); Y=$(( 0x${HHEX:2:2} ))
    WG_SELF="10.100.$((X & 255)).$((Y & 255))"
  fi

  sudo umask 077
  WG_DIR="/etc/wireguard"
  sudo mkdir -p "${WG_DIR}"
  if [[ ! -f "${WG_DIR}/privatekey" ]]; then
    sudo wg genkey | sudo tee "${WG_DIR}/privatekey" >/dev/null
    sudo cat "${WG_DIR}/privatekey" | wg pubkey | sudo tee "${WG_DIR}/publickey" >/dev/null
  fi
  PRIV=$(sudo cat "${WG_DIR}/privatekey")

  # Basic wg0.conf skeleton; peers are added via MASTER_URL / cluster discovery later
  cat <<EOF | sudo tee "${WG_DIR}/wg0.conf" >/dev/null
[Interface]
PrivateKey = ${PRIV}
Address = ${WG_SELF}/16
ListenPort = ${WG_PORT}
# Routing: prefer local LAN; VPN used only for 10.100.0.0/16 (no 0.0.0.0/0)
PostUp = sysctl -w net.ipv4.ip_forward=1
SaveConfig = true
EOF

  sudo systemctl enable wg-quick@wg0
  sudo systemctl restart wg-quick@wg0 || sudo systemctl start wg-quick@wg0
  echo ">> WireGuard up on ${WG_SELF}/16"
fi

# Helper: choose K3S_URL preference (LAN first if MASTER_URL not set)
pick_master_url() {
  if [[ -n "${MASTER_URL}" ]]; then
    echo "${MASTER_URL}"; return
  fi
  # prefer local LAN 6443 if reachable
  if nc -z -w2 10.0.0.81 6443 2>/dev/null; then echo "https://10.0.0.81:6443"; return; fi
  # fallback to WG self if set (assumes first master will announce itself later)
  if [[ -n "${WG_SELF}" ]]; then echo "https://${WG_SELF}:6443"; return; fi
  # last resort: use LAN_IP (bootstrap case)
  echo "https://${LAN_IP}:6443"
}

# ============== K3s INSTALL / JOIN ==============
install_k3s_server_cluster_init() {
  echo ">> Installing K3s (server, cluster-init)…"
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --cluster-init --write-kubeconfig-mode=644 --tls-san ${LAN_IP}" sh -
  sleep 8
  K3S_TOKEN="$(sudo cat /var/lib/rancher/k3s/server/node-token)"
  MASTER_URL="https://${LAN_IP}:6443"
  # persist locally for next runs
  {
    echo "MASTER_URL=${MASTER_URL}"
    echo "K3S_TOKEN=${K3S_TOKEN}"
    [[ "${WG_ENABLE}" == "true" ]] && echo "WG_SELF=${WG_SELF}"
  } | sudo tee "${LOCAL_CFG}" >/dev/null
}

install_k3s_server_join() {
  echo ">> Installing K3s (server join)…"
  local base="$(pick_master_url)"
  if [[ -z "${K3S_TOKEN}" ]]; then
    echo "ERROR: K3S_TOKEN not set. Set it in config.env or run a cluster-init master first."
    exit 1
  fi
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --server ${base} --token ${K3S_TOKEN} --write-kubeconfig-mode=644 --tls-san ${LAN_IP}" sh -
}

install_k3s_agent() {
  echo ">> Installing K3s (worker/agent)…"
  local base="$(pick_master_url)"
  if [[ -z "${K3S_TOKEN}" ]]; then
    echo "ERROR: K3S_TOKEN not set. Set it in config.env (copied from the first master)."
    exit 1
  fi
  curl -sfL https://get.k3s.io | K3S_URL="${base}" K3S_TOKEN="${K3S_TOKEN}" sh -
}

# Determine: are we the first master?
ALREADY_HAS_K3S="$(command -v k3s >/dev/null && echo yes || echo no)"
if [[ "${ALREADY_HAS_K3S}" == "no" ]]; then
  if [[ "${ROLE}" == "master" ]]; then
    if [[ -z "${MASTER_URL}" && -z "${K3S_TOKEN}" ]]; then
      install_k3s_server_cluster_init
    else
      install_k3s_server_join
    fi
  else
    install_k3s_agent
  fi
else
  echo ">> K3s already present; skipping install."
fi

# kubectl helper alias
if ! command -v kubectl >/dev/null 2>&1; then
  sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl || true
fi

# ============== ADD-ONS (only on master) ==============
is_master() {
  # master runs server service
  systemctl is-active --quiet k3s && return 0 || return 1
}

if is_master; then
  echo ">> Waiting for API to become ready…"
  for i in {1..60}; do
    if sudo k3s kubectl get nodes >/dev/null 2>&1; then break; fi
    sleep 2
  done

  echo ">> Labeling node roles…"
  NODE="$(sudo k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
  sudo k3s kubectl label node "${NODE}" node-role.kubernetes.io/control-plane=true --overwrite

  echo ">> Deploying Longhorn (CRDs + UI)…"
  sudo k3s kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.2/deploy/longhorn.yaml
  # Default storage class with 3 replicas
  sudo k3s kubectl apply -f "${REPO_DIR}/addons/longhorn-storageclass.yaml"

  echo ">> Deploying Portainer (NodePort 9443)…"
  sudo k3s kubectl apply -f "${REPO_DIR}/addons/portainer.yaml"

  echo ">> Installing kube-prometheus-stack via Helm…"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
  helm repo update >/dev/null
  helm upgrade --install kube-prom prometheus-community/kube-prometheus-stack \
    --namespace monitoring --create-namespace \
    -f "${REPO_DIR}/addons/kube-prom-stack.values.yaml" >/dev/null

  echo ">> Add-ons deployed."
fi

# ============== SUMMARY ==============
IS_MASTER="no"; is_master && IS_MASTER="yes"

PORTAINER_URL="https://${LAN_IP}:9443"
GRAFANA_URL="http://${LAN_IP}:3000"
PROM_URL="http://${LAN_IP}:9090"
LONGHORN_URL="http://${LAN_IP}:30400"

cat <<EOF | tee /tmp/cluster-summary.txt
✅ Cluster node ready
────────────────────────────────────
Hostname: ${HOSTNAME}
Role: ${IS_MASTER^^}
LAN IP: ${LAN_IP}
VPN IP: ${WG_SELF:-disabled}
Master URL: ${MASTER_URL:-$(pick_master_url)}
K3S Token: ${K3S_TOKEN:-(on masters: /var/lib/rancher/k3s/server/node-token)}

📦 Portainer: ${PORTAINER_URL}
📊 Grafana:   ${GRAFANA_URL} (admin / admin)
📈 Prometheus:${PROM_URL}
💾 Longhorn:  ${LONGHORN_URL}

Files saved:
  ${LOCAL_CFG}   (MASTER_URL, K3S_TOKEN, WG_SELF)
  /root/cluster-info.txt (this summary)
EOF

sudo cp /tmp/cluster-summary.txt /root/cluster-info.txt
echo
cat /tmp/cluster-summary.txt
echo
echo "Done."
