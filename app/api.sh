#!/bin/bash
# FnClearup CGI API 脚本 (纯 Bash + python3 for JSON)
# 版本: 0.2.1

VERSION="0.2.1"

PATH_INFO="${PATH_INFO:-/}"
REQUEST_METHOD="${REQUEST_METHOD:-GET}"

# ========== 获取已安装应用 ==========

get_installed_apps() {
    if ! command -v appcenter-cli &>/dev/null; then
        return 1
    fi
    local output
    output=$(appcenter-cli list 2>/dev/null)
    [ $? -ne 0 ] || [ -z "$output" ] && return 1

    echo "$output" | while IFS= read -r line; do
        [ -z "$(echo "$line" | tr -d ' \t')" ] && continue
        # 跳过边框行（含水平线字符）
        echo "$line" | grep -q '[─┼┬┴┤├┘┐└┌─]' && continue
        # 跳过表头
        echo "$line" | grep -qiE '(APP[N_]?NAME|DISPLAY[N_]?NAME|^ID$)' && continue
        # 只处理含 │ 的行
        echo "$line" | grep -q '│' || continue

        # 按 │ 分割取前两列
        appname=$(echo "$line" | awk -F'│' '{print $1}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        disp=$(echo "$line" | awk -F'│' '{print $2}' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')

        [ -n "$appname" ] && echo -e "$appname	$disp"
    done | sort -u
}

# ========== 扫描 ==========

do_scan() {
    declare -A installed_map
    while IFS=$'\t' read -r appname disp; do
        [ -z "$appname" ] && continue
        installed_map["${appname,,}"]="$disp"
    done < <(get_installed_apps)

    first_orphan=1
    orphan_pairs=""

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
                    [ $first_orphan -eq 0 ] && orphan_pairs="${orphan_pairs},"
                    first_orphan=0

                    subdirs_json="["
                    first_sub=1
                    while IFS= read -r sub; do
                        [ -z "$sub" ] && continue
                        [ $first_sub -eq 0 ] && subdirs_json="${subdirs_json},"
                        first_sub=0
                        subdirs_json="${subdirs_json}\"$(python3 -c "import sys, json; sys.stdout.write(json.dumps(sys.stdin.read()))" 2>/dev/null <<< "$sub")\""
                    done < <(find "$inst_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
                    subdirs_json="${subdirs_json}]"

                    inst_name_json=$(python3 -c "import sys, json; sys.stdout.write(json.dumps('$inst_name'))" 2>/dev/null)
                    orphan_pairs="${orphan_pairs}${inst_name_json}: ${subdirs_json}"
                fi
            done
        done
    done

    first=1
    installed_json=""
    for key in "${!installed_map[@]}"; do
        [ $first -eq 0 ] && installed_json="${installed_json},"
        first=0
        disp="${installed_map[$key]}"
        kn=$(python3 -c "import sys, json; sys.stdout.write(json.dumps('$key'))" 2>/dev/null)
        dn=$(python3 -c "import sys, json; sys.stdout.write(json.dumps('$disp'))" 2>/dev/null)
        installed_json="${installed_json}{\"appname\":$kn,\"display_name\":$dn}"
    done
    installed_json="[${installed_json}]"

    if command -v python3 &>/dev/null; then
        python3 -c "
import sys, json
try:
    installed = json.loads('${installed_json}')
except:
    installed = []
try:
    orphan = json.loads('{${orphan_pairs}}')
except:
    orphan = {}
print(json.dumps({'installed': installed, 'orphan': orphan, 'success': True}, ensure_ascii=False))
"
    else
        printf '%s\n' "{\"installed\": ${installed_json}, \"orphan\": {${orphan_pairs}}, \"success\": true}"
    fi
}

# ========== 删除 ==========

do_delete() {
    content_length="${CONTENT_LENGTH:-0}"
    body=""
    if [ "$content_length" -gt 0 ] 2>/dev/null; then
        body=$(dd bs=1 count="$content_length" 2>/dev/null)
    fi

    delete_users=0
    echo "$body" | grep -q '"delete_users"[[:space:]]*:[[:space:]]*true' && delete_users=1

    if command -v python3 &>/dev/null; then
        python3 -c "
import sys, json, os, shutil, pwd, subprocess

try:
    data = json.loads('${body}')
except:
    data = {}

paths = data.get('paths', [])
du = data.get('delete_users', False)

deleted = []
failed = []
users_deleted = []
users_failed = []

for p in paths:
    if os.path.isdir(p):
        try:
            shutil.rmtree(p)
            deleted.append(p)
        except:
            failed.append(p)
    elif os.path.isfile(p):
        try:
            os.remove(p)
            deleted.append(p)
        except:
            failed.append(p)
    else:
        failed.append(p)

    if du:
        parts = p.split('/')
        try:
            idx = parts.index('app')
            if idx + 1 < len(parts):
                username = parts[idx+1]
                try:
                    pwd.getpwnam(username)
                    r = subprocess.run(['userdel', '-r', username], capture_output=True)
                    if r.returncode == 0:
                        users_deleted.append(username)
                    else:
                        users_failed.append(username)
                except KeyError:
                    pass
                except Exception:
                    users_failed.append(username)
        except ValueError:
            pass

result = {'deleted': deleted, 'failed': failed, 'total': len(deleted), 'failures': len(failed),
          'users_deleted': users_deleted, 'users_failed': users_failed}
print(json.dumps(result, ensure_ascii=False))
"
    else
        printf '%s\n' '{"deleted":[],"failed":[],"total":0,"failures":0,"users_deleted":[],"users_failed":[]}'
    fi
}

# ========== 路由 ==========

case "$PATH_INFO" in
/api/scan)
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
    do_scan
    ;;

/api/delete)
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
    do_delete
    ;;

/api/version)
    printf '%s\n' 'Content-Type: application/json'
    printf '%s\n' ''
    printf '%s\n' "{\"version\": \"$VERSION\"}"
    ;;

*)
    printf '%s\n' 'Status: 404 Not Found'
    printf '%s\n' 'Content-Type: text/plain'
    printf '%s\n' ''
    printf '%s\n' 'API endpoint not found'
    ;;
esac
