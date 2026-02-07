# Claude Code Toast 通知清理指南

本文档记录了为设置自定义 Toast 通知而创建的所有文件和注册表项。

---

## 一、注册表项

### 1. AppUserModelId 注册
**路径**: `HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode`

**创建内容**:
| 属性 | 值 | 类型 |
|------|-----|------|
| DisplayName | Claude Code | String |
| IconUri | C:\Users\Xiao\.claude\assets\claude-logo.png | String |
| BackgroundColor | 1F1F1F | String |
| ToastActivatorCLSID | {00000000-0000-0000-0000-000000000000} | String |

**清理命令**:
```powershell
# 删除整个 AppUserModelId 项
Remove-Item "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode" -Recurse -Force
```

---

## 二、快捷方式文件

### 快捷方式位置
**路径**: `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk`

**完整路径**: `C:\Users\Xiao\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk`

**清理命令**:
```powershell
# 删除快捷方式
Remove-Item "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk" -Force
```

---

## 三、脚本文件

以下脚本被创建在 `C:\Users\Xiao\.claude\hooks\` 目录：

| 文件名 | 用途 |
|--------|------|
| register-toast-appid.ps1 | 注册 AppUserModelId 到注册表 |
| create-shortcut.ps1 | 创建开始菜单快捷方式 |

**注意**: 这些脚本文件不会影响系统功能，可以保留或删除。

**清理命令**:
```powershell
# 删除脚本文件（可选）
Remove-Item "C:\Users\Xiao\.claude\hooks\register-toast-appid.ps1" -Force
Remove-Item "C:\Users\Xiao\.claude\hooks\create-shortcut.ps1" -Force
```

---

## 四、完整清理脚本

将以下命令复制到 PowerShell 中执行，可一次性清理所有相关内容：

```powershell
# Claude Code Toast 清理脚本
Write-Host "正在清理 Claude Code Toast 相关内容..." -ForegroundColor Cyan

# 1. 删除注册表项
if (Test-Path "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode") {
    Remove-Item "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode" -Recurse -Force
    Write-Host "✓ 已删除注册表项" -ForegroundColor Green
} else {
    Write-Host "○ 注册表项不存在，跳过" -ForegroundColor Gray
}

# 2. 删除快捷方式
$ShortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk"
if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "✓ 已删除快捷方式" -ForegroundColor Green
} else {
    Write-Host "○ 快捷方式不存在，跳过" -ForegroundColor Gray
}

# 3. 删除脚本文件（可选）
$HookDir = "C:\Users\Xiao\.claude\hooks"
$ScriptFiles = @("register-toast-appid.ps1", "create-shortcut.ps1")
foreach ($File in $ScriptFiles) {
    $FilePath = Join-Path $HookDir $File
    if (Test-Path $FilePath) {
        Remove-Item $FilePath -Force
        Write-Host "✓ 已删除脚本: $File" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "清理完成！" -ForegroundColor Green
Write-Host "注意: Toast 通知可能需要注销/重新登录或重启 Windows 后才能完全生效。" -ForegroundColor Yellow
```

---

## 五、验证清理结果

```powershell
# 验证注册表是否已删除
Write-Host "检查注册表..."
if (Test-Path "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode") {
    Write-Host "✗ 注册表项仍然存在" -ForegroundColor Red
} else {
    Write-Host "✓ 注册表项已删除" -ForegroundColor Green
}

# 验证快捷方式是否已删除
Write-Host "检查快捷方式..."
$ShortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk"
if (Test-Path $ShortcutPath) {
    Write-Host "✗ 快捷方式仍然存在: $ShortcutPath" -ForegroundColor Red
} else {
    Write-Host "✓ 快捷方式已删除" -ForegroundColor Green
}
```

---

## 六、创建时间线

| 时间 | 操作 | 文件/位置 |
|------|------|-----------|
| 2026-02-07 05:45 | 首次注册 AppUserModelId | 注册表 |
| 2026-02-07 05:48 | 添加 ToastActivatorCLSID | 注册表 |
| 2026-02-07 05:49 | 创建快捷方式（尝试1） | 开始菜单 |
| 2026-02-07 05:50 | 创建快捷方式（尝试2-多次） | 开始菜单 |
| 2026-02-07 05:54 | 修改注册表，添加 ToastActivatorCLSID | HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode |
| 2026-02-07 05:56 | 修改 create-shortcut.ps1（第1版） | C:\Users\Xiao\.claude\hooks\create-shortcut.ps1 |
| 2026-02-07 05:57 | 修改 create-shortcut.ps1（第2版 - C# 代码） | C:\Users\Xiao\.claude\hooks\create-shortcut.ps1 |
| 2026-02-07 05:58 | 创建 clear-toast-cache.ps1 | C:\Users\Xiao\.claude\hooks\clear-toast-cache.ps1 |
| 2026-02-07 05:59 | 修改 create-shortcut.ps1（第3版 - 指向 PowerShell.exe） | C:\Users\Xiao\.claude\hooks\create-shortcut.ps1 |
| 2026-02-07 06:00 | 运行 clear-toast-cache.ps1 | 清除 ActionCenter 缓存 |
| 2026-02-07 06:04 | 创建 fix-shortcut-appid.ps1 | C:\Users\Xiao\.claude\hooks\fix-shortcut-appid.ps1 |
| 2026-02-07 06:04 | 创建 fix-terminal-appid.ps1 | C:\Users\Xiao\.claude\hooks\fix-terminal-appid.ps1 |
| 2026-02-07 06:05 | 修改 Windows Terminal AppId 注册表 | HKCU:\Software\Classes\AppUserModelId\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App |
| 2026-02-07 06:05 | 修改 windows-notification.ps1 使用 Windows Terminal AppId | C:\Users\Xiao\.claude\hooks\windows-notification.ps1 |

---

## 七、完整文件和注册表清单

### 注册表项

| 路径 | 用途 | 状态 |
|------|------|------|
| `HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode` | 自定义 AppId 配置 | 已创建 |
| `HKCU:\Software\Classes\AppUserModelId\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App` | Windows Terminal AppId（已修改 DisplayName） | 已修改 |

### 文件

| 路径 | 用途 | 状态 |
|------|------|------|
| `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk` | 开始菜单快捷方式 | 已创建 |
| `C:\Users\Xiao\.claude\hooks\register-toast-appid.ps1` | 注册 AppUserModelId 脚本 | 已创建 |
| `C:\Users\Xiao\.claude\hooks\create-shortcut.ps1` | 创建快捷方式脚本（多次修改） | 已创建 |
| `C:\Users\Xiao\.claude\hooks\clear-toast-cache.ps1` | 清除 Toast 缓存脚本 | 已创建 |
| `C:\Users\Xiao\.claude\hooks\fix-shortcut-appid.ps1` | 设置快捷方式 AppId 脚本（失败） | 已创建 |
| `C:\Users\Xiao\.claude\hooks\fix-terminal-appid.ps1` | 修改 Windows Terminal AppId 脚本 | 已创建 |
| `C:\Users\Xiao\.claude\hooks\windows-notification.ps1` | 主通知脚本 | 已修改 |
| `C:\Users\Xiao\.claude\hooks\CLEANUP_GUIDE.md` | 本清理指南 | 已创建 |

---

## 八、当前配置状态

### windows-notification.ps1 当前配置
- **AppId**: `Microsoft.WindowsTerminal_8wekyb3d8bbwe!App`
- **问题**: 使用 Windows Terminal AppId 会显示默认的"终端"标题和"新通知"内容

### 注册表状态
1. **ClaudeCode.ClaudeCode** - 自定义 AppId，但 Windows 不识别其快捷方式
2. **WindowsTerminal** - DisplayName 已改为"Claude Code"，但 toast 仍显示默认内容

### 已知问题
1. ❌ Toast 内容显示为"新通知"而非自定义 XML 内容
2. ❌ Toast 标题显示为"终端"而非"Claude Code"
3. ❌ 听到两个提示音（系统默认 + 自定义音频）

---

## 九、完整清理脚本（更新版）

```powershell
# Claude Code Toast 完整清理脚本
Write-Host "正在清理 Claude Code Toast 相关内容..." -ForegroundColor Cyan

# 1. 删除自定义 AppId 注册表项
if (Test-Path "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode") {
    Remove-Item "HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode" -Recurse -Force
    Write-Host "✓ 已删除 ClaudeCode.ClaudeCode 注册表项" -ForegroundColor Green
} else {
    Write-Host "○ ClaudeCode.ClaudeCode 注册表项不存在，跳过" -ForegroundColor Gray
}

# 2. 恢复 Windows Terminal AppId 的 DisplayName
$WtAppId = "HKCU:\Software\Classes\AppUserModelId\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
if (Test-Path $WtAppId) {
    # 删除自定义的 DisplayName（恢复默认）
    Remove-ItemProperty -Path $WtAppId -Name "DisplayName" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $WtAppId -Name "IconUri" -ErrorAction SilentlyContinue
    Write-Host "✓ 已恢复 Windows Terminal AppId 默认配置" -ForegroundColor Green
} else {
    Write-Host "○ Windows Terminal AppId 注册表项不存在" -ForegroundColor Gray
}

# 3. 删除快捷方式
$ShortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk"
if (Test-Path $ShortcutPath) {
    Remove-Item $ShortcutPath -Force
    Write-Host "✓ 已删除快捷方式" -ForegroundColor Green
} else {
    Write-Host "○ 快捷方式不存在，跳过" -ForegroundColor Gray
}

# 4. 删除脚本文件
$HookDir = "C:\Users\Xiao\.claude\hooks"
$ScriptFiles = @(
    "register-toast-appid.ps1",
    "create-shortcut.ps1",
    "clear-toast-cache.ps1",
    "fix-shortcut-appid.ps1",
    "fix-terminal-appid.ps1",
    "CLEANUP_GUIDE.md"
)
foreach ($File in $ScriptFiles) {
    $FilePath = Join-Path $HookDir $File
    if (Test-Path $FilePath) {
        Remove-Item $FilePath -Force
        Write-Host "✓ 已删除: $File" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "清理完成！" -ForegroundColor Green
Write-Host "注意: 如需完全恢复，建议重启 Windows。" -ForegroundColor Yellow
```
