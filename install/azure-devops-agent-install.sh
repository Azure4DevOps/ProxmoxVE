#!/usr/bin/env bash
# Copyright (c) 2025 Azure4DevOps
# Author: Azure4DevOps
# License: MIT
# Source: https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent
#
# Fully self-contained — no dependency on FUNCTIONS_FILE_PATH or install.func
# Can be run directly:  bash <(curl -fsSL https://raw.githubusercontent.com/Azure4DevOps/ProxmoxVE/main/install/azure-devops-agent-install.sh)

set -euo pipefail

# ─── Inline helpers (replaces install.func) ───────────────────────────────────
RED='\033[0;31m'; YW='\033[33m'; GN='\033[1;32m'; CL='\033[m'; BFR='\r\033[K'; HOLD=' '
CM="${GN}✔${CL}"; CROSS="${RED}✖${CL}"

msg_info()  { echo -ne " ${HOLD} ${YW}${1}...${CL}"; }
msg_ok()    { echo -e "${BFR} ${CM} ${GN}${1}${CL}"; }
msg_error() { echo -e "${BFR} ${CROSS} ${RED}${1}${CL}"; exit 1; }

STD=">/dev/null 2>&1"   # used as: eval "command $STD"  — but we'll just pipe directly

# ─── OS bootstrap ─────────────────────────────────────────────────────────────
msg_info "Updating OS"
apt-get update -qq
apt-get upgrade -y -qq
msg_ok "Updated OS"

# ─── Dependencies ─────────────────────────────────────────────────────────────
msg_info "Installing dependencies"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  curl wget git jq unzip \
  apt-transport-https ca-certificates gnupg lsb-release \
  libicu-dev libkrb5-3 zlib1g libssl3 \
  iputils-ping sudo
msg_ok "Installed dependencies"

# ─── Docker CLI ───────────────────────────────────────────────────────────────
msg_info "Installing Docker CLI"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list >/dev/null
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  docker-ce-cli docker-buildx-plugin docker-compose-plugin
msg_ok "Installed Docker CLI"

# ─── Service account ──────────────────────────────────────────────────────────
msg_info "Creating azdo-agent service account"
if ! id -u azdo-agent &>/dev/null; then
  useradd -r -m -d /home/azdo-agent -s /bin/bash azdo-agent
fi
usermod -aG docker azdo-agent 2>/dev/null || true
cat > /etc/sudoers.d/azdo-agent <<'EOF'
azdo-agent ALL=(ALL) NOPASSWD: /usr/bin/apt-get, /usr/bin/apt, /usr/bin/dpkg
EOF
chmod 0440 /etc/sudoers.d/azdo-agent
msg_ok "Created azdo-agent service account"

# ─── Download latest agent ────────────────────────────────────────────────────
msg_info "Fetching latest Azure Pipelines agent release"
RELEASE=$(curl -fsSL \
  "https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest" \
  | jq -r '.tag_name' | sed 's/^v//')
if [[ -z "$RELEASE" ]]; then
  msg_error "Could not determine latest agent release from GitHub API"
fi
msg_ok "Latest release: v${RELEASE}"

TARBALL="vsts-agent-linux-x64-${RELEASE}.tar.gz"
DOWNLOAD_URL="https://vstsagentpackage.azureedge.net/agent/${RELEASE}/${TARBALL}"

msg_info "Downloading Azure DevOps Agent v${RELEASE}"
wget --retry-connrefused --waitretry=5 --tries=3 --timeout=60 \
  -q --show-progress \
  -O "/tmp/${TARBALL}" "${DOWNLOAD_URL}"

# Verify the tarball is valid before extracting
if ! gzip -t "/tmp/${TARBALL}" 2>/dev/null; then
  msg_error "Downloaded tarball is corrupt or incomplete: /tmp/${TARBALL}"
fi
msg_ok "Downloaded ${TARBALL}"

# ─── Extract ──────────────────────────────────────────────────────────────────
msg_info "Extracting agent to /opt/azdo-agent"
mkdir -p /opt/azdo-agent
tar -xzf "/tmp/${TARBALL}" -C /opt/azdo-agent
rm -f "/tmp/${TARBALL}"
chown -R azdo-agent:azdo-agent /opt/azdo-agent
msg_ok "Extracted agent"

# ─── Runtime dependencies (Microsoft script) ──────────────────────────────────
msg_info "Installing agent runtime dependencies"
bash /opt/azdo-agent/bin/installdependencies.sh >/dev/null 2>&1
msg_ok "Installed agent runtime dependencies"

echo "${RELEASE}" >/opt/azdo-agent_version.txt

# ─── systemd unit ─────────────────────────────────────────────────────────────
msg_info "Creating systemd unit"
cat > /etc/systemd/system/azdo-agent.service <<'EOF'
[Unit]
Description=Azure DevOps Pipelines Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=azdo-agent
WorkingDirectory=/opt/azdo-agent
ExecStart=/opt/azdo-agent/run.sh
Restart=on-failure
RestartSec=10
KillMode=process
KillSignal=SIGTERM
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
msg_ok "Created systemd unit"

# ─── Interactive setup helper ─────────────────────────────────────────────────
msg_info "Creating azdo-agent-setup helper"
cat > /usr/local/bin/azdo-agent-setup <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'; CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${CYAN}"
echo -e "╔══════════════════════════════════════════════════════╗"
echo -e "║       Azure DevOps Agent — Interactive Setup         ║"
echo -e "╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -rp "$(echo -e "${BOLD}Organisation URL ${NC}[https://dev.azure.com/myorg]: ")" AZP_URL
while [[ -z "$AZP_URL" ]]; do
  echo -e "${YELLOW}Organisation URL is required.${NC}"
  read -rp "$(echo -e "${BOLD}Organisation URL: ${NC}")" AZP_URL
done

read -rsp "$(echo -e "${BOLD}Personal Access Token (PAT): ${NC}")" AZP_TOKEN
echo ""
while [[ -z "$AZP_TOKEN" ]]; do
  echo -e "${YELLOW}PAT is required.${NC}"
  read -rsp "$(echo -e "${BOLD}Personal Access Token (PAT): ${NC}")" AZP_TOKEN
  echo ""
done

read -rp "$(echo -e "${BOLD}Agent pool name ${NC}[Default]: ")" AZP_POOL
AZP_POOL="${AZP_POOL:-Default}"

read -rp "$(echo -e "${BOLD}Agent name ${NC}[$(hostname)]: ")" AZP_AGENT_NAME
AZP_AGENT_NAME="${AZP_AGENT_NAME:-$(hostname)}"

read -rp "$(echo -e "${BOLD}Work folder ${NC}[_work]: ")" AZP_WORK
AZP_WORK="${AZP_WORK:-_work}"

echo ""
echo -e "${YELLOW}► Configuring agent...${NC}"

sudo -u azdo-agent /opt/azdo-agent/config.sh \
  --unattended \
  --url    "${AZP_URL}" \
  --auth   pat \
  --token  "${AZP_TOKEN}" \
  --pool   "${AZP_POOL}" \
  --agent  "${AZP_AGENT_NAME}" \
  --work   "${AZP_WORK}" \
  --replace \
  --acceptTeeEula

echo ""
echo -e "${YELLOW}► Installing and enabling systemd service...${NC}"
pushd /opt/azdo-agent >/dev/null
bash svc.sh install azdo-agent
bash svc.sh start
popd >/dev/null

echo ""
echo -e "${GREEN}✔  Agent '${AZP_AGENT_NAME}' registered and running!${NC}"
echo -e "   Pool  : ${AZP_POOL}"
echo -e "   URL   : ${AZP_URL}"
echo -e "   Work  : /opt/azdo-agent/${AZP_WORK}"
echo ""
echo -e "   ${BOLD}Useful commands:${NC}"
echo -e "     systemctl status azdo-agent"
echo -e "     journalctl -u azdo-agent -f"
echo -e "     azdo-agent-setup     ← re-run to reconfigure"
WRAPPER
chmod +x /usr/local/bin/azdo-agent-setup
msg_ok "Created azdo-agent-setup helper"

# ─── MOTD ─────────────────────────────────────────────────────────────────────
cat > /etc/motd <<'MOTD'
 _____                           ____             ___
|  _  |___ _ _ ___ ___    ___  |    \ ___ _ _ __|   |___ ___
|     |- _| | |  _| -_|  | . | |  |  | -_| | | . | . |_ -|
|__|__|___|___|_| |___|  |___| |____/|___|\_/|___|___|___|

  Azure DevOps Pipelines Agent – ready to configure

  Run:  azdo-agent-setup

  You will need:
    • Organisation URL  (https://dev.azure.com/<org>)
    • PAT with 'Agent Pools (Read & Manage)' scope
    • Pool name  (default: Default)

MOTD

msg_ok "Azure DevOps Agent v${RELEASE} installed successfully"
