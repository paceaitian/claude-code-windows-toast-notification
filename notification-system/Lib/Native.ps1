# Native.ps1 - Windows API P/Invoke 封装
# 提供进程管理、窗口操作等原生 API 调用

try {
    if (-not ([System.Management.Automation.PSTypeName]'WinApi').Type) {
        Add-Type @"
        using System;
        using System.Runtime.InteropServices;
        using System.Text;
        using System.Diagnostics;

        public class WinApi {
            // ================================================================
            // Console API - 控制台附加/分离
            // ================================================================
            [DllImport("kernel32.dll")]
            public static extern bool AttachConsole(uint dwProcessId);

            [DllImport("kernel32.dll")]
            public static extern bool FreeConsole();

            // ================================================================
            // Window API - 窗口操作
            // ================================================================
            [DllImport("user32.dll")]
            public static extern IntPtr GetForegroundWindow();

            [DllImport("user32.dll")]
            public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

            [DllImport("user32.dll")]
            public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

            [DllImport("user32.dll")]
            public static extern bool SetForegroundWindow(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool IsIconic(IntPtr hWnd);

            [DllImport("user32.dll")]
            public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

            [DllImport("user32.dll")]
            public static extern bool IsWindow(IntPtr hWnd);

            // ================================================================
            // Process API - 进程遍历 (Toolhelp32Snapshot)
            // ================================================================
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

            /// <summary>
            /// 获取指定进程的父进程 ID
            /// </summary>
            /// <param name="pid">目标进程 ID</param>
            /// <returns>父进程 ID，失败返回 0</returns>
            public static int GetParentPid(int pid) {
                IntPtr hSnapshot = IntPtr.Zero;
                try {
                    hSnapshot = CreateToolhelp32Snapshot(0x00000002, 0); // TH32CS_SNAPPROCESS
                    if (hSnapshot == IntPtr.Zero) return 0;

                    PROCESSENTRY32 procEntry = new PROCESSENTRY32();
                    procEntry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));

                    if (Process32First(hSnapshot, ref procEntry)) {
                        do {
                            if (procEntry.th32ProcessID == pid) {
                                return (int)procEntry.th32ParentProcessID;
                            }
                        } while (Process32Next(hSnapshot, ref procEntry));
                    }
                    return 0;
                } finally {
                    if (hSnapshot != IntPtr.Zero) {
                        CloseHandle(hSnapshot);
                    }
                }
            }
        }
"@
    }
} catch {
    # WinApi type already loaded or Add-Type failed - silent fail
    # 注意：此处不能调用 Write-DebugLog，因为 Common.ps1 可能尚未加载
}
