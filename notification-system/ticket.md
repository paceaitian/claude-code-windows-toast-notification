# Notification System - 交接文档

> 最后更新: 2026-02-13T22:40+08:00

## 1. 系统概述

Claude Code hooks 通知系统，当 Claude Code 需要用户注意时（权限提示 / 任务完成），通过 Windows Toast 通知用户，支持点击跳转到正确的 WT tab 和一键 Approve。

**文件结构:**
```
notification-system/
├── Launcher.ps1          # 入口 — 被 hooks 调用，解析 payload，注入标题，启动 Worker
├── Worker.ps1            # 后台 — Watchdog 标题注入 + 焦点检测 + 内容构建 + 发送 Toast
├── ProtocolHandler.ps1   # 点击回调 — 响应 claude-runner:// 协议，激活窗口/切换 tab/发按键
├── Lib/
│   ├── Common.ps1        # 调试日志 + Test-IsDefaultTitle
│   ├── Config.ps1        # 集中配置（魔法数字、路径、阈值）
│   ├── Native.ps1        # Win32 P/Invoke（Console/Window/Process/Mouse API）
│   ├── Toast.ps1         # BurntToast Toast 构建 + 发送
│   └── Transcript.ps1    # JSONL 转录文件解析 + Format-ClaudeToolInfo
├── runner.vbs            # VBS 包装器（绕过 PowerShell 窗口闪烁）
├── E2E_TEST_GUIDE.md     # 端到端测试指南（30+ 用例）
└── ticket.md             # 本文件
```

---

## 2. 本次会话改动（未提交）

### 2.1 已应用的改动

| 文件 | 改动 | 状态 |
|------|------|------|
| `Worker.ps1:170-177` | 添加 "A:" 前缀（回复内容标记，与 Title 的 "Q:" 对应） | ✅ 已改，未测试 |
| `Native.ps1:111-138` | 添加 Console Input API（`WriteConsoleInputW` + `SendConsoleKey`） | ✅ 已改，未测试 |
| `Native.ps1:49-78` | 添加鼠标 API（`GetWindowRect` + `SetCursorPos` + `mouse_event` + `ClickWindowCenter`） | ✅ 已改，未测试 |
| `ProtocolHandler.ps1:132-139` | UIA 切换 tab 后点击终端区域激活输入焦点 | ✅ 已改，未测试 |
| `ProtocolHandler.ps1:195-204` | Approve 按钮改用 `SendConsoleKey` 替代 `SendKeys`（避免 NumLock） | ✅ 已改，未测试 |

### 2.2 待修复的审计发现

三轮并行 subagent 审计发现 14 个问题，经本地运行场景过滤后保留 3 个：

| # | 级别 | 文件:行 | 问题 | 修复方案 |
|---|------|---------|------|---------|
| 1 | **P0** | `Transcript.ps1:147` | **双重 XML 转义** — 手动 `& → &amp;` 后 BurntToast UWP Toolkit 再次转义，Toast 显示乱码 | 删除该行。注释已说明 BurntToast 自动处理（Toast.ps1:96） |
| 2 | P1 | `Native.ps1:180` | `CreateToolhelp32Snapshot` 失败返回 `INVALID_HANDLE_VALUE`(-1)，代码检查 `IntPtr.Zero` | 改为检查 `new IntPtr(-1)`，finally 同步修正 |
| 3 | P1 | `ProtocolHandler.ps1:87` | B2a 标题注入 catch 缺 `FreeConsole()`，异常时残留 Console attach | catch 块首行加 `[WinApi]::FreeConsole()` |

### 2.3 审计中判定为过度审计（不修）

以下 11 项在**本地运行、受信输入**场景下无实际风险，决定跳过：

- `tool_name` / `NotificationType` 命令注入 → 输入来自 Claude Code 自身 payload，无外部攻击面
- `SendConsoleKey` 失败路径控制台泄漏 → hidden 进程无 console，无影响
- `ClickWindowCenter` 光标跳动 → 用户刚点 Toast 正在切窗口，预期行为
- `$Info` 变量作用域 → PS 默认非 StrictMode，`$null -and` 短路正确
- NotifyIcon 未 Dispose → fallback 路径，进程立即退出
- 日志并发写入 → 调试日志丢一行无影响
- 焦点检测通配符 → 项目名含 `[?*` 极罕见
- SensitiveFields 正则注入 → 默认值硬编码，用户不改 Config
- UniqueId 碰撞 → 正常流程 TranscriptPath 始终存在，碰撞仅在极端降级路径
- Braille 范围过度匹配 → 用户几乎不用 Braille 字符命名项目
- SHA256 未 Dispose → 短生命周期进程，退出即回收

---

## 3. 关键设计决策

### 3.1 Watchdog 标题注入
- **为什么需要**: Claude Code 2.1.41+ 用 OSC 序列持续覆盖标题为 `* Claude Code`
- **怎么做**: Worker 通过 `AttachConsole` + `[Console]::Title` + OSC 每秒对抗
- **为什么重要**: 标题是焦点检测和 tab 切换的唯一标识

### 3.2 SendConsoleKey vs SendKeys
- **问题**: UIA `Select()` 切换 tab 后键盘焦点留在 tab 栏，`WScript.Shell.SendKeys` 发到错误目标，触发 NumLock
- **方案**: `WriteConsoleInputW` 直接写入目标进程的控制台输入缓冲区，完全绕过窗口焦点
- **降级**: `SendConsoleKey` 失败时 fallback 到 `SendKeys`

### 3.3 ClickWindowCenter 终端焦点
- **问题**: UIA 切换 tab 后用户无法立刻输入，需手动点击终端区域
- **方案**: 切换后自动 `mouse_event` 点击窗口垂直 60% 处（避开 tab 栏）
- **时序**: UIA Select → 100ms → ClickWindowCenter → SendKeysDelay → SendConsoleKey

### 3.4 数据融合 (Data Fusion)
```
Payload (tool_name/tool_input) ──→ ToolInfo (精确、快速)
                                          ↘
                                     合并：Payload 优先，Transcript 补充
                                          ↗
Transcript (JSONL 解析) ──→ Title(Q:) + Description + ResponseTime
```

### 3.5 "A:" 前缀逻辑
- ToolInfo 存在 → `"A: [时间] [工具] 详情"`
- 仅 Description → `"A: [时间] 回复文本"`
- 与 Title 的 `"Q: 用户问题"` 形成问答对

---

## 4. 下一步待办

### 优先级 1: 修复审计发现（3 项）
1. 删除 `Transcript.ps1:147` 的手动 XML 转义行
2. 修正 `Native.ps1:180` 的 `INVALID_HANDLE_VALUE` 检查
3. `ProtocolHandler.ps1:87` catch 块加 `FreeConsole()`

### 优先级 2: 测试本次改动
按 `E2E_TEST_GUIDE.md` 执行，重点验证：
- **T-5.2**: SendConsoleKey 是否正确发送 "1" 到 Claude Code（替代 SendKeys）
- **T-5.6**: ClickWindowCenter 是否让终端立刻可输入
- **T-1.1/1.2**: "A:" 前缀是否正确显示在 Toast 通知中
- **T-8.2**: 完整 E2E 流程 — 权限提示 → Toast → 点击 Proceed → 自动审批

### 优先级 3: 提交
所有测试通过后提交，建议拆分：
- commit 1: `fix(notification): 修复审计发现的代码问题`（3 项审计修复）
- commit 2: `feat(notification): 优化窗口激活和按键发送机制`（SendConsoleKey + ClickWindowCenter + A: 前缀）

---

## 5. 已知限制

- **单 WT 实例假设**: UIA 搜索所有 WT 窗口但假设同名 tab 只有一个
- **Console API 限制**: `AttachConsole` 同一时间只能 attach 一个进程
- **BurntToast 依赖**: 未安装时降级到 Balloon（功能受限，无按钮）
- **标题竞争**: Watchdog 和 Claude Code 每秒争夺标题控制权，偶尔闪烁
