
#!/bin/sh

# wget -q -O - "https://crmeb.sharewifi.cc/download/update.sh" |sh
#wget -O - https://download.sharewifi.cc/download/updateDNS/test_server_ph.sh | sh

#sleep 5

# 升级历史记录文件
UPDATE_LOG_FILE="/sharewifiupdate/upgrade.log"
UPDATE_SUCCESS=0
router_mac=$(cat /sys/class/net/br-lan/address 2>/dev/null)
router_mac_hex=$(echo "$router_mac" | tr -d ':\r\n' | tr 'a-f' 'A-F')
router_mac_bigint=$(printf "%d" "0x$router_mac_hex" 2>/dev/null)
if [ -z "$router_mac_bigint" ]; then
    router_mac_bigint=0
fi
# 封装回调函数
send_callback() {
    local event="$1"
    local command="$2"
    curl -s -X POST "http://app.sharewifi.cc/api/routerCheckInfoCallback" \
        -H "Content-Type: application/json" \
        -d "{\"mac\":\"$router_mac\",\"event\":\"$event\",\"command\":\"$command\",\"type\":\"3\",\"source\":\"1\"}" >/dev/null 2>&1
    echo "$(date '+%F %T') - callback sent: event=$event, command=$command"
}

router_update_progress() {
    local desc="$1"
    curl -s -X POST "http://app.sharewifi.cc/api/routerUpdateProgress" \
        --data-urlencode "mac=$router_mac_bigint" \
        --data-urlencode "desc=$desc" >/dev/null 2>&1
    echo "$(date '+%F %T') - routerUpdateProgress: mac=$router_mac_bigint, desc=$desc"
}

# 模块化函数：检查文件夹是否存在并下载文件
sharewifi_update() {
     
    # 参数
    VERSION=$1   
    EXTRACT_DIR="/tmp/sharewifiupdate/download/$VERSION"        # 解压目录
    FILE_URL="$2"                          # 下载链接
    TEMP_FILE="/tmp/sharewifi_update_$VERSION.tar.gz"  # 临时保存下载的文件路径
    FORCE=${3:-"0"}
    FRONTEND_VERSION='2026070202'   
    if [ $FORCE -eq 1 ]; then
        echo "Skip version check..."
    else
        check_version_upgraded "$VERSION"
        # 根据返回值进行后续操作
        if [ $? -eq 1 ]; then
            echo "Proceeding with upgrade tasks..."
        else
            return 1
        fi
    fi
        
    rm -f $TEMP_FILE
    rm -rf /tmp/sharewifiupdate/download
    rm -f /etc/config/wifidogx
    rm -r /www/sharewifi
    #rm  /etc/crontabs/root
    
    echo "Downloading file from $FILE_URL..."
    send_callback "开始下载文件" "$FILE_URL"
    total_size=$(curl -sIL "$FILE_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tail -n 1 | tr -d '\r')
    last_step=0
    if [ -n "$total_size" ] && [ "$total_size" -gt 0 ] 2>/dev/null; then
        rm -f "/tmp/wget_${VERSION}.log"
        wget -c -t 9999 "$FILE_URL" -O "$TEMP_FILE" >"/tmp/wget_${VERSION}.log" 2>&1 &
        wget_pid=$!
        while kill -0 "$wget_pid" >/dev/null 2>&1; do
            current_size=0
            if [ -f "$TEMP_FILE" ]; then
                current_size=$(wc -c < "$TEMP_FILE" 2>/dev/null | tr -d ' ')
            fi
            if [ -n "$current_size" ] && [ "$current_size" -gt 0 ] 2>/dev/null; then
                percent=$((current_size * 100 / total_size))
                step=$((percent / 10 * 10))
                if [ "$step" -ge 10 ] && [ "$step" -le 90 ] && [ "$step" -gt "$last_step" ]; then
                    last_step="$step"
                    router_update_progress "Downloading: ${step}%"
                fi
            fi
            sleep 2
        done
        wait "$wget_pid"
        wget_status=$?
    else
        wget -c -t 9999 "$FILE_URL" -O "$TEMP_FILE"
        wget_status=$?
    fi
    
    # 检查下载是否成功
    if [ $wget_status -eq 0 ]; then
        # SHA256校验
        SHA256_URL="${FILE_URL}.sha256"
        SHA256_FILE="$TEMP_FILE.sha256"
        echo "Downloading SHA256 checksum from $SHA256_URL..."
        wget -q "$SHA256_URL" -O "$SHA256_FILE" 2>/dev/null
        verify_checksum() {
            if [ -f "$SHA256_FILE" ]; then
                expected=$(awk '{print $1}' "$SHA256_FILE" | tr -d '\r\n ')
                actual=$(sha256sum "$TEMP_FILE" 2>/dev/null | awk '{print $1}')
                echo "expected: $expected, actual: $actual"
                if [ -n "$expected" ] && [ "$expected" = "$actual" ]; then
                    return 0
                fi
            fi
            return 1
        }
        if verify_checksum; then
            echo "SHA256 checksum verified successfully."
        else
            echo "SHA256 verification failed. Retrying download..."
            send_callback "SHA256 verification failed, retrying" "$FILE_URL"
            rm -f "$TEMP_FILE" "$SHA256_FILE"
            wget -c -t 9999 "$FILE_URL" -O "$TEMP_FILE"
            wget_status=$?
            if [ $wget_status -eq 0 ]; then
                wget -q "$SHA256_URL" -O "$SHA256_FILE" 2>/dev/null
                if verify_checksum; then
                    echo "SHA256 checksum verified after retry."
                else
                    echo "SHA256 verification failed after retry. Aborting."
                    send_callback "SHA256 verification failed after retry" "$FILE_URL"
                    rm -f "$TEMP_FILE" "$SHA256_FILE"
                    exit 1
                fi
            else
                echo "Retry download failed."
                send_callback "Retry download failed" "$FILE_URL"
                rm -f "$TEMP_FILE" "$SHA256_FILE"
                exit 1
            fi
        fi
        rm -f "$SHA256_FILE"
        echo "Download completed successfully."
        echo "File saved as: $TEMP_FILE"
        router_update_progress "Download completed"
        router_update_progress "Installing started"
        send_callback "Download completed successfully" "$FILE_URL"
        #rm -r /sharewifiupdate/download
        #  保存一份到 /etc 目录 修复路由器时使用
        cp "$TEMP_FILE" "/etc/sharewifi_fix.tar.gz"
        # 解压文件到指定目录
        echo "Extracting file to $EXTRACT_DIR..."
        
        mkdir -p $EXTRACT_DIR
        tar -xzf "$TEMP_FILE" -C "$EXTRACT_DIR"
        send_callback "解压文件到" "$EXTRACT_DIR"
        # 检查解压是否成功
        if [ $? -eq 0 ]; then
            rm -f $TEMP_FILE
            echo "Extraction completed successfully."
            send_callback "Extraction completed successfully" ""
        else
            echo "Failed to extract the file."
            send_callback "Failed to extract the file" ""
            exit 1
        fi
        
        script_path="$EXTRACT_DIR/scripts/pre-execution.sh"
        
        # 预执行脚本
        if [ -f "$script_path" ]; then
            echo "proceeding with pre-upgrade script."
            chmod +x $script_path
            "$script_path"
        fi
           
        # 移动文件     
        cp -r $EXTRACT_DIR/files/* /     
        
        # 检查移动是否成功
        if [ $? -eq 0 ]; then
            echo "Copy file successfully."
            send_callback "Copy file successfully" ""
            script_path="$EXTRACT_DIR/scripts/post-execution.sh"
            # 判断web版本。决定是否要下载最新的web包
            #sh /sharewifiupdate/updateWeb.sh $FRONTEND_VERSION
            #send_callback "download web file" ""
            # 后执行脚本
            if [ -f "$script_path" ]; then
                echo "proceeding with post-upgrade script."
                send_callback "proceeding with post-upgrade script" ""
                chmod +x $script_path
                "$script_path"
            fi
            sleep 3
            cp -r $EXTRACT_DIR/files/* /     
            # 获取当前日期和时间
            CURRENT_DATE=$(date '+%Y-%m-%d %H:%M:%S')
            echo "version $VERSION upgrade successfully."
            echo "[$CURRENT_DATE] version $VERSION SUCCESS " >> $UPDATE_LOG_FILE
            
            UPDATE_SUCCESS=1
            echo "On pause，waiting system loading"
            sleep 5
            MAC_ADDRESS=$(cat /sys/class/net/eth0/address)
            
            curl "http://download.sharewifi.cc/api/updateShVer?mac=$MAC_ADDRESS&ver=$VERSION"
            send_callback "update router version" ""
            cp -r $EXTRACT_DIR/files/* /     
            rm -r $EXTRACT_DIR
            sh /sharewifiupdate/update_ver.sh $VERSION
            #sh /sharewifiupdate/update_web_ver.sh $FRONTEND_VERSION
            router_update_progress "Install completed"
        else
            echo "Failed to move the file."
            send_callback "Failed to move the file" ""
            exit 1
        fi
        
    else
        echo "Failed to download the file."
        send_callback "Failed to download the file" ""
        exit 1
    fi
}

# 函数：判断版本号是否已升级成功
check_version_upgraded() {
    local version=$1

    # 在日志文件中查找版本号
    if grep -q "version $version SUCCESS" "$UPDATE_LOG_FILE"; then
        echo "Version $version has been successfully upgraded."
        send_callback "Version $version has been successfully upgraded" ""
        return 0
    else
        echo "Version $version has not been upgraded yet."
        send_callback "Version $version has not been upgraded yet." ""
        return 1
    fi
}

#1 强制升级
#0 或者不带参数 版本号变化才升级
VERSION="$1"

#URL="http://mq.hirechat.net:8080/download/${VERSION}.tar.gz"
URL="https://raw.githubusercontent.com/TStar-Admin/file/refs/heads/main/${VERSION}.tar.gz"
FORCE=1  # 如需强制升级可改成 1，或再加逻辑接参数控制
send_callback "script run" ""
sharewifi_update "$VERSION" "$URL" "$FORCE"
