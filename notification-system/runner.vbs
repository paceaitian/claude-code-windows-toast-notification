' runner.vbs - VBScript 启动包装器
' 用于从 URI 协议启动 PowerShell 处理器，避免命令行窗口闪烁

Set args = WScript.Arguments
If args.Count > 0 Then
    ProtoArg = args(0)

    ' 安全检查：过滤危险字符（防止命令注入）
    ProtoArg = Replace(ProtoArg, """", "")
    ProtoArg = Replace(ProtoArg, "&", "")
    ProtoArg = Replace(ProtoArg, "|", "")
    ProtoArg = Replace(ProtoArg, ";", "")
    ProtoArg = Replace(ProtoArg, "`", "")
    ProtoArg = Replace(ProtoArg, "$", "")
    ProtoArg = Replace(ProtoArg, "(", "")
    ProtoArg = Replace(ProtoArg, ")", "")
    ProtoArg = Replace(ProtoArg, "%", "")
    ProtoArg = Replace(ProtoArg, "<", "")
    ProtoArg = Replace(ProtoArg, ">", "")
    ProtoArg = Replace(ProtoArg, vbCr, "")
    ProtoArg = Replace(ProtoArg, vbLf, "")

    ' Path to the PowerShell Handler（验证路径安全性）
    Set fso = CreateObject("Scripting.FileSystemObject")
    HandlerPath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%\.claude\hooks\notification-system\ProtocolHandler.ps1")

    ' 安全检查：验证路径在预期目录内，防止路径遍历
    ExpectedBase = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%\.claude\hooks\notification-system")
    If InStr(1, HandlerPath, ExpectedBase, vbTextCompare) <> 1 Then
        WScript.Quit 1
    End If

    ' 验证文件存在
    If Not fso.FileExists(HandlerPath) Then
        WScript.Quit 1
    End If

    ' Construct command: pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ...
    ' 添加 -EnableDebug 参数以启用日志记录
    Command = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & HandlerPath & """ """ & ProtoArg & """ -EnableDebug"

    CreateObject("WScript.Shell").Run Command, 0, False
End If
