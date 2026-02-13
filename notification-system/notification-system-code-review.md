# 通知系统完整代码审计报告

> 审计时间: 2026-02-13T22:30+08:00
> 审计方式: 三个并行 subagent 分层审计（主流程 / 窗口激活 / 工具库）
> 审计范围: `notification-system/` 全部 7 个 PowerShell 脚本 + BurntToast 模块源码交叉验证

---

## 审计总览

| 级别 | 数量 | 最终处理 |
|------|------|---------|
| P0 致命 | 3 | 修 1 / 跳 2（本地受信场景无攻击面） |
| P1 重要 | 9 | 修 2 / 跳 7（过度审计） |
| P2 改进 | 2 | 全部跳过 |
| **合计** | **14** | **修 3 / 跳 11** |

---

## P0 致命

### P0-1. ToolInfo 双重 XML 转义 — 用户可见显示 Bug

- **文件**: `Lib/Transcript.ps1:147`
- **置信度**: 95%
- **处理**: ✅ 需修复

```powershell
# 第 147 行
$Detail = $Detail -replace "&", "&amp;" -replace "<", "&lt;" -replace ">", "&gt;"
```

**问题**: `Format-ClaudeToolInfo` 手动将 `&` 转义为 `&amp;`。但返回值经 `New-BTText -Text $ToolInfo` 赋给 `AdaptiveText.Text` 后，UWP Toolkit 的 `ToastContent.GetContent()` 在序列化 XML 时**再次自动转义**。

**复现链路**:
- 输入: `echo <hello> & world`
- 手动转义: `echo &lt;hello&gt; &amp; world`
- UWP 再转义: `echo &amp;lt;hello&amp;gt; &amp;amp; world`
- Toast 显示: `echo &lt;hello&gt; &amp; world`（乱码）

**影响范围**: 所有包含 `&`、`<`、`>` 的 Bash 命令（如 `echo a && b`、管道命令等）。

**证据**: Toast.ps1:96 注释明确写 `# BurntToast 内部已做 XML 转义，不需要手动替换 & 为 &amp;`，说明开发者已知此事但 `Format-ClaudeToolInfo` 中的手动转义未同步移除。

经 BurntToast 1.1.0 源码验证: `New-BTText` (`BurntToast.psm1:1670-1674`) 直接赋值 `AdaptiveText.Text`，`New-BTContent` (`BurntToast.psm1:903-951`) 通过 `ToastContent.GetContent()` 序列化时自动 XML 转义。

**修复**: 删除该行。

---

### P0-2. `tool_name` / `NotificationType` 未编码直接嵌入命令行

- **文件**: `Launcher.ps1:200, 152, 213`
- **置信度**: 90%
- **处理**: ⏭️ 跳过（本地受信源）

```powershell
# 第 200 行 — tool_name 直接拼入命令行
$ToolNameArg = "-ToolName `"$($Payload.tool_name)`""

# 第 152 行 — NotificationType 直接取值
$NotificationType = $Payload.notification_type

# 第 213 行 — 未编码嵌入 Start-Process ArgumentList
$WorkerProc = Start-Process "pwsh" ... -ArgumentList "... -NotificationType `"$NotificationType`" ... $ToolNameArg ..."
```

**对比**: Title/Message 用 Base64，ProjectName/TranscriptPath/AudioPath 用 URI 编码，`tool_name` 和 `NotificationType` 完全裸露。

**跳过理由**: 输入来自 Claude Code hooks payload（本地受信源）。`tool_name` 值为 `"Bash"`、`"Read"`、`"Task"` 等 Claude Code 内部标识符。攻击者需先控制本机 Claude Code 进程，此时已有完全控制权，注入 `tool_name` 无额外收益。

---

### P0-3. `CreateToolhelp32Snapshot` 返回值检查错误

- **文件**: `Lib/Native.ps1:180`
- **置信度**: 95%
- **处理**: ✅ 需修复（降级为 P1 执行，因本地极少触发）

```csharp
hSnapshot = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
if (hSnapshot == IntPtr.Zero) return 0;  // BUG: 应检查 INVALID_HANDLE_VALUE (-1)
```

**问题**: `CreateToolhelp32Snapshot` 失败返回 `INVALID_HANDLE_VALUE` 即 `new IntPtr(-1)`，而非 `IntPtr.Zero`。当前检查永远不会命中失败分支。

**后果**:
1. 失败时继续用无效句柄 `-1` 调用 `Process32First` → 未定义行为
2. `finally` 中 `hSnapshot != IntPtr.Zero` 对 `-1` 为 true → 对无效句柄调用 `CloseHandle`

**同文件对比**: 第 148 行 `SendConsoleKey` 正确检查了 `new IntPtr(-1)`，说明作者了解此模式但在 `GetParentPid` 中遗漏。

**修复**: 改为检查 `new IntPtr(-1)`，finally 同步修正。

---

## P1 重要

### P1-1. `SendConsoleKey` 失败路径控制台泄漏

- **文件**: `Lib/Native.ps1:143-145`
- **置信度**: 85%
- **处理**: ⏭️ 跳过

```csharp
public static bool SendConsoleKey(uint pid, char key) {
    FreeConsole();                           // 断开自身控制台
    if (!AttachConsole(pid)) return false;   // 失败 → 直接 return，绕过 finally
    try { ... } finally { FreeConsole(); }
}
```

**问题**: `AttachConsole` 失败时 `return false` 在 `try` 之前，`finally` 不执行。当前进程已 `FreeConsole()` 但未重新附加。

**跳过理由**: ProtocolHandler 是 `runner.vbs` 以 `-WindowStyle Hidden` 启动的后台进程，本身没有可见控制台。`FreeConsole()` 对无控制台进程是 no-op。

---

### P1-2. B2a 标题注入 catch 缺 `FreeConsole`

- **文件**: `ProtocolHandler.ps1:86-88`
- **置信度**: 82%
- **处理**: ✅ 需修复

```powershell
try {
    [WinApi]::FreeConsole() | Out-Null
    if ([WinApi]::AttachConsole([uint32]$PidArg)) {
        [Console]::Title = $WindowTitle      # 第 78 行 — 可能异常
        [Console]::Write("`e]0;$WindowTitle`a")
        [WinApi]::FreeConsole() | Out-Null
    }
} catch {
    Write-DebugLog "PROTOCOL: Title re-injection failed: $_"
    # 缺少 [WinApi]::FreeConsole()
}
```

**问题**: 第 78-79 行异常时 catch 只记日志，不调 `FreeConsole()`。进程残留在目标 Console 上。

**修复**: catch 块首行加 `[WinApi]::FreeConsole() | Out-Null`。

---

### P1-3. `ClickWindowCenter` 使用废弃 `mouse_event` + 光标跳动

- **文件**: `Lib/Native.ps1:69-78`
- **置信度**: 80%
- **处理**: ⏭️ 跳过

```csharp
public static void ClickWindowCenter(IntPtr hWnd) {
    RECT rect;
    if (!GetWindowRect(hWnd, out rect)) return;
    int x = (rect.Left + rect.Right) / 2;
    int y = rect.Top + (int)((rect.Bottom - rect.Top) * 0.6);
    SetCursorPos(x, y);       // 物理移动光标
    mouse_event(0x0002, ...); // 废弃 API
    mouse_event(0x0004, ...);
}
```

**跳过理由**:
1. `mouse_event` 虽被标记废弃但仍可用，企业安全策略限制场景不适用于个人本地工具
2. 用户刚点了 Toast 通知正在切窗口，光标移动到目标窗口是预期行为

---

### P1-4. `$Info` 变量在 `$TranscriptPath` 分支外被引用

- **文件**: `Worker.ps1:175`
- **置信度**: 85%
- **处理**: ⏭️ 跳过

```powershell
if ($TranscriptPath) {
    $Info = Get-ClaudeTranscriptInfo ...   # 仅在此分支赋值
}

# 分支外引用
if ($Info -and $Info.ResponseTime) { ... }   # 第 175 行
```

**跳过理由**: PowerShell 默认非 StrictMode，未定义变量为 `$null`，`$null -and ...` 短路为 `$false`，行为正确。仅 `Set-StrictMode -Version Latest` 时报错，当前代码未启用。

---

### P1-5. NotifyIcon（Balloon Fallback）资源泄漏

- **文件**: `Lib/Toast.ps1:72-87`
- **置信度**: 85%
- **处理**: ⏭️ 跳过

```powershell
$balloon = New-Object System.Windows.Forms.NotifyIcon
$balloon.Visible = $true
$balloon.ShowBalloonTip(5000)
Start-Sleep -Milliseconds 100
# 缺少 $balloon.Dispose()
```

**跳过理由**: 这是 BurntToast 未安装时的 fallback 路径。Worker 进程发完通知立即退出，Windows 在进程退出时回收所有句柄。系统托盘的"幽灵图标"鼠标悬停即消失。

---

### P1-6. Watchdog 焦点检测 `-like` 通配符误判

- **文件**: `Worker.ps1:68`
- **置信度**: 82%
- **处理**: ⏭️ 跳过

```powershell
if ($CurrentTitle -like "*$TitleForFocusCheck*") { return $true }
```

**问题**: 项目名含 `[`、`]`、`?`、`*` 时被解释为通配符。如 `my-app[v2]` 中 `[v2]` 变成字符类。

**跳过理由**: 项目名含通配符特殊字符的概率极低。焦点检测本身是尽力而为的功能，误判最多导致多发或少发一次通知。

---

### P1-7. UniqueId 去重 Hash Source 碰撞

- **文件**: `Worker.ps1:191-200`
- **置信度**: 80%
- **处理**: ⏭️ 跳过

```powershell
$HashSource = if ($TranscriptPath) { "$TranscriptPath||$Title" } else { "$ProjectName||$Title" }
```

**问题**: 无 `$TranscriptPath` 且 `$Title` 为默认值时，所有通知共享同一 UniqueId，后者替换前者。

**跳过理由**: Stop hooks 的 payload 始终包含 `transcript_path`。无 TranscriptPath 仅在极端降级路径出现（如 Launcher 解析失败），此时通知内容本身也是残缺的。

---

### P1-8. 日志并发写入无锁

- **文件**: `Lib/Common.ps1:38-42`
- **置信度**: 85%
- **处理**: ⏭️ 跳过

```powershell
"[$((Get-Date).ToString('HH:mm:ss'))] $Msg" | Out-File $DebugLog -Append -Encoding UTF8
```

**跳过理由**: 调试日志仅在 `$EnableDebug` 开启时写入。并发冲突丢失一行日志无功能影响。大多数调用点有外层 try/catch 保护。

---

### P1-9. SensitiveFields 正则注入

- **文件**: `Lib/Transcript.ps1:23-25`
- **置信度**: 82%
- **处理**: ⏭️ 跳过

```powershell
foreach ($field in $SensitiveFields) {
    if ($str -match "(?i)$field\s*[=:]") { return $true }
}
```

**问题**: `$SensitiveFields` 值直接嵌入正则表达式。含 `.`/`+`/`[` 时被解释为正则语法。

**跳过理由**: 默认值在 `Config.ps1:73-80` 硬编码为 `api_key`、`password`、`token` 等纯字母下划线字符串，不含正则元字符。用户自行修改 Config 的场景极少。

---

## P2 改进

### P2-1. Test-IsDefaultTitle Braille 范围过度匹配

- **文件**: `Lib/Common.ps1:68`
- **置信度**: 80%
- **处理**: ⏭️ 跳过

```powershell
'^[\u2800-\u28FF]'    # 以 Braille 字符开头 = Claude Code 动画前缀
```

匹配任何 Braille 开头标题。实际用途是识别 Claude Code 对话摘要标题（如 `⠐ 多智能体审查`）。用户几乎不会用 Braille 字符命名项目。

---

### P2-2. SHA256 对象未 Dispose

- **文件**: `Worker.ps1:193`
- **置信度**: 80%
- **处理**: ⏭️ 跳过

Worker 是短生命周期进程（发完 Toast 即退出），进程退出时 GC 自动回收。

---

## 审计通过项

以下方面经审查未发现问题：

- **Base64 编解码链**: Launcher 编码 → Worker 解码，UTF-8 一致
- **URI 编解码链**: `EscapeDataString` 编码 → `UnescapeDataString` 解码，对称正确
- **JSONL 解析健壮性**: `Get-Content -Tail 50` 限制读取量 + 逐行 try/catch
- **P/Invoke 结构体**: `INPUT_RECORD`、`KEY_EVENT_RECORD`、`PROCESSENTRY32`、`RECT` 布局全部正确
- **三层降级策略**: HWND → PID+UIA → Title Search，覆盖合理
- **双重标题验证**: ProtocolHandler 发按键前两次 `GetWindowText` 校验，防止误发
- **Watchdog FreeConsole**: finally 块确保释放
- **BurntToast 模块加载**: 三级 fallback（指定路径 → 默认导入 → PSModulePath → Balloon）
- **Config.ps1 集中化**: 魔法数字集中管理，带默认值 fallback
- **Transcript UserEntryCount**: 限制回溯深度，避免解析无关旧消息
- **Test-IsDefaultTitle 正则**: 无 ReDoS 风险，所有模式线性时间
- **runner.vbs URI 过滤**: 已修复为保留 `&` 和 `%` 合法 URI 字符
