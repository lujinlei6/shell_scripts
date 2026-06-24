#!/bin/bash

#############################################################
# Name    : repo-config.sh
# Version : 1.0
# Desc    : 配置阿里云软件源 (自动检测系统类型)
#############################################################

set -uo pipefail

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
END="\033[0m"

# ============================================================
# 检测操作系统类型
# ============================================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_NAME="$NAME"
    elif [ -f /etc/redhat-release ]; then
        OS_ID="centos"
        OS_VERSION=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        OS_NAME=$(cat /etc/redhat-release)
    else
        echo -e "${RED}[错误] 无法检测操作系统类型${END}"
        exit 1
    fi
}

# ============================================================
# 备份原有源配置
# ============================================================
backup_repo() {
    local repo_dir="$1"
    local backup_dir="${repo_dir}.bak.$(date +%Y%m%d%H%M%S)"
    
    if [ -d "$repo_dir" ] && [ "$(ls -A $repo_dir 2>/dev/null)" ]; then
        cp -r "$repo_dir" "$backup_dir"
        echo -e "${GREEN}[信息] 已备份原有源配置到: ${backup_dir}${END}"
    fi
}

# ============================================================
# 配置 CentOS 源
# ============================================================
configure_centos() {
    local version="$1"
    local major_version=$(echo "$version" | cut -d. -f1)
    
    echo -e "${BLUE}[信息] 正在配置 CentOS ${major_version} 阿里云源...${END}"
    
    backup_repo "/etc/yum.repos.d"
    
    # 删除原有repo文件
    rm -f /etc/yum.repos.d/*.repo
    
    # 创建阿里云CentOS源
    cat > /etc/yum.repos.d/CentOS-Base.repo <<EOF
[base]
name=CentOS-\$releasever - Base - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/os/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/os/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}

[updates]
name=CentOS-\$releasever - Updates - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/updates/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/updates/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}

[extras]
name=CentOS-\$releasever - Extras - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/extras/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/extras/\$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}

[centosplus]
name=CentOS-\$releasever - Plus - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/centosplus/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/centosplus/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}

[contrib]
name=CentOS-\$releasever - Contrib - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/contrib/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/contrib/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}
EOF

    # CentOS 8 以上版本需要配置 PowerTools
    if [ "$major_version" -ge 8 ]; then
        cat > /etc/yum.repos.d/CentOS-PowerTools.repo <<EOF
[PowerTools]
name=CentOS-\$releasever - PowerTools - mirrors.aliyun.com
failovermethod=priority
baseurl=https://mirrors.aliyun.com/centos/${major_version}/PowerTools/\$basearch/
        http://mirrors.aliyun.com/centos/${major_version}/PowerTools/\$basearch/
gpgcheck=1
enabled=0
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-${major_version}
EOF
    fi
    
    echo -e "${GREEN}[信息] CentOS ${major_version} 阿里云源配置完成${END}"
}

# ============================================================
# 配置 Rocky Linux 源
# ============================================================
configure_rocky() {
    local version="$1"
    local major_version=$(echo "$version" | cut -d. -f1)
    
    echo -e "${BLUE}[信息] 正在配置 Rocky Linux ${major_version} 阿里云源...${END}"
    
    backup_repo "/etc/yum.repos.d"
    
    # 删除原有repo文件
    rm -f /etc/yum.repos.d/*.repo
    
    # 创建阿里云Rocky Linux源
    cat > /etc/yum.repos.d/Rocky-Base.repo <<EOF
[baseos]
name=Rocky Linux \$releasever - BaseOS
baseurl=https://mirrors.aliyun.com/rockylinux/${major_version}/BaseOS/\$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/rockylinux/RPM-GPG-KEY-Rocky-${major_version}
enabled=1

[appstream]
name=Rocky Linux \$releasever - AppStream
baseurl=https://mirrors.aliyun.com/rockylinux/${major_version}/AppStream/\$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/rockylinux/RPM-GPG-KEY-Rocky-${major_version}
enabled=1

[crb]
name=Rocky Linux \$releasever - CRB
baseurl=https://mirrors.aliyun.com/rockylinux/${major_version}/CRB/\$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/rockylinux/RPM-GPG-KEY-Rocky-${major_version}
enabled=0

[extras]
name=Rocky Linux \$releasever - Extras
baseurl=https://mirrors.aliyun.com/rockylinux/${major_version}/extras/\$basearch/os/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/rockylinux/RPM-GPG-KEY-Rocky-${major_version}
enabled=1
EOF

    echo -e "${GREEN}[信息] Rocky Linux ${major_version} 阿里云源配置完成${END}"
}

# ============================================================
# 配置 Ubuntu 源
# ============================================================
configure_ubuntu() {
    local version="$1"
    local codename="$2"
    
    echo -e "${BLUE}[信息] 正在配置 Ubuntu ${version} (${codename}) 阿里云源...${END}"
    
    backup_repo "/etc/apt/sources.list"
    backup_repo "/etc/apt/sources.list.d"
    
    # 创建阿里云Ubuntu源
    cat > /etc/apt/sources.list <<EOF
deb https://mirrors.aliyun.com/ubuntu/ ${codename} main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${codename} main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${codename}-security main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${codename}-security main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${codename}-updates main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${codename}-updates main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${codename}-proposed main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${codename}-proposed main restricted universe multiverse

deb https://mirrors.aliyun.com/ubuntu/ ${codename}-backports main restricted universe multiverse
deb-src https://mirrors.aliyun.com/ubuntu/ ${codename}-backports main restricted universe multiverse
EOF

    echo -e "${GREEN}[信息] Ubuntu ${version} (${codename}) 阿里云源配置完成${END}"
}

# ============================================================
# 清理并更新缓存
# ============================================================
update_cache() {
    echo -e "${BLUE}[信息] 正在清理并更新软件源缓存...${END}"
    
    if command -v yum &> /dev/null; then
        yum clean all
        yum makecache
    elif command -v dnf &> /dev/null; then
        dnf clean all
        dnf makecache
    elif command -v apt-get &> /dev/null; then
        apt-get clean
        apt-get update
    fi
    
    echo -e "${GREEN}[信息] 软件源缓存更新完成${END}"
}

# ============================================================
# 主函数
# ============================================================
main() {
    echo -e "${BLUE}========================================${END}"
    echo -e "${BLUE}    阿里云软件源自动配置脚本${END}"
    echo -e "${BLUE}========================================${END}"
    
    # 检查是否为root用户
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[错误] 请使用 root 用户运行此脚本${END}"
        exit 1
    fi
    
    # 检测操作系统
    detect_os
    
    echo -e "${GREEN}[信息] 检测到操作系统: ${OS_NAME}${END}"
    echo -e "${GREEN}[信息] 系统ID: ${OS_ID}${END}"
    echo -e "${GREEN}[信息] 系统版本: ${OS_VERSION}${END}"
    echo ""
    
    # 根据操作系统类型配置相应的源
    case "$OS_ID" in
        centos)
            configure_centos "$OS_VERSION"
            ;;
        rocky)
            configure_rocky "$OS_VERSION"
            ;;
        ubuntu)
            # 获取Ubuntu代号
            codename=$(lsb_release -cs 2>/dev/null || echo "${OS_ID}")
            configure_ubuntu "$OS_VERSION" "$codename"
            ;;
        *)
            echo -e "${RED}[错误] 不支持的操作系统: ${OS_ID}${END}"
            echo -e "${YELLOW}[提示] 此脚本支持: CentOS, Rocky Linux, Ubuntu${END}"
            exit 1
            ;;
    esac
    
    # 更新缓存
    update_cache
    
    echo ""
    echo -e "${GREEN}========================================${END}"
    echo -e "${GREEN}    软件源配置完成！${END}"
    echo -e "${GREEN}========================================${END}"
}

# 执行主函数
main "$@"