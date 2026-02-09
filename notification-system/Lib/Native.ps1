try {
    if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        using System.Text;
        using System.Diagnostics;

        public class WinApi {
            [DllImport("kernel32.dll")] public static extern bool AttachConsole(uint dwProcessId);
            [DllImport("kernel32.dll")] public static extern bool FreeConsole();
            [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
            [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

            // Parent Process Logic (Toolhelp32Snapshot)
            [DllImport("kernel32.dll", SetLastError = true)]
            static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

            [DllImport("kernel32.dll", SetLastError = true)]
            static extern bool Process32First(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

            [DllImport("kernel32.dll", SetLastError = true)]
            static extern bool Process32Next(IntPtr hSnapshot, ref PROCESSENTRY32 lppe);

            [DllImport("kernel32.dll", SetLastError = true)]
            [return: MarshalAs(UnmanagedType.Bool)]
            static extern bool CloseHandle(IntPtr hObject);

            [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
            struct PROCESSENTRY32 {
                public uint dwSize;
                public uint cntUsage;
                public uint th32ProcessID;
                public IntPtr th32DefaultHeapID;
                public uint th32ModuleID;
                public uint cntThreads;
                public uint th32ParentProcessID;
                public int pcPriClassBase;
                public uint dwFlags;
                [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
                public string szExeFile;
            }

            public static int GetParentPid(int pid) {
                IntPtr hSnapshot = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
                if (hSnapshot == IntPtr.Zero) return 0;

                PROCESSENTRY32 procEntry = new PROCESSENTRY32();
                procEntry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

                if (Process32First(hSnapshot, ref procEntry)) {
                    do {
                        if (procEntry.th32ProcessID == pid) {
                            CloseHandle(hSnapshot);
                            return (int)procEntry.th32ParentProcessID;
                        }
                    } while (Process32Next(hSnapshot, ref procEntry));
                }
                CloseHandle(hSnapshot);
                return 0;
            }
        }
"@
    }
} catch { Write-DebugLog "WinApi Setup Error: $_" }
