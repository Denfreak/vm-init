#!/bin/bash
set -Eeuo pipefail

############################
# Colors
############################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

############################
# Dry-run logic
############################
DRY_RUN=true
if [[ "${1:-}" == "--apply" ]]; then
    DRY_RUN=false
fi

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN] $*${NC}"
    else
        eval "$@"
    fi
}

############################
# Check if running as root
############################
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}-----This script must be run as root-----${NC}"
   exit 1
fi

echo -e "${BLUE}===== Bootstrap start (dry-run: $DRY_RUN) =====${NC}"

############################
# Variables
############################
USER_NAME="joe"
TIMEZONE="Europe/Moscow"
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC+ostkXoo9cJj7bUgWxmljthPKQJ19bTZFy/6ayciUfJ4JfhcrEvCd7K+5ygE+mqWPv0s9C4UKI0yMyOkGzGcq1+kdg8vK7k1CG7K2PxtRctvMbG6Ua9A2oMN3DwpysmslBfruXenszlumMiOy9MmRw4iQ0XAcG1HD8dt4EJZA7EZ8MG3YkqAFYWw+mCG6S89p+MkY6zg5eFT7b5fri4d88FHeW3gGAiEqJF6Lb4QN/FmzSrMkq7G+O344AK52E1s63439n1RR6KWBVDjECMFXUMsGbqicVJ58ULx6Qmq29QvoadGOBFsAfqBo/1kH7s9hARmNCOExy0PkxC96z6aH Joe"

############################
# SELinux
############################
CURRENT_STATUS=$(getenforce || echo "Unknown")
echo -e "${BLUE}-----SELinux status: $CURRENT_STATUS-----${NC}"

SELINUX_CONFIG="/etc/selinux/config"
if [[ -f "$SELINUX_CONFIG" ]]; then
    if ! grep -q "^SELINUX=disabled" "$SELINUX_CONFIG"; then
        run "cp $SELINUX_CONFIG ${SELINUX_CONFIG}.bak"
        run "sed -i 's/^SELINUX=.*/SELINUX=disabled/' $SELINUX_CONFIG"
        echo -e "${YELLOW}SELinux will be disabled after reboot${NC}"
    else
        echo -e "${GREEN}SELinux already disabled${NC}"
    fi
fi

############################
# Firewalld
############################
echo -e "${BLUE}-----Firewalld-----${NC}"
if systemctl is-active --quiet firewalld; then
    echo -e "${GREEN}Firewalld is running${NC}"
    run "firewall-cmd --permanent --add-service=ssh"
    run "firewall-cmd --reload"
else
    echo -e "${YELLOW}Firewalld is not running${NC}"
fi

############################
# Packages and update
############################
echo -e "${BLUE}-----Packages-----${NC}"
run "dnf install -y vim epel-release"
run "dnf install -y fail2ban"
run "dnf upgrade -y --refresh"

############################
# Sudo for wheel
############################
echo -e "${BLUE}-----Sudo for wheel-----${NC}"
SUDO_FILE="/etc/sudoers.d/wheel_nopasswd"
TEMP_FILE=$(mktemp)

cat <<EOF > "$TEMP_FILE"
%wheel ALL=(ALL) NOPASSWD: ALL
EOF

if visudo -cf "$TEMP_FILE" >/dev/null 2>&1; then
    run "cp $TEMP_FILE $SUDO_FILE"
    run "chmod 0440 $SUDO_FILE"
else
    echo -e "${RED}sudoers syntax error${NC}"
    rm -f "$TEMP_FILE"
    exit 1
fi
rm -f "$TEMP_FILE"

############################
# User
############################
echo -e "${BLUE}-----User $USER_NAME-----${NC}"
id -u "$USER_NAME" &>/dev/null || run "useradd -m -s /bin/bash $USER_NAME"
getent group wheel >/dev/null || run "groupadd wheel"
run "usermod -aG wheel $USER_NAME"

############################
# SSH key
############################
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
run "mkdir -p $USER_HOME/.ssh"
run "install -m 600 /dev/null $USER_HOME/.ssh/authorized_keys"
run "echo '$SSH_KEY' > $USER_HOME/.ssh/authorized_keys"
run "chown -R $USER_NAME:$USER_NAME $USER_HOME/.ssh"
run "chmod 700 $USER_HOME/.ssh"

############################
# SSH config
############################
echo -e "${BLUE}-----SSH hardening-----${NC}"
run "sed -i 's/^#\\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config"
run "sed -i 's/^#\\?PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config"
run "sed -i 's/^#\\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config"
run "sed -i 's/^#\\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config"

if sshd -t; then
    run "systemctl restart sshd"
else
    echo -e "${RED}sshd config invalid${NC}"
    exit 1
fi

############################
# Fail2ban
############################
echo -e "${BLUE}-----Fail2ban-----${NC}"
cat <<EOF > /etc/fail2ban/jail.d/sshd.local
[sshd]
enabled = true
EOF

run "systemctl enable fail2ban"
run "systemctl restart fail2ban"

############################
# Timezone
############################
echo -e "${BLUE}-----Timezone-----${NC}"
run "timedatectl set-timezone $TIMEZONE"

############################
# Prompt
############################
echo -e "${BLUE}-----Shell config-----${NC}"

cat <<'EOF' > /etc/profile.d/prompt.sh
if [ -n "$BASH_VERSION" ]; then
    if [ "$EUID" = "0" ]; then
        PS1='\[\033[1;31m\][\u@\h \W]\$\[\033[0m\] '
    else
        PS1='\[\033[1;32m\][\u@\h \W]\$\[\033[0m\] '
    fi
fi
EOF

cat <<'EOF' > /etc/profile.d/bash.sh
if [ -n "$BASH_VERSION" ]; then
    export HISTTIMEFORMAT='[%d %b %H:%M] '
    export HISTSIZE=10000
    export HISTFILESIZE=10000
    shopt -s histappend
    export PROMPT_COMMAND="history -a"
fi
EOF

run "chmod 644 /etc/profile.d/prompt.sh /etc/profile.d/bash.sh"

############################
# Root lock (POINT OF NO RETURN)
############################
echo -e "${YELLOW}-----Locking root account (POINT OF NO RETURN)-----${NC}"
run "passwd -l root"

############################
# Finish
############################
echo -e "${GREEN}===== Bootstrap finished =====${NC}"
echo -e "${YELLOW}Reboot is recommended${NC}"