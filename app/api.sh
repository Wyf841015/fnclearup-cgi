#!/bin/bash
# FnClearup CGI API - Pure Bash CGI
# Version: 0.3.0

VERSION="0.2.0"
PATH_INFO="${PATH_INFO:-/}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
DEBUG_LOG="/tmp/fnclearup_debug.log"

# Debug: log all CGI env vars
{
    echo "=== api.sh invoked ==="
    echo "PATH_INFO=$PATH_INFO"
    echo "REQUEST_METHOD=$REQUEST_METHOD"
    echo "REQUEST_URI=${REQUEST_URI:-}"
} >> "$DEBUG_LOG"

json_escape() {
    local str="$1" result="" i c
    for ((i=0; i<${#str}; i++)); do
        c="${str:i:1}"
        case "$c" in
            \\ ) result+="\\" ;;
            \") result+="\"" ;;
            $'\n') result+="\n" ;;
            $'\t') result+="\t" ;;
            *) result+="$c" ;;
        esac
    done
    printf '%s' "$result"
}

json_str() { printf '"%s"' "$(json_escape "$1")"; }

# Helper: send HTTP response with proper CRLF
# Usage: http_response status_code content_type body
http_response() {
    local status="$1"
    local ctype="$2"
    local body="$3"
    printf 'Status: %s\r\n' "$status"
    printf 'Content-Type: %s\r\n' "$ctype"
    printf 'Access-Control-Allow-Origin: *\r\n'
    printf '\r\n'
    printf '%s' "$body"
}

read_body() { cat; }

get_installed_apps() {
    local output
    output=$(appcenter-cli list 2>&1)
    local cli_status=$?

    [ $cli_status -ne 0 ] || [ -z "$output" ] && { return 1; }

    # Parse table-style output: split by │ and trim each field
    local json_output
    json_output=$(printf '%s' "$output" | awk '
    BEGIN { first=1; printf "[" }
    {
        gsub(/\r/, "", $0)
        if ($0 == "") next
        # Split by │ character (U+2502)
        n = split($0, parts, /\xE2\x94\x82/)
        # Trim leading/trailing whitespace from each part
        for (i = 1; i <= n; i++) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        }
        # Valid data line: at least 3 fields, parts[2]=appname (parts[1] is always empty, line starts with │)
        # Skip header lines (parts[2] contains column names)
        if (n >= 3 && parts[2] != "" && parts[2] !~ /^(APP|DISPLAY|VERSION|STATUS|├|─)/ && parts[2] !~ /[─+]/) {
            if (first) { first=0 } else { printf "," }
            printf "\n  {\"appname\":\"%s\",\"display_name\":\"%s\"}", parts[2], parts[3]
        }
    }
    END { printf "\n]\n" }')

    echo "$json_output"
}



do_version() {
    http_response "200 OK" "application/json" "{\"version\": $(json_str "$VERSION"), \"success\": true}"
}

do_scan() {
    [ "$REQUEST_METHOD" != "POST" ] && {
        http_response "405 Method Not Allowed" "text/plain" "POST required"
        exit 0
    }

    # 直接获取已安装应用的 JSON 数组（get_installed_apps 直接输出 JSON）
    local installed_json
    installed_json=$(get_installed_apps) || installed_json="[]"

    # 构建已安装应用名称集合（用于孤儿检测）
    declare -A installed_names
    
    # 从 installed_json 提取每个 appname：grep -oE 取出 "appname":"xxx" 再去掉前缀后缀
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        installed_names["${name,,}"]=1
    done < <(echo "$installed_json" | sed -n 's/.*"appname":"\([^"]*\)".*/\1/p')


 first_orphan=1
    orphan_json=""
    for vol_path in /vol*; do
        [ -d "$vol_path" ] || continue
        for app_dir in "$vol_path"/@app*; do
            [ -d "$app_dir" ] || continue
            for inst_dir in "$app_dir"/*; do
                [ -d "$inst_dir" ] || continue
                inst_name="${inst_dir##*/}"
                inst_lc="${inst_name,,}"

                is_installed=0
                # 检查：appname 完全匹配
                [ -n "${installed_names[$inst_lc]}" ] && is_installed=1
                # 检查：appname-docker 变体（去除 -docker 后缀）
                if [ "$is_installed" -eq 0 ] && [ "${inst_lc%-docker}" != "$inst_lc" ]; then
                    base="${inst_lc%-docker}"
                    [ -n "${installed_names[$base]}" ] && is_installed=1
                fi
                # 检查：docker-appname 变体（去除 docker- 前缀）
                if [ "$is_installed" -eq 0 ] && [ "${inst_lc#docker-}" != "$inst_lc" ]; then
                    base="${inst_lc#docker-}"
                    [ -n "${installed_names[$base]}" ] && is_installed=1
                fi

                if [ "$is_installed" -eq 0 ]; then
                    first_sub=1
                    subdirs_json=""
                    while IFS= read -r sub; do
                        [ -z "$sub" ] && continue
                        sub_name="${sub##*/}"
                        [ $first_sub -eq 0 ] && subdirs_json="${subdirs_json},"
                        first_sub=0
                        subdirs_json="${subdirs_json}$(json_str "$sub_name")"
                    done < <(find "$inst_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

                    [ -z "$subdirs_json" ] && subdirs_json="[]"
                    [ "${subdirs_json:0:1}" != "[" ] && subdirs_json="[${subdirs_json}]"

                    [ $first_orphan -eq 0 ] && orphan_json="${orphan_json},"
                    first_orphan=0
                    # 输出：appname, vol_path, 完整路径
                    orphan_json="${orphan_json}{\"app\":$(json_str "$inst_name"),\"vol\":$(json_str "$vol_path"),\"path\":$(json_str "$inst_dir"),\"dirs\":${subdirs_json}}"
                fi
            done
        done
    done

    [ -z "$orphan_json" ] && orphan_json="[]" || orphan_json="[${orphan_json}]"

    http_response "200 OK" "application/json" "{\"installed\": ${installed_json}, \"orphan\": ${orphan_json}, \"success\": true}"
}

do_delete() {
    echo "=== do_delete entered ===" >> "$DEBUG_LOG"

    [ "$REQUEST_METHOD" != "POST" ] && {
        http_response "405 Method Not Allowed" "text/plain" "POST required"
        exit 0
    }

    body=$(cat)
    echo "do_delete body len=${#body}" >> "$DEBUG_LOG"
    echo "do_delete body=$body" >> "$DEBUG_LOG"

    delete_users=false
    delete_users=$(echo "$body" | jq -r '.delete_users // false' 2>&1)
    echo "do_delete: delete_users raw=$delete_users" >> "$DEBUG_LOG"
    if [ "$delete_users" = "true" ]; then
      delete_users=true
    else
      delete_users=false
    fi
    echo "do_delete: delete_users bool=$delete_users" >> "$DEBUG_LOG"

    # 使用 jq 直接解析 paths 数组（更可靠）
    echo "do_delete: checking if jq is available" >> "$DEBUG_LOG"
    if ! command -v jq &>/dev/null; then
        echo "do_delete: jq not found, falling back to grep" >> "$DEBUG_LOG"
        paths_str=$(echo "$body" | grep -oE '\[[^]]*\]' | head -1)
    else
        echo "do_delete: using jq to extract paths" >> "$DEBUG_LOG"
        paths_str=$(echo "$body" | jq -r '.paths[]' 2>/dev/null)
    fi
    echo "do_delete: paths_str=$paths_str" >> "$DEBUG_LOG"

    first_path=1 deleted_json="" failed_json="" total=0 failures=0

    if [ -n "$paths_str" ]; then
        echo "do_delete: extracting paths" >> "$DEBUG_LOG"
        while IFS= read -r path; do
            # 清理路径中的 
 (Windows 行尾)
            path="${path//$'
'/}"
            [ -z "$path" ] && continue
            echo "do_delete: rm command executing for path=[$path]" >> "$DEBUG_LOG"
            # 检查路径是否存在
            if [ -d "$path" ]; then
                echo "do_delete: path is a directory, exists" >> "$DEBUG_LOG"
            elif [ -f "$path" ]; then
                echo "do_delete: path is a regular file" >> "$DEBUG_LOG"
            elif [ -e "$path" ]; then
                echo "do_delete: path exists but type unknown" >> "$DEBUG_LOG"
            else
                echo "do_delete: path does NOT exist" >> "$DEBUG_LOG"
            fi
            # 尝试移除 FnOS 保护属性 (1属性=不允许删除)
            if command -v chattr &>/dev/null; then
                echo "do_delete: trying chattr -i on $path" >> "$DEBUG_LOG"
                chattr -i "$path" 2>>"$DEBUG_LOG"
            fi
            # Delete and capture exit status directly (不使用管道)
            rm -rf "$path"
            stat=$?
            echo "do_delete: rm exit stat=$stat for path=[$path]" >> "$DEBUG_LOG"
            if [ $stat -ne 0 ]; then
                echo "do_delete: rm failed, trying ls to debug..." >> "$DEBUG_LOG"
                ls -la "$path" >> "$DEBUG_LOG" 2>&1 || echo "ls failed" >> "$DEBUG_LOG"
                echo "do_delete: checking parent dir perms..." >> "$DEBUG_LOG"
                parent=$(dirname "$path")
                ls -ld "$parent" >> "$DEBUG_LOG" 2>&1
                echo "do_delete: checking mount status..." >> "$DEBUG_LOG"
                mount | grep "$parent" >> "$DEBUG_LOG" 2>&1 || echo "not a mount point" >> "$DEBUG_LOG"
                echo "do_delete: checking immutable attr..." >> "$DEBUG_LOG"
                lsattr -d "$path" >> "$DEBUG_LOG" 2>&1 || echo "lsattr not available" >> "$DEBUG_LOG"
            fi
            if [ $stat -eq 0 ]; then
                [ $first_path -eq 0 ] && deleted_json="${deleted_json},"
                first_path=0
                deleted_json="${deleted_json}$(json_str "$path")"
                total=$((total + 1))
            else
                [ $first_path -eq 0 ] && failed_json="${failed_json},"
                first_path=0
                failed_json="${failed_json}$(json_str "$path")"
                failures=$((failures + 1))
            fi
        done <<< "$paths_str"
    else
        echo "do_delete: paths_str is empty!" >> "$DEBUG_LOG"
    fi

    first_user=1 users_deleted_json="" users_failed_json=""
   
    echo "delete_users=$delete_users" >> "$DEBUG_LOG"
    if [ "$delete_users" = true ]; then
        # 重新从 body 提取 paths（因为上面的 while 已经消费了 paths_str）
        user_paths=$(echo "$body" | jq -r '.paths[]' 2>/dev/null)
        while IFS= read -r path; do
           [ -z "$path" ] && continue
            username=""
            case "$path" in
                /vol*/@app*/*) username="${path##*/@app*/}"; username="${username%%/*}" ;echo "******$username" >> "$DEBUG_LOG";
            esac
                    
            [ -z "$username" ] && continue
            id "$username" &>/dev/null || continue
            userdel -r "$username" 2>/dev/null && stat=0 || stat=1
            if [ $stat -eq 0 ]; then
                [ $first_user -eq 0 ] && users_deleted_json="${users_deleted_json},"
                first_user=0
                users_deleted_json="${users_deleted_json}$(json_str "$username")"
            else
                [ $first_user -eq 0 ] && users_failed_json="${users_failed_json},"
                first_user=0
                users_failed_json="${users_failed_json}$(json_str "$username")"
            fi
        done <<< "$user_paths"
    fi

    [ -z "$deleted_json" ] && deleted_json="[]" || deleted_json="[${deleted_json}]"
    [ -z "$failed_json" ] && failed_json="[]" || failed_json="[${failed_json}]"
    [ -z "$users_deleted_json" ] && users_deleted_json="[]" || users_deleted_json="[${users_deleted_json}]"
    [ -z "$users_failed_json" ] && users_failed_json="[]" || users_failed_json="[${users_failed_json}]"
   echo  "{\"deleted\": ${deleted_json}, \"failed\": ${failed_json}, \"total\": ${total}, \"failures\": ${failures}, \"users_deleted\": ${users_deleted_json}, \"users_failed\": ${users_failed_json}, \"success\": true}" >> "$DEBUG_LOG"
    http_response "200 OK" "application/json" "{\"deleted\": ${deleted_json}, \"failed\": ${failed_json}, \"total\": ${total}, \"failures\": ${failures}, \"users_deleted\": ${users_deleted_json}, \"users_failed\": ${users_failed_json}, \"success\": true}"
}

do_debug() {
    echo "=== do_debug ===" >> "$DEBUG_LOG"
    local output
    output=$(/usr/bin/appcenter-cli list 2>&1)
    echo "raw_output_lines=$(echo "$output" | wc -l)" >> "$DEBUG_LOG"
    echo "first_line=$(echo "$output" | head -1 | cat -v)" >> "$DEBUG_LOG"
    # Return raw output for inspection
    http_response "200 OK" "text/plain" "$output"
}

do_ping() {
    http_response "200 OK" "application/json" "{\"ok\":true,\"method\":\"$REQUEST_METHOD\",\"uri\":\"$REQUEST_URI\"}"
}



do_mounts() {
    echo "=== do_mounts entered ===" >> "$DEBUG_LOG"
    local json_file="/etc/mountmgr/mount_info.json"
    [ ! -f "$json_file" ] && {
        echo "do_mounts: file not found: $json_file" >> "$DEBUG_LOG"
        http_response "200 OK" "application/json" "{\"mounts\": [], \"success\": true, \"message\": \"mount_info.json not found\"}"
        exit 0
    }

    echo "do_mounts: using jq to parse $json_file" >> "$DEBUG_LOG"

    # Check if jq exists
    if ! command -v jq &>/dev/null; then
        echo "do_mounts: jq not found" >> "$DEBUG_LOG"
        http_response "200 OK" "application/json" "{\"mounts\": [], \"success\": false, \"message\": \"jq not installed\"}"
        exit 0
    fi

    # Use jq to extract all mount entries
    # JSON structure: { uid: { mountId: { mountData } } }
    # We want all objects that have a mountPoint field
    local mounts_json
    # Use jq to parse - write filter to temp file to avoid shell quoting issues
    local jq_filter
    jq_filter=$(mktemp)
    cat > "$jq_filter" << 'JQFEOF'
    [
        to_entries[] |
        .value |
        to_entries[] |
        .value |
        select(.mountPoint != null and .mountPoint != "") |
        {
            address: (.address // ""),
            cloudStorageTypeStr: (.cloudStorageTypeStr // ""),
            comment: (.comment // ""),
            mountPoint: (.mountPoint // ""),
            path: (.path // ""),
            port: ((.port // 0) | tostring),
            proto: (.proto // ""),
            username: (.username // "")
        }
    ]
JQFEOF
    mounts_json=$(jq -c -f "$jq_filter" "$json_file" 2>>"$DEBUG_LOG")
    rm -f "$jq_filter"

    local jq_status=$?
    echo "do_mounts: jq return status=$jq_status, mounts_json=$mounts_json" >> "$DEBUG_LOG"

    [ -z "$mounts_json" ] && mounts_json="[]"
    http_response "200 OK" "application/json" "{\"mounts\": $mounts_json, \"success\": true}"
}


do_vol02() {
    echo "=== do_vol02 entered ===" >> "$DEBUG_LOG"

    local json_file="/etc/mountmgr/mount_info.json"
    local vol02_base="/vol02"

    # Get all subdirectories in /vol02 - build JSON array directly with jq
    local vol02_dirs="[]"
    if [ -d "$vol02_base" ]; then
        local vol02_json=""
        first=1
        for dir in "$vol02_base"/*; do
            [ -d "$dir" ] || continue
            dir_name="${dir##*/}"
            echo "do_vol02: found vol02 subdir=$dir_name" >> "$DEBUG_LOG"
            [ $first -eq 1 ] && first=0 || vol02_json="${vol02_json},"
            vol02_json="${vol02_json}$(json_str "$dir_name")"
        done
        [ -n "$vol02_json" ] && vol02_dirs="[${vol02_json}]"
    else
        echo "do_vol02: $vol02_base does not exist" >> "$DEBUG_LOG"
    fi
    echo "do_vol02: vol02_dirs=$vol02_dirs" >> "$DEBUG_LOG"

    # Get mounted mountPoints using jq -f filter file
    local mounted_points="[]"
    if [ -f "$json_file" ]; then
        local jq_filter
        jq_filter=$(mktemp)
        cat > "$jq_filter" << 'JQFEOF2'
[
    to_entries[] |
    .value |
    to_entries[] |
    .value |
    select(.mountPoint != null and .mountPoint != "") |
    .mountPoint
]
JQFEOF2
        echo "do_vol02: running jq with filter file" >> "$DEBUG_LOG"
        mounted_points=$(jq -c -f "$jq_filter" "$json_file")
        local jq_ret=$?
        echo "do_vol02: jq return=$jq_ret" >> "$DEBUG_LOG"
        echo "do_vol02: mounted_points raw='$mounted_points'" >> "$DEBUG_LOG"
        rm -f "$jq_filter"
    else
        echo "do_vol02: $json_file does not exist" >> "$DEBUG_LOG"
    fi
    [ -z "$mounted_points" ] && mounted_points="[]"

    echo "do_vol02: final response" >> "$DEBUG_LOG"
    echo "do_vol02: vol02_dirs=$vol02_dirs" >> "$DEBUG_LOG"
    echo "do_vol02: mounted_points=$mounted_points" >> "$DEBUG_LOG"

    http_response "200 OK" "application/json" "{\"vol02_dirs\": ${vol02_dirs}, \"mounted_points\": ${mounted_points}, \"success\": true}"
}




# ----------- Docker volumes -----------
do_volumes() {
    echo "=== do_volumes entered ===" >> "$DEBUG_LOG"

    if ! command -v docker &>/dev/null; then
        echo "do_volumes: docker not found" >> "$DEBUG_LOG"
        http_response "200 OK" "application/json" '{"volumes":{"all":[],"in_use":[],"orphan":[]},"success":true,"message":"docker not available"}'
        return
    fi

    # Get all volume names -> temp file
    local vol_list_file
    vol_list_file=$(mktemp)
    docker volume ls -q 2>/dev/null > "$vol_list_file"

    # Build all volumes array
    local all_json=""
    first=1
    while IFS= read -r vn; do
        [ -z "$vn" ] && continue
        [ $first -eq 1 ] && first=0 || all_json="${all_json},"
        all_json="${all_json}$(json_str "$vn")"
    done < "$vol_list_file"
    [ -n "$all_json" ] && all_json="[${all_json}]" || all_json="[]"

    # Get used volume names from docker ps -> temp file
    local used_file
    used_file=$(mktemp)
    docker ps -a --format '{{json .Mounts}}' 2>/dev/null | while IFS= read -r mounts_json; do
        [ -z "$mounts_json" ] && continue
        echo "$mounts_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r m; do
            [ -z "$m" ] && continue
            echo "$m" | cut -d: -f1
        done
    done | sort -u > "$used_file"

    # Separate in-use and orphan
    local in_use_json=""
    local orphan_json=""
    first_in_use=1
    first_orphan=1

    while IFS= read -r vol_name; do
        [ -z "$vol_name" ] && continue

        # Inspect volume for driver/mountpoint
        local vol_info driver mountpoint
        vol_info=$(docker volume inspect -- "$vol_name" 2>/dev/null)
        driver=$(echo "$vol_info" | jq -r '.[0].Driver // ""' 2>/dev/null)
        mountpoint=$(echo "$vol_info" | jq -r '.[0].Mountpoint // ""' 2>/dev/null)

        # Find containers using this volume
        local cont_file cont_list first_cont
        cont_file=$(mktemp)
        docker ps -a --format '{{.Names}}' 2>/dev/null > "$cont_file"
        cont_list=""
        first_cont=1
        while IFS= read -r cname; do
            [ -z "$cname" ] && continue
            local vol_in_cont
            vol_in_cont=$(docker inspect -- "{{range .Mounts}}{{.Name}}{{println}}{{end}}" "$cname" 2>/dev/null | grep -F "$vol_name")
            if [ -n "$vol_in_cont" ]; then
                [ $first_cont -eq 1 ] && first_cont=0 || cont_list="${cont_list},"
                cont_list="${cont_list}$(json_str "$cname")"
            fi
        done < "$cont_file"
        rm -f "$cont_file"
        [ -z "$cont_list" ] && cont_list="[]" || cont_list="[${cont_list}]"

        # Classify
        if grep -qF "$vol_name" "$used_file" 2>/dev/null; then
            [ $first_in_use -eq 1 ] && first_in_use=0 || in_use_json="${in_use_json},"
            in_use_json="${in_use_json}{\"name\":$(json_str "$vol_name"),\"driver\":$(json_str "$driver"),\"mountpoint\":$(json_str "$mountpoint"),\"containers\":${cont_list}}"
        else
            [ $first_orphan -eq 1 ] && first_orphan=0 || orphan_json="${orphan_json},"
            orphan_json="${orphan_json}{\"name\":$(json_str "$vol_name"),\"driver\":$(json_str "$driver"),\"mountpoint\":$(json_str "$mountpoint")}"
        fi
    done < "$vol_list_file"

    rm -f "$vol_list_file" "$used_file"

    [ -z "$in_use_json" ] && in_use_json="[]" || in_use_json="[${in_use_json}]"
    [ -z "$orphan_json" ] && orphan_json="[]" || orphan_json="[${orphan_json}]"

    echo "do_volumes: in_use=$(echo $in_use_json | jq length 2>/dev/null) orphan=$(echo $orphan_json | jq length 2>/dev/null)" >> "$DEBUG_LOG"

    http_response "200 OK" "application/json" "{\"volumes\":{\"all\":${all_json},\"in_use\":${in_use_json},\"orphan\":${orphan_json}},\"success\":true}"
}

do_docker_delete() {
    echo "=== do_docker_delete entered ===" >> "$DEBUG_LOG"

    [ "$REQUEST_METHOD" != "POST" ] && {
        http_response "405 Method Not Allowed" "text/plain" "POST required"
        exit 0
    }

    body=$(cat)

    if ! command -v docker &>/dev/null; then
        http_response "200 OK" "application/json" '{"total":0,"failures":0,"errors":["docker not available"],"success":false}'
        return
    fi

    local volumes_str
    volumes_str=$(echo "$body" | jq -r '.volumes[]' 2>/dev/null)

    first=1 deleted_json="" failed_json="" total=0 failures=0
    errors_json="[]"

    if [ -n "$volumes_str" ]; then
        while IFS= read -r vol; do
            [ -z "$vol" ] && continue
            docker volume rm "$vol" 2>>"$DEBUG_LOG"
            stat=$?
            if [ $stat -eq 0 ]; then
                [ $first -eq 1 ] && first=0 || deleted_json="${deleted_json},"
                deleted_json="${deleted_json}$(json_str "$vol")"
                total=$((total + 1))
            else
                [ $first -eq 1 ] && first=0 || failed_json="${failed_json},"
                failed_json="${failed_json}$(json_str "$vol")"
                failures=$((failures + 1))
                errors_json=$(echo "$errors_json" | jq --arg e "failed: $vol" '. + [$e]')
            fi
        done <<< "$volumes_str"
    fi

    [ -z "$deleted_json" ] && deleted_json="[]" || deleted_json="[${deleted_json}]"
    [ -z "$failed_json" ] && failed_json="[]" || failed_json="[${failed_json}]"

    http_response "200 OK" "application/json" "{\"deleted\":${deleted_json},\"failed\":${failed_json},\"total\":${total},\"failures\":${failures},\"errors\":${errors_json},\"success\":true}"
}

case "$PATH_INFO" in
/version) do_version ;;
/scan)    do_scan    ;;
/delete)  do_delete  ;;
/ping)    do_ping    ;;
/mounts)  do_mounts  ;;
/vol02)   do_vol02   ;;
/volumes) do_volumes ;;
/volumes/delete) do_docker_delete ;;
*)
    http_response "404 Not Found" "text/plain" "API endpoint not found"
    ;;
esac