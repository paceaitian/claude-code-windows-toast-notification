Set args = WScript.Arguments
If args.Count > 0 Then
    ProtoArg = args(0)
    ' Path to the PowerShell Handler
    HandlerPath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%\.claude\hooks\notification-system\ProtocolHandler.ps1")
    
    ' Construct command: pwsh -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ...
    Command = "pwsh.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & HandlerPath & """ """ & ProtoArg & """"
    
    CreateObject("WScript.Shell").Run Command, 0, False
End If
