# 清理精灵 CGI

> 扫描 FnOS 所有 vol 目录，找出已卸载但残留目录的孤立应用，一键清理。

[![Platform](https://img.shields.io/badge/platform-FnOS-blue)](https://www.fnnas.com/)
[![License](https://img.shields.io/badge/license-MIT-yellow)](LICENSE)

## 功能特性

- **智能扫描** — 自动发现系统所有存储卷（`/vol1` ~ `/vol10` 及 `@app*` 目录），交叉比对已安装应用列表与实际文件目录
- **孤立目录检测** — 精准识别已卸载应用但残留文件目录的情况
- **批量清理** — 支持勾选批量删除，带确认弹窗与路径预览，可选同步删除关联系统用户
- **明暗主题** — 支持手动切换、自动跟随系统主题，深夜时段（22:00-06:00）自动启用深色模式
- **响应式布局** — 适配桌面端与移动端
- **轻量架构** — 纯 Bash CGI 实现，无 Python/Flask 依赖

## 界面预览

- KPI 卡片展示扫描统计（孤立应用数、已安装数、涉及卷数）
- 表格形式展示孤立目录，含复选框批量选择
- 确认弹窗显示待删除路径，支持关联用户同步清理
- 展开/折叠已安装应用列表

## 技术架构

```
App.Native.FnClearup/
├── manifest               # FnOS 应用清单
├── app/
│   ├── api.sh             # Bash CGI API（核心业务逻辑）
│   └── ui/
│       ├── index.cgi      # CGI 入口，路由 /api/* 和静态文件
│       └── www/
│           ├── index.html       # 前端入口（SEO meta、defer JS）
│           ├── css/style.css    # 样式（CSS 变量系统，支持亮/暗主题）
│           ├── js/main.js       # 前端逻辑（IIFE 命名空间封装）
│           └── images/          # 图标资源
├── cmd/                   # FnOS 生命周期脚本
│   ├── install_init       # 安装初始化
│   ├── install_callback   # 安装完成回调
│   ├── upgrade_init       # 升级初始化
│   ├── upgrade_callback   # 升级完成回调
│   ├── uninstall_init     # 卸载初始化
│   ├── uninstall_callback # 卸载完成回调
│   ├── config_init        # 配置初始化
│   └── config_callback    # 配置变更回调
├── config/
│   ├── resource           # 资源配置
│   └── privilege          # 权限配置
└── wizard/
    └── uninstall          # 卸载向导
```

### 后端 API

| 接口 | 方法 | 说明 |
|------|------|------|
| `/api/ping` | GET | 心跳检测，返回版本信息 |
| `/api/scan` | POST | 扫描孤立目录，返回已安装应用与孤立目录列表 |
| `/api/delete` | POST | 删除指定路径列表（可选同步删除用户） |

### 前端技术

- **HTML5** — 语义化标签，SEO meta，`defer` 异步加载脚本
- **CSS3** — CSS 变量系统（颜色/阴影/圆角/间距），`@media` 响应式布局，`prefers-color-scheme` 深色模式，`prefers-reduced-motion` 减少动画
- **Vanilla JS** — IIFE 命名空间封装，HTML 转义防 XSS，fetch API 调用后端

## 构建与打包

```bash
# 打包 fnpack
cd /app/dist/data/fnclearup-cgi
/app/dist/data/tool-bin/fnpack build .

# 输出文件
App.Native.FnClearup.fpk
```

## 安装

将 `App.Native.FnClearup.fpk` 上传至 FnOS 应用中心安装。

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| [v0.2.0](https://github.com/Wyf841015/fnclearup-cgi/compare/v0.1.5...v0.2.0) | 2026-04-30 | 修复删除目录失败: 使用jq解析paths数组、chattr -i移除不可变属性、追加日志写入 |
| [v0.1.5](https://github.com/Wyf841015/fnclearup-cgi/compare/v0.1.4...v0.1.5) | 2026-04-30 | 前端审计修复: XSS防护、label for、WCAG AA对比度优化 |
| [v0.1.4](https://github.com/Wyf841015/fnclearup-cgi/compare/v0.1.3...v0.1.4) | 2026-04-30 | CSS变量化重构、JS IIFE命名空间封装、SEO增强 |
| [v0.1.3](https://github.com/Wyf841015/fnclearup-cgi/compare/v0.1.2...v0.1.3) | 2026-04-30 | 拆分js和css到外部文件 |
| v0.1.2 | 2026-04-30 | 第一版发布 |

## 维护者

- 作者：[@一零一二](https://gitee.com/wyf1015)
- 主页：https://gitee.com/wyf1015/fnclearupcgi

---

> 如果这个项目对您有帮助，欢迎赞助支持 ❤️
