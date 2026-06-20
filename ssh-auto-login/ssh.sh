#!/bin/bash

HOST_FILE="hosts.txt"

SUCCESS_LOG="./ssh_success.log"
ERROR_LOG="./ssh_error.log"

# 每次执行清空旧日志
> "$SUCCESS_LOG"
> "$ERROR_LOG"

GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
END="\033[0m"

SUCCESS=0
FAILED=0
OFFLINE=0

read -p "Username: " USER
read -s -p "Password: " PASS
echo

# 检查 SSH 密钥
if [ ! -f ~/.ssh/id_ed25519 ]; then
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
fi

while read HOST
do
    # 跳过空行
    [ -z "$HOST" ] && continue

    # 跳过注释
    [[ "$HOST" =~ ^# ]] && continue

    echo -e "${YELLOW}========== $HOST ==========${END}"

    # 检测主机是否存活
    if ! ping -c 2 -W 2 "$HOST" &>/dev/null; then
        echo -e "${RED}[OFFLINE]${END} $HOST"

        {
            echo "$(date '+%F %T')"
            echo "$HOST OFFLINE"
            echo
        } >> "$ERROR_LOG"

        ((OFFLINE++))
        continue
    fi

expect <<EOF
set timeout 20

spawn ssh-copy-id -i /root/.ssh/id_ed25519.pub ${USER}@${HOST}

expect {
    -re ".*yes/no.*" {
        send "yes\r"
        exp_continue
    }

    -re ".*password:.*" {
        send "$PASS\r"
        exp_continue
    }

    eof
}
EOF

    if [ $? -eq 0 ]; then

        echo -e "${GREEN}[SUCCESS]${END} $HOST"

        {
            echo "$(date '+%F %T')"
            echo "$HOST SUCCESS"
            echo
        } >> "$SUCCESS_LOG"

        ((SUCCESS++))

    else

        echo -e "${RED}[FAILED]${END} $HOST"

        {
            echo "$(date '+%F %T')"
            echo "$HOST FAILED"
            echo
        } >> "$ERROR_LOG"

        ((FAILED++))

    fi

done < "$HOST_FILE"
echo
echo "=============================="
echo -e "${GREEN}Success : $SUCCESS${END}"
echo -e "${RED}Failed  : $FAILED${END}"
echo -e "${YELLOW}Offline : $OFFLINE${END}"
echo "=============================="

echo "Success Log : $SUCCESS_LOG"
echo "Error Log   : $ERROR_LOG"
