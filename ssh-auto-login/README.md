# SSH Auto Login

> 一个基于 **Shell + Expect** 实现的 SSH 批量免密登录工具。

## ✨ 功能特点

* ✅ 批量读取主机列表
* ✅ 自动生成 SSH ED25519 密钥（首次运行）
* ✅ 使用 Expect 自动输入密码
* ✅ 自动处理首次连接 `yes/no`
* ✅ 检测目标主机是否在线
* ✅ 跳过空行及注释
* ✅ 彩色输出执行结果
* ✅ 自动记录成功、失败日志
* ✅ 执行完成后输出统计信息

---

# 📂 项目结构

```text
ssh-auto-login/
├── ssh.sh── hosts.txt 
├── ssh_success.log
├── ssh_error.log
└── README.md
```

---

# 💻 环境要求

* Linux
* Bash
* OpenSSH
* Expect

## 安装 Expect

### CentOS / Rocky / AlmaLinux

```bash
yum install -y expect
```

### Ubuntu / Debian

```bash
apt install -y expect
```

---

# 📄 hosts.txt

每行填写一个 IP 地址。

支持空行。

支持注释。

例如：

```text
# Web Server
192.168.53.7
192.168.53.8

# Database
192.168.53.10
```

---

# 🚀 使用方法

赋予执行权限：

```bash
chmod +x ssh.sh

```

执行脚本：

```bash
./ssh.sh
```

程序会提示输入：

```text
Username: root
Password:
```

之后脚本会自动完成 SSH 公钥分发。

---

# 📷 运行效果

```text
Username: root
Password:

========== 192.168.53.7 ==========
[SUCCESS] 192.168.53.7

========== 192.168.53.8 ==========
[FAILED] 192.168.53.8

========== 192.168.53.9 ==========
[OFFLINE] 192.168.53.9

==============================
Success : 1
Failed  : 1
Offline : 1
==============================
```

---

# 📝 日志说明

## ssh_success.log

```text
2026-06-20 14:20:11
192.168.53.7 SUCCESS
```

## ssh_error.log

```text
2026-06-20 14:20:15
192.168.53.8 FAILED

2026-06-20 14:21:02
192.168.53.9 OFFLINE
```

---

# ⚙️ 工作流程

```text
           hosts.txt
                │
                ▼
        读取主机 IP 地址
                │
                ▼
      检测目标主机是否在线
          │            │
          │            │
        在线          离线
          │            │
          ▼            ▼
    ssh-copy-id      写入错误日志
          │
          ▼
 Expect 自动输入密码
          │
          ▼
     配置 SSH 公钥
          │
          ▼
   写入成功/失败日志
          │
          ▼
      输出执行统计
```

---

# 🛠️ 技术栈

* Shell Script
* Bash
* Expect
* OpenSSH
* ssh-copy-id

---

# 📌 后续计划

* [ ] 支持自定义 SSH 端口
* [ ] 支持命令行参数
* [ ] 支持并发配置
* [ ] 支持从 CSV/INI 文件读取主机
* [ ] 自动验证免密登录是否成功
* [ ] 输出 HTML 执行报告
* [ ] 支持日志轮转

---

# 📄 License

MIT License

