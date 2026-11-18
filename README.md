# Context Window Monitor (`context`)

为 **Google Antigravity** 打造的实时上下文窗口监控插件，提供 `/context` 零模型调用桌面卡片弹窗与右侧辅助栏（Aux Pane）实时监控面板。

## 功能特性

- **零模型调用直出 `/context` 弹窗**
  - 通过 `PreInvocation` Hook 在调用模型前直接拦截 `/context` 命令，不消耗模型请求或 Token，也不在聊天流留下多余前缀。
  - 自动读取 `~/.gemini/config/config.json` 中的 `themeMode`（浅色 / 深色 / 跟随系统）与自定义主题种子色（`customThemeSeedsLight` / `customThemeSeedsDark`），与客户端配色保持一致。
  - 支持标题栏拖拽、右上角 `✕` 及 `Esc` 一键关闭。
- **右侧辅助栏（Aux Pane）实时 Sidecar 面板**
  - 每 1.5 秒基于文件 `mtime/size` 与 `etag` 增量轮询本地 `transcript.jsonl`，自动适配客户端深浅色主题。
  - 展示双色分段进度条（基础系统开销 vs 会话累计增量）、四宫格指标卡片、SVG 上下文增长趋势曲线、倒序调用步数明细表。
  - **新会话自动识别**：新建空白对话时自动清零增量并展示预计首轮基础开销，不会串入上一对话的数据。
- **五大「基础系统开销」详细拆解**
  - **System & Native Tools**：系统核心协议指令与内置工具声明。
  - **Skills**：动态扫描用户独立 Skills、已启用插件 Skills 与系统内置 Skills 的摘要与全文估算。
  - **Rules / Instructions**：扫描 `GEMINI.md`、`AGENTS.md` 与已启用插件规则。
  - **MCP**：扫描已挂载 MCP 服务的工具 Schema 与说明文件。
  - **Plugins**：展示 Marketplace 目录开销及各已启用插件的组件归因汇总。

## 安装方式（Windows）

### 方式一：通过 Git 克隆（推荐）

在 PowerShell 中执行以下命令将插件克隆到 Antigravity 全局插件目录：

```powershell
git clone https://github.com/HiAsh02/antigravity-context-plugin.git "$env:USERPROFILE\.gemini\config\plugins\context"
```

### 方式二：下载 Release 压缩包

1. 前往 [Releases](https://github.com/HiAsh02/antigravity-context-plugin/releases) 下载最新的 `context-plugin-v1.0.0.zip`。
2. 解压到 `%USERPROFILE%\.gemini\config\plugins\context\`（确保 `plugin.json` 直接位于该目录下）。

> Antigravity 会自动发现并启用全局插件，新开一轮对话即可生效；可在客户端 Customizations 页面管理插件开关与启用右侧 `Context` Sidecar 面板。

## 使用方法

1. **快捷弹窗**：在任意对话输入框中发送 `/context`，立即弹出与客户端同主题的上下文统计卡片（不触发模型调用）。
2. **右侧常驻面板**：在右侧辅助栏打开 **Context** 面板，随对话过程实时查看上下文变化曲线与步数明细。
3. **自然语言分析**：如需让模型结合当前上下文给出压缩或优化建议，直接用自然语言提问（如“分析当前会话的 Token 消耗趋势”）。

## 目录结构

```text
context/
├── plugin.json                              # 插件清单
├── hooks.json                               # PreInvocation 生命周期钩子配置
├── README.md                                # 说明文档
├── assets/
│   └── logo.svg                             # 插件图标
├── sidecars/
│   └── context_monitor/                     # 右侧 Aux Pane 实时监控 Web Sidecar
│       ├── sidecar.json
│       ├── package.json
│       ├── main.mjs
│       ├── index.html
│       ├── styles.css
│       └── app.js
└── skills/
    └── context/
        ├── SKILL.md                         # /context Skill 定义与菜单补全入口
        └── scripts/
            ├── get-context-usage.ps1        # 会话 transcript.jsonl 解析统计脚本
            ├── pre-invocation.ps1           # /context PreInvocation Hook 拦截入口
            └── show-context-hud.ps1         # 自适应客户端主题的 WPF 卡片弹窗
```
