#!/bin/bash

# FnClearup CGI 入口脚本
# 版本: 0.2.0
# 描述: 处理 API 请求和静态文件服务

# 静态文件根目录
BASE_PATH="/var/apps/App.Native.FnClearup/target/ui/www"

# API 脚本
API_SH="/var/apps/App.Native.FnClearup/target/api.sh"

# 解析 REQUEST_URI 获取路径
URI_NO_QUERY="${REQUEST_URI%%\?*}"
REL_PATH="/"

case "$URI_NO_QUERY" in
    *index.cgi*)
        REL_PATH="${URI_NO_QUERY#*index.cgi}"
        ;;
esac

# 默认首页
if [ -z "$REL_PATH" ] || [ "$REL_PATH" = "/" ]; then
    REL_PATH="/index.html"
fi

# API 路径处理
if [[ "$REL_PATH" == /api/* ]]; then
    if [ -x "$API_SH" ]; then
        exec "$API_SH"
    else
        echo "Status: 500 Internal Server Error"
        echo "Content-Type: text/plain; charset=utf-8"
        echo ""
        echo "API script not found or not executable"
        exit 0
    fi
fi

# 静态文件
TARGET_FILE="${BASE_PATH}${REL_PATH}"

# 防御：禁止 .. 越级访问
if echo "$TARGET_FILE" | grep -q '\.\.'; then
    echo "Status: 400 Bad Request"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "Bad Request"
    exit 0
fi

# 文件不存在
if [ ! -f "$TARGET_FILE" ]; then
    echo "Status: 404 Not Found"
    echo "Content-Type: text/plain; charset=utf-8"
    echo ""
    echo "404 Not Found: ${REL_PATH}"
    exit 0
fi

# 根据扩展名判断 Content-Type
ext="${TARGET_FILE##*.}"
case "$ext" in
    html|htm)
        mime="text/html; charset=utf-8"
        ;;
    css)
        mime="text/css; charset=utf-8"
        ;;
    js)
        mime="application/javascript; charset=utf-8"
        ;;
    jpg|jpeg)
        mime="image/jpeg"
        ;;
    png)
        mime="image/png"
        ;;
    gif)
        mime="image/gif"
        ;;
    svg)
        mime="image/svg+xml"
        ;;
    txt|log)
        mime="text/plain; charset=utf-8"
        ;;
    json)
        mime="application/json; charset=utf-8"
        ;;
    *)
        mime="application/octet-stream"
        ;;
esac

# 输出头 + 文件内容
echo "Content-Type: $mime"
echo ""

cat "$TARGET_FILE"
