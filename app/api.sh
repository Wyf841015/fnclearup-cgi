#!/bin/bash
# FnClearup CGI API 脚本 (纯 Bash)
# 版本: 0.2.0

VERSION="0.2.0"

# 获取请求路径
PATH_INFO="${PATH_INFO:-/}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"

# ========== 工具函数 ==========

log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S')] $*" >> /tmp/fnclearup-cgi.log
}

json_escape_str() {
    # 适用于字符串值（两侧加引号）
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | sed '1s/^/"/; 1s/$/"/'
}

get_installed_apps() {
    # 通过 appcenter-cli list 获取已安装应用
    if ! command -v appcenter-cli &>/dev/null; then
        return 1
    fi
    local output
    output=$(appcenter-cli list 2>/dev/null)
    [ $? -ne 0 ] || [ -z "$output" ] && return 1

    echo "$output" | grep '|' | grep -v '[─│┬┴┼├┤┘┐└┌─]' | grep -v -iE '(APP NAME|DISPLAY NAME|appname|应用名称)' | while IFS= read -r line; do
        line="${line#|}"
        line="${line%|}"
        OLDIFS="$IFS"
        IFS='|'
        set -- $line
        IFS="$OLDIFS"
        appname=$(echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        disp=$(echo "$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        [ -n "$appname" ] && echo -e "$appname\t$disp"
    done | sort -u
}

# ========== 路由 ==========

case "$PATH_INFO" in
/api/scan)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        log "CGI scan request"

        # 获取已安装应用列表（转小写集合）
        declare -A installed_map
        while IFS=$'\t' read -r appname disp; do
            [ -z "$appname" ] && continue
            installed_map["${appname,,}"]="$disp"
        done < <(get_installed_apps)

        # 扫描 /mnt/vol*
        orphan_json="{"
        first_orphan=1

        for vol_path in /mnt/vol*; do
            [ -d "$vol_path" ] || continue
            for app_dir in "$vol_path"/@app*; do
                [ -d "$app_dir" ] || continue
                for inst_dir in "$app_dir"/*; do
                    [ -d "$inst_dir" ] || continue
                    inst_name="${inst_dir##*/}"
                    inst_lc="${inst_name,,}"

                    # 检查是否已安装
                    is_installed=0
                    if [ -n "${installed_map[$inst_lc]}" ]; then
                        is_installed=1
                    fi
                    # -docker 变体检查
                    if [ "$is_installed" -eq 0 ] && [ "${inst_lc%-docker}" != "$inst_lc" ]; then
                        base="${inst_lc%-docker}"
                        if [ -n "${installed_map[$base]}" ]; then
                            is_installed=1
                        fi
                    fi

                    if [ "$is_installed" -eq 0 ]; then
                        [ $first_orphan -eq 0 ] && orphan_json="${orphan_json},"
                        first_orphan=0
                        # 收集子目录路径
                        subdirs_json="["
                        first_sub=1
                        while IFS= read -r sub; do
                            [ -z "$sub" ] && continue
                            [ $first_sub -eq 0 ] && subdirs_json="${subdirs_json},"
                            first_sub=0
                            subdirs_json="${subdirs_json}$(json_escape_str "$sub")"
                        done < <(find "$inst_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                        subdirs_json="${subdirs_json}]"
                        orphan_json="${orphan_json}$(json_escape_str "$inst_name"): ${subdirs_json}"
                    fi
                done
            done
        done
        orphan_json="${orphan_json}}"

        # installed JSON
        installed_json="["
        first=1
        for key in "${!installed_map[@]}"; do
            [ $first -eq 0 ] && installed_json="${installed_json},"
            first=0
            disp="${installed_map[$key]}"
            installed_json="${installed_json}{\"appname\":$(json_escape_str "$key"),\"display_name\":$(json_escape_str "$disp")}"
        done
        installed_json="${installed_json}]"

        echo "Content-Type: application/json"
        echo "Cache-Control: no-cache"
        echo ""
        echo "{"
        echo "  \"installed\": ${installed_json},"
        echo "  \"orphan\": ${orphan_json},"
        echo "  \"success\": true"
        echo "}"
    else
        echo "Status: 405 Method Not Allowed"
        echo "Content-Type: text/plain"
        echo ""
        echo "POST required"
    fi
    ;;

/api/delete)
    if [ "$REQUEST_METHOD" = "POST" ]; then
        log "CGI delete request"
        content_length="${CONTENT_LENGTH:-0}"
        body=""
        if [ "$content_length" -gt 0 ] 2>/dev/null; then
            body=$(dd bs=1 count="$content_length" 2>/dev/null)
        fi

        delete_users=0
        echo "$body" | grep -q '"delete_users"[[:space:]]*:[[:space:]]*true' && delete_users=1

        # 提取所有 "..." 路径
        paths_json=$(echo "$body" | sed -n 's/.*"paths"[[:space:]]*:[[:space:]]*\[/[/; s/\].*/]/p')
        paths_json="${paths_json#[}"
        paths_json="${paths_json%]}"

        deleted_json="["
        failed_json="["
        users_deleted_json="["
        users_failed_json="["
        first_d=1
        first_f=1
        first_u=1
        total_d=0
        total_f=0

        echo "$paths_json" | grep -oP '(?<=")[^"\\]*(?:\\.[^"\\]*)*(?=")' 2>/dev/null | while IFS= read -r p; do
            [ -z "$p" ] && continue
            p=$(echo "$p" | sed 's/\\"/"/g; s/\\\\/\\/g')

            # 删除目录/文件
            if [ -d "$p" ]; then
                rm -rf "$p" 2>/dev/null && ret=0 || ret=1
            elif [ -f "$p" ]; then
                rm -f "$p" 2>/dev/null && ret=0 || ret=1
            else
                ret=1
            fi

            if [ "$ret" -eq 0 ]; then
                [ $first_d -eq 0 ] && deleted_json="${deleted_json},"
                first_d=0
                deleted_json="${deleted_json}$(json_escape_str "$p")"
                total_d=$((total_d + 1))
            else
                [ $first_f -eq 0 ] && failed_json="${failed_json},"
                first_f=0
                failed_json="${failed_json}$(json_escape_str "$p")"
                total_f=$((total_f + 1))
            fi

            # 删除关联用户
            if [ "$delete_users" -eq 1 ]; then
                username="${p#/mnt/*/}"
                username="${username%%/*}"
                [ -z "$username" ] && continue
                if id "$username" &>/dev/null; then
                    userdel -r "$username" 2>/dev/null && ur=0 || ur=1
                    if [ "$ur" -eq 0 ]; then
                        [ $first_u -eq 0 ] && users_deleted_json="${users_deleted_json},"
                        first_u=0
                        users_deleted_json="${users_deleted_json}$(json_escape_str "$username")"
                    else
                        [ $first_u -eq 0 ] && users_failed_json="${users_failed_json},"
                        first_u=0
                        users_failed_json="${users_failed_json}$(json_escape_str "$username")"
                    fi
                fi
            fi
        done

        deleted_json="${deleted_json}]"
        failed_json="${failed_json}]"
        users_deleted_json="${users_deleted_json}]"
        users_failed_json="${users_failed_json}]"

        echo "Content-Type: application/json"
        echo "Cache-Control: no-cache"
        echo ""
        echo "{"
        echo "  \"deleted\": ${deleted_json},"
        echo "  \"failed\": ${failed_json},"
        echo "  \"total\": $total_d,"
        echo "  \"failures\": $total_f,"
        echo "  \"users_deleted\": ${users_deleted_json},"
        echo "  \"users_failed\": ${users_failed_json}"
        echo "}"
    else
        echo "Status: 405 Method Not Allowed"
        echo "Content-Type: text/plain"
        echo ""
        echo "POST required"
    fi
    ;;

/api/version)
    echo "Content-Type: application/json"
    echo ""
    echo "{\"version\": \"$VERSION\"}"
    ;;

*)
    echo "Status: 404 Not Found"
    echo "Content-Type: text/plain"
    echo ""
    echo "API endpoint not found"
    ;;
esac
