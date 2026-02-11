# Notification System 架构文档

## 设计理念

Claude Code 会自动管理窗口标题（设置为对话摘要，如 `⠐ 多智能体审查`），且在用户下一次输入前不会修改。本系统利用这一特性：**读取标题而非覆盖标题**，仅在标题为默认值时 fallback 设置项目名。

## 系统架构概览

```
┌─────────────────────────────────────────────────────────────────────┐
│                        触发入口                                      │
├─────────────────────────────────────────────────────────────────────┤
│  1. Launcher.ps1 (Hook 直接调用)                                     │
│  2. runner.vbs → ProtocolHandler.ps1 (URI 协议触发)                  │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        核心组件                                      │
├─────────────────────────────────────────────────────────────────────┤
│  Launcher.ps1  →  Worker.ps1  →  Toast.ps1 (发送通知)                │
│  ProtocolHandler.ps1 (处理通知按钮点击)                              │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        支撑模块 (Lib/)                               │
├─────────────────────────────────────────────────────────────────────┤
│  Config.ps1    - 配置常量                                            │
│  Common.ps1    - 调试日志 + 标题检测                                 │
│  Native.ps1    - Windows API P/Invoke                                │
│  Transcript.ps1 - 转录文件解析                                       │
│  Toast.ps1     - BurntToast 通知发送                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 入口 1: Launcher.ps1 (Claude Hook 触发)

**触发场景**: Claude Code 的 Hook 机制调用

### 执行流程

1. **输入解析** (L25-59)
   - 优先级: Pipeline JSON > InputObject > 位置参数
   - 支持 JSON Payload 或传统参数模式

2. **项目名提取** (L62-71)
   - 来源优先级: `project_name` > `title` > `projectPath` > `project_dir` > `$env:CLAUDE_PROJECT_DIR`

3. **查找交互式 Shell** (L73-107)
   - 向上遍历进程树（最多 10 层）
   - 检测 Claude 进程链 (`claude|node|claude-code`)
   - 找到 Claude 之后的第一个 Shell (`cmd|pwsh|powershell|bash`)
   - 使用 `WinApi::GetParentPid()` P/Invoke 快速遍历

4. **读取窗口标题** (L109-141)
   - `AttachConsole()` 附加到目标 Shell，读取当前窗口标题
   - 调用 `Test-IsDefaultTitle()` 检测标题类型:
     - **默认值** (Claude Code / PowerShell / cmd 等) → 设置为项目名作为 fallback
     - **非默认值** (Claude Code 已设置的对话摘要) → 直接使用，不修改
   - 将 `$ActualTitle` 传给 Worker 用于焦点检测和 Toast URI

5. **启动 Worker** (L207-210)
   - 编码参数 (Base64 + URI Escape)
   - 传递 `-ActualTitle` 参数
   - `Start-Process pwsh -WindowStyle Hidden` 启动后台进程
   - 可选 `-Wait` 模式等待 Worker 完成

---

## 入口 2: runner.vbs + ProtocolHandler.ps1 (URI 协议触发)

**触发场景**: 用户点击 Toast 通知或按钮

### register-protocol.ps1 (一次性注册)

注册 `claude-runner://` URI 协议到 Windows 注册表:
```
HKCU:\Software\Classes\claude-runner\shell\open\command
→ wscript.exe "runner.vbs" "%1"
```

### runner.vbs (安全包装器)

**安全过滤** (L8-21):
- 移除危险字符: `" & | ; ` $ ( ) % < > \r \n`
- 防止命令注入

**路径验证** (L27-36):
- 验证 HandlerPath 在预期目录内
- 验证文件存在

**启动 PowerShell** (L39-40):
- `pwsh -WindowStyle Hidden -File ProtocolHandler.ps1 "uri_args" -EnableDebug`

### ProtocolHandler.ps1 (协议处理器)

**参数解析** (L14-28):
- `hwnd=<数字>` - 窗口句柄
- `pid=<数字>` - 进程 ID
- `windowtitle=<编码字符串>` - 窗口标题

**窗口激活策略** (L31-100):

| 策略 | 条件 | 方法 |
|------|------|------|
| A | 有 HWND | `IsWindow()` 验证 → `ShowWindow(SW_RESTORE)` → `SetForegroundWindow()` |
| B | 有 PID | `Get-Process` → 获取 MainWindowHandle → 同上 |
| B Fallback | PID 但无窗口句柄 | `WScript.Shell.AppActivate(PID)` |
| C | 有 WindowTitle | `Get-Process` 搜索匹配标题 → 同上 |

**按钮动作处理** (L102-139):

当 URI 包含 `action=approve` 时:
1. 等待 250ms 让窗口获得焦点
2. **双重窗口验证**:
   - 第一次检查当前窗口标题是否匹配
   - 等待 50ms
   - 第二次检查（减少竞态条件）
3. 验证通过后发送 `SendKeys("1")` (模拟按下 "1" 键)
4. **安全措施**: 无 WindowTitle 时禁止发送按键

---

## Worker.ps1 (后台工作进程)

### 执行流程

1. **参数解码** (L31-56)
   - Base64 解码 Title/Message/ToolInput
   - URI 解码 ProjectName/TranscriptPath/AudioPath/ActualTitle

2. **焦点检测** (L58-83)
   - 使用 `$ActualTitle` 匹配前台窗口标题
   - 在 Delay 期间每秒检测一次
   - **如果用户聚焦 → 立即退出，不发送通知**
   - 不修改窗口标题（Claude Code 自行管理）

3. **最终焦点检查** (L85-89)
   - 再次检查用户是否聚焦
   - 聚焦则退出，不发送通知

4. **内容提取** (L91-169)

   **Payload 优先** (来自 Hook 直接传入):
   - `Get-ClaudeContentFromPayload()` 格式化工具信息

   **Transcript 补充** (来自转录文件):
   - `Get-ClaudeTranscriptInfo()` 提取:
     - 用户问题 → Title (`Q: ...`)
     - 工具调用 → ToolInfo (`[Bash] ls -la`)
     - 助手回复 → Description
     - 响应时间 → 前缀到 ToolInfo
     - 通知类型 → NotificationType

5. **发送 Toast** (L175-182)
   - 使用 `$ActualTitle`（实际窗口标题）构建 URI
   - 调用 `Send-ClaudeToast()`

---

## Toast.ps1 (通知发送模块)

### BurntToast 加载 (L44-87)

1. 尝试指定路径
2. 尝试 `Import-Module BurntToast`
3. 搜索 PSModulePath + 常见路径
4. **Fallback**: 使用 Windows 系统托盘气球通知

### 通知构建 (L89-159)

| 元素 | 内容 |
|------|------|
| 标题 | 用户问题 (`Q: ...`) |
| 第二行 | 工具信息 (`[Bash] ls -la`) |
| 第三行 | 助手回复描述 |
| Logo | `~/.claude/assets/claude-logo.png` |
| 点击动作 | `claude-runner:focus?windowtitle=...&pid=...` |
| 按钮 | `Proceed` (权限提示时) + `Dismiss` |

### 音频逻辑 (L97-106)

- 自定义 AudioPath > 权限提示专用音频 > 默认系统音
- 权限提示: `$env:USERPROFILE\OneDrive\Aurora.wav`

### 通知场景

`Scenario Reminder` - 通知会持久显示，不会自动消失

---

## 支撑模块详解

### Config.ps1 - 配置常量

| 类别 | 配置项 | 默认值 |
|------|--------|--------|
| 路径 | DEBUG_LOG_PATH | `~/.claude/toast_debug.log` |
| 路径 | LOGO_PATH | `~/.claude/assets/claude-logo.png` |
| 路径 | PERMISSION_AUDIO_PATH | `~/OneDrive/Aurora.wav` |
| 时间 | SENDKEYS_DELAY_MS | 250 |
| 时间 | WORKER_TIMEOUT_MS | 30000 |
| 长度 | TOOL_DETAIL_MAX_LENGTH | 400 |
| 长度 | MESSAGE_MAX_LENGTH | 800 |
| 长度 | TITLE_MAX_LENGTH | 60 |
| 敏感 | SENSITIVE_FIELDS | api_key, password, token... |

### Common.ps1 - 调试日志 + 标题检测

**调试日志** (`Write-DebugLog`):
- 遍历 Scope 0-5 查找 `$EnableDebug` 参数
- 也支持 `$env:CLAUDE_HOOK_DEBUG=1` 环境变量

**默认标题检测** (`Test-IsDefaultTitle`):
- Claude Code 动态标题: `* Claude Code`, `· Claude Code`, `✻ Claude Code`
- Claude Code Braille 动画前缀: `⠐`, `⠑`, `⠒` 等 (Unicode \u2800-\u28FF)
- Claude Code 目录格式: `claude - <目录>`
- Shell 默认标题: `PowerShell`, `cmd`, `pwsh` 等
- Shell 可执行文件路径: `\\cmd.exe`, `\\powershell.exe`, `\\pwsh.exe`
- 返回 `$true` = 默认值（需要 fallback），`$false` = Claude Code 已设置有意义的标题

### Native.ps1 - Windows API

| API | 用途 |
|-----|------|
| `AttachConsole/FreeConsole` | 附加/分离控制台 |
| `GetForegroundWindow` | 获取当前焦点窗口 |
| `GetWindowText` | 获取窗口标题 |
| `SetForegroundWindow` | 激活窗口 |
| `IsIconic/ShowWindow` | 检测/恢复最小化窗口 |
| `IsWindow` | 验证窗口句柄有效性 |
| `GetParentPid` | 获取父进程 ID (Toolhelp32Snapshot) |

### Transcript.ps1 - 转录解析

**敏感信息检测** (`Test-SensitiveContent`):
- 字段名模式: `api_key=`, `password:` 等
- 值模式: `sk-xxx`, `ghp_xxx`, `AKIA...`, JWT 等

**工具信息格式化** (`Format-ClaudeToolInfo`):

| 工具类型 | 格式化结果 |
|----------|------------|
| Task (subagent) | `[SubagentType] description` |
| MCP (mcp__server__tool) | `[ToolName] command/query/path` |
| Bash | `[Bash] command` |
| Grep | `[Grep] Search: pattern` |
| Read/Write/Edit | `[Read] filename` |
| WebSearch | `[WebSearch] Search: query` |

---

## 所有运行情况汇总

### 情况 1: Claude Code 已设置对话标题 (主要场景)

```
Hook 触发 → Launcher.ps1
  → 找到 Shell PID
  → 读取当前标题 "⠐ 多智能体审查" (Claude Code 已设置)
  → Test-IsDefaultTitle() 返回 false → 直接使用
  → 启动 Worker.ps1 -ActualTitle "⠐ 多智能体审查"
    → 焦点检测使用 "⠐ 多智能体审查" 匹配
    → 用户未聚焦 → 发送 Toast 通知
    → 用户点击 Toast → ProtocolHandler 用该标题找到窗口
```

### 情况 2: 标题为默认值 (Fallback 场景)

```
Hook 触发 → Launcher.ps1
  → 读取当前标题 "PowerShell" (默认值)
  → Test-IsDefaultTitle() 返回 true
  → Fallback: 设置标题为项目名 "hooks"
  → 启动 Worker.ps1 -ActualTitle "hooks"
    → 焦点检测使用 "hooks" 匹配
```

### 情况 3: 用户已聚焦 (不发送通知)

```
Hook 触发 → Launcher.ps1 → Worker.ps1
  → 焦点检测命中
  → exit 0 (不发送通知)
```

### 情况 4: 权限提示 (带 Proceed 按钮)

```
Hook 触发 (notification_type=permission_prompt)
  → Worker.ps1 → Send-ClaudeToast()
    → 显示带 "Proceed" 按钮的通知
    → 播放 Aurora.wav 音频
    → 用户点击 "Proceed"
      → runner.vbs → ProtocolHandler.ps1
        → 激活窗口
        → 双重验证窗口标题
        → SendKeys("1") 自动批准
```

### 情况 5: 无 BurntToast 模块 (Fallback)

```
Worker.ps1 → Send-ClaudeToast()
  → Import-Module BurntToast 失败
  → 使用 System.Windows.Forms.NotifyIcon
  → 显示系统托盘气球通知
```

### 情况 6: 无 Shell PID (降级模式)

```
Launcher.ps1
  → 未找到交互式 Shell
  → 无法读取标题
  → Worker.ps1 使用项目名作为 fallback
  → 发送通知
```

### 情况 7: URI 协议直接触发

```
用户点击 claude-runner://... 链接
  → runner.vbs (安全过滤)
  → ProtocolHandler.ps1
    → 解析 hwnd/pid/windowtitle
    → 激活对应窗口
    → 处理 action=approve (如有)
```

### 情况 8: 安全拦截 (无 WindowTitle)

```
ProtocolHandler.ps1 收到 action=approve
  → 但 URI 中无 windowtitle 参数
  → 拒绝发送 SendKeys
  → 记录日志 "No WindowTitle provided. Aborting SendKeys for security."
```

### 情况 9: 窗口竞态条件检测

```
ProtocolHandler.ps1 收到 action=approve
  → 第一次验证窗口标题匹配
  → 等待 50ms
  → 第二次验证窗口标题
  → 标题变化 → 拒绝发送 SendKeys
  → 记录日志 "Window changed during verification"
```

---

## 文件结构

```
notification-system/
├── Launcher.ps1          # 入口：Hook 触发，读取标题，启动 Worker
├── Worker.ps1            # 后台进程：焦点检测 + 内容提取 + 发送通知
├── ProtocolHandler.ps1   # URI 协议处理：窗口激活 + 按钮动作
├── runner.vbs            # VBS 包装器：安全过滤 + 启动 PowerShell
├── register-protocol.ps1 # 一次性：注册 URI 协议
├── Lib/
│   ├── Config.ps1        # 配置常量
│   ├── Common.ps1        # 调试日志 + 标题检测
│   ├── Native.ps1        # Windows API P/Invoke
│   ├── Transcript.ps1    # 转录文件解析
│   └── Toast.ps1         # BurntToast 通知发送
└── ARCHITECTURE.md       # 本文档
```
