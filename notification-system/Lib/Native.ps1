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

            [DllImport("kernel32.dll")]
            public static extern IntPtr GetConsoleWindow();

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

            [DllImport("user32.dll")]
            public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

            [DllImport("user32.dll")]
            public static extern bool SetCursorPos(int X, int Y);

            [DllImport("user32.dll")]
            public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, IntPtr dwExtraInfo);

            [StructLayout(LayoutKind.Sequential)]
            public struct RECT {
                public int Left;
                public int Top;
                public int Right;
                public int Bottom;
            }

            /// <summary>
            /// 模拟点击窗口内容区域（垂直 60% 处），激活终端输入焦点
            /// </summary>
            public static void ClickWindowCenter(IntPtr hWnd) {
                RECT rect;
                if (!GetWindowRect(hWnd, out rect)) return;
                // 水平居中，垂直 60%（避开顶部 tab 栏）
                int x = (rect.Left + rect.Right) / 2;
                int y = rect.Top + (int)((rect.Bottom - rect.Top) * 0.6);
                SetCursorPos(x, y);
                mouse_event(0x0002, 0, 0, 0, IntPtr.Zero); // MOUSEEVENTF_LEFTDOWN
                mouse_event(0x0004, 0, 0, 0, IntPtr.Zero); // MOUSEEVENTF_LEFTUP
            }

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

            // ================================================================
            // Console Input API - 直接写入控制台输入缓冲区
            // ================================================================
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern IntPtr GetStdHandle(int nStdHandle);

            [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
            public static extern bool WriteConsoleInputW(
                IntPtr hConsoleInput,
                [MarshalAs(UnmanagedType.LPArray)] INPUT_RECORD[] lpBuffer,
                uint nLength,
                out uint lpNumberOfEventsWritten);

            [StructLayout(LayoutKind.Explicit)]
            public struct INPUT_RECORD {
                [FieldOffset(0)] public ushort EventType;
                [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent;
            }

            [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
            public struct KEY_EVENT_RECORD {
                [FieldOffset(0)]  public int bKeyDown;
                [FieldOffset(4)]  public ushort wRepeatCount;
                [FieldOffset(6)]  public ushort wVirtualKeyCode;
                [FieldOffset(8)]  public ushort wVirtualScanCode;
                [FieldOffset(10)] public char UnicodeChar;
                [FieldOffset(12)] public uint dwControlKeyState;
            }

            /// <summary>
            /// 直接向目标进程的控制台输入缓冲区发送按键，绕过窗口焦点
            /// </summary>
            public static bool SendConsoleKey(uint pid, char key) {
                FreeConsole();
                if (!AttachConsole(pid)) return false;
                try {
                    IntPtr hInput = GetStdHandle(-10); // STD_INPUT_HANDLE
                    if (hInput == IntPtr.Zero || hInput == new IntPtr(-1)) return false;

                    INPUT_RECORD[] records = new INPUT_RECORD[2];

                    // Key Down
                    records[0].EventType = 1; // KEY_EVENT
                    records[0].KeyEvent.bKeyDown = 1;
                    records[0].KeyEvent.wRepeatCount = 1;
                    records[0].KeyEvent.UnicodeChar = key;

                    // Key Up
                    records[1].EventType = 1;
                    records[1].KeyEvent.bKeyDown = 0;
                    records[1].KeyEvent.wRepeatCount = 1;
                    records[1].KeyEvent.UnicodeChar = key;

                    uint written;
                    return WriteConsoleInputW(hInput, records, 2, out written);
                } finally {
                    FreeConsole();
                }
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
                    if (hSnapshot == new IntPtr(-1)) return 0; // INVALID_HANDLE_VALUE

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
                    if (hSnapshot != IntPtr.Zero && hSnapshot != new IntPtr(-1)) {
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
