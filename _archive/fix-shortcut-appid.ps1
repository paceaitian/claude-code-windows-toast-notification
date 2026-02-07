# Fix shortcut AppUserModelId using proper COM interfaces

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.IO;

public class ShortcutHelper
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    public class ShellLink {}

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
    public interface IShellLinkW
    {
        void GetPath(out string pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription(out string pszName);
        void SetDescription(string pszName);
        void GetWorkingDirectory(out string pszDir);
        void SetWorkingDirectory(string pszDir);
        void GetArguments(out string pszArgs);
        void SetArguments(string pszArgs);
        void GetHotkey(out short pwHotkey);
        void SetHotkey(short pwHotkey);
        void GetShowCmd(out uint piShowCmd);
        void SetShowCmd(uint piShowCmd);
        void GetIconLocation(out string pszIconPath, int cchIconPath, out int piIcon);
        void SetIconLocation(string pszIconPath, int iIcon);
        void SetRelativePath(string pszPathRel, uint dwReserved);
        void Resolve(IntPtr hWnd, uint fFlags);
        void SetPath(string pszFile);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010B-0000-0000-C000-000000000046")]
    public interface IPersistFile
    {
        void GetClassID(out Guid pClassID);
        void IsDirty();
        void Load(string pszFileName, uint dwMode);
        void Save(string pszFileName, bool fRemember);
        void SaveCompleted(string pszFileName);
        void GetCurFile(out string ppszFileName);
    }

    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("45E2B4AE-BD61-11D1-9B7A-00C04FB92584")]
    public interface IPropertyStore
    {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public IntPtr ptrVal;
        public static PropVariant CreateString(string value)
        {
            var pv = new PropVariant();
            pv.vt = 31; // VT_LPWSTR
            pv.ptrVal = Marshal.StringToCoTaskMemUni(value);
            return pv;
        }
    }

    public static void SetShortcutAppId(string shortcutPath, string appId)
    {
        var shellLink = new ShellLink();
        var link = (IShellLinkW)shellLink;

        // Load existing shortcut
        var persistFile = (IPersistFile)shellLink;
        persistFile.Load(shortcutPath, 0);

        // Get IPropertyStore
        var propertyStore = (IPropertyStore)shellLink;

        // PKEY_AppUserModel_ID: {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5
        var appUserModelIdKey = new PropertyKey
        {
            fmtid = new Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}"),
            pid = 5
        };

        // Set the AppUserModelId
        var pv = PropVariant.CreateString(appId);
        propertyStore.SetValue(ref appUserModelIdKey, ref pv);
        Marshal.FreeCoTaskMem(pv.ptrVal);
        propertyStore.Commit();

        // Save the shortcut
        persistFile.Save(shortcutPath, true);
    }
}
"@

$ShortcutPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Claude Code.lnk"
$AppId = "ClaudeCode.ClaudeCode"

Write-Host "Setting AppUserModelId on shortcut..." -ForegroundColor Cyan

if (-not (Test-Path $ShortcutPath)) {
    Write-Host "✗ Shortcut not found at: $ShortcutPath" -ForegroundColor Red
    Write-Host "Please run create-shortcut.ps1 first." -ForegroundColor Yellow
    exit 1
}

try {
    [ShortcutHelper]::SetShortcutAppId($ShortcutPath, $AppId)
    Write-Host "✓ AppUserModelId set to: $AppId" -ForegroundColor Green
    Write-Host "  Shortcut: $ShortcutPath" -ForegroundColor Gray

    # Verify
    Write-Host ""
    Write-Host "Verifying AppUserModelId..." -ForegroundColor Cyan
    $Shl = New-Object -ComObject Shell.Application
    $Folder = $Shl.NameSpace((Split-Path $ShortcutPath))
    $Item = $Folder.ParseName((Split-Path $ShortcutPath -Leaf))

    # Read back the property
    $PropertyAccessor = $Item.Properties()
    $FoundAppId = $false
    foreach ($Prop in $PropertyAccessor) {
        if ($Prop.Name -eq "System.AppUserModel.ID") {
            Write-Host "✓ Verified: $($Prop.Value)" -ForegroundColor Green
            $FoundAppId = $true
            break
        }
    }

    if (-not $FoundAppId) {
        Write-Host "⚠ Could not verify AppUserModelId, but it may still be set correctly." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Please log off and log on again for changes to take effect." -ForegroundColor Yellow
} catch {
    Write-Host "✗ Error: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
}
