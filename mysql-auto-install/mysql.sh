#!/bin/bash

#############################################################
# Name    : mysql-auto-install.sh
# Version : 4.0
# Desc    : MySQL Binary Install Script
#           - 幂等安装 / 参数化配置 / 防火墙 & SELinux / 卸载
#############################################################

set -uo pipefail
# 注意: 未使用 set -e，因为不同发行版包名可能略有差异，
# 安装命令失败不应直接退出，后续有 command -v 验证兜底

# ============================================================
# 0. 默认值 (可被命令行参数覆盖)
# ============================================================
MYSQL_VERSION="8.0.41"
MYSQL_PORT="3306"
INSTALL_DIR="/usr/local"
MYSQL_HOME="${INSTALL_DIR}/mysql"
DATA_DIR="/data/mysql"
LOG_DIR="/var/log/mysql"
MYSQL_ROOT_PASSWORD=""          # 为空则只显示临时密码

ACTION="install"                # install | uninstall | status

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[36m"
END="\033[0m"

# ============================================================
# 0.1 帮助信息
# ============================================================
usage() {
    cat <<EOF
用法: $0 [选项]

操作模式:
  install           安装 MySQL (默认)
  uninstall         卸载 MySQL (保留数据目录)
  uninstall --purge 彻底卸载 (含数据)
  status            仅显示当前状态

参数:
  -v, --version VER     MySQL 版本       (默认: ${MYSQL_VERSION})
  -p, --port PORT       MySQL 端口       (默认: ${MYSQL_PORT})
  -b, --basedir DIR     安装目录         (默认: ${INSTALL_DIR})
  -d, --datadir DIR     数据目录         (默认: ${DATA_DIR})
  -l, --logdir DIR      日志目录         (默认: ${LOG_DIR})
  --password PASS       设置 root 密码   (默认: 仅显示临时密码)
  -h, --help            显示帮助

示例:
  $0                                          # 默认安装
  $0 -v 5.7.44 -p 3307                        # 指定版本和端口
  $0 --port 3307 --datadir /data/mysql57      # 多实例
  $0 uninstall                                # 卸载 (保留数据)
  $0 uninstall --purge                        # 彻底卸载
  $0 status                                   # 查看状态
EOF
    exit 0
}

# ============================================================
# 0.2 参数解析
# ============================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            install|uninstall|status)
                ACTION="$1"
                shift
                ;;
            --purge)
                PURGE="true"
                shift
                ;;
            -v|--version)
                MYSQL_VERSION="$2"; shift 2 ;;
            -p|--port)
                MYSQL_PORT="$2"; shift 2 ;;
            -b|--basedir)
                INSTALL_DIR="$2"
                MYSQL_HOME="${INSTALL_DIR}/mysql"
                shift 2 ;;
            -d|--datadir)
                DATA_DIR="$2"; shift 2 ;;
            -l|--logdir)
                LOG_DIR="$2"; shift 2 ;;
            --password)
                MYSQL_ROOT_PASSWORD="$2"; shift 2 ;;
            -h|--help)
                usage ;;
            *)
                print_error "未知参数: $1"
                usage ;;
        esac
    done

    # 动态 tarball 名称
    case "${MYSQL_VERSION}" in
        8.*)
            MYSQL_TAR="mysql-${MYSQL_VERSION}-linux-glibc2.28-x86_64.tar.xz" ;;
        5.7.*)
            MYSQL_TAR="mysql-${MYSQL_VERSION}-linux-glibc2.12-x86_64.tar.gz" ;;
        *)
            die "不支持的 MySQL 版本：${MYSQL_VERSION} (仅支持 5.7.x / 8.x)" ;;
    esac

    PID_FILE="${DATA_DIR}/mysql.pid"
    SOCKET_FILE="/tmp/mysql_${MYSQL_PORT}.sock"
}

# ============================================================
# 0.3 公共输出函数
# ============================================================
print_info()  { echo -e "${GREEN}[INFO]${END} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${END} $1"; }
print_error() { echo -e "${RED}[ERROR]${END} $1" >&2; }
die()         { print_error "$1"; exit 1; }
print_skip()  { print_info "${YELLOW}[SKIP]${END} $1"; }

# ============================================================
# 0.4 基础检查
# ============================================================
check_root() {
    [ "$EUID" -eq 0 ] || die "请使用 root 用户运行此脚本"
}

detect_os() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        OS_ID=$ID
        OS_VERSION=${VERSION_ID%%.*}
    elif [ -f /etc/redhat-release ]; then
        OS_ID="centos"
        OS_VERSION=$(rpm -q --qf "%{VERSION}" $(rpm -q --whatprovides redhat-release) 2>/dev/null | cut -d. -f1)
    else
        die "无法识别操作系统"
    fi
    print_info "系统：${PRETTY_NAME:-$OS_ID $OS_VERSION}"
}

# ============================================================
# 1. 基础环境安装
# ============================================================
# 安全安装：单包逐一尝试，失败只 warn 不退出
safe_install_pkgs() {
    local failed=()
    for pkg in "$@"; do
        print_info "  → 安装 ${pkg} ..."
        case ${OS_ID} in
            centos|rocky|rhel|almalinux|fedora)
                if command -v dnf &>/dev/null; then
                    dnf install -y --setopt=tsflags=nodocs "${pkg}" || failed+=("${pkg}")
                else
                    yum install -y "${pkg}" || failed+=("${pkg}")
                fi
            ;;
            ubuntu|debian)
                apt install -y -qq "${pkg}" 2>&1 || failed+=("${pkg}")
            ;;
        esac
    done
    [ ${#failed[@]} -gt 0 ] && print_warn "以下包安装失败: ${failed[*]}"
}

install_base_tools() {
    print_info "安装基础工具..."

    # 先确保包管理器缓存可用
    case ${OS_ID} in
        centos|rocky|rhel|almalinux|fedora)
            command -v dnf &>/dev/null && dnf makecache &>/dev/null || yum makecache &>/dev/null || true
        ;;
        ubuntu|debian)
            apt update -qq 2>/dev/null || true
        ;;
    esac

    case ${OS_ID} in
        centos|rocky|rhel|almalinux|fedora)
            # 有些包可能互斥（如 vim-minimal vs vim-enhanced），先尝试装，失败了继续
            safe_install_pkgs \
                wget \
                tar \
                perl \
                net-tools \
                curl

            # vim 包名兼容：先试 vim-minimal，失败试 vim-enhanced，再失败试 vim-common
            if ! command -v vim &>/dev/null; then
                dnf install -y vim-minimal 2>/dev/null || \
                dnf install -y vim-enhanced 2>/dev/null || \
                dnf install -y vim-common 2>/dev/null || \
                print_warn "vim 安装失败，不影响脚本继续"
            fi

            # procps 包名兼容 (Rocky 10+ 可能是 procps，旧版是 procps-ng)
            if ! command -v ps &>/dev/null; then
                dnf install -y procps-ng 2>/dev/null || \
                dnf install -y procps 2>/dev/null || \
                print_warn "procps 安装失败，不影响脚本继续"
            fi
        ;;
        ubuntu|debian)
            safe_install_pkgs wget tar xz-utils perl net-tools less curl unzip bzip2 lsof procps
            command -v vim &>/dev/null || apt install -y -qq vim 2>/dev/null || true
        ;;
        *) die "当前系统暂不支持: ${OS_ID}" ;;
    esac

    # 只验证脚本自身绝对依赖的命令
    local missing=()
    for cmd in wget tar xz perl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    [ ${#missing[@]} -gt 0 ] && die "基础工具仍缺失: ${missing[*]}"
    print_info "基础工具就绪"
}

install_mysql_dependencies() {
    print_info "安装 MySQL 运行时依赖..."
    case ${OS_ID} in
        centos|rocky|rhel|almalinux|fedora)
            # numactl-libs 在某些新版 Rocky 上可能改名 numactl-libs → 逐一装，失败不退出
            if command -v dnf &>/dev/null; then
                dnf install -y libaio 2>/dev/null || true
                dnf install -y numactl-libs 2>/dev/null || dnf install -y numactl 2>/dev/null || true
            else
                yum install -y libaio 2>/dev/null || true
                yum install -y numactl-libs 2>/dev/null || yum install -y numactl 2>/dev/null || true
            fi
        ;;
        ubuntu|debian)
            apt install -y -qq libaio1 numactl 2>/dev/null || true
        ;;
    esac
    print_info "运行时依赖就绪"
}

# ============================================================
# 1.1 防火墙处理
# ============================================================
handle_firewall() {
    print_info "检查防火墙..."

    # ---------- firewalld ----------
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        if firewall-cmd --list-ports 2>/dev/null | grep -q "${MYSQL_PORT}/tcp"; then
            print_skip "firewalld ${MYSQL_PORT}/tcp 已放行"
        else
            firewall-cmd --permanent --add-port="${MYSQL_PORT}/tcp" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
            print_info "firewalld 已放行 ${MYSQL_PORT}/tcp"
        fi
    fi

    # ---------- iptables ----------
    if command -v iptables &>/dev/null; then
        if iptables -C INPUT -p tcp --dport "${MYSQL_PORT}" -j ACCEPT 2>/dev/null; then
            print_skip "iptables ${MYSQL_PORT}/tcp 已放行"
        else
            iptables -I INPUT -p tcp --dport "${MYSQL_PORT}" -j ACCEPT 2>/dev/null || true
            # 持久化
            if command -v iptables-save &>/dev/null; then
                case ${OS_ID} in
                    centos|rocky|rhel|almalinux)
                        service iptables save 2>/dev/null || iptables-save > /etc/sysconfig/iptables 2>/dev/null || true
                    ;;
                    ubuntu|debian)
                        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
                    ;;
                esac
            fi
            print_info "iptables 已放行 ${MYSQL_PORT}/tcp"
        fi
    fi

    # ---------- ufw (Ubuntu) ----------
    if command -v ufw &>/dev/null && ufw status | grep -q "Status: active" 2>/dev/null; then
        if ufw status | grep -q "${MYSQL_PORT}/tcp"; then
            print_skip "ufw ${MYSQL_PORT}/tcp 已放行"
        else
            ufw allow "${MYSQL_PORT}/tcp" &>/dev/null || true
            print_info "ufw 已放行 ${MYSQL_PORT}/tcp"
        fi
    fi
}

# ---- 卸载防火墙规则 ----
remove_firewall_rules() {
    print_info "清理防火墙规则..."

    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --remove-port="${MYSQL_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
        print_info "firewalld 已移除 ${MYSQL_PORT}/tcp"
    fi

    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "${MYSQL_PORT}" -j ACCEPT 2>/dev/null || true
        print_info "iptables 已移除 ${MYSQL_PORT}/tcp"
    fi

    if command -v ufw &>/dev/null; then
        ufw delete allow "${MYSQL_PORT}/tcp" 2>/dev/null || true
        print_info "ufw 已移除 ${MYSQL_PORT}/tcp"
    fi
}

# ============================================================
# 1.2 SELinux 处理
# ============================================================
handle_selinux() {
    # 没有 SELinux 就跳过
    command -v getenforce &>/dev/null || return 0
    local mode
    mode=$(getenforce 2>/dev/null) || return 0

    print_info "SELinux 当前模式: ${mode}"

    case "${mode}" in
        Disabled)
            print_skip "SELinux 已禁用，无需处理"
            return 0
        ;;
        Permissive)
            print_warn "SELinux 处于 Permissive 模式（不拦截，仅审计）"
            # 仍然打标签，万一切回 Enforcing 也不出问题
        ;;
        Enforcing)
            print_info "SELinux Enforcing — 配置上下文..."
        ;;
    esac

    # 安装 SELinux 管理工具
    case ${OS_ID} in
        centos|rocky|rhel|almalinux|fedora)
            if ! command -v semanage &>/dev/null; then
                if command -v dnf &>/dev/null; then
                    dnf install -y policycoreutils-python-utils 2>/dev/null || true
                else
                    yum install -y policycoreutils-python-utils 2>/dev/null || true
                fi
            fi
        ;;
        ubuntu|debian)
            command -v semanage &>/dev/null || apt install -y -qq policycoreutils 2>/dev/null || true
        ;;
    esac

    # --- 给 MySQL 目录打正确的 SELinux 标签 ---
    # mysqld 二进制 → mysqld_exec_t
    if [ -e "${MYSQL_HOME}/bin/mysqld" ]; then
        semanage fcontext -a -t mysqld_exec_t "${MYSQL_HOME}/bin/mysqld" 2>/dev/null || true
        restorecon "${MYSQL_HOME}/bin/mysqld" 2>/dev/null || true
    fi
    # bin 目录下其他可执行文件
    if [ -d "${MYSQL_HOME}/bin" ]; then
        semanage fcontext -a -t mysqld_exec_t "${MYSQL_HOME}/bin(/.*)?" 2>/dev/null || true
        restorecon -R "${MYSQL_HOME}/bin" 2>/dev/null || true
    fi
    # 数据目录 → mysqld_db_t
    if [ -d "${DATA_DIR}" ]; then
        semanage fcontext -a -t mysqld_db_t "${DATA_DIR}(/.*)?" 2>/dev/null || true
        restorecon -R "${DATA_DIR}" 2>/dev/null || true
    fi
    # 日志目录 → mysqld_log_t
    if [ -d "${LOG_DIR}" ]; then
        semanage fcontext -a -t mysqld_log_t "${LOG_DIR}(/.*)?" 2>/dev/null || true
        restorecon -R "${LOG_DIR}" 2>/dev/null || true
    fi

    # --- 允许 MySQL 监听非默认端口 ---
    if [ "${MYSQL_PORT}" != "3306" ]; then
        semanage port -a -t mysqld_port_t -p tcp "${MYSQL_PORT}" 2>/dev/null || true
        print_info "SELinux 已放行端口 ${MYSQL_PORT}/tcp"
    fi

    # --- 布尔值: 允许 MySQL 连接外部网络 (如主从复制) ---
    setsebool -P mysql_connect_any on 2>/dev/null || true

    print_info "SELinux 上下文已配置"
}

# ---- 卸载 SELinux 上下文 ----
remove_selinux_context() {
    command -v semanage &>/dev/null || return 0

    print_info "清理 SELinux 上下文..."

    # 移除 mysqld_exec_t 标签
    [ -d "${MYSQL_HOME}/bin" ] && semanage fcontext -d -t mysqld_exec_t "${MYSQL_HOME}/bin(/.*)?" 2>/dev/null || true
    [ -e "${MYSQL_HOME}/bin/mysqld" ] && semanage fcontext -d -t mysqld_exec_t "${MYSQL_HOME}/bin/mysqld" 2>/dev/null || true
    # 移除 mysqld_db_t 标签
    [ -d "${DATA_DIR}" ] && semanage fcontext -d -t mysqld_db_t "${DATA_DIR}(/.*)?" 2>/dev/null || true
    # 移除 mysqld_log_t 标签
    [ -d "${LOG_DIR}" ] && semanage fcontext -d -t mysqld_log_t "${LOG_DIR}(/.*)?" 2>/dev/null || true

    if [ "${MYSQL_PORT}" != "3306" ]; then
        semanage port -d -t mysqld_port_t -p tcp "${MYSQL_PORT}" 2>/dev/null || true
    fi

    print_info "SELinux 上下文已清理"
}

# ============================================================
# 2. 幂等性检测
# ============================================================
is_mysql_binary_installed()  { [ -x "${MYSQL_HOME}/bin/mysqld" ]; }
is_data_initialized()        { [ -d "${DATA_DIR}/mysql" ] || [ -f "${DATA_DIR}/ibdata1" ]; }
is_service_created() {
    [ -f "/usr/lib/systemd/system/mysqld.service" ] || \
    [ -f "/etc/systemd/system/mysqld.service" ]
}
is_mysql_running() {
    [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}")" 2>/dev/null && return 0
    ss -tlnp 2>/dev/null | grep -q ":${MYSQL_PORT} " && return 0
    return 1
}

# ============================================================
# 3. 下载
# ============================================================
download_mysql() {
    if is_mysql_binary_installed; then
        print_skip "MySQL 二进制已安装，跳过下载"
        return 0
    fi

    if [ -f "${MYSQL_TAR}" ] && [ -s "${MYSQL_TAR}" ]; then
        print_info "安装包已存在：${MYSQL_TAR}，跳过下载"
        return 0
    fi

    DOWNLOAD_URL="https://downloads.mysql.com/archives/get/p/23/file/${MYSQL_TAR}"
    print_info "开始下载 MySQL..."
    echo "URL: ${DOWNLOAD_URL}"

    wget -c  "${DOWNLOAD_URL}" -O "${MYSQL_TAR}" || die "下载失败"
    [ -f "${MYSQL_TAR}" ] || die "下载完成但安装包不存在"
    print_info "下载完成"
}

# ============================================================
# 4. 用户 / 目录 / 解压
# ============================================================
create_mysql_user() {
    if id mysql &>/dev/null; then
        print_skip "mysql 用户已存在"
        return 0
    fi
    useradd -r -s /sbin/nologin mysql
    print_info "mysql 用户已创建"
}

remove_old_mysql() {
    if is_mysql_binary_installed; then
        print_skip "MySQL 二进制已就绪，跳过清理"
        return 0
    fi
    if [ -d "${MYSQL_HOME}" ]; then
        print_info "删除旧版本 ${MYSQL_HOME}"
        systemctl stop mysqld 2>/dev/null || true
        rm -rf "${MYSQL_HOME}"
    fi
}

extract_mysql() {
    if is_mysql_binary_installed; then
        print_skip "MySQL 已解压至 ${MYSQL_HOME}"
        return 0
    fi

    print_info "解压 ${MYSQL_TAR} → ${INSTALL_DIR} ..."
    mkdir -p "${INSTALL_DIR}" || die "无法创建目录: ${INSTALL_DIR}"
    tar -xf "${MYSQL_TAR}" -C "${INSTALL_DIR}" || die "解压失败"

    local extracted_dir
    extracted_dir=$(ls -d "${INSTALL_DIR}"/mysql-* 2>/dev/null | head -1)
    [ -n "${extracted_dir}" ] || die "未找到解压目录"
    mv "${extracted_dir}" "${MYSQL_HOME}" || die "重命名失败"
    print_info "解压完成 → ${MYSQL_HOME}"
}

create_directory() {
    mkdir -p "${DATA_DIR}"
    mkdir -p "${LOG_DIR}"
    touch "${LOG_DIR}/mysqld.log"

    chown -R mysql:mysql "${MYSQL_HOME}" 2>/dev/null || true
    chown -R mysql:mysql "${DATA_DIR}"   2>/dev/null || true
    chown -R mysql:mysql "${LOG_DIR}"    2>/dev/null || true

    print_info "目录结构就绪"
}

# ============================================================
# 5. 配置
# ============================================================
configure_env() {
    # 1. 写入 profile.d（仅对 bash login shell 生效）
    cat >/etc/profile.d/mysql.sh <<EOF
export PATH=${MYSQL_HOME}/bin:\$PATH
EOF
    print_info "已写入 /etc/profile.d/mysql.sh"

    # 2. 创建软链接到 /usr/local/bin，让命令立即可用（不依赖 PATH）
    print_info "创建软链接到 /usr/local/bin ..."
    mkdir -p /usr/local/bin
    for bin in "${MYSQL_HOME}"/bin/*; do
        local name
        name=$(basename "$bin")
        local link="/usr/local/bin/${name}"
        # 已存在的非软链接文件（如用户自己的脚本）跳过，不覆盖
        if [ -e "$link" ] && [ ! -L "$link" ]; then
            continue
        fi
        ln -sf "$bin" "$link" 2>/dev/null || true
    done
    print_info "软链接已创建，现在可直接使用 mysql / mysqldump 等命令"
}

generate_mycnf() {
    cat >/etc/my.cnf <<EOF
[client]
port=${MYSQL_PORT}
socket=${SOCKET_FILE}

[mysqld]
user=mysql
port=${MYSQL_PORT}

basedir=${MYSQL_HOME}
datadir=${DATA_DIR}

socket=${SOCKET_FILE}
pid-file=${PID_FILE}

log-error=${LOG_DIR}/mysqld.log

character-set-server=utf8mb4
collation-server=utf8mb4_general_ci

# 基础调优 (可根据内存调整)
innodb_buffer_pool_size=512M
max_connections=200
EOF
    print_info "/etc/my.cnf 已生成 (端口: ${MYSQL_PORT}, socket: ${SOCKET_FILE})"
}

# ============================================================
# 6. 初始化
# ============================================================
initialize_mysql() {
    if is_data_initialized; then
        print_skip "数据目录 ${DATA_DIR} 已初始化"
        return 0
    fi

    print_info "初始化 MySQL 数据目录..."
    "${MYSQL_HOME}"/bin/mysqld \
        --initialize \
        --user=mysql \
        --basedir="${MYSQL_HOME}" \
        --datadir="${DATA_DIR}" || die "MySQL 初始化失败，请检查 ${LOG_DIR}/mysqld.log"

    print_info "初始化完成"
}

# ============================================================
# 7. systemd
# ============================================================
create_systemd() {
    if is_service_created; then
        print_skip "systemd 服务已存在"
        systemctl daemon-reload
        return 0
    fi

    cat >/usr/lib/systemd/system/mysqld.service <<EOF
[Unit]
Description=MySQL Server ${MYSQL_VERSION} (port ${MYSQL_PORT})
After=network.target

[Service]
User=mysql
Group=mysql
ExecStart=${MYSQL_HOME}/bin/mysqld --defaults-file=/etc/my.cnf
LimitNOFILE=65535
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable mysqld &>/dev/null || true
    print_info "systemd 服务已创建并启用"
}

# ============================================================
# 8. 启动 & 改密码
# ============================================================
start_mysql() {
    if is_mysql_running; then
        print_skip "MySQL 已在运行 (端口 ${MYSQL_PORT})"
        systemctl status mysqld --no-pager 2>/dev/null || true
        return 0
    fi

    print_info "启动 MySQL..."
    systemctl start mysqld || die "MySQL 启动失败，请检查: journalctl -u mysqld"

    # 等它真正起来
    local retries=10
    while [ $retries -gt 0 ] && ! is_mysql_running; do
        sleep 1
        retries=$((retries - 1))
    done

    if is_mysql_running; then
        print_info "MySQL 启动成功 (端口 ${MYSQL_PORT})"
        systemctl status mysqld --no-pager 2>/dev/null || true
    else
        die "MySQL 启动后端口仍不可达，请检查: journalctl -u mysqld"
    fi
}

change_root_password() {
    [ -n "${MYSQL_ROOT_PASSWORD}" ] || return 0

    local tmp_pwd
    tmp_pwd=$(grep "temporary password" "${LOG_DIR}/mysqld.log" 2>/dev/null | awk '{print $NF}')

    if [ -z "${tmp_pwd}" ]; then
        print_warn "未找到临时密码，跳过密码修改"
        return 0
    fi

    print_info "修改 root 密码..."

    # 用 --connect-expired-password 允许过期密码登录后修改
    "${MYSQL_HOME}"/bin/mysql -u root -p"${tmp_pwd}" --connect-expired-password \
        -S "${SOCKET_FILE}" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';" 2>/dev/null

    if [ $? -eq 0 ]; then
        print_info "root 密码已修改: ${MYSQL_ROOT_PASSWORD}"
    else
        print_warn "自动修改密码失败，请手动执行:"
        echo "  ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourPassword';"
    fi
}

show_password() {
    echo
    print_info "========== MySQL 安装完成 =========="
    echo
    echo -e "  版本   : ${GREEN}${MYSQL_VERSION}${END}"
    echo -e "  端口   : ${GREEN}${MYSQL_PORT}${END}"
    echo -e "  安装目录: ${GREEN}${MYSQL_HOME}${END}"
    echo -e "  数据目录: ${GREEN}${DATA_DIR}${END}"
    echo -e "  日志   : ${LOG_DIR}/mysqld.log"
    echo

    local tmp_pwd_line
    tmp_pwd_line=$(grep "temporary password" "${LOG_DIR}/mysqld.log" 2>/dev/null)

    if [ -n "${MYSQL_ROOT_PASSWORD}" ]; then
        echo -e "  root 密码: ${GREEN}${MYSQL_ROOT_PASSWORD}${END} (已设置)"
    elif [ -n "${tmp_pwd_line}" ]; then
        echo -e "  ${RED}${tmp_pwd_line}${END}"
        echo
        echo "  登录: mysql -uroot -p -S ${SOCKET_FILE}"
        echo "  修改密码: ALTER USER 'root'@'localhost' IDENTIFIED BY 'YourPassword';"
    else
        echo "  登录: mysql -uroot -p -S ${SOCKET_FILE}"
        print_warn "未找到临时密码（可能此前已初始化过）"
    fi
    echo
}

# ============================================================
# 9. 卸载
# ============================================================
do_uninstall() {
    print_info "========== 开始卸载 MySQL =========="
    echo

    # 9.1 停服务
    if systemctl is-active --quiet mysqld 2>/dev/null; then
        print_info "停止 MySQL 服务..."
        systemctl stop mysqld || true
        sleep 2
    fi
    if systemctl is-enabled --quiet mysqld 2>/dev/null; then
        systemctl disable mysqld &>/dev/null || true
    fi

    # 9.2 删 systemd 文件
    rm -f /usr/lib/systemd/system/mysqld.service /etc/systemd/system/mysqld.service
    systemctl daemon-reload
    print_info "systemd 服务已移除"

    # 9.3 防火墙
    remove_firewall_rules

    # 9.4 SELinux
    remove_selinux_context

    # 9.5 删软链接
    print_info "清理 /usr/local/bin 中的 MySQL 软链接..."
    if [ -d "${MYSQL_HOME}/bin" ]; then
        for bin in "${MYSQL_HOME}"/bin/*; do
            name=$(basename "$bin")
            link="/usr/local/bin/${name}"
            if [ -L "$link" ]; then
                target=$(readlink "$link" 2>/dev/null)
                [ "$target" = "$bin" ] && rm -f "$link"
            fi
        done
    fi

    # 9.6 删安装目录
    if [ -d "${MYSQL_HOME}" ]; then
        rm -rf "${MYSQL_HOME}"
        print_info "已删除安装目录: ${MYSQL_HOME}"
    fi

    # 9.7 数据目录
    if [ "${PURGE:-false}" = "true" ]; then
        if [ -d "${DATA_DIR}" ]; then
            rm -rf "${DATA_DIR}"
            print_info "已删除数据目录: ${DATA_DIR}"
        fi
        rm -rf "${LOG_DIR}"
        rm -f /etc/my.cnf
        rm -f /etc/profile.d/mysql.sh
        print_info "已删除配置 & 日志"
    else
        print_warn "保留数据目录: ${DATA_DIR}"
        print_warn "保留日志目录: ${LOG_DIR}"
        print_warn "保留 /etc/my.cnf"
        echo
        echo "  如需彻底清除，请执行: $0 uninstall --purge"
    fi

    echo
    print_info "========== 卸载完成 =========="
}

# ============================================================
# 10. 状态查看
# ============================================================
do_status() {
    echo
    echo -e "  ${BLUE}========== MySQL 状态 ==========${END}"
    echo

    echo -e "  ${YELLOW}[二进制]${END}"
    if is_mysql_binary_installed; then
        echo -e "    状态   : ${GREEN}已安装${END}  → ${MYSQL_HOME}/bin/mysqld"
        echo    "    版本   : $("${MYSQL_HOME}"/bin/mysqld --version 2>/dev/null || echo '未知')"
    else
        echo -e "    状态   : ${RED}未安装${END}"
    fi

    echo
    echo -e "  ${YELLOW}[数据]${END}"
    if is_data_initialized; then
        echo -e "    状态   : ${GREEN}已初始化${END}  → ${DATA_DIR}"
        du -sh "${DATA_DIR}" 2>/dev/null | awk '{print "    大小   : "$1}'
    else
        echo -e "    状态   : ${RED}未初始化${END}"
    fi

    echo
    echo -e "  ${YELLOW}[服务]${END}"
    if is_mysql_running; then
        echo -e "    状态   : ${GREEN}运行中${END}  (端口 ${MYSQL_PORT})"
    else
        echo -e "    状态   : ${RED}未运行${END}"
    fi

    echo
    echo -e "  ${YELLOW}[防火墙]${END}"
    if command -v firewall-cmd &>/dev/null && firewall-cmd --list-ports 2>/dev/null | grep -q "${MYSQL_PORT}"; then
        echo -e "    firewalld: ${GREEN}${MYSQL_PORT}/tcp 已放行${END}"
    elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "${MYSQL_PORT}"; then
        echo -e "    ufw      : ${GREEN}${MYSQL_PORT}/tcp 已放行${END}"
    elif command -v iptables &>/dev/null && iptables -L INPUT -n 2>/dev/null | grep -q "dpt:${MYSQL_PORT}"; then
        echo -e "    iptables : ${GREEN}${MYSQL_PORT}/tcp 已放行${END}"
    else
        echo -e "    ${RED}端口 ${MYSQL_PORT} 可能未放行${END}"
    fi

    echo
    echo -e "  ${YELLOW}[SELinux]${END}"
    if command -v getenforce &>/dev/null; then
        echo "    模式   : $(getenforce 2>/dev/null)"
    else
        echo "    状态   : 未安装"
    fi

    echo
}

# ============================================================
# main
# ============================================================
main() {
    parse_args "$@"

    # --- status 模式不依赖 root，但部分命令可能受限 ---
    if [ "${ACTION}" = "status" ]; then
        do_status
        exit 0
    fi

    check_root
    detect_os

    # --- uninstall ---
    if [ "${ACTION}" = "uninstall" ]; then
        do_uninstall
        exit 0
    fi

    # ==================== install ====================

    # ---- Phase 0: 环境 ----
    install_base_tools
    install_mysql_dependencies
    handle_firewall
    handle_selinux

    # ---- Phase 1: 下载 ----
    download_mysql

    # ---- Phase 2: 用户 & 目录 ----
    create_mysql_user
    remove_old_mysql
    extract_mysql
    create_directory

    # ---- Phase 3: 配置 ----
    configure_env
    generate_mycnf

    # ---- Phase 4: 初始化 ----
    initialize_mysql

    # ---- Phase 5: systemd ----
    create_systemd

    # ---- Phase 6: 启动 ----
    start_mysql

    # ---- Phase 7: 密码 ----
    change_root_password

    # ---- Phase 8: 完成 ----
    show_password
}

main "$@"
