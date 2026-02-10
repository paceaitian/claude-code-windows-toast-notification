# Config.ps1 - 通知系统配置常量
# 集中管理所有可配置的路径和魔法数字，便于维护和自定义

# ============================================================================
# 路径配置
# ============================================================================

# 调试日志路径
$Script:CONFIG_DEBUG_LOG_PATH = "$env:USERPROFILE\.claude\toast_debug.log"

# Claude Logo 图标路径
$Script:CONFIG_LOGO_PATH = "$env:USERPROFILE\.claude\assets\claude-logo.png"

# 权限提示音频路径（Permission Prompt 专用）
$Script:CONFIG_PERMISSION_AUDIO_PATH = "$env:USERPROFILE\OneDrive\Aurora.wav"

# ============================================================================
# 时间配置（毫秒）
# ============================================================================

# Watchdog 初始等待时间（让 Shell 启动）
$Script:CONFIG_WATCHDOG_INIT_DELAY_MS = 300

# 协议处理器发送按键前的等待时间（等待窗口获得焦点）
$Script:CONFIG_SENDKEYS_DELAY_MS = 250

# Worker 默认超时时间（-Wait 模式）
$Script:CONFIG_WORKER_TIMEOUT_MS = 30000

# Worker 超时额外缓冲时间（Delay * 1000 + 此值）
$Script:CONFIG_WORKER_TIMEOUT_BUFFER_MS = 10000

# ============================================================================
# 文本长度限制
# ============================================================================

# 工具详情最大长度
$Script:CONFIG_TOOL_DETAIL_MAX_LENGTH = 400

# 消息内容最大长度
$Script:CONFIG_MESSAGE_MAX_LENGTH = 800

# 用户问题标题最大长度
$Script:CONFIG_TITLE_MAX_LENGTH = 60

# JSON Fallback 最大长度
$Script:CONFIG_JSON_FALLBACK_MAX_LENGTH = 50

# ============================================================================
# Toast 显示配置
# ============================================================================

# 标题最大显示行数
$Script:CONFIG_TOAST_TITLE_MAX_LINES = 1

# 工具信息最大显示行数
$Script:CONFIG_TOAST_TOOL_MAX_LINES = 1

# 消息内容最大显示行数
$Script:CONFIG_TOAST_MESSAGE_MAX_LINES = 2

# ============================================================================
# 进程遍历配置
# ============================================================================

# 父进程遍历最大深度
$Script:CONFIG_PARENT_PROCESS_MAX_DEPTH = 10

# ============================================================================
# 敏感字段过滤（JSON Fallback 时排除）
# ============================================================================

$Script:CONFIG_SENSITIVE_FIELDS = @(
    'api_key', 'apikey', 'api-key',
    'password', 'passwd', 'pwd',
    'token', 'access_token', 'refresh_token',
    'secret', 'secret_key', 'secretkey',
    'credential', 'credentials',
    'private_key', 'privatekey'
)
