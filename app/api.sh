#!/bin/bash
# FnClearup CGI API - Pure Bash CGI, no external dependencies
# Version: 0.2.2

VERSION="0.2.2"

PATH_INFO="${PATH_INFO:-/}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"

# json_escape: pure bash char-loop JSON escaping
json_escape() {
    local str="$1"
    local result=""
    local i c
    for ((i=0; i<${#str}; i++)); do
        c="${str:i:1}"
        case "$c" in
            \\) result+="\\\\" ;;
            \") result+="\\\"" ;;
            $'\n') result+="\\n" ;;
            $'\t') result+="\\t" ;;
            *) result+="$c" ;;
        esac
    done
    printf '%s' "$result"
}

json_str() {
    printf '%s' "$(json_escape "$1")"
}

read_body() {
    cat
}

get_installed_apps() {
    if ! command -v appcenter-cli &>/dev/null; then
        return 1
    fi
    local output
    output=$(appcenter-cli list 2>/dev/null)
    [ $? -ne 0 ] || [ -z "$output" ] && return 1

    echo "$output" | while IFS= read -r line; do
        [ -z "$(echo "$line" | tr -d ' \t')" ] && continue
        echo "$line" | grep -qE '[┌┬┐├┼┤└┘─│]┃' && continue
        echo "$line" | grep -qiE '(APPNAME|DISPLAY.NAME|^ID$)' && continue
        echo "$line" | grep -q '│' || continue

        col1=$(echo "$line" | awk -F'│' '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        col2=$(echo "$line" | awk -F'│' '{print $2}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        [ -n "$col1" ] && echo -e "${col1}\t${col2}"
    done | sort -u
}

do_version() {
    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' ''
    printf '%s\n' "{\"version\": $(json_str "$VERSION"), \"success\": true}"
}

do_scan() {
    if [ "$REQUEST_METHOD" != "POST" ]; then
        printf '%s\n' 'Status: 405 Method Not Allowed'
        printf '%s\n' 'Content-Type: text/plain'
        printf '%s\n' ''
        printf '%s\n' 'POST required'
        exit 0
    fi

    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' 'Cache-Control: no-cache'
    printf '%s\n' ''

    declare -A installed_map
    while IFS=$'\t' read -r appname disp; do
        [ -z "$appname" ] && continue
        installed_map["${appname,,}"]="$disp"
    done < <(get_installed_apps)

    first_orphan=1
    orphan_json=""
    for vol_path in /mnt/vol*; do
        [ -d "$vol_path" ] || continue
        for app_dir in "$vol_path"/@app*; do
            [ -d "$app_dir" ] || continue
            for inst_dir in "$app_dir"/*; do
                [ -d "$inst_dir" ] || continue
                inst_name="${inst_dir##*/}"
                inst_lc="${inst_name,,}"

                is_installed=0
                [ -n "${installed_map[$inst_lc]}" ] && is_installed=1
                if [ "$is_installed" -eq 0 ] && [ "${inst_lc%-docker}" != "$inst_lc" ]; then
                    base="${inst_lc%-docker}"
                    [ -n "${installed_map[$base]}" ] && is_installed=1
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
                    orphan_json="${orphan_json}$(json_str "$inst_name"): ${subdirs_json}"
                fi
            done
        done
    done

    first=1
    installed_json=""
    for key in "${!installed_map[@]}"; do
        [ $first -eq 0 ] && installed_json="${installed_json},"
        first=0
        installed_json="${installed_json}{\"appname\": $(json_str "$key"), \"display_name\": $(json_str "${installed_map[$key]}")}"
    done
    installed_json="[${installed_json}]"

    if [ -z "$orphan_json" ]; then
        orphan_json="{}"
    else
        orphan_json="{ ${orphan_json} }"
    fi

    printf '%s\n' "{\"installed\": ${installed_json}, \"orphan\": ${orphan_json}, \"success\": true}"
}

do_delete() {
    if [ "$REQUEST_METHOD" != "POST" ]; then
        printf '%s\n' 'Status: 405 Method Not Allowed'
        printf '%s\n' 'Content-Type: text/plain'
        printf '%s\n' ''
        printf '%s\n' 'POST required'
        exit 0
    fi

    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' 'Cache-Control: no-cache'
    printf '%s\n' ''

    local body
    body=$(read_body)

    local delete_users=false
    echo "$body" | grep -qE 'delete_users[[:space:]]*:[[:space:]]*true' 2>/dev/null && delete_users=true

    local paths_str
    paths_str=$(echo "$body" | grep -oE '\[[^]]*\]' | head -1)

    local first_path=1
    local deleted_json=""
    local failed_json=""
    local total=0
    local failures=0

    if [ -n "$paths_str" ]; then
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            if [ -e "$path" ]; then
                if [ -d "$path" ]; then
                    rm -rf "$path" 2>/dev/null && stat=0 || stat=1
                else
                    rm -f "$path" 2>/dev/null && stat=0 || stat=1
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
            else
                [ $first_path -eq 0 ] && failed_json="${failed_json},"
                first_path=0
                failed_json="${failed_json}$(json_str "$path")"
                failures=$((failures + 1))
            fi
        done < <(echo "$paths_str" | grep -oE '\"[^\"]*\"' | tr -d '\\"')
    fi

    local users_deleted_json=""
    local users_failed_json=""
    local first_user=1

    if [ "$delete_users" = true ]; then
        if [ -n "$paths_str" ]; then
            while IFS= read -r path; do
                [ -z "$path" ] && continue
                username=""
                case "$path" in
                    /mnt/vol*/@app*/*)
                        username="${path##*/@app*/}"
                        username="${username%%/*}"
                        ;;
                esac
                [ -z "$username" ] && continue
                if id "$username" &>/dev/null; then
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
                fi
            done < <(echo "$paths_str" | grep -oE '\"[^\"]*\"' | tr -d '\\"')
        fi
    fi

    [ -z "$deleted_json" ] && deleted_json="[]"
    [ -z "$failed_json" ] && failed_json="[]"
    [ -z "$users_deleted_json" ] && users_deleted_json="[]"
    [ -z "$users_failed_json" ] && users_failed_json="[]"

    printf '%s\n' "{\"deleted\": ${deleted_json}, \"failed\": ${failed_json}, \"total\": ${total}, \"failures\": ${failures}, \"users_deleted\": ${users_deleted_json}, \"users_failed\": ${users_failed_json}, \"success\": true}"
}

case "$PATH_INFO" in
/api/version)
    do_version
    ;;
/api/scan)
    do_scan
    ;;
/api/delete)
    do_delete
    ;;
*)
    printf '%s\n' 'Status: 404 Not Found'
    printf '%s\n' 'Content-Type: text/plain'
    printf '%s\n' ''
    printf '%s\n' 'API endpoint not found'
    ;;
esac
