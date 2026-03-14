#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2025 community-scripts ORG
# Author: community-scripts
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://learn.microsoft.com/en-us/azure/devops/pipelines/agents/linux-agent

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
  RELEASE=$(curl -fsSL https://api.github.com/repos/microsoft/azure-pipelines-agent/releases/latest | grep "tag_name" | cut -d '"' -f4 | sed 's/^v//')

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
  cp /opt/azdo-agent/.agent /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.credentials /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.env /opt/azdo-agent-new/ 2>/dev/null || true
  cp /opt/azdo-agent/.service /opt/azdo-agent-new/ 2>/dev/null || true
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

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Next step — configure the agent inside the container:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}pct enter $(cat /tmp/CTID)${CL}"
echo -e "${TAB}${GATEWAY}${BGN}sudo -u azdo-agent /opt/azdo-agent/config.sh${CL}"
echo -e "${INFO}${YW} You will need:${CL}"
echo -e "${TAB}- Azure DevOps organisation URL  (e.g. https://dev.azure.com/myorg)"
echo -e "${TAB}- Personal Access Token (PAT) with 'Agent Pools (Read & Manage)' scope"
echo -e "${TAB}- Agent pool name (default: Default)"
