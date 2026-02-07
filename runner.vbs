Set args = WScript.Arguments
If args.Count > 0 Then
    ProtoArg = args(0)
    ' Path to the PowerShell Handler
    HandlerPath = CreateObject("WScript.Shell").ExpandEnvironmentStrings("%USERPROFILE%\.claude\hooks\protocol-handler.ps1")
    
    ' Construct command: pwsh -ExecutionPolicy Bypass -WindowStyle Hidden -File ...
    ' We use 0 (Hide) as the second argument to Run to ensure NO window (and thus no Tab) triggers.
    Command = "pwsh.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & HandlerPath & """ """ & ProtoArg & """"
    
    CreateObject("WScript.Shell").Run Command, 0, False
End If
