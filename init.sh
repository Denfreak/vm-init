#!/bin/bash
set -xeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "${RED}-----This script must be run as root-----${NC}"
   exit 1
fi

# SELinux
CURRENT_STATUS=$(getenforce)
echo -e "${BLUE}-----Selinux $CURRENT_STATUS-----${NC}"
SELINUX_CONFIG="/etc/selinux/config"
if [ "$CURRENT_STATUS" != "Disabled" ]; then
    echo "${GREEN}set selinux to permissive mode${NC}"
    if command -v setenforce >/dev/null; then
        setenforce 0 2>/dev/null && echo "${GREEN}set selinux to permissive mode${NC}" || echo "${YELLOW}SELinux is not active or tools missing${NC}"
    else
        echo "${YELLOW}setenforce not available${NC}"
    fi
else
    echo "${GREEN}selinux already disabled${NC}"
fi
if [ -f "$SELINUX_CONFIG" ]; then
    if grep -q "^SELINUX=disabled" "$SELINUX_CONFIG"; then
        echo "${GREEN}selinux already disabled${NC}"
    else
        echo "${BLUE}-----Disable selinux-----${NC}"
        cp "$SELINUX_CONFIG" "${SELINUX_CONFIG}.bak"
        sed -i 's/^SELINUX=.*/SELINUX=disabled/' "$SELINUX_CONFIG"
        echo "${GREEN}-----Disabled-----${NC}"
        echo "${YELLOW}-----Do not forget to reboot!-----${NC}"
    fi
fi

# Check firewalld status and opened ports
echo -e "${BLUE}-----Check firewalld status and opened ports-----${NC}"
if systemctl is-active --quiet firewalld; then
    echo "${BLUE}-----Firewalld is running-----${NC}"
    firewall-cmd --permanent --list-all

else
    echo "${YELLOW}-----Firewalld is not running-----${NC}"
fi

# Packages and update
echo -e "${BLUE}-----Install packages and update-----${NC}"
dnf install -y vim epel-release
dnf install -y fail2ban
dnf update -y
echo -e "${GREEN}-----Installed and updated-----${NC}"
echo -e "${YELLOW}-----Do not forget to reboot!-----${NC}"

# Allow sudo for group wheel
echo -e "${BLUE}-----Allow sudo for group wheel-----${NC}"
SUDO_FILE="/etc/sudoers.d/wheel_nopasswd"
TEMP_FILE=$(mktemp)
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > "$TEMP_FILE"
if visudo -cf "$TEMP_FILE" >/dev/null 2>&1; then
    echo -e "${GREEN}visudo syntax is OK${NC}"
    cp "$TEMP_FILE" "$SUDO_FILE"
    chmod 0440 "$SUDO_FILE"
    chown root:root "$SUDO_FILE"
else
    echo -e "${RED}visudo syntax is NOT OK${NC}"
    rm "$TEMP_FILE"
    exit 1
fi
rm "$TEMP_FILE"
echo -e "${GREEN}-----Allowed-----${NC}"

# Add user joe
USER_NAME="joe"
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC+ostkXoo9cJj7bUgWxmljthPKQJ19bTZFy/6ayciUfJ4JfhcrEvCd7K+5ygE+mqWPv0s9C4UKI0yMyOkGzGcq1+kdg8vK7k1CG7K2PxtRctvMbG6Ua9A2oMN3DwpysmslBfruXenszlumMiOy9MmRw4iQ0XAcG1HD8dt4EJZA7EZ8MG3YkqAFYWw+mCG6S89p+MkY6zg5eFT7b5fri4d88FHeW3gGAiEqJF6Lb4QN/FmzSrMkq7G+O344AK52E1s63439n1RR6KWBVDjECMFXUMsGbqicVJ58ULx6Qmq29QvoadGOBFsAfqBo/1kH7s9hARmNCOExy0PkxC96z6aH Joe"
echo -e "${BLUE}-----Add user joe-----${NC}"
id -u "$USER_NAME" &>/dev/null || useradd -m -s /bin/bash "$USER_NAME"
echo -e "${GREEN}-----Added-----${NC}"

# Add user joe to wheel group
echo -e "${BLUE}-----Add user joe to wheel group-----${NC}"
getent group wheel >/dev/null || groupadd wheel
usermod -aG wheel "$USER_NAME"
echo -e "${GREEN}-----Added-----${NC}"

# Add ssh key to user joe
echo -e "${BLUE}-----Add ssh key-----${NC}"
USER_HOME=$(getent passwd "$USER_NAME" | cut -d: -f6)
mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

echo -e "${BLUE}-----Ensure joe can use sudo-----${NC}"
su - "$USER_NAME" -c 'sudo -n true' 2>/dev/null && \
    echo -e "${GREEN}-----User $USER_NAME can use sudo without password-----${NC}" || \
    { echo -e "${RED}-----User $USER_NAME cannot use sudo-----${NC}"; exit 1; }
echo -e "${GREEN}-----Added-----${NC}"

# Remove root password
echo -e "${BLUE}-----Remove root password-----${NC}"
passwd -l root
echo -e "${GREEN}-----Removed-----${NC}"

# Configure ssh
echo -e "${BLUE}-----Configure ssh-----${NC}"
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitEmptyPasswords .*/PermitEmptyPasswords no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
if sshd -t; then
    systemctl restart sshd
else
    echo "-----sshd config is not valid-----"
fi
echo -e "${GREEN}-----Configured-----${NC}"

# Set timezone
echo -e "${BLUE}-----Set timezone-----${NC}"
timedatectl set-timezone Europe/Moscow
echo -e "${GREEN}-----Set-----${NC}"

# Enable file2ban service
echo -e "${BLUE}-----Enable fail2ban service-----${NC}"
systemctl enable fail2ban
systemctl start fail2ban
echo -e "${GREEN}-----Enabled-----${NC}"

# Configure color prompt
echo -e "${BLUE}-----Configure color prompt-----${NC}"
PROMPT_CONF="/etc/profile.d/prompt.sh"
cat << 'EOF' > "$PROMPT_CONF"
if [ -n "$BASH_VERSION" ]; then
    if [ "$EUID" = "0" ]; then
        PS1='\[\033[1;38;5;81m\][\u@\h\[\033[00m\] \[\033[1;38;5;32m\]\W\[\033[1;38;5;81m\]]\[\033[00m\]\$ '
    else
        PS1='\[\033[1;38;5;84m\][\u@\h\[\033[00m\] \[\033[1;38;5;32m\]\W\[\033[1;38;5;84m\]]\[\033[00m\]\$ '
    fi
fi
EOF
chmod 644 "$PROMPT_CONF"
echo -e "${GREEN}-----Configured-----${NC}"

# Configure bash
echo -e "${BLUE}-----Configure bash-----${NC}"
BASH_CONF="/etc/profile.d/bash.sh"
cat << 'EOF' > "$BASH_CONF"
if [ -n "$BASH_VERSION" ]; then
    export HISTTIMEFORMAT='[%d %b %H:%M] '
    export HISTSIZE=10000
    export HISTFILESIZE=10000

    shopt -s histappend
    shopt -s cmdhist
    export PROMPT_COMMAND="history -a; $PROMPT_COMMAND"
fi
EOF
chmod 644 "$BASH_CONF"
echo -e "${GREEN}-----Configured-----${NC}"


