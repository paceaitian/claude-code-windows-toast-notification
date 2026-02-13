# Notification System 端到端测试指南

> 最后更新：2026-02-13 v4.4（UIA Tab 切换 + SendConsoleKey + A: 前缀）

## 测试环境

- **OS**: Windows 11
- **Shell**: PowerShell 7 (pwsh)
- **依赖**: BurntToast 模块、UIAutomationClient (.NET)
- **日志**: `~/.claude/toast_debug.log`
- **Claude Code Hook 配置** (`~/.claude/settings.json`):
  - `Notification` (matcher: `permission_prompt`): Delay=10, EnableDebug
  - `Stop` (matcher: 全部): Delay=20, EnableDebug

---

## 测试准备

```powershell
# 确认 BurntToast 可用
Import-Module BurntToast -ErrorAction Stop

# 清空日志
"" | Set-Content "$env:USERPROFILE\.claude\toast_debug.log"

# 另开终端实时查看日志
Get-Content "$env:USERPROFILE\.claude\toast_debug.log" -Tail 30 -Wait
```

---

## 第一部分：通知格式测试

### Toast 三层结构

```
┌─────────────────────────────────────────────────┐
│ [Logo]  Line 1: Title         (MaxLines=1)      │
│         Line 2: ToolInfo      (MaxLines=1,Wrap)  │
│         Line 3: Description   (MaxLines=2,Wrap)  │
│                                                   │
│         [Proceed?] [Dismiss]                      │
└─────────────────────────────────────────────────┘
```

### T-1.1 Permission Prompt — ToolInfo + Description

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 删除临时文件"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("需要执行 rm -rf /tmp/cache"))
$B64I = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"command":"rm -rf /tmp/cache","description":"清理临时缓存目录"}'))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test-proj" `
    -NotificationType "permission_prompt" -ToolName "Bash" `
    -Base64ToolInput $B64I -AudioPath "$env:USERPROFILE\OneDrive\Aurora.wav" -EnableDebug
```

**预期 Toast**:
```
Line 1: Q: 删除临时文件
Line 2: A: [Bash] 清理临时缓存目录              ← "A:" 前缀，Payload 无 Transcript 所以无时间
Line 3: 需要执行 rm -rf /tmp/cache
Buttons: [Proceed] [Dismiss]
Audio: Aurora.wav
```

**日志验证**:
```
ToolInfo: A: [Bash] 清理临时缓存目录
Description: 需要执行 rm -rf /tmp/cache
```

### T-1.2 Permission Prompt — 仅 ToolInfo（最常见场景）

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: ls /c"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Task finished."))
$B64I = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"command":"ls /c","description":"列出 C:\\ 根目录"}'))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test-proj" `
    -NotificationType "permission_prompt" -ToolName "Bash" -Base64ToolInput $B64I -EnableDebug
```

**预期 Toast**:
```
Line 1: Q: ls /c
Line 2: A: [Bash] 列出 C:\ 根目录
(无 Line 3 — Message="Task finished." 被过滤)
Buttons: [Proceed] [Dismiss]
Audio: Default
```

### T-1.3 Stop 完成 — 仅 Description，有 Transcript 时间

> 模拟 Transcript 提供 ResponseTime 但无 ToolInfo 的场景

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 你好"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("你好！有什么可以帮你的？"))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test-proj" -EnableDebug
```

**预期 Toast**:
```
Line 1: Q: 你好
Line 2: A: 你好！有什么可以帮你的？              ← Description 被提升到 Line 2，加 "A:" 前缀
(无 Line 3)
Buttons: [Dismiss]
```

**日志验证**:
```
ToolInfo:                                         ← 空（无 ToolName 且无 Transcript）
Description: A: 你好！有什么可以帮你的？
```

### T-1.4 ContentGuard 拦截 — 两者都为空

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Claude Notification"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Task finished."))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test-proj" -EnableDebug
```

**预期**: **不显示 Toast**

**日志验证**:
```
ToolInfo:
Description:
ContentGuard: No Description or ToolInfo. Skipping empty toast.
```

### T-1.5 Fallback Title — 无法提取用户问题

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Claude Notification"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("全部完成。"))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "pace-test-D" -EnableDebug
```

**预期 Toast**:
```
Line 1: Claude Notification                       ← 无 Transcript 所以用默认标题
Line 2: A: 全部完成。
Buttons: [Dismiss]
```

### T-1.6 敏感信息检测

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 设置 API"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(""))
$B64I = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('{"command":"export API_KEY=sk-1234567890abcdef1234567890abcdef"}'))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test-proj" `
    -ToolName "Bash" -Base64ToolInput $B64I -EnableDebug
```

**预期 Toast**:
```
Line 1: Q: 设置 API
Line 2: A: [Bash] [内容已隐藏]                    ← 检测到 sk-xxx 模式
Buttons: [Dismiss]
```

---

## 第二部分：Format-ClaudeToolInfo 单元测试

```powershell
# 加载模块
. .\Lib\Common.ps1
. .\Lib\Transcript.ps1
```

### T-2.1 Bash — description 优先

| 输入 | 预期输出 |
|------|----------|
| `{command:"git status"}` | `[Bash] git status` |
| `{command:"git add .",description:"暂存变更"}` | `[Bash] 暂存变更` |
| `{command:"npm install",description:""}` | `[Bash] npm install` |

```powershell
# 验证命令
Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command="git status" })
Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command="git add ."; description="暂存变更" })
Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command="npm install"; description="" })
```

### T-2.2 Read/Write/Edit — 路径截取

| 输入路径 | 预期输出 |
|----------|----------|
| `C:\Users\Xiao\.claude\hooks\notification-system\Lib\Config.ps1` | `[Read] notification-system\Lib\Config.ps1` |
| `C:\test.txt` | `[Write] test.txt` |
| `C:\a\b.js` | `[Edit] a\b.js` |

```powershell
Format-ClaudeToolInfo -Name "Read" -InputObj ([PSCustomObject]@{ file_path="C:\Users\Xiao\.claude\hooks\notification-system\Lib\Config.ps1" })
Format-ClaudeToolInfo -Name "Write" -InputObj ([PSCustomObject]@{ file_path="C:\test.txt" })
Format-ClaudeToolInfo -Name "Edit" -InputObj ([PSCustomObject]@{ file_path="C:\a\b.js" })
```

### T-2.3 Skill — skill 名作为 DisplayName

| 输入 | 预期输出 |
|------|----------|
| `{skill:"commit"}` | `[Commit]` |
| `{skill:"web-artifacts-builder",args:"page.html"}` | `[Web-artifacts-builder] page.html` |
| `{skill:"usage-query-skill",description:"查询用量"}` | `[Usage-query-skill] 查询用量` |

### T-2.4 Task/Subagent

| 输入 | 预期输出 |
|------|----------|
| `{subagent_type:"general-purpose",description:"搜索代码"}` | `[General-purpose] 搜索代码` |
| `{subagent_type:"feature-dev:code-explorer",description:"分析架构"}` | `[Code-explorer] 分析架构` |

### T-2.5 MCP Tools

| 输入 | 预期输出 |
|------|----------|
| Name=`mcp__Serper__google_search`, `{q:"react docs"}` | `[Google_search] Search: react docs` |
| Name=`mcp__fetch__fetch`, `{url:"https://example.com"}` | `[Fetch] https://example.com` |

### T-2.6 Grep / WebSearch

| 输入 | 预期输出 |
|------|----------|
| Name=`Grep`, `{pattern:"TODO"}` | `[Grep] Search: TODO` |
| Name=`WebSearch`, `{query:"react 2026"}` | `[WebSearch] Search: react 2026` |

### T-2.7 XML 转义（BurntToast 内部处理）

> P0-1 修复后：`Format-ClaudeToolInfo` 不再手动 XML 转义。
> BurntToast 的 `AdaptiveText.Text` → `ToastContent.GetContent()` 自动处理 XML 转义。

```powershell
Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command="git add . && git commit" })
# 预期: [Bash] git add . && git commit    ← 原始字符，BurntToast 内部转义

Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command="echo '<html>'" })
# 预期: [Bash] echo '<html>'              ← 原始字符
```

### T-2.8 长度截断（默认 400 字）

```powershell
$long = "a" * 500
$r = Format-ClaudeToolInfo -Name "Bash" -InputObj ([PSCustomObject]@{ command=$long })
$r.Length -le 407  # [Bash] (7) + 397 + "..." (3)
$r.EndsWith("...")
```

---

## 第三部分：Transcript 解析测试

### T-3.1 正常提取 — ToolInfo + Description + Title

> 创建模拟 transcript 文件

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
@'
{"type":"user","message":{"content":"请列出根目录"},"timestamp":"2026-02-13T21:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls /","description":"列出根目录"}},{"type":"text","text":"C:\\ 根目录内容如上。🐱：喵~~~"}]},"timestamp":"2026-02-13T21:01:00Z"}
'@ | Set-Content $tmp -Encoding UTF8

. .\Lib\Common.ps1; . .\Lib\Transcript.ps1
$info = Get-ClaudeTranscriptInfo -TranscriptPath $tmp -ProjectName "test"
```

**验证**:
```powershell
$info.Title          # "Q: 请列出根目录"
$info.ToolInfo       # "[Bash] 列出根目录"
$info.Description    # "C:\ 根目录内容如上。🐱：喵~~~"
$info.ResponseTime   # "05:01" (UTC+8 → 本地时间)
```

### T-3.2 权限确认场景 — 跨 user 消息提取 ToolInfo

> 权限流程中，user 确认消息插在 tool_use 和最终 text 之间

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
@'
{"type":"user","message":{"content":"ls /c"},"timestamp":"2026-02-13T21:08:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls /c","description":"列出 C 根目录"}}]},"timestamp":"2026-02-13T21:08:01Z"}
{"type":"user","message":{"content":"<permission_response>granted</permission_response>"},"isMeta":true,"timestamp":"2026-02-13T21:09:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"C:\\ 根目录内容如上。🐱：喵~~~"}]},"timestamp":"2026-02-13T21:09:30Z"}
'@ | Set-Content $tmp -Encoding UTF8

$info = Get-ClaudeTranscriptInfo -TranscriptPath $tmp -ProjectName "test"
```

**验证**（关键测试点 — 之前的 bug 场景）:
```powershell
$info.Title          # "Q: ls /c"
$info.ToolInfo       # "[Bash] 列出 C 根目录"    ← 必须非空！跨越了 1 条 user 消息
$info.Description    # "C:\ 根目录内容如上。🐱：喵~~~"
```

### T-3.3 多个 user 消息 — 不应跨越 2 条以上

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
@'
{"type":"user","message":{"content":"第一个问题"},"timestamp":"2026-02-13T20:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo old"}}]},"timestamp":"2026-02-13T20:00:01Z"}
{"type":"user","message":{"content":"第二个问题"},"timestamp":"2026-02-13T21:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"旧回复"}]},"timestamp":"2026-02-13T21:00:01Z"}
{"type":"user","message":{"content":"第三个问题"},"timestamp":"2026-02-13T21:05:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"最新回复"}]},"timestamp":"2026-02-13T21:05:01Z"}
'@ | Set-Content $tmp -Encoding UTF8

$info = Get-ClaudeTranscriptInfo -TranscriptPath $tmp -ProjectName "test"
```

**验证**:
```powershell
$info.Title          # "Q: 第三个问题"
$info.Description    # "最新回复"
$info.ToolInfo       # $null  ← 不应提取到"第一个问题"的 tool_use（跨越了 2+ user 消息）
```

### T-3.4 Fallback Title

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
@'
{"type":"assistant","message":{"content":[{"type":"text","text":"完成了"}]},"timestamp":"2026-02-13T21:00:00Z"}
'@ | Set-Content $tmp -Encoding UTF8

$info = Get-ClaudeTranscriptInfo -TranscriptPath $tmp -ProjectName "my-project"
```

**验证**:
```powershell
$info.Title          # "Task Done [my-project]"   ← Fallback
$info.Description    # "完成了"
```

### T-3.5 用户消息以 `<` 开头 — 应跳过

```powershell
$tmp = [System.IO.Path]::GetTempFileName()
@'
{"type":"user","message":{"content":"正常问题"},"timestamp":"2026-02-13T20:58:00Z"}
{"type":"user","message":{"content":"<system-reminder>hook output</system-reminder>"},"timestamp":"2026-02-13T21:00:00Z"}
{"type":"assistant","message":{"content":[{"type":"text","text":"回复"}]},"timestamp":"2026-02-13T21:00:01Z"}
'@ | Set-Content $tmp -Encoding UTF8

$info = Get-ClaudeTranscriptInfo -TranscriptPath $tmp -ProjectName "test"
```

**验证**:
```powershell
$info.Title          # "Q: 正常问题"   ← 跳过了 <system-reminder> 开头的消息
```

---

## 第四部分：焦点检测测试

### T-4.1 用户聚焦 → 不发送

```powershell
# 将当前窗口标题设为目标
$host.UI.RawUI.WindowTitle = "focus-test"

$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 测试"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("结果"))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "focus-test" `
    -ActualTitle "focus-test" -Delay 3 -EnableDebug
```

**日志验证**: `Watchdog: User Focused at T=0. Exiting.`
**预期**: 不显示 Toast

### T-4.2 用户未聚焦 → 发送

```powershell
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 测试"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("结果"))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test" `
    -ActualTitle "不存在的窗口_xyz" -Delay 2 -EnableDebug
```

**预期**: 显示 Toast

---

## 第五部分：ProtocolHandler 窗口激活测试

### 架构说明

```
点击 Toast 体    → claude-runner:focus?windowtitle=X&pid=N
点击 Proceed    → claude-runner:approve?action=approve&pid=N&windowtitle=X
       ↓
   runner.vbs   → 启动 pwsh ProtocolHandler.ps1
       ↓
   Strategy B:  B1 爬进程树找 WT PID
                B2a AttachConsole 注入标题
                B2b UIA 搜索所有 WT 窗口 → 找到目标 tab → Select()
                B3 降级 SetForegroundWindow / AppActivate
       ↓
   Action Logic: SendConsoleKey (UIA成功) 或 SendKeys (fallback)
```

### T-5.1 UIA Tab 切换 — 多窗口搜索

**前置条件**: 打开 2+ 个 Windows Terminal 窗口，每个有不同 tab

**操作**: 在非目标窗口触发通知，点击 Toast 体

**日志验证**:
```
PROTOCOL: Target PID XXXXX
PROTOCOL: Found WT process PID YYYYY
PROTOCOL: Re-injected title 'project-name' into PID XXXXX
PROTOCOL: UIA found N WT window(s) for PID YYYYY
PROTOCOL: Activated correct WT window (HWND ZZZZZ)
PROTOCOL: UIA Selected tab 'project-name'
```

**检查**: 是否切换到了正确的 WT 窗口和 tab

### T-5.2 Proceed 按钮 — SendConsoleKey

**前置条件**: Claude Code 正在等待权限确认

**操作**: 点击 Toast 的 Proceed 按钮

**日志验证**:
```
PROTOCOL: Action 'Approve' detected.
PROTOCOL: Tab switched by UIA. SendConsoleKey(PID XXXXX) -> True
```

**检查**:
- [ ] Claude Code 收到 "1" 并继续执行
- [ ] NumLock 状态**未**被改变
- [ ] 不是 `Sending '1'...`（那是旧的 SendKeys 路径）

### T-5.3 SendConsoleKey 失败 → SendKeys 降级

**模拟**: 目标 PID 已退出时点击 Proceed

**日志验证**:
```
PROTOCOL: Tab switched by UIA. SendConsoleKey(PID XXXXX) -> False
PROTOCOL: Fallback to SendKeys...
```

### T-5.4 Title 验证分支（非 UIA 路径）

**场景**: UIA 失败，降级到 Strategy C，点击 Proceed

**日志验证**:
```
PROTOCOL: Window verified (double-check). Sending '1'...
```
或安全拦截:
```
PROTOCOL: Window mismatch. Expected 'X', got 'Y'. Aborting SendKeys.
```

### T-5.5 无 WindowTitle → 安全阻止

**日志验证**:
```
PROTOCOL: No WindowTitle provided. Aborting SendKeys for security.
```

### T-5.6 降级策略 B3

**场景**: UIA 完全失败（UIAutomationClient 加载失败等）

**日志验证**:
```
PROTOCOL: UIA failed: ...
PROTOCOL: Fallback SetForegroundWindow(WT) -> True/False
```

---

## 第六部分：URI 参数传递测试

### T-6.1 Toast URI 无 `&amp;` 双重编码

**操作**: 触发任意通知，点击 Toast 体

**日志验证**: URI 参数使用 `&`，不是 `&amp;`
```
PROTOCOL: Triggered with 'claude-runner:focus?windowtitle=hooks&pid=32892'
```

**错误示例**（不应出现）:
```
PROTOCOL: Triggered with 'claude-runner:focus?windowtitle=hooks&amppid=32892'
```

### T-6.2 Approve URI 正确

**操作**: 点击 Proceed 按钮

**日志验证**:
```
PROTOCOL: Triggered with 'claude-runner:approve?action=approve&pid=XXXXX&windowtitle=project-name'
```

---

## 第七部分：边界情况

### T-7.1 空 Payload

```powershell
'{}' | pwsh -NoProfile -ExecutionPolicy Bypass -File .\Launcher.ps1 -Delay 0 -EnableDebug -Wait
```

**预期**: 无报错，项目名使用 `Claude` 或 `$env:CLAUDE_PROJECT_DIR`

### T-7.2 超长内容截断

```powershell
$payload = @{
    tool_name = "Bash"
    tool_input = @{ command = "a" * 500; description = "长" * 300 }
    message = "b" * 1000
} | ConvertTo-Json -Depth 5

$payload | pwsh -NoProfile -ExecutionPolicy Bypass -File .\Launcher.ps1 -Delay 0 -EnableDebug -Wait
```

**预期**: Toast 正常显示，内容截断，无报错

### T-7.3 特殊字符

```powershell
$payload = @{
    tool_name = "Bash"
    tool_input = @{ command = "echo '<script>' && rm -rf /"; description = "测试 & <特殊> 字符" }
    message = '包含 "引号" 和 反斜杠\\'
    project_dir = "C:\Users\Xiao\projects\test"
} | ConvertTo-Json -Depth 5

$payload | pwsh -NoProfile -ExecutionPolicy Bypass -File .\Launcher.ps1 -Delay 0 -EnableDebug -Wait
```

**预期**: XML 转义由 BurntToast 内部处理，Toast 正常显示原始字符

### T-7.4 BurntToast 不可用 → Balloon Fallback

```powershell
# 临时移除 BurntToast
$B64T = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Q: 测试"))
$B64M = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("Fallback 测试"))

pwsh -NoProfile -ExecutionPolicy Bypass -File .\Worker.ps1 -Worker `
    -Base64Title $B64T -Base64Message $B64M -ProjectName "test" `
    -ModulePath "C:\nonexistent\path" -EnableDebug
```

**日志验证**: `BurntToast not found. Using Windows balloon fallback.`

---

## 第八部分：实际 E2E 流程测试

> 在实际 Claude Code 会话中验证

### T-8.1 简单问答 → Stop 通知

1. 在 Claude Code 中输入简单问题（如 "ls /c"）
2. 切换到其他窗口
3. 等待 20 秒

**验证**:
- [ ] Toast 显示 `Q: ls /c`
- [ ] Line 2 包含 `A:` 前缀
- [ ] 点击 Toast 体能切换回正确 tab

### T-8.2 Permission Prompt → Proceed 按钮

1. 在 Claude Code 中触发需要权限的操作（如 `ls /c` 触发 Bash 权限）
2. 切换到其他窗口
3. 等待通知出现

**验证**:
- [ ] Toast 有 [Proceed] 按钮
- [ ] 点击 Proceed 后切换到正确 tab
- [ ] Claude Code 收到 "1" 并继续执行
- [ ] NumLock 状态未变
- [ ] 日志显示 `SendConsoleKey` 而非 `SendKeys`

### T-8.3 多 Tab 场景

1. 打开 3 个 Claude Code tab（如 hooks, Dialyuse, pace-test-D）
2. 在 pace-test-D 中触发操作
3. 切换到 hooks tab 或 Chrome

**验证**:
- [ ] 点击 Toast 能切换到 pace-test-D 的正确 tab
- [ ] 不会拉起错误的窗口
- [ ] 日志显示 `UIA found N WT window(s)` 和 `Activated correct WT window`

### T-8.4 权限执行后的完成通知

1. 触发权限请求（如 `ls /c`）
2. 通过 Proceed 或手动按 1 批准
3. 等待完成通知

**验证**:
- [ ] 完成通知的 ToolInfo **非空**（应显示之前的工具信息）
- [ ] 日志中 ToolInfo 行不为空
- [ ] 如果 ToolInfo 为空 → Transcript.ps1 跨 user 消息逻辑可能有问题

---

## 测试结果检查清单

### 通知格式 (T-1)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 1.1 | Permission + ToolInfo + Desc | Line 2 有 `A:` 前缀，Line 3 有描述 | |
| 1.2 | Permission + 仅 ToolInfo | Line 2 有 `A:` 前缀，无 Line 3 | |
| 1.3 | Stop + 仅 Description | Description 提升到 Line 2，有 `A:` 前缀 | |
| 1.4 | ContentGuard 拦截 | 不显示 Toast | |
| 1.5 | Fallback Title | 标题为 `Claude Notification` | |
| 1.6 | 敏感信息 | 显示 `[内容已隐藏]` | |

### 工具格式化 (T-2)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 2.1 | Bash desc 优先 | description > command | |
| 2.2 | Read/Write/Edit 路径 | 最后 3 段 | |
| 2.3 | Skill 名称 | skill 值作为 DisplayName | |
| 2.4 | Task/Subagent | 冒号后最后一段 | |
| 2.5 | MCP 工具 | 双下划线分割取最后段 | |
| 2.6 | Grep/WebSearch | `Search: ` 前缀 | |
| 2.7 | XML 转义 | 返回原始字符（BurntToast 内部处理） | |
| 2.8 | 长度截断 | ≤400 字 + `...` | |

### Transcript 解析 (T-3)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 3.1 | 正常提取 | Title + ToolInfo + Desc 都有值 | |
| 3.2 | 跨 user 消息 | ToolInfo 非空（跨 1 条 user） | |
| 3.3 | 2+ user 消息 | ToolInfo 为空（不跨越 2+） | |
| 3.4 | Fallback Title | `Task Done [name]` | |
| 3.5 | `<` 开头跳过 | 标题取上一条正常消息 | |

### 焦点检测 (T-4)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 4.1 | 用户聚焦 | 不显示 Toast | |
| 4.2 | 用户未聚焦 | 显示 Toast | |

### ProtocolHandler (T-5)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 5.1 | UIA 多窗口搜索 | 切换到正确 tab | |
| 5.2 | SendConsoleKey | 收到 "1"，无 NumLock 副作用 | |
| 5.3 | SendConsoleKey 降级 | Fallback to SendKeys | |
| 5.4 | Title 验证 | 匹配/不匹配正确处理 | |
| 5.5 | 无 WindowTitle | 安全阻止 | |
| 5.6 | B3 降级策略 | SetForegroundWindow fallback | |

### URI 传递 (T-6)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 6.1 | Focus URI | `&pid=` 不是 `&amppid=` | |
| 6.2 | Approve URI | 参数完整 | |

### 边界情况 (T-7)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 7.1 | 空 Payload | 无报错 | |
| 7.2 | 超长内容 | 截断显示 | |
| 7.3 | 特殊字符 | XML 转义正确 | |
| 7.4 | BurntToast 缺失 | Balloon fallback | |

### E2E 实际流程 (T-8)

| # | 场景 | 关键验证 | Pass? |
|---|------|----------|-------|
| 8.1 | 简单问答 | Toast 有 A: 前缀 | |
| 8.2 | Permission + Proceed | SendConsoleKey 成功 | |
| 8.3 | 多 Tab | UIA 切换正确窗口/tab | |
| 8.4 | 权限后完成通知 | ToolInfo 非空 | |

---

## 调试技巧

```powershell
# 实时日志
Get-Content "$env:USERPROFILE\.claude\toast_debug.log" -Tail 50 -Wait

# 清空日志
"" | Set-Content "$env:USERPROFILE\.claude\toast_debug.log"

# 检查 runner.vbs 错误
$errLog = "C:\Users\Xiao\.claude\hooks\notification-system\runner-error.log"
if (Test-Path $errLog) { Get-Content $errLog } else { "无错误" }

# 手动触发 ProtocolHandler（模拟 Proceed 点击）
pwsh -NoProfile -ExecutionPolicy Bypass -File .\ProtocolHandler.ps1 `
    -UriArgs "claude-runner:approve?action=approve&pid=12345&windowtitle=test" -EnableDebug

# 检查 UIAutomation 可用性
Add-Type -AssemblyName UIAutomationClient
[System.Windows.Automation.AutomationElement]::RootElement.Current.Name
```
