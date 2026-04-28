#!/bin/bash
# FnClearup CGI API - Pure Bash CGI
# Version: 0.2.4

VERSION="0.2.7"
PATH_INFO="${PATH_INFO:-/}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"
DEBUG_LOG="/tmp/fnclearup_debug.log"

# Debug: log all CGI env vars
echo "=== api.sh invoked ===" >> /tmp/fnclearup_debug.log
echo "PATH_INFO=$PATH_INFO" >> /tmp/fnclearup_debug.log
echo "REQUEST_METHOD=$REQUEST_METHOD" >> /tmp/fnclearup_debug.log
echo "REQUEST_URI=$REQUEST_URI" >> /tmp/fnclearup_debug.log
echo "SCRIPT_NAME=$SCRIPT_NAME" >> /tmp/fnclearup_debug.log
echo "SERVER_NAME=$SERVER_NAME" >> /tmp/fnclearup_debug.log
echo "=== end env ===" >> /tmp/fnclearup_debug.log

json_escape() {
    local str="$1" result="" i c
    for ((i=0; i<${#str}; i++)); do
        c="${str:i:1}"
        case "$c" in
            \\\\) result+="\\\\" ;;
            \") result+="\\\"" ;;
            $'\n') result+="\\n" ;;
            $'\t') result+="\\t" ;;
            *) result+="$c" ;;
        esac
    done
    printf '%s' "$result"
}

json_str() { printf '%s' "$(json_escape "$1")"; }

read_body() { cat; }

get_installed_apps() {
    echo "=== get_installed_apps ===" >> "$DEBUG_LOG"

    local output
    output=$(appcenter-cli list 2>&1)
    local cli_status=$?
    echo "cli_status=$cli_status" >> "$DEBUG_LOG"

    [ $cli_status -ne 0 ] || [ -z "$output" ] && { echo "FAIL: no cli output" >> "$DEBUG_LOG"; return 1; }

    # Dump first 3 lines for delimiter detection
    echo "--- raw lines for delimiter detection ---" >> "$DEBUG_LOG"
    local count=0
    while IFS= read -r line; do
        [[ $count -ge 3 ]] && break
        echo "RAW[$count]=$(printf '%s' "$line" | cut -c1-200 | od -A n -t x1 | tr -s ' ' | head -1)" >> "$DEBUG_LOG"
        echo "LINE[$count]=$line" >> "$DEBUG_LOG"
        count=$((count+1))
    done <<< "$output"

    # Detect delimiter: Unicode │ (U+2502) or ASCII | (0x7C)
    local has_unicode=0 has_ascii=0
    if echo "$output" | head -3 | grep -q $'\xE2\x94\x82'; then
        has_unicode=1
        echo "Detected: Unicode" >> "$DEBUG_LOG"
    fi
    if echo "$output" | head -3 | grep -q $'\x7C'; then
        has_ascii=1
        echo "Detected: ASCII" >> "$DEBUG_LOG"
    fi

    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num+1))

        [ -z "${line// }" ] && continue

        # Skip box-drawing border lines
        if echo "$line" | grep -qE '^[[:space:]]*[┌┬┐├┤┴┼][─]*[┬┐├┤┴┼─]*[┬┐├┤┴┼][[:space:]]*$'; then
            continue
        fi

        # Determine delimiter
        local delim="│"
        local pipe_char="│"
        if [[ "$line" != *"$pipe_char"* ]]; then
            delim="|"
            pipe_char="|"
        fi

        # Strip leading/trailing delimiter and whitespace
        line="${line#$pipe_char}"
        line="${line%$pipe_char}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"

        # Split by delimiter
        local -a parts=()
        IFS="$delim" read -ra parts <<< "$line"

        # Trim each field
        local -a trimmed=()
        for part in "${parts[@]}"; do
            part="${part#"${part%%[![:space:]]*}"}"
            part="${part%"${part##*[![:space:]]}"}"
            part="${part//\r/}"
            trimmed+=("$part")
        done

        echo "PARSED[$line_num]: ${#trimmed[@]} fields: ${trimmed[*]}" >> "$DEBUG_LOG"

        [[ ${#trimmed[@]} -lt 2 ]] && continue

        local appname="${trimmed[0]}"
        local display_name="${trimmed[1]}"

        [ -z "$appname" ] && continue
        [[ "$appname" == "APP NAME" ]] && continue
        [[ "$appname" == "NONE" ]] && continue

        echo "OUT: ${appname}\t${display_name}" >> "$DEBUG_LOG"
        echo -e "${appname}\t${display_name}"

    done <<< "$output"

    echo "=== get_installed_apps done ===" >> "$DEBUG_LOG"
}

do_version() {
    printf '%s\n' 'Status: 200'
    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' ''
    printf '%s\n' "{\"version\": $(json_str "$VERSION"), \"success\": true}"
}

do_scan() {
    printf '%s\n' 'Status: 200'
    [ "$REQUEST_METHOD" != "POST" ] && { printf '%s\n' 'Status: 405 Method Not Allowed'; printf '%s\n' 'Content-Type: text/plain'; printf '%s\n' ''; printf '%s\n' 'POST required'; exit 0; }

    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' 'Cache-Control: no-cache'
    printf '%s\n' ''

    echo "=== do_scan ===" >> "$DEBUG_LOG"

    declare -A installed_map
    while IFS=$'\t' read -r appname disp; do
        [ -z "$appname" ] && continue
        installed_map["${appname,,}"]="$disp"
    done < <(get_installed_apps)

    echo "installed_map size=${#installed_map[@]}" >> "$DEBUG_LOG"
    for k in "${!installed_map[@]}"; do echo "  map[$k]=${installed_map[$k]}" >> "$DEBUG_LOG"; done

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
    printf '%s\n' "{\"installed\": ${installed_json}, \"orphan\": ${orphan_json}, \"success\": true}"
}

do_delete() {
    printf '%s\n' 'Status: 200'
    [ "$REQUEST_METHOD" != "POST" ] && { printf '%s\n' 'Status: 405 Method Not Allowed'; printf '%s\n' 'Content-Type: text/plain'; printf '%s\n' ''; printf '%s\n' 'POST required'; exit 0; }

    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' 'Cache-Control: no-cache'
    printf '%s\n' ''

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

    printf '%s\n' "{\"deleted\": ${deleted_json}, \"failed\": ${failed_json}, \"total\": ${total}, \"failures\": ${failures}, \"users_deleted\": ${users_deleted_json}, \"users_failed\": ${users_failed_json}, \"success\": true}"
}

case "$PATH_INFO" in
/version) do_version ;;
/scan)    do_scan    ;;
/delete)  do_delete  ;;
*)
    printf '%s\n' 'Status: 404 Not Found'
    printf '%s\n' 'Content-Type: text/plain'
    printf '%s\n' ''
    printf '%s\n' 'API endpoint not found'
    ;;
esac
