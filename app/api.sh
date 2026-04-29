#!/bin/bash
# FnClearup CGI API - Pure Bash CGI
# Version: 0.3.0

VERSION="0.3.0"
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
    echo "=== get_installed_apps ===" >> "$DEBUG_LOG"

    local output
    output=$(/usr/bin/appcenter-cli list 2>&1)
    local cli_status=$?
    echo "cli_status=$cli_status" >> "$DEBUG_LOG"
    echo "raw_output_bytes=${#output}" >> "$DEBUG_LOG"
    echo "raw_output_first_500: ${output:0:500}" >> "$DEBUG_LOG"

    [ $cli_status -ne 0 ] || [ -z "$output" ] && { echo "FAIL: no cli output" >> "$DEBUG_LOG"; return 1; }

    local parsed
    # Detect delimiter: Unicode │ (U+2502) or ASCII | (0x7C)
    if echo "$output" | head -3 | grep -q $'\xE2\x94\x82'; then
        echo "Detected: Unicode delimiter" >> "$DEBUG_LOG"
        parsed=$(echo "$output" | sed -e 's/│/|/g' -e 's/\r$//' | awk -F "|" '
            {
                if (NF < 3) next
                f1 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f1)
                f2 = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
                if (f1 == "" || f1 == "APP NAME" || f1 == "DISPLAY NAME" || f1 == "NONE") next
                if (f1 ~ /^[┌┬┐├┤┴┼]/) next
                if (f1 ~ /^-+$/) next
                printf "%s\t%s\n", f1, f2
            }')
    else
        echo "Detected: ASCII delimiter" >> "$DEBUG_LOG"
        parsed=$(echo "$output" | sed -e 's/\r$//' | awk -F "|" '
            {
                if (NF < 3) next
                f1 = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f1)
                f2 = $3; gsub(/^[[:space:]]+|[[:space:]]+$/, "", f2)
                if (f1 == "" || f1 == "APP NAME" || f1 == "DISPLAY NAME" || f1 == "NONE") next
                if (f1 ~ /^-+$/) next
                printf "%s\t%s\n", f1, f2
            }')
    fi

    echo "parsed_lines=$(echo "$parsed" | wc -l)" >> "$DEBUG_LOG"
    echo "parsed_first_300: ${parsed:0:300}" >> "$DEBUG_LOG"
    printf '%s' "$parsed"

    echo "=== get_installed_apps done ===" >> "$DEBUG_LOG"
}



do_version() {
    http_response "200 OK" "application/json" "{\"version\": $(json_str "$VERSION"), \"success\": true}"
}

do_scan() {
    [ "$REQUEST_METHOD" != "POST" ] && {
        http_response "405 Method Not Allowed" "text/plain" "POST required"
        exit 0
    }

    echo "=== do_scan ===" >> "$DEBUG_LOG"

    declare -A installed_map
    while IFS=$'\t' read -r appname disp; do
        [ -z "$appname" ] && continue
        installed_map["${appname,,}"]="$disp"
    done < <(get_installed_apps)

    echo "installed_map size=${#installed_map[@]}" >> "$DEBUG_LOG"

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

    [ -z "$orphan_json" ] && orphan_json="{}" || orphan_json="{ ${orphan_json} }"

    echo "scan_result: installed=${#installed_map[@]} orphan=?" >> "$DEBUG_LOG"
    http_response "200 OK" "application/json" "{\"installed\": ${installed_json}, \"orphan\": ${orphan_json}, \"success\": true}"
}

do_delete() {
    [ "$REQUEST_METHOD" != "POST" ] && {
        http_response "405 Method Not Allowed" "text/plain" "POST required"
        exit 0
    }

    body=$(read_body)

    delete_users=false
    echo "$body" | grep -qE 'delete_users[[:space:]]*:[[:space:]]*true' 2>/dev/null && delete_users=true

    paths_str=$(echo "$body" | grep -oE '\[[^]]*\]' | head -1)

    first_path=1 deleted_json="" failed_json="" total=0 failures=0

    if [ -n "$paths_str" ]; then
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            if [ -e "$path" ]; then
                [ -d "$path" ] && rm -rf "$path" 2>/dev/null && stat=0 || stat=1
                [ -f "$path" ] && rm -f "$path" 2>/dev/null && stat=0 || stat=1
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

    first_user=1 users_deleted_json="" users_failed_json=""

    if [ "$delete_users" = true ]; then
        while IFS= read -r path; do
            [ -z "$path" ] && continue
            username=""
            case "$path" in
                /mnt/vol*/@app*/*) username="${path##*/@app*/}"; username="${username%%/*}" ;;
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
        done < <(echo "$paths_str" | grep -oE '\"[^\"]*\"' | tr -d '\\"')
    fi

    [ -z "$deleted_json" ] && deleted_json="[]"
    [ -z "$failed_json" ] && failed_json="[]"
    [ -z "$users_deleted_json" ] && users_deleted_json="[]"
    [ -z "$users_failed_json" ] && users_failed_json="[]"

    http_response "200 OK" "application/json" "{\"deleted\": ${deleted_json}, \"failed\": ${failed_json}, \"total\": ${total}, \"failures\": ${failures}, \"users_deleted\": ${users_deleted_json}, \"users_failed\": ${users_failed_json}, \"success\": true}"
}

do_ping() {
    http_response "200 OK" "application/json" "{\"ok\":true,\"method\":\"$REQUEST_METHOD\",\"uri\":\"$REQUEST_URI\"}"
}

case "$PATH_INFO" in
/version) do_version ;;
/scan)    do_scan    ;;
/delete)  do_delete  ;;
/ping)    do_ping    ;;
*)
    http_response "404 Not Found" "text/plain" "API endpoint not found"
    ;;
esac
