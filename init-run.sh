#!/bin/bash
set -Eeuo pipefail

#################################
# Colors for output
#################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#################################
# Dry-run
#################################
DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
    DRY_RUN=false
fi

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN] $*${NC}"
    else
        "$@"
    fi
}

#################################
# Root check
#################################
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root${NC}"
    exit 1
fi

#################################
# Logging
#################################
LOG_FILE="/var/log/bootstrap.log"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "================================================="
echo " Bootstrap started: $(date)"
echo " Dry-run mode: $DRY_RUN"
echo "================================================="

#################################
# Variables
#################################
USER_NAME="joe"
TIMEZONE="Europe/Moscow"
SSH_PORT=18022
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC+ostkXoo9cJj7bUgWxmljthPKQJ19bTZFy/6ayciUfJ4JfhcrEvCd7K+5ygE+mqWPv0s9C4UKI0yMyOkGzGcq1+kdg8vK7k1CG7K2PxtRctvMbG6Ua9A2oMN3DwpysmslBfruXenszlumMiOy9MmRw4iQ0XAcG1HD8dt4EJZA7EZ8MG3YkqAFYWw+mCG6S89p+MkY6zg5eFT7b5fri4d88FHeW3gGAiEqJF6Lb4QN/FmzSrMkq7G+O344AK52E1s63439n1RR6KWBVDjECMFXUMsGbqicVJ58ULx6Qmq29QvoadGOBFsAfqBo/1kH7s9hARmNCOExy0PkxC96z6aH Joe"

#################################
# Swap
#################################
echo -e "${BLUE}-----Swap-----${NC}"
if ! swapon --show | grep -q swap; then
    echo -e "${YELLOW}No swap detected, creating 1G swap${NC}"
    run fallocate -l 1G /swapfile || run dd if=/dev/zero of=/swapfile bs=1M count=1024
    run chmod 600 /swapfile
    run mkswap /swapfile
    run swapon /swapfile
    run bash -c "echo '/swapfile none swap sw 0 0' >> /etc/fstab"
else
    echo -e "${GREEN}Swap already enabled${NC}"
fi

#################################
# SELinux
#################################
echo -e "${BLUE}-----SELinux-----${NC}"
SELINUX_CONFIG="/etc/selinux/config"
CURRENT_STATUS=$(getenforce || echo "unknown")
echo -e "${BLUE}-----SELinux status: $CURRENT_STATUS-----${NC}"

if [[ -f "$SELINUX_CONFIG" ]] && ! grep -q "^SELINUX=disabled" "$SELINUX_CONFIG"; then
    run cp "$SELINUX_CONFIG" "${SELINUX_CONFIG}.bak"
    run sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$SELINUX_CONFIG"
    echo -e "${YELLOW}SELinux will be disabled after reboot${NC}"
fi

#################################
# Packages
#################################
echo -e "${BLUE}-----Packages-----${NC}"
run dnf install -y vim --setopt=install_weak_deps=False --setopt=tsflags=nodocs
run dnf install -y epel-release
run crb enable
run dnf install -y fail2ban --setopt=install_weak_deps=False --setopt=tsflags=nodocs
run dnf upgrade -y --refresh

#################################
# User
#################################
echo -e "${BLUE}-----User setup-----${NC}"
id -u "$USER_NAME" &>/dev/null || run useradd -m -s /bin/bash "$USER_NAME"
getent group wheel >/dev/null || run groupadd wheel
run usermod -aG wheel "$USER_NAME"

#################################
# Sudo
#################################
echo -e "${BLUE}-----Sudo-----${NC}"
TMP=$(mktemp)
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "$TMP"
visudo -cf "$TMP" >/dev/null
run cp "$TMP" /etc/sudoers.d/wheel_nopasswd
run chmod 0440 /etc/sudoers.d/wheel_nopasswd
rm -f "$TMP"

#################################
# SSH key
#################################
echo -e "${BLUE}-----SSH key-----${NC}"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
run mkdir -p "$USER_HOME/.ssh"
run bash -c "echo '$SSH_KEY' > $USER_HOME/.ssh/authorized_keys"
run chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.ssh"
run chmod 700 "$USER_HOME/.ssh"
run chmod 600 "$USER_HOME/.ssh/authorized_keys"

#################################
# SSH configuration (port 18022)
#################################
echo -e "${BLUE}-----SSH configuration-----${NC}"

run sed -i "s/^#\?Port .*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
run sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
run sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
run sed -i 's/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
run sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
run sed -i 's/^#\?UsePAM .*/UsePAM yes/' /etc/ssh/sshd_config

sshd -t
run systemctl restart sshd

#################################
# Firewalld (ONLY 18022)
#################################
echo -e "${BLUE}-----Firewalld-----${NC}"
if systemctl is-active --quiet firewalld; then
    for svc in $(firewall-cmd --permanent --list-services); do
        run firewall-cmd --permanent --remove-service="$svc"
    done
    for port in $(firewall-cmd --permanent --list-ports); do
        run firewall-cmd --permanent --remove-port="$port"
    done
    run firewall-cmd --permanent --add-port=${SSH_PORT}/tcp
    run firewall-cmd --reload
else
    echo -e "${YELLOW}Firewalld is not running${NC}"
fi

#################################
# Fail2ban (SSH 18022)
#################################
echo -e "${BLUE}-----Fail2ban-----${NC}"
run mkdir -p /etc/fail2ban/jail.d

cat <<EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

run systemctl enable fail2ban
run systemctl restart fail2ban

#################################
# Timezone
#################################
echo -e "${BLUE}-----Timezone-----${NC}"
run timedatectl set-timezone "$TIMEZONE"

#################################
# Bash history
#################################
echo -e "${BLUE}-----Bash history-----${NC}"
cat <<'EOF' > /etc/profile.d/bash.sh
if [ -n "$BASH_VERSION" ]; then
    export HISTTIMEFORMAT='[%d %b %H:%M] '
    export HISTSIZE=10000
    export HISTFILESIZE=10000
    shopt -s histappend
    export PROMPT_COMMAND="history -a"
fi
EOF
run chmod 644 /etc/profile.d/bash.sh

#################################
# Colored prompt (reliable)
#################################
echo -e "${BLUE}-----Colored prompt-----${NC}"
cat <<'EOF' > /etc/profile.d/custom_prompt.sh
[[ $- != *i* ]] && return

if [[ -z "$CUSTOM_PROMPT_SET" ]]; then
    if [[ $EUID -eq 0 ]]; then
        PS1='\[\033[1;38;5;81m\][\u@\h\[\033[00m\] \[\033[1;38;5;32m\]\W\[\033[1;38;5;81m\]]\[\033[00m\]\$ '
    else
        PS1='\[\033[1;38;5;84m\][\u@\h\[\033[00m\] \[\033[1;38;5;32m\]\W\[\033[1;38;5;84m\]]\[\033[00m\]\$ '
    fi
    export CUSTOM_PROMPT_SET=1
fi
EOF
chmod 644 /etc/profile.d/custom_prompt.sh

#################################
# Lock root
#################################
echo -e "${YELLOW}-----Locking root account-----${NC}"
run passwd -l root

#################################
# Finish
#################################
echo "================================================="
echo " Bootstrap finished: $(date)"
echo "================================================="
echo -e "${YELLOW}Reboot recommended${NC}"