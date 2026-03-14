#!/usr/bin/env bash

# Copyright (c) 2025 Azure4DevOps
# Author: Azure4DevOps
# License: MIT
# Source: https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

APP="Azure DevOps Agent"
var_tags="devops;cicd;azure"
var_cpu="2"
var_ram="2048"
var_disk="10"
var_os="ubuntu"
var_version="24.04"
var_unprivileged="1"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /opt/azdo-agent/config.sh ]]; then
    msg_error "No Azure DevOps Agent installation found!"
    exit 1
  fi

  CURRENT=$(cat /opt/azdo-agent_version.txt 2>/dev/null || echo "unknown")
  RELEASE=$(curl -fsSL https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest \
    | grep "tag_name" | cut -d '"' -f4 | sed 's/^v//')

  if [[ "$RELEASE" == "$CURRENT" ]]; then
    msg_ok "Already on latest version: v${RELEASE}"
    exit 0
  fi

  msg_info "Stopping Azure DevOps Agent service"
  systemctl stop azdo-agent 2>/dev/null
  msg_ok "Stopped Azure DevOps Agent service"

  msg_info "Downloading Azure DevOps Agent v${RELEASE}"
  TARBALL="vsts-agent-linux-x64-${RELEASE}.tar.gz"
  wget -qO "/tmp/${TARBALL}" \
    "https://vstsagentpackage.azureedge.net/agent/${RELEASE}/${TARBALL}"
  msg_ok "Downloaded Azure DevOps Agent v${RELEASE}"

  msg_info "Extracting agent"
  rm -rf /opt/azdo-agent-new
  mkdir -p /opt/azdo-agent-new
  tar -xzf "/tmp/${TARBALL}" -C /opt/azdo-agent-new
  rm "/tmp/${TARBALL}"
  msg_ok "Extracted agent"

  msg_info "Preserving configuration"
  cp /opt/azdo-agent/.agent       /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.credentials /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.env         /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.service     /opt/azdo-agent-new/ 2>/dev/null || true
  msg_ok "Configuration preserved"

  msg_info "Swapping agent binaries"
  mv /opt/azdo-agent /opt/azdo-agent-old
  mv /opt/azdo-agent-new /opt/azdo-agent
  chown -R azdo-agent:azdo-agent /opt/azdo-agent
  rm -rf /opt/azdo-agent-old
  msg_ok "Agent binaries updated"

  echo "${RELEASE}" >/opt/azdo-agent_version.txt

  msg_info "Starting Azure DevOps Agent service"
  systemctl start azdo-agent
  msg_ok "Started Azure DevOps Agent service"

  msg_ok "Updated Azure DevOps Agent to v${RELEASE}"
  exit
}

# ── Override build_container to use OUR install script ────────────────────────
# build.func hardcodes the upstream URL; redefining the function after sourcing
# redirects the final install step to our fork.
build_container() {
  if [ "${CT_TYPE}" == "1" ]; then
    FEATURES="keyctl=1,nesting=1"
  else
    FEATURES="nesting=1"
  fi
  [[ "${ENABLE_FUSE:-no}" == "yes" ]] && FEATURES="${FEATURES},fuse=1"

  TEMP_DIR=$(mktemp -d)
  pushd "$TEMP_DIR" >/dev/null

  export CTID="$CT_ID"
  export CTTYPE="$CT_TYPE"
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="$var_version"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export PCT_OPTIONS="
    -features $FEATURES
    -hostname $HN
    -net0 name=eth0,bridge=$BRG${MAC:+,hwaddr=$MAC},ip=${NET}${GATE:+,gw=$GATE}${VLAN:+,tag=$VLAN}${MTU:+,mtu=$MTU}
    -onboot 1
    -cores $CORE_COUNT
    -memory $RAM_SIZE
    -unprivileged $CT_TYPE
    $PWHASH
  "

  bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/create_lxc.sh)" || exit 1
  msg_ok "LXC Container $CT_ID was successfully created."

  msg_info "Starting LXC Container"
  pct start "$CTID"
  msg_ok "Started LXC Container"

  # Wait for network
  msg_info "Waiting for network"
  for i in $(seq 1 20); do
    if pct exec "$CTID" -- ping -c1 -W2 8.8.8.8 &>/dev/null; then break; fi
    sleep 3
  done
  msg_ok "Network in LXC is reachable"

  msg_info "Customizing LXC Container"
  pct exec "$CTID" -- bash -c "apt-get update -qq && apt-get install -y -qq curl wget sudo" >/dev/null 2>&1
  msg_ok "Customized LXC Container"

  # ── Run OUR self-contained install script inside the container ───────────────
  msg_info "Running Azure DevOps Agent installer"
  pct exec "$CTID" -- bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Azure4DevOps/ProxmoxVE/main/install/azure-devops-agent-install.sh)"
  msg_ok "Azure DevOps Agent installer completed"

  popd >/dev/null
  rm -rf "$TEMP_DIR"
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Next step — configure the agent inside the container:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}pct enter ${CTID}${CL}"
echo -e "${TAB}${GATEWAY}${BGN}azdo-agent-setup${CL}"
echo -e "${INFO}${YW} You will need:${CL}"
echo -e "${TAB}- Azure DevOps organisation URL  (e.g. https://dev.azure.com/myorg)"
echo -e "${TAB}- Personal Access Token (PAT) with 'Agent Pools (Read & Manage)' scope"
echo -e "${TAB}- Agent pool name (default: Default)"
