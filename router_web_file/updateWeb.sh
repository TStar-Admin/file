#!/bin/sh

# 传入的目标版本号，例如: sh update.sh 2025091801
TARGET_VERSION="$1"

if [ -z "$TARGET_VERSION" ]; then
    echo "❌ 错误: 请传入目标版本号，例如:"
    echo "   sh $0 2025091801"
    exit 1
fi

VERSION_FILE="/etc/frontend_version"
#DOWNLOAD_URL="http://mq.hirechat.net:8080/download/router_web_file/$TARGET_VERSION.tar.gz"
DOWNLOAD_URL="http://download.sharewifi.cc/download/router_web_file/$TARGET_VERSION.tar.gz"
#DOWNLOAD_URL="http://scontent-ph-1.nybl.fbcdn.net:8080/download/router_web_file/$TARGET_VERSION.tar.gz"
SAVE_DIR="/sharewifiupdate"
SAVE_PATH="$SAVE_DIR/web.tar.gz"

router_mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
router_mac_hex=$(echo "$router_mac" | tr -d ':\r\n' | tr 'a-f' 'A-F')
router_mac_bigint=$(printf "%d" "0x$router_mac_hex" 2>/dev/null)
if [ -z "$router_mac_bigint" ]; then
    router_mac_bigint=0
fi

router_update_progress() {
    local desc="$1"
    curl -s -X POST "http://app.sharewifi.cc/api/routerUpdateProgress" \
        --data-urlencode "mac=$router_mac_bigint" \
        --data-urlencode "desc=$desc" >/dev/null 2>&1
    echo "$(date '+%F %T') - routerUpdateProgress: mac=$router_mac_bigint, desc=$desc"
}



# 获取当前版本
# if [ -f "$VERSION_FILE" ]; then
#     CURRENT_VERSION=$(cat "$VERSION_FILE")
# else
#     CURRENT_VERSION=0
# fi
CURRENT_VERSION=0
echo "当前版本: $CURRENT_VERSION"
echo "目标版本: $TARGET_VERSION"

# 比较版本号
if [ "$CURRENT_VERSION" -lt "$TARGET_VERSION" ]; then
     mkdir -p "$SAVE_DIR" >/dev/null 2>&1
     rm -rf /etc/frontend_version 
     rm -rf /sharewifiupdate/web.tar.gz
    echo "开始下载更新文件..."
    router_update_progress "Downloading started"
    total_size=$(curl -sIL "$DOWNLOAD_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tail -n 1 | tr -d '\r')
    log_file="/tmp/wget_web_${TARGET_VERSION}.log"
    rm -f "$log_file"
    wget -c --tries=9999 --waitretry=10 -O "$SAVE_PATH" "$DOWNLOAD_URL" >"$log_file" 2>&1 &
    wget_pid=$!
    last_step=0
    while kill -0 "$wget_pid" >/dev/null 2>&1; do
        percent=""
        if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null && [ -f "$SAVE_PATH" ]; then
            current_size=$(wc -c < "$SAVE_PATH" 2>/dev/null | tr -d ' ')
            if [ -n "$current_size" ] && [ "$current_size" -ge 0 ] 2>/dev/null; then
                percent=$((current_size * 100 / total_size))
            fi
        fi
        if [ -z "$percent" ] && [ -f "$log_file" ]; then
            percent=$(tail -n 30 "$log_file" 2>/dev/null | sed -n 's/.* \([0-9]\{1,3\}\)%.*/\1/p' | tail -n 1)
        fi
        if [ -n "$percent" ] && [ "$percent" -ge 0 ] 2>/dev/null; then
            if [ "$percent" -gt 100 ] 2>/dev/null; then
                percent=100
            fi
            step=$((percent / 10 * 10))
            if [ "$step" -ge $((last_step + 10)) ]; then
                last_step="$step"
                router_update_progress "Downloading: ${step}%"
            fi
        fi
        sleep 1
    done
    wait "$wget_pid"
    wget_status=$?
    if [ $wget_status -eq 0 ]; then
        echo "✅ 下载完成: $SAVE_PATH"
        router_update_progress "Download completed"
        router_update_progress "Installing started"
        /etc/init.d/unpack_web start
        sh /sharewifiupdate/update_web_ver.sh $TARGET_VERSION
        router_update_progress "Install completed"
    else
        echo "❌ 下载失败"
    fi
else
    echo "版本已是最新，无需下载"
fi
