# Claude Code Windows Notification System (模块化版)

一个为 [Claude Code](https://github.com/anthropics/claude-code) 量身定制的高性能、上下文感知的 Windows 通知系统。

## 🌟 核心特性 (Key Features)

*   **⚡ 极速启动**: 采用模块化设计与 P/Invoke 优化，通知延迟从 ~5秒降低至 **~1秒**。
*   **🧠 智能感知**: 能够识别工具调用、子代理 (Subagent) 任务，并区分“任务完成”与“权限请求”。
*   **🔊 智能音频**:
    *   **权限请求**: 自动播放高优先级提示音 (如 `Aurora.mp3`)，提醒您需要人工介入。
    *   **普通任务**: 使用系统默认提示音，保持低打扰。
*   **🛡️ 非阻塞运行**: 通知逻辑在后台进程中运行，确保终端立即响应。
*   **🔗 交互式点击**: 点击通知可直接激活 Claude Code 所在的窗口或标签页 (通过 `claude-runner://` 协议)。

## 📂 系统架构 (Architecture)

本系统由两个主要部分组成：

### 1. 通知子系统 (`hooks/notification-system/`)
负责生成和显示通知。
- **`Launcher.ps1`**: **启动器**。快速入口，负责注入窗口标题并启动后台 Worker。
- **`Worker.ps1`**: **后台进程**。负责解析 Transcript、播放音频和显示 Toast。
- **`Lib/Transcript.ps1`**: **解析核心**。提取上下文信息（如提取 `[Bash] rm -rf` 命令详情）。
- **`Lib/Toast.ps1`**: **UI 核心**。调用 BurntToast 显示通知，并绑定点击事件到协议。

### 2. 协议处理器 (`hooks/protocol-handler.ps1`)
负责响应通知点击事件。
- 当用户点击 Toast 通知或按钮（如 "Proceed"）时，系统触发 `claude-runner://` 协议。
- **`protocol-handler.ps1`**: 接收协议请求，自动查找并激活对应的 Windows Terminal 窗口/标签页，甚至自动发送确认键（如 `y` 或 `Enter`）。

## 🚀 安装与配置 (Installation)

### 第一步：注册协议 (一次性)
为了让点击通知能跳转回 Claude，需要注册自定义协议。
在 PowerShell (管理员) 中运行：
```powershell
cd ~/.claude/hooks
.\register-protocol.ps1
```

### 第二步：配置 Claude Code
修改 `~/.claude/settings.json`，添加以下 Hooks 配置：

```json
"hooks": {
  "Notification": [
    {
      "hooks": [{
        "command": "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"if ($env:CLAUDE_NO_NOTIFICATION -ne '1' -and -not (Test-Path '.claude/no-notification')) { $input | & 'C:/Users/Xiao/.claude/hooks/notification-system/Launcher.ps1' -AudioPath 'C:/Users/Xiao/OneDrive/Aurora.wav' -Delay 10 }\"",
        "type": "command"
      }],
      "matcher": "permission_prompt"
    }
  ],
  "Stop": [
    {
        "hooks": [{
          "command": "pwsh -NoProfile -ExecutionPolicy Bypass -Command \"if ($env:CLAUDE_NO_NOTIFICATION -ne '1' -and -not (Test-Path '.claude/no-notification')) { $input | & 'C:/Users/Xiao/.claude/hooks/notification-system/Launcher.ps1' -AudioPath 'C:/Users/Xiao/OneDrive/Aurora.wav' -Delay 20 }\"",
          "type": "command"
        }],
        "matcher": ""
    }
  ]
}
```

## 🎵 音频逻辑 (Audio Logic)

系统根据以下优先级决定播放什么声音：

1.  **最高优先级：强制指定** (`-AudioPath`)
    *   如果在 `settings.json` 中传入了 `-AudioPath`，则**无论什么情况**都播放该音频。

2.  **智能默认：上下文感知** (当未指定 `-AudioPath` 时)
    *   **权限请求 (Permission)**: 尝试播放 `~/OneDrive/Aurora.mp3`。
    *   **普通任务 (Stop)**: 播放 Windows 系统默认通知音。

3.  **静音回退**
    *   如果找不到音频文件，则仅显示静音通知。

## ⚙️ 参数说明 (Parameters)

| 参数 | 说明 |
| :--- | :--- |
| `-AudioPath` | **(可选)** 强制指定通知音效文件的路径。 |
| `-Delay` | **(可选)** 延迟几秒后显示通知。对于“权限请求”很有用，可以防止通知过早消失。 |
| `-Wait` | **(可选)** 阻塞模式。脚本会等待直到通知被点击或消失。通常不需要开启。 |
| `-EnableDebug`| **(可选)** 开启调试模式。日志将写入 `~/.claude/toast_debug.log`。 |

## 🔍 故障排查 (Troubleshooting)

如果通知没有出现或点击无反应：
1.  **检查协议**: 运行 `Start-Process "claude-runner://test"`，看是否触发脚本（或报错）。
2.  **检查日志**: 在配置中添加 `-EnableDebug`，然后查看 `~/.claude/toast_debug.log`。
3.  **检查依赖**: 确保 `BurntToast` 模块已安装 (`Install-Module BurntToast`)。
