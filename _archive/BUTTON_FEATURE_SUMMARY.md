# Toast 按钮功能实现总结

## 一、需求概述

**提出时间**: 2026-02-07

**原始需求**:
在 permission prompt 的 toast 通知中添加 3 个交互按钮：
1. **同意** (Allow) - 输入数字 1
2. **总是同意** (Always Allow) - 输入数字 2
3. **不同意** (Deny) - 输入数字 3

点击按钮后：
- 聚焦到 Claude Code 窗口
- 自动模拟输入对应的数字（1/2/3）

---

## 二、实现的功能

### 2.1 XML 模板修改（已实现）

**文件**: `C:\Users\Xiao\.claude\hooks\windows-notification.ps1`

**位置**: 第 151-174 行

```xml
<actions>
  <action content="Allow" launch="$ButtonUri1" activationType="protocol" />
  <action content="Always Allow" launch="$ButtonUri2" activationType="protocol" />
  <action content="Deny" launch="$ButtonUri3" activationType="protocol" />
</actions>
```

每个按钮的 launch URI 包含：
- `hwnd`: 窗口句柄
- `pid`: 进程 ID
- `beacon`: 信标标题（用于定位 tab）
- `notification_type`: `permission_prompt`
- `button`: 按钮编号（1/2/3）

### 2.2 协议处理（已实现）

**文件**: `C:\Users\Xiao\.claude\hooks\protocol-handler.ps1`

**功能**:
1. 解析 URI 参数，包括 `button` 参数
2. 使用 UI Automation 聚焦到正确的 tab
3. 使用鼠标点击模拟设置键盘焦点
4. 使用 `SendKeys` 模拟输入对应的数字

**关键代码**:
```powershell
# 解析 button 参数
if ($UriArgs -match "button=(\d+)") {
    $ButtonNumber = [int]$Matches[1]
}

# 模拟鼠标点击设置焦点
[MouseApi]::SetCursorPos($clickX, $clickY)
[MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
[MouseApi]::mouse_event([MouseApi]::MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)

# 模拟键盘输入
[System.Windows.Forms.SendKeys]::SendWait("$ButtonNumber")
```

### 2.3 焦点管理（已实现并测试通过）

用户确认焦点功能正常工作，点击 toast 后能正确聚焦到 Claude Code 窗口并可输入。

---

## 三、遇到的问题

### 3.1 Toast 内容显示问题（未解决）

**问题描述**: Toast 显示为默认的"终端 新通知"，而不是自定义的内容（问题和命令详情）

**预期显示**:
- 标题: `Q: 帮我看下D盘的根目录都有什么文件夹`
- 内容: `[Bash] dir /b D:\ - List folders in D drive root`
- 按钮: Allow / Always Allow / Deny

**实际显示**:
- 标题: `终端`
- 内容: `新通知`
- 按钮: 不显示

**日志确认**: XML 生成正确，包含完整内容和按钮定义，但 Windows 不使用自定义 XML

### 3.2 双重提示音问题（部分解决）

**原因**: 脚本中存在重复的 toast 显示代码

**状态**: 已删除重复代码，但用户报告仍听到两个提示音（系统默认 + 自定义音频）

### 3.3 AppId 配置问题（未解决）

**尝试的方案**:
1. ❌ 使用自定义 AppId `ClaudeCode.ClaudeCode`
   - 问题: Windows 不识别，toast 显示默认内容

2. ❌ 使用 PowerShell AppId
   - 问题: Toast 不显示

3. ❌ 创建快捷方式并设置 AppUserModelId
   - 问题: COM 接口不可用，无法设置属性

4. ❌ 使用 Windows Terminal AppId 并修改注册表 DisplayName
   - 问题: 仍显示默认的"终端"样式

---

## 四、技术分析

### 4.1 根本原因

Windows 11 对带按钮的 toast 通知有特殊处理：
- 当使用某些 AppId 时，Windows 会强制使用默认模板
- 自定义 XML 内容被忽略，显示为默认的"新通知"

### 4.2 已验证可行的部分

1. ✅ XML 模板生成正确
2. ✅ 协议激活工作正常（claude-runner: 协议已注册）
3. ✅ 按钮参数传递正确
4. ✅ 窗口焦点功能正常
5. ✅ SendKeys 输入功能正常

### 4.3 问题所在

**核心问题**: Windows 对带按钮 toast 的显示控制

- 无按钮的 toast（Stop hook）: 显示正常 ✅
- 有按钮的 toast（Permission prompt）: 显示默认内容 ❌

这表明问题不是 XML 或 AppId 配置，而是 Windows 对带交互按钮的 toast 有不同的渲染策略。

---

## 五、修改的文件清单

| 文件 | 修改类型 | 说明 |
|------|----------|------|
| `windows-notification.ps1` | 修改 | 添加按钮检测、XML 模板、URI 参数 |
| `protocol-handler.ps1` | 修改 | 添加 button 参数解析、SendKeys 输入 |
| `settings.json` | 未修改 | permission_prompt hook 配置保持不变 |

---

## 六、新增的文件清单

| 文件 | 用途 |
|------|------|
| `register-toast-appid.ps1` | 注册自定义 AppId（失败） |
| `create-shortcut.ps1` | 创建快捷方式（多次修改） |
| `clear-toast-cache.ps1` | 清除 toast 缓存 |
| `fix-shortcut-appid.ps1` | 设置快捷方式 AppId（失败） |
| `fix-terminal-appid.ps1` | 修改 Windows Terminal AppId |
| `CLEANUP_GUIDE.md` | 清理指南 |
| `BUTTON_FEATURE_SUMMARY.md` | 本文档 |

---

## 七、注册表变更

### 新增
- `HKCU:\Software\Classes\AppUserModelId\ClaudeCode.ClaudeCode`
  - DisplayName: Claude Code
  - IconUri: ...
  - BackgroundColor: 1F1F1F
  - ToastActivatorCLSID: {00000000-0000-0000-0000-000000000000}

### 修改
- `HKCU:\Software\Classes\AppUserModelId\Microsoft.WindowsTerminal_8wekyb3d8bbwe!App`
  - DisplayName: Claude Code（原为空或默认值）
  - IconUri: ...（新增）

### 快捷方式
- `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk`
  - Target: PowerShell.exe
  - 图标: Claude logo

---

## 八、当前状态

| 功能 | 状态 | 说明 |
|------|------|------|
| 按钮显示 | ❌ | 按钮不显示，toast 使用默认样式 |
| 焦点管理 | ✅ | 点击后正确聚焦窗口 |
| 按钮参数解析 | ✅ | protocol-handler 正确解析 button 参数 |
| 数字模拟输入 | ✅ | SendKeys 功能正常 |
| Toast 内容显示 | ❌ | 显示"新通知"而非自定义内容 |

---

## 九、可能的后续方案

### 方案 A: 使用 BurntToast 模块
```powershell
Install-Module -Name BurntToast
# BurntToast 是 PowerShell 社区模块，对 toast 有更好的控制
```

### 方案 B: 创建一个实际的包装程序
- 编写一个小的 C# 或 Rust 可执行文件
- 该程序作为真正的"应用"注册到 Windows
- 通过该程序显示 toast

### 方案 C: 使用 Windows App SDK
- 使用 Windows App SDK 创建一个打包的应用
- 完全控制 toast 通知的显示

### 方案 D: 接受当前限制
- 保持不带按钮的 toast（显示正确内容）
- 用户点击后手动输入数字

---

## 十、时间线

| 时间 | 事件 |
|------|------|
| 05:14 | 用户提出添加 3 个按钮的需求 |
| 05:15-05:20 | 实现按钮 XML 模板和 URI 参数 |
| 05:20-05:25 | 实现协议处理和 SendKeys 功能 |
| 05:25 | 焦点功能测试通过 |
| 05:27-05:30 | 发现 toast 显示"终端 新通知"问题 |
| 05:30-06:05 | 尝试多种 AppId 配置方案 |
| 06:05 | 所有方案均失败，暂停修改 |

---

## 十一、日志文件

- Toast 调试日志: `C:\Users\Xiao\.claude\toast_debug.log`
- 协议处理日志: `C:\Users\Xiao\.claude\protocol_debug.log`
