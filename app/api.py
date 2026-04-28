#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FnClearup CGI API 处理脚本
版本: 0.2.0
"""
import os
import sys
import subprocess
import json
import re
import shutil
import pwd

# ========== 版本 ==========
VERSION = "0.2.0"

# ========== 日志 ==========
def log(msg):
    with open('/tmp/fnclearup-cgi.log', 'a') as f:
        f.write(f"[{datetime.now().isoformat()}] {msg}\n")

from datetime import datetime

# ========== 核心函数 ==========

def discover_vols():
    """动态发现可用的 vol 目录"""
    vols = []
    mnt = "/mnt"
    if not os.path.exists(mnt):
        return vols
    try:
        for entry in os.listdir(mnt):
            if re.match(r'^vol\d+$', entry):
                full = os.path.join(mnt, entry)
                if os.path.isdir(full):
                    vols.append(full)
    except Exception:
        pass
    vols.sort(key=lambda x: int(re.search(r'\d+', x).group()))
    return vols

def discover_app_dirs(vol_path):
    """发现 vol 下的 @app* 类型目录"""
    if not os.path.isdir(vol_path):
        return []
    app_dirs = []
    try:
        for entry in os.listdir(vol_path):
            if entry.startswith("@app") and os.path.isdir(os.path.join(vol_path, entry)):
                app_dirs.append(entry)
    except Exception:
        pass
    return sorted(app_dirs)

def get_installed_apps():
    """通过 appcenter-cli 获取已安装应用列表"""
    try:
        result = subprocess.run(
            ["appcenter-cli", "list"],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            apps = []
            for line in result.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                # 跳过框线分隔行
                if any(c in line for c in ('─', '┬', '┼', '┴', '┤', '├', '│')):
                    continue
                # 跳过表头
                if 'APP NAME' in line or 'DISPLAY NAME' in line:
                    continue
                # 解析数据行
                if '│' in line:
                    parts = [p.strip() for p in line.split('│')]
                    parts = [p for p in parts if p]
                    if parts and parts[0] not in ("APP NAME", "APPNAME", "-", ""):
                        apps.append({"appname": parts[0], "display_name": parts[1] if len(parts) > 1 else parts[0]})
            # 去重
            seen = set()
            unique = []
            for a in apps:
                if a["appname"] not in seen:
                    seen.add(a["appname"])
                    unique.append(a)
            return unique
    except Exception:
        pass
    return []

def get_vol_app_dirs(vol_path):
    """扫描某个 vol 下的所有 @app* 目录下的子目录"""
    app_dirs = set()
    app_type_dirs = discover_app_dirs(vol_path)
    for app_type in app_type_dirs:
        full_path = os.path.join(vol_path, app_type)
        if not os.path.isdir(full_path):
            continue
        try:
            for sub in os.listdir(full_path):
                sub_path = os.path.join(full_path, sub)
                if os.path.isdir(sub_path):
                    app_dirs.add((sub, sub_path))
        except Exception:
            pass
    return app_dirs

def scan_all_vols():
    """扫描所有 vol，返回孤立应用"""
    installed_raw = get_installed_apps()
    installed_names = set(app["appname"] for app in installed_raw)
    vols = discover_vols()
    merged = {}
    
    for vol_path in vols:
        vol_app_dirs = get_vol_app_dirs(vol_path)
        for sub_name, full_path in vol_app_dirs:
            lower_name = sub_name.lower()
            # 跳过已安装的应用（包括 -docker 变体）
            if lower_name.endswith("-docker"):
                base_name = sub_name[:-7]
                matched = next((app for app in installed_names if app.lower() == base_name.lower()), None)
                if matched:
                    continue
            is_installed = any(app.lower() == sub_name.lower() for app in installed_names)
            if not is_installed:
                if sub_name not in merged:
                    merged[sub_name] = []
                merged[sub_name].append(full_path)
    
    orphan = {k: sorted(merged[k]) for k in sorted(merged)}
    return orphan, installed_raw

# ========== CGI 入口 ==========

def main():
    # 获取请求路径
    path_info = os.environ.get('PATH_INFO', '/')
    method = os.environ.get('REQUEST_METHOD', 'GET')
    
    log(f"CGI request: {method} {path_info}")
    
    # 设置输出编码
    sys.stdout.reconfigure(encoding='utf-8')
    
    if path_info == '/api/scan' and method == 'POST':
        # 扫描请求
        orphan, installed = scan_all_vols()
        result = {
            "installed": installed,
            "orphan": orphan,
            "success": True
        }
        print("Content-Type: application/json")
        print("")
        print(json.dumps(result, ensure_ascii=False))
        
    elif path_info == '/api/delete' and method == 'POST':
        # 删除请求
        import cgi
        content_length = int(os.environ.get('CONTENT_LENGTH', 0))
        body = sys.stdin.read(content_length) if content_length > 0 else ''
        
        try:
            payload = json.loads(body)
        except:
            payload = {}
        
        paths = payload.get('paths', [])
        delete_users = payload.get('delete_users', False)
        
        deleted = []
        failed = []
        users_deleted = []
        users_failed = []
        
        # 收集待删除的用户名
        users_to_delete = set()
        if delete_users:
            for p in paths:
                sub_name = os.path.basename(p.rstrip('/'))
                users_to_delete.add(sub_name)
                if not sub_name.endswith('-docker'):
                    users_to_delete.add(sub_name + '-docker')
                else:
                    users_to_delete.add(sub_name[:-7])
        
        # 删除目录
        for p in paths:
            try:
                if os.path.isdir(p):
                    shutil.rmtree(p)
                    deleted.append(p)
                elif os.path.isfile(p):
                    os.remove(p)
                    deleted.append(p)
                else:
                    failed.append(p)
            except Exception as e:
                log(f"Delete failed {p}: {e}")
                failed.append(p)
        
        # 删除用户
        if delete_users and users_to_delete:
            for username in users_to_delete:
                try:
                    pwd.getpwnam(username)
                    result = subprocess.run(
                        ['userdel', '-r', username],
                        capture_output=True, text=True
                    )
                    if result.returncode == 0:
                        users_deleted.append(username)
                    else:
                        users_failed.append(username)
                except KeyError:
                    pass  # 用户不存在
                except Exception:
                    users_failed.append(username)
        
        result = {
            "deleted": deleted,
            "failed": failed,
            "total": len(deleted),
            "failures": len(failed),
            "users_deleted": users_deleted,
            "users_failed": users_failed
        }
        print("Content-Type: application/json")
        print("")
        print(json.dumps(result, ensure_ascii=False))
        
    elif path_info == '/api/version':
        print("Content-Type: application/json")
        print("")
        print(json.dumps({"version": VERSION}, ensure_ascii=False))
        
    else:
        print("Status: 404 Not Found")
        print("Content-Type: text/plain")
        print("")
        print("API endpoint not found")

if __name__ == '__main__':
    main()
