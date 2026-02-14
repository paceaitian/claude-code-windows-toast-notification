# Claude Code Windows Hooks

为 [Claude Code](https://github.com/anthropics/claude-code) 定制的 Windows Hook 工具集。

## 目录

- [Notification System](#notification-system) — 智能 Toast 通知 + 窗口激活
- [Bash Permission Enforcer](#bash-permission-enforcer) — 强制执行 Bash 权限规则

---

## Notification System

高性能、上下文感知的 Windows Toast 通知系统。当 Claude Code 需要用户关注时（权限请求、任务完成），自动发送桌面通知并支持一键切换回对应 Tab。

### 核心特性

- **极速启动**: 模块化设计 + P/Invoke，通知延迟 ~1 秒
- **智能内容**: 解析 Transcript 提取用户问题、工具调用、AI 回复
- **Tab 切换**: 点击通知自动激活 Windows Terminal 对应 Tab（UIA 自动化）
- **一键审批**: 权限请求通知带 Approve 按钮，点击直接发送确认键
- **焦点检测**: 用户已在窗口前时自动跳过通知
- **标题注入**: Watchdog 每秒注入项目名，对抗 Claude Code 的 OSC 标题覆盖
- **去重机制**: 基于内容哈希的 UniqueId 防止重复通知

### 架构

```
Hook 触发 (Notification/Stop)
    │
    ▼
Launcher.ps1          # 入口：注入标题，启动后台 Worker
    │
    ▼
Worker.ps1            # 后台：Watchdog 焦点检测 → 解析 Payload/Transcript → 发送 Toast
    ├── Lib/Config.ps1       # 配置常量（延迟、截断长度等）
    ├── Lib/Common.ps1       # 调试日志、Test-IsDefaultTitle、工具函数
    ├── Lib/Transcript.ps1   # Transcript JSONL 解析、工具信息格式化、Markdown 清理
    ├── Lib/Toast.ps1        # BurntToast 通知构建、URI 协议绑定
    └── Lib/Native.ps1       # Win32 P/Invoke（窗口操作、进程树、控制台 API）

用户点击 Toast
    │
    ▼
runner.vbs → ProtocolHandler.ps1   # URI 协议处理：Tab 切换、标题注入、Approve 按键
```

### Toast 内容格式

```
┌──────────────────────────────────────┐
│ Q: 用户的问题                          │  ← Title (从 Transcript 提取最新用户消息)
│ A: [02:05] [Bash] git push           │  ← ToolInfo (工具名 + 命令/路径, 最多 2 行)
│ 已推送到远程。收工！                    │  ← Description (AI 回复文本)
│                    [Approve] [Focus]  │  ← 按钮 (权限请求时显示 Approve)
└──────────────────────────────────────┘
```

### 安装

**1. 安装依赖**

```powershell
Install-Module BurntToast -Scope CurrentUser
```

**2. 注册 URI 协议（管理员权限，一次性）**

```powershell
cd ~/.claude/hooks/notification-system
.\register-protocol.ps1
```

**3. 配置 `~/.claude/settings.json`**

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "permission_prompt",
        "hooks": [{
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"if ($env:CLAUDE_NO_NOTIFICATION -ne '1' -and -not (Test-Path '.claude/no-notification')) { $input | & 'C:/Users/Xiao/.claude/hooks/notification-system/Launcher.ps1' -AudioPath 'C:/Users/Xiao/OneDrive/Aurora.wav' -Delay 10 -EnableDebug }\""
        }]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [{
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"if ($env:CLAUDE_NO_NOTIFICATION -ne '1' -and -not (Test-Path '.claude/no-notification')) { $input | & 'C:/Users/Xiao/.claude/hooks/notification-system/Launcher.ps1' -AudioPath 'C:/Users/Xiao/OneDrive/Aurora.wav' -Delay 20 -EnableDebug }\""
        }]
      }
    ]
  }
}
```

### 参数

| 参数 | 说明 |
| :--- | :--- |
| `-AudioPath` | 自定义通知音效文件路径 |
| `-Delay` | 延迟秒数（权限请求建议 10，Stop 建议 20） |
| `-EnableDebug` | 开启调试日志 `~/.claude/toast_debug.log` |

### 静音控制

- **环境变量**: `CLAUDE_NO_NOTIFICATION=1`
- **项目级**: 在项目 `.claude/` 目录下创建 `no-notification` 空文件

### 测试

```powershell
cd ~/.claude/hooks/notification-system
# 回归测试（50+ 用例）
pwsh -NoProfile -ExecutionPolicy Bypass -File _regression_test.ps1
# E2E 测试（60+ 用例）
pwsh -NoProfile -ExecutionPolicy Bypass -File _e2e_test.ps1
```

---

## Bash Permission Enforcer

绕过 Claude Code 的 [Bash 权限匹配 bug](https://github.com/anthropics/claude-code/issues/25441)，直接读取 `settings.json` 权限规则并强制执行。

### 问题背景

Claude Code 的原生权限系统存在已知缺陷：
- 通配符不匹配多行/heredoc 命令（[#25441](https://github.com/anthropics/claude-code/issues/25441)）
- 通配符不匹配含重定向符（`2>&1`）的命令（[#13137](https://github.com/anthropics/claude-code/issues/13137)）
- Deny 规则可通过命令变体绕过（如 `git -C /path reset --hard`）
- 前缀匹配与通配符匹配行为不一致（[#18961](https://github.com/anthropics/claude-code/issues/18961)）

### 工作原理

```
Claude Code 调用 Bash 工具
    │
    ▼
PreToolUse Hook 触发 (matcher: "Bash")
    │
    ▼
enforce-bash-permissions.ps1
    ├── 读取 settings.json 的 permissions.allow / permissions.deny
    ├── 将多行命令折叠为单行（修复原生 bug）
    ├── 先检查 deny 规则（优先级最高）→ 返回 deny
    ├── 再检查 allow 规则 → 返回 allow
    └── 无匹配 → 不返回决定，交由原生权限系统处理
```

### 规则匹配

脚本读取 `settings.json` 中的标准 Claude Code 权限格式：

```json
{
  "permissions": {
    "allow": [
      "Bash(ls *)",
      "Bash(echo *)",
      "Bash(git log *)"
    ],
    "deny": [
      "Bash(rm -rf *)"
    ]
  }
}
```

**匹配逻辑：**
- `Bash(ls)` → 精确匹配 `ls`
- `Bash(ls *)` → 匹配 `ls` 开头的任意命令（`ls -la`、`ls /tmp` 等）
- `Bash` → 匹配所有 Bash 命令
- 多行命令自动折叠为单行后匹配（原生系统无法做到）
- Deny 规则优先于 Allow 规则

### 配置

在 `~/.claude/settings.json` 的 hooks 中添加：

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{
          "type": "command",
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File C:/Users/Xiao/.claude/hooks/enforce-bash-permissions.ps1"
        }]
      }
    ]
  }
}
```

### 行为示例

| 命令 | 规则 | Hook 决定 | 原生系统 |
| :--- | :--- | :--- | :--- |
| `ls -la` | `Bash(ls *)` ✅ | allow | 跳过 |
| `echo hello` | `Bash(echo *)` ✅ | allow | 跳过 |
| `rm -rf /tmp` | `Bash(rm -rf *)` ❌ | **deny** | 跳过 |
| `git status` | 无匹配 | 无决定 | 弹窗询问 |
| 多行 heredoc | `Bash(cat *)` ✅ | allow（折叠后匹配） | 匹配失败 |

---

## 故障排查

| 问题 | 排查方法 |
| :--- | :--- |
| Toast 不出现 | 添加 `-EnableDebug`，查看 `~/.claude/toast_debug.log` |
| 点击通知无反应 | 运行 `Start-Process "claude-runner://test"` 检查协议注册 |
| BurntToast 缺失 | `Install-Module BurntToast -Scope CurrentUser` |
| 权限 hook 不生效 | 重启 Claude Code（settings.json 的 hooks 变更需要重启） |
| Tab 切换失败 | 检查日志中的 `PROTOCOL:` 行，确认 UIA 是否找到窗口 |

## 依赖

- Windows 11
- PowerShell 7+ (`pwsh`)
- [BurntToast](https://github.com/Windos/BurntToast) PowerShell 模块
- Windows Terminal（Tab 切换依赖 UIA 自动化）
