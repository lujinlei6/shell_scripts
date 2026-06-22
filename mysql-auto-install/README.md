# MySQL Auto Install Script

> MySQL 通用二进制包一键安装脚本，支持 **幂等安装 / 参数化配置 / 防火墙 & SELinux 自动处理 / 完整卸载**。

---

## 目录

- [快速开始](#快速开始)
- [命令参考](#命令参考)
- [参数说明](#参数说明)
- [操作模式](#操作模式)
- [架构设计](#架构设计)
- [执行流程](#执行流程)
- [幂等性设计](#幂等性设计)
- [目录规划](#目录规划)
- [兼容性](#兼容性)
- [常见问题](#常见问题)

---

## 快速开始

```bash
# 1. 默认安装（MySQL 8.0.41, 端口 3306）
bash mysql-auto-install.sh

# 2. 装完直接登录
mysql -uroot -p
# 输入日志中的临时密码: grep 'temporary password' /var/log/mysql/mysqld.log
```

---

## 命令参考

### 安装

```bash
# 默认参数
bash mysql-auto-install.sh

# 自定义版本 + 端口（多实例）
bash mysql-auto-install.sh -v 5.7.44 -p 3307

# 自定义所有路径
bash mysql-auto-install.sh \
    -v 8.0.41 \
    -p 3306 \
    -b /opt/mysql \
    -d /data/mysql3306 \
    -l /var/log/mysql3306 \
    --password 'MyStrongPass@123'
```

### 查看状态

```bash
bash mysql-auto-install.sh status
```

输出示例：

```
========== MySQL 状态 ==========

[二进制]
  状态   : 已安装  → /usr/local/mysql/bin/mysqld
  版本   : Ver 8.0.41 for Linux on x86_64

[数据]
  状态   : 已初始化  → /data/mysql
  大小   : 156M

[服务]
  状态   : 运行中  (端口 3306)

[防火墙]
  firewalld: 3306/tcp 已放行

[SELinux]
  模式   : Enforcing
```

### 卸载

```bash
# 保留数据和配置（可重新安装恢复）
bash mysql-auto-install.sh uninstall

# 彻底清除（含数据、配置、日志）
bash mysql-auto-install.sh uninstall --purge
```

---

## 参数说明

| 参数 | 简写 | 默认值 | 说明 |
|------|------|--------|------|
| `--version` | `-v` | `8.0.41` | MySQL 版本（支持 5.7.x / 8.x） |
| `--port` | `-p` | `3306` | MySQL 监听端口 |
| `--basedir` | `-b` | `/usr/local` | 安装父目录（实际路径 `$basedir/mysql`） |
| `--datadir` | `-d` | `/data/mysql` | 数据存储目录 |
| `--logdir` | `-l` | `/var/log/mysql` | 日志目录 |
| `--password` | — | 空 | 设定 root 密码（空则只显示临时密码） |
| `--help` | `-h` | — | 显示帮助 |

---

## 操作模式

```
                    ┌─────────────┐
                    │  脚本入口    │
                    └──────┬──────┘
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌──────────┐    ┌──────────┐    ┌──────────┐
    │ install  │    │uninstall │    │  status  │
    │ (默认)   │    │          │    │          │
    └────┬─────┘    └────┬─────┘    └────┬─────┘
         │          ┌────┴────┐          │
         │          ▼         ▼          │
         │    保留数据    彻底清除        │
         │    (默认)    (--purge)        │
         │                               │
         ▼                               ▼
   幂等安装                          只读查询
   安全可重跑                       无需 root
```

---

## 架构设计

### 整体分层

```
┌──────────────────────────────────────────────────────┐
│                    main() 主控流程                     │
│                                                      │
│  parse_args → check → 按 ACTION 分发                  │
└──────────────────────────────────────────────────────┘
         │                    │                    │
    install              uninstall              status
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Phase 0  环境   │  │  停止服务        │  │  检查二进制      │
│  Phase 1  下载   │  │  删除 systemd    │  │  检查数据        │
│  Phase 2  解压   │  │  清理防火墙      │  │  检查服务        │
│  Phase 3  配置   │  │  清理 SELinux    │  │  检查防火墙      │
│  Phase 4  初始化 │  │  清理软链接      │  │  检查 SELinux    │
│  Phase 5  服务   │  │  删除文件        │  └─────────────────┘
│  Phase 6  启动   │  └─────────────────┘
│  Phase 7  密码   │
│  Phase 8  输出   │
└─────────────────┘
```

### 函数依赖图

```
main
├── parse_args          # 参数解析 → 设置全局变量
├── check_root          # 权限检查
├── detect_os           # OS 识别 → OS_ID / OS_VERSION
│
├── [install 分支]
│   ├── install_base_tools      # 基础工具
│   │   └── safe_install_pkgs   # 逐包容错安装
│   ├── install_mysql_dependencies  # MySQL 运行时依赖
│   ├── handle_firewall         # 防火墙
│   │   ├── firewalld
│   │   ├── iptables
│   │   └── ufw
│   ├── handle_selinux          # SELinux
│   │   ├── semanage fcontext   # 文件标签
│   │   ├── semanage port       # 端口放行
│   │   └── setsebool           # 布尔开关
│   ├── download_mysql          # 下载 tarball
│   ├── create_mysql_user       # 创建 mysql 用户
│   ├── remove_old_mysql        # 清理旧安装
│   ├── extract_mysql           # 解压
│   ├── create_directory        # 创建目录结构
│   ├── configure_env           # PATH + 软链接
│   ├── generate_mycnf          # 生成 /etc/my.cnf
│   ├── initialize_mysql        # mysqld --initialize
│   ├── create_systemd          # systemd 服务文件
│   ├── start_mysql             # 启动 + 等待就绪
│   ├── change_root_password    # ALTER USER
│   └── show_password           # 输出安装摘要
│
├── [uninstall 分支]
│   ├── systemctl stop/disable
│   ├── remove_firewall_rules
│   ├── remove_selinux_context
│   └── rm -rf (按 --purge 决定范围)
│
└── [status 分支]
    ├── is_mysql_binary_installed
    ├── is_data_initialized
    └── is_mysql_running
```

### 幂等性守卫

每个关键函数在执行前都会检查对应**守卫函数**，已完成的步骤直接跳过：

```
download_mysql ────── is_mysql_binary_installed() ── 检查 $MYSQL_HOME/bin/mysqld
extract_mysql ────── is_mysql_binary_installed() ── 同上
initialize_mysql ──── is_data_initialized() ──────── 检查 ibdata1 或 mysql/ 目录
create_systemd ────── is_service_created() ───────── 检查 .service 文件
start_mysql ───────── is_mysql_running() ─────────── pid 存活 or 端口监听
create_mysql_user ─── id mysql ───────────────────── 检查 passwd 中的用户
```

---

## 执行流程

### 安装流程详解

```
开始
 │
 ├─ [Phase 0] 环境准备
 │   ├─ 1. 检测 OS（/etc/os-release）
 │   ├─ 2. 安装 wget/tar/xz/vim/curl/less 等基础工具
 │   ├─ 3. 安装 MySQL 运行时依赖 (libaio, numactl)
 │   ├─ 4. 配置防火墙规则（firewalld / iptables / ufw）
 │   └─ 5. 配置 SELinux 上下文（标签 + 端口 + 布尔值）
 │
 ├─ [Phase 1] 下载
 │   └─ wget -c 断点续传下载 MySQL tarball
 │
 ├─ [Phase 2] 解压 & 目录
 │   ├─ 创建 mysql 系统用户
 │   ├─ 删除旧版本（如果存在）
 │   ├─ tar -xf 解压 → /usr/local/mysql
 │   └─ 创建数据/日志目录 + chown
 │
 ├─ [Phase 3] 配置
 │   ├─ /etc/profile.d/mysql.sh ← PATH
 │   ├─ /usr/local/bin/* ← 软链接（立即可用）
 │   └─ /etc/my.cnf ← MySQL 配置
 │
 ├─ [Phase 4] 初始化
 │   └─ mysqld --initialize --user=mysql
 │
 ├─ [Phase 5] 注册服务
 │   └─ /usr/lib/systemd/system/mysqld.service
 │
 ├─ [Phase 6] 启动
 │   ├─ systemctl start mysqld
 │   └─ 轮询等待端口可达（最多 10 秒）
 │
 └─ [Phase 7] 输出
     ├─ 展示临时密码
     └─ 若指定 --password 则自动 ALTER USER
```

### 卸载流程详解

```
开始
 │
 ├─ 1. systemctl stop mysqld（如果运行中）
 ├─ 2. systemctl disable mysqld
 ├─ 3. 删除 /usr/lib/systemd/system/mysqld.service
 ├─ 4. 清理防火墙规则（firewalld/iptables/ufw）
 ├─ 5. 清理 SELinux 上下文（semanage fcontext -d）
 ├─ 6. 清理 /usr/local/bin 中的软链接
 ├─ 7. rm -rf MYSQL_HOME
 └─ 8. 根据 --purge 决定:
     ├─ 无 --purge: 保留 DATA_DIR / LOG_DIR / /etc/my.cnf
     └─ 有 --purge: 全部删除
```

---

## 目录规划

```
安装后文件布局:
─────────────────────────────────────────────────────
/usr/local/mysql/           ← MYSQL_HOME（安装目录）
  ├── bin/
  │   ├── mysqld             → MySQL 服务端
  │   ├── mysql              → 命令行客户端
  │   ├── mysqldump          → 备份工具
  │   └── ...                → 其他工具
  ├── lib/                   → 私有库
  ├── share/                 → 字符集/错误信息
  └── ...

/usr/local/bin/              ← 软链接（PATH 内，立即可用）
  ├── mysql      → /usr/local/mysql/bin/mysql
  ├── mysqldump  → /usr/local/mysql/bin/mysqldump
  └── ...

/data/mysql/                 ← DATA_DIR（数据目录）
  ├── ibdata1                → InnoDB 系统表空间
  ├── mysql/                 → 系统库 (mysql.user 等)
  ├── mysql.pid              → 进程 ID 文件
  └── ...

/var/log/mysql/
  └── mysqld.log              ← 错误日志（含临时密码）

/etc/my.cnf                   ← MySQL 配置（[client] + [mysqld]）
/etc/profile.d/mysql.sh       ← PATH 环境变量
/usr/lib/systemd/system/
  └── mysqld.service          ← systemd 服务定义
─────────────────────────────────────────────────────
```

---

## 幂等性设计

脚本的第二大核心特性（仅次于安装本身）是**安全可重跑**。

### 设计原则

| 原则 | 说明 |
|------|------|
| **检测先于执行** | 每步操作前都要问"这一步做过了没有？" |
| **数据只增不改** | 已初始化的数据目录绝不触碰 |
| **配置可覆盖** | `/etc/my.cnf` 和 systemd 文件每次都更新（不影响数据） |
| **失败可恢复** | 任一步骤失败，修正参数后重跑即可继续 |

### 实现方式

```bash
# 每个函数都遵循此模式:
some_step() {
    # 守卫：已完成就跳过
    if already_done_check; then
        print_skip "这一步已经做过了"
        return 0
    fi

    # 执行
    do_the_actual_work || die "失败退出"

    print_info "完成"
}
```

### 重跑场景

```
第一次运行:                       第二次运行:
  [INFO] 安装基础工具...            [SKIP] 基础工具就绪
  [INFO] 下载 MySQL...              [SKIP] 二进制已安装
  [INFO] 解压...                    [SKIP] 已解压
  [INFO] 初始化 MySQL...            [SKIP] 数据目录已初始化
  [INFO] MySQL 启动成功             [SKIP] MySQL 已在运行
  ...
```

---

## 兼容性

### 操作系统

| 发行版 | 版本 | 包管理器 | 状态 |
|--------|------|----------|------|
| Rocky Linux | 8 / 9 / 10 | dnf | ✅ |
| CentOS | 7 / 8 | yum / dnf | ✅ |
| RHEL | 7 / 8 / 9 | yum / dnf | ✅ |
| AlmaLinux | 8 / 9 | dnf | ✅ |
| Fedora | 36+ | dnf | ✅ |
| Ubuntu | 20.04 / 22.04 / 24.04 | apt | ✅ |
| Debian | 11 / 12 | apt | ✅ |

### MySQL 版本

| 版本 | 架构 | 格式 |
|------|------|------|
| 8.0.x | x86_64, glibc 2.28 | `.tar.xz` |
| 5.7.x | x86_64, glibc 2.12 | `.tar.gz` |

### 防火墙

| 防火墙 | 自动添加 | 自动删除（卸载时） |
|--------|----------|-------------------|
| firewalld | ✅ | ✅ |
| iptables | ✅ | ✅ |
| ufw | ✅ | ✅ |

### SELinux

| 模式 | 处理方式 |
|------|----------|
| Enforcing | 打标签 + 放行端口 + 开布尔值 |
| Permissive | 同样打标签（预防后续切回 Enforcing） |
| Disabled | 跳过 |

---

## 常见问题

### Q: 脚本跑一半断了怎么办？

直接重跑。幂等设计确保已完成步骤会自动跳过，从断点继续。

### Q: mysql 命令找不到？

脚本已创建软链接到 `/usr/local/bin/`，该目录默认在 `$PATH` 中。如果仍然找不到：

```bash
# 检查软链接
ls -la /usr/local/bin/mysql

# 或手动 source
source /etc/profile.d/mysql.sh
```

### Q: 连接报 `Can't connect through socket`？

```bash
# 客户端默认读 /etc/my.cnf 的 [client] 段获取 socket 路径。
# 检查配置是否含 [client] 段:
head -5 /etc/my.cnf

# 如果没有，重跑脚本自动生成，或手动指定:
mysql -uroot -p -S /tmp/mysql_3306.sock
```

### Q: 忘记 root 密码？

```bash
# 1. 停服
systemctl stop mysqld

# 2. 跳过授权表启动
mysqld --skip-grant-tables --user=mysql &
sleep 3

# 3. 无密码登录并重置
mysql -uroot
ALTER USER 'root'@'localhost' IDENTIFIED BY 'NewPass@123';
FLUSH PRIVILEGES;

# 4. 重启
kill %1
systemctl start mysqld
```

### Q: 端口被占用？

```bash
# 查看占用
ss -tlnp | grep 3306

# 换个端口重装
bash mysql-auto-install.sh -p 3307 --datadir /data/mysql3307
```

### Q: 安装多实例？

```bash
# 实例1: 默认 3306
bash mysql-auto-install.sh

# 实例2: 端口 3307，数据目录独立
bash mysql-auto-install.sh -p 3307 -d /data/mysql3307 -l /var/log/mysql3307

# 管理多实例
systemctl status mysqld        # instance 1（注意：第二个会覆盖 service 文件）
```

> ⚠️ 当前版本的 systemd 服务文件名为固定的 `mysqld.service`。多实例场景建议在第一个实例安装后，手动将 service 文件复制为 `mysqld@.service` 模板。后续版本会原生支持多实例 systemd。

### Q: 如何静默安装（非交互）？

```bash
# 指定 --password 跳过手动改密码环节
bash mysql-auto-install.sh --password 'Root@123456'
```

### Q: 下载慢 / 网络不通？

```bash
# 手动下载 tarball 放到脚本同目录，脚本检测到已有文件会跳过下载
# 文件名必须匹配: mysql-8.0.41-linux-glibc2.28-x86_64.tar.xz
```
