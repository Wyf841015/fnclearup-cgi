# FnOS 开发指南笔记

基于 https://developer.fnnas.com/docs/category/开发指南

## 应用架构概述

### 目录结构（安装后）
```
/var/apps/[appname]/
├── cmd/          # 生命周期脚本
├── config/       # 配置文件(privilege, resource)
├── wizard/       # 用户向导配置
├── target/       # 应用可执行文件 (link to /volN/@appcenter/[appname])
├── etc/          # 静态配置 (link to /volN/@appconf/[appname])
├── var/          # 运行时数据 (link to /volN/@appdata/[appname])
├── tmp/          # 临时文件 (link to /volN/@apptemp/[appname])
├── home/         # 用户数据 (link to /volN/@apphome/[appname])
├── shares/       # 数据共享目录
├── manifest      # 应用元数据
└── LICENSE       # 隐私协议(可选)
```

### FPK 打包结构（fnpack 标准）
```
myapp/
├── app/           # → 解压到 target/ 目录的内容
│   ├── ui/        # Web 界面目录 (由 desktop_uidir 指定)
│   │   ├── config        # 应用入口配置
│   │   ├── index.html    # 入口页面
│   │   └── ...
│   └── ...        # 其他可执行文件
├── cmd/           # 生命周期脚本 (直接放根目录)
├── config/        # 应用配置 (直接放根目录)
├── manifest       # 应用元数据 (关键文件)
├── wizard/        # 用户向导
├── ICON.PNG       # 64x64 应用图标
└── ICON_256.PNG   # 256x256 应用图标
```

**注意**: cmd/ 和 config/ 必须放在项目根目录，不要放在 app/ 内部。

## manifest 文件

关键字段：
- `appname`: 唯一标识符（如 `App.Native.FnClearup`）
- `version`: 版本号（如 `0.3.0`）
- `display_name`: 显示名称
- `arch`: `x86_64` / `arm` / `all`（all 用于纯脚本应用如 CGI）
- `source`: 固定为 `thirdparty`
- `desktop_uidir`: UI 目录，默认为 `ui`
- `desktop_applaunchname`: 桌面入口 ID

## 应用入口配置 (app/ui/config)

```json
{
    ".url": {
        "App.Native.FnClearup.Application": {
            "title": "清理精灵",
            "icon": "images/icon_{0}.png",
            "type": "iframe",
            "protocol": "http",
            "url": "/",
            "allUsers": true
        }
    }
}
```

**type=iframe 时**: URL 填 `/`，由 fnOS App Center 处理路由
**type=url 时**: URL 填完整路径，会在新标签页打开

## CGI 应用开发

### URL 路由机制

FnOS App Center 将请求路由到 `index.cgi`，通过以下规则：

1. 桌面图标点击 → iframe 或新标签页打开
2. iframe 方式: URL `/` 由 index.cgi 处理
3. API 请求通过 index.cgi 代理

### CGI 脚本要点

**HTTP 响应格式（关键！）**:
```bash
# HTTP 头必须使用 CRLF (\r\n)
# 正确:
printf "Status: 200 OK\\r\\n"
printf "Content-Type: application/json\\r\\n"
printf "\\r\\n"

# 错误 - 单引号中的 \n 是字面值:
printf '%s\\n' 'Status: 200'   # 产生 "Status: 200\\n" (LF + 字面值)

# body 用 LF 结尾:
printf '{"success": true}\\n'
```

**API 代理模式** (index.cgi → api.sh):
```bash
# index.cgi 接收 REL_PATH = "api/scan"
# 转发给 api.sh:
export PATH_INFO="/scan"
export REQUEST_METHOD="POST"
RESPONSE=$(bash "$API_SH" < "$BODY_TMP")

# api.sh 返回格式:
#   Status: 200 OK\r\n
#   Content-Type: application/json\r\n
#   \r\n
#   {"json": "body"}
```

**CGI 环境变量**:
- `PATH_INFO`: URL 路径（如 `/scan`）
- `REQUEST_METHOD`: `GET` 或 `POST`
- `REQUEST_URI`: 完整 URI（含查询参数）
- `SCRIPT_FILENAME`: 脚本路径
- `CONTENT_LENGTH`: 请求体长度

### Bash CGI 注意事项

1. **永远用双引号配合 `\r\n`**: `printf "Status: 200\\r\\n"`
2. **不用单引号配合 `\n`**: `printf '%s\n'` 会产生字面值 `\` `n`
3. **body 读取**: `dd bs=1 count="${CONTENT_LENGTH}"` 而非 `cat`
4. **数组UTF-8**: bash 4.x 多字节字符索引有 bug，用 `awk` 解析

## 生命周期脚本 (cmd/)

| 脚本 | 调用时机 | 常见用途 |
|------|----------|----------|
| install_init | 安装前 | 检查依赖、显示协议 |
| install_callback | 安装后 | 初始化配置 |
| upgrade_init | 升级前 | 备份数据 |
| upgrade_callback | 升级后 | 数据迁移 |
| config_init | 配置变更前 | 读取新配置 |
| config_callback | 配置变更后 | 通知应用配置变更 |
| uninstall_init | 卸载前 | 清理提示 |
| uninstall_callback | 卸载后 | 清理数据 |
| main | 状态检查/启停 | start/stop/status |

### cmd/main 状态返回值
- `exit 0`: 运行中
- `exit 3`: 未运行
- `exit 1`: 错误

## 权限配置 (config/privilege)

```json
{
    "defaults": {
        "run-as": "root"
    }
}
```

- `package`: 应用专用用户（安全，默认）
- `root`: root 权限（需申请）

**fnclearup 需要 root 权限**来扫描文件系统中的孤立目录。

## 环境变量

| 变量 | 说明 |
|------|------|
| `TRIM_APPNAME` | 应用名 |
| `TRIM_APPVER` | 版本号 |
| `TRIM_APPDEST` | 可执行文件目录 |
| `TRIM_PKGETC` | 配置目录 |
| `TRIM_PKGVAR` | 运行时数据目录 |
| `TRIM_PKGTMP` | 临时文件目录 |
| `TRIM_SERVICE_PORT` | 服务端口 |
| `TRIM_USERNAME` | 应用用户名 |
| `TRIM_RUN_USERNAME` | 执行脚本的用户 |
| `TRIM_TEMP_LOGFILE` | 临时日志（写入错误信息） |

## fnpack CLI

```bash
# 创建项目
fnpack create <appname>

# 打包
fnpack build <directory>

# 打包校验规则:
# - manifest 必须存在
# - cmd/ 脚本必须有执行权限
# - ICON.PNG 和 ICON_256.PNG 必须存在
```

## appcenter-cli

```bash
# 安装
appcenter-cli install-fpk app.fpk

# 从本地目录安装（开发用）
appcenter-cli install-local

# 列出已安装应用
appcenter-cli list

# 启动/停止
appcenter-cli start <appname>
appcenter-cli stop <appname>
```

## 中间件依赖

在 manifest 中声明 `install_dep_apps`:
- `redis`: Redis 服务
- `minio`: MinIO 对象存储
- `rabbitmq`: RabbitMQ 消息队列
- `python312` 等: 运行时环境

## 数据共享 (config/resource)

```json
{
    "data-share": {
        "shares": [
            {
                "name": "myapp/data",
                "permission": {
                    "rw": ["myapp"]
                }
            }
        ]
    }
}
```

## 已知问题与解决方案

1. **HTTP 头 CRLF**: 必须用 `printf "Header: value\\r\\n"`，单引号 + `\n` 错误
2. **bash UTF-8 bug**: 多字节字符数组索引有问题，用 `awk` 代替
3. **FnOS CLI CRLF**: `appcenter-cli list` 输出有 `\r`，需要 `sed 's/\r$//'`
4. **Unicode 分隔符**: FnOS CLI 用 Unicode `│` (U+2502)，需要 `sed 's/│/|/g'`
5. **awk 字段**: `sed 's/│/|/g'` 后，每行以 `|` 开头，`$1` 为空，`$2` 是 app 名，`$3` 是显示名
6. **mawk 限制**: FnOS 只有 `awk`（mawk），`gawk` 不可用
