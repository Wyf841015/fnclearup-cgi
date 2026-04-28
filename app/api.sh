#!/bin/bash

# FnClearup API 处理脚本
# 版本: 0.2.0

# 读取 POST body
REQUEST_METHOD_POST() {
    if [ "$REQUEST_METHOD" = "POST" ]; then
        cat
    fi
}

# 解析 JSON 辅助函数
get_json_value() {
    local key="$1"
    local body="$2"
    # 简单 JSON 解析（不支持嵌套）
    echo "$body" | grep -o ""$key"[[:space:]]*:[[:space:]]*[^,}]*" | sed 's/.*:[[:space:]]*//' | tr -d '"' | tr -d "'"
}

# 日志
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> /tmp/fnclearup-api.log
}

# 动态发现 vol 目录
discover_vols() {
    local vols=()
    for vol in /mnt/vol*; do
        if [ -d "$vol" ]; then
            vols+=("$vol")
        fi
    done
    echo "${vols[@]}"
}

# 获取已安装应用列表
get_installed_apps() {
    appcenter-cli list 2>/dev/null | grep -E "^\|" | tail -n +3 | while read line; do
        # 解析格式: | appname | displayname |
        appname=$(echo "$line" | awk -F'|' '{print $2}' | tr -d ' ')
        display=$(echo "$line" | awk -F'|' '{print $3}' | tr -d ' ')
        if [ -n "$appname" ]; then
            echo "{"appname":"$appname","display_name":"$display"}"
        fi
    done
}

# 扫描孤立目录
do_scan() {
    local result='{"installed":[], "orphan":{}}'
    local installed='[]'
    local orphan='{}'
    
    # 获取已安装应用
    local apps=$(get_installed_apps)
    
    # 获取所有 vol
    local vols=$(discover_vols)
    
    # TODO: 实现完整扫描逻辑
    # 目前返回空结果
    
    echo "Content-Type: application/json"
    echo ""
    echo "{"installed":[], "orphan":{}, "success":true}"
}

# 删除目录
do_delete() {
    local body=$(REQUEST_METHOD_POST)
    local paths=$(echo "$body" | grep -o '"paths":\[[^]]*\]' | sed 's/"paths":\[//' | sed 's/\]$//' | tr -d '"' | tr -d ' ')
    local delete_users=$(echo "$body" | grep -o '"delete_users":[^,}]*' | sed 's/"delete_users"://')
    
    log "DELETE request: paths=$paths, delete_users=$delete_users"
    
    echo "Content-Type: application/json"
    echo ""
    echo "{"deleted":[], "failed":[], "total":0, "failures":0}"
}

# 获取版本
do_version() {
    echo "Content-Type: application/json"
    echo ""
    echo '{"version":"0.2.0"}'
}

# 路由
PATH_INFO="$1"
case "$PATH_INFO" in
    /api/scan)
        do_scan
        ;;
    /api/delete)
        do_delete
        ;;
    /api/version)
        do_version
        ;;
    *)
        echo "Status: 404 Not Found"
        echo "Content-Type: text/plain"
        echo ""
        echo "API endpoint not found"
        ;;
esac
