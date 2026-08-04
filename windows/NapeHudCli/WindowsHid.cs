using System.Runtime.InteropServices;
using System.Text;

namespace NapeHud;

/// <summary>
/// Windows の HID アクセス。SetupAPI でデバイスを列挙し、hid.dll で属性と
/// レポート記述子の情報（PrimaryUsagePage / Usage）を取る。
///
/// macOS 版と違い、Windows はイベントごとにデバイスを区別できるので
/// 相関などの回避策は不要。ベンダ面（0xFF60）は排他されないため普通に開ける
/// （キーボード/マウスの最上位コレクションは OS が排他するので開けない）。
/// </summary>
public static class WinHid
{
    public sealed record DeviceInfo(
        string Path, int VendorId, int ProductId, string Product,
        int UsagePage, int Usage, int InputReportLength, int OutputReportLength);

    const int DIGCF_PRESENT = 0x02, DIGCF_DEVICEINTERFACE = 0x10;
    const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2;
    const uint OPEN_EXISTING = 3, FILE_FLAG_OVERLAPPED = 0x40000000;
    internal static readonly IntPtr INVALID_HANDLE = new(-1);

    [StructLayout(LayoutKind.Sequential)]
    struct SP_DEVICE_INTERFACE_DATA
    { public int cbSize; public Guid InterfaceClassGuid; public int Flags; public IntPtr Reserved; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SP_DEVICE_INTERFACE_DETAIL_DATA
    { public int cbSize; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 512)] public string DevicePath; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDD_ATTRIBUTES
    { public int Size; public ushort VendorID; public ushort ProductID; public ushort VersionNumber; }

    [StructLayout(LayoutKind.Sequential)]
    struct HIDP_CAPS
    {
        public ushort Usage, UsagePage;
        public ushort InputReportByteLength, OutputReportByteLength, FeatureReportByteLength;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 17)] public ushort[] Reserved;
        public ushort NumberLinkCollectionNodes;
        public ushort NumberInputButtonCaps, NumberInputValueCaps, NumberInputDataIndices;
        public ushort NumberOutputButtonCaps, NumberOutputValueCaps, NumberOutputDataIndices;
        public ushort NumberFeatureButtonCaps, NumberFeatureValueCaps, NumberFeatureDataIndices;
    }

    [DllImport("hid.dll")] static extern void HidD_GetHidGuid(out Guid guid);
    [DllImport("hid.dll")] static extern bool HidD_GetAttributes(IntPtr h, ref HIDD_ATTRIBUTES a);
    [DllImport("hid.dll", CharSet = CharSet.Unicode)]
    static extern bool HidD_GetProductString(IntPtr h, StringBuilder buf, int len);
    [DllImport("hid.dll")] static extern bool HidD_GetPreparsedData(IntPtr h, out IntPtr data);
    [DllImport("hid.dll")] static extern bool HidD_FreePreparsedData(IntPtr data);
    [DllImport("hid.dll")] static extern int HidP_GetCaps(IntPtr preparsed, ref HIDP_CAPS caps);
    [DllImport("hid.dll")] static extern bool HidD_SetNumInputBuffers(IntPtr h, int count);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SetupDiGetClassDevs(ref Guid g, IntPtr enumerator, IntPtr hwnd, int flags);
    [DllImport("setupapi.dll")]
    static extern bool SetupDiEnumDeviceInterfaces(IntPtr set, IntPtr devInfo, ref Guid g,
        int index, ref SP_DEVICE_INTERFACE_DATA data);
    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr set, ref SP_DEVICE_INTERFACE_DATA data,
        ref SP_DEVICE_INTERFACE_DETAIL_DATA detail, int detailSize, IntPtr required, IntPtr devInfo);
    [DllImport("setupapi.dll")] static extern bool SetupDiDestroyDeviceInfoList(IntPtr set);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec,
        uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)] internal static extern bool CloseHandle(IntPtr h);

    /// <summary>すべての HID デバイスを列挙する（開かずに属性だけ取る）。</summary>
    public static List<DeviceInfo> Enumerate()
    {
        var result = new List<DeviceInfo>();
        HidD_GetHidGuid(out var guid);
        var set = SetupDiGetClassDevs(ref guid, IntPtr.Zero, IntPtr.Zero,
                                     DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (set == INVALID_HANDLE) return result;
        try
        {
            for (int i = 0; ; i++)
            {
                var iface = new SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf<SP_DEVICE_INTERFACE_DATA>() };
                if (!SetupDiEnumDeviceInterfaces(set, IntPtr.Zero, ref guid, i, ref iface)) break;

                var detail = new SP_DEVICE_INTERFACE_DETAIL_DATA
                {
                    // 32bit/64bit で必要な cbSize が違う（構造体サイズではなくこの値）
                    cbSize = IntPtr.Size == 8 ? 8 : 4 + Marshal.SystemDefaultCharSize,
                    DevicePath = ""
                };
                if (!SetupDiGetDeviceInterfaceDetail(set, ref iface, ref detail,
                        Marshal.SizeOf(detail), IntPtr.Zero, IntPtr.Zero)) continue;

                var info = Describe(detail.DevicePath);
                if (info != null) result.Add(info);
            }
        }
        finally { SetupDiDestroyDeviceInfoList(set); }
        return result;
    }

    /// <summary>属性取得は共有読みで開く。キーボード/マウス面でも属性だけなら取れる。</summary>
    static DeviceInfo? Describe(string path)
    {
        var h = CreateFile(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                           OPEN_EXISTING, 0, IntPtr.Zero);
        if (h == INVALID_HANDLE) return null;
        try
        {
            var attr = new HIDD_ATTRIBUTES { Size = Marshal.SizeOf<HIDD_ATTRIBUTES>() };
            if (!HidD_GetAttributes(h, ref attr)) return null;

            var sb = new StringBuilder(256);
            var product = HidD_GetProductString(h, sb, sb.Capacity * 2) ? sb.ToString() : "";

            int usagePage = 0, usage = 0, inLen = 0, outLen = 0;
            if (HidD_GetPreparsedData(h, out var pre))
            {
                try
                {
                    var caps = new HIDP_CAPS { Reserved = new ushort[17] };
                    if (HidP_GetCaps(pre, ref caps) == 0x00110000)  // HIDP_STATUS_SUCCESS
                    {
                        usagePage = caps.UsagePage; usage = caps.Usage;
                        inLen = caps.InputReportByteLength; outLen = caps.OutputReportByteLength;
                    }
                }
                finally { HidD_FreePreparsedData(pre); }
            }
            return new DeviceInfo(path, attr.VendorID, attr.ProductID, product,
                                  usagePage, usage, inLen, outLen);
        }
        finally { CloseHandle(h); }
    }

    /// <summary>読み書きのために開く。ベンダ面なら成功する。</summary>
    public static HidStream? Open(DeviceInfo dev)
    {
        bool canWrite = true;
        var h = CreateFile(dev.Path, GENERIC_READ | GENERIC_WRITE,
                           FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero,
                           OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
        if (h == INVALID_HANDLE)
        {
            // 書き込みを許さないデバイスもあるので、読み取りだけで再試行する
            canWrite = false;
            h = CreateFile(dev.Path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, IntPtr.Zero);
            if (h == INVALID_HANDLE) return null;
        }
        // 既定の 32 では処理が遅れたときに取りこぼす。失敗しても致命的ではない。
        HidD_SetNumInputBuffers(h, 64);
        return new HidStream(h, dev.InputReportLength, dev.OutputReportLength, canWrite);
    }
}

/// <summary>
/// HID デバイスの読み書き。overlapped I/O を使う。
///
/// 非 overlapped で開くと ReadFile がレポート到着まで戻らず、呼び出し側の
/// タイムアウト判定も Ctrl-C も一切効かなくなる。ここでイベント待ち＋CancelIoEx
/// を自前で回すことで、待ち時間に上限を設けられるようにしている。
///
/// バッファはアンマネージ側に確保する。overlapped I/O の最中は
/// カーネルが生ポインタを握るので、GC が動かせるマネージ配列は渡せない。
/// </summary>
public sealed class HidStream : IDisposable
{
    const uint INFINITE = 0xFFFFFFFF, WAIT_OBJECT_0 = 0, WAIT_TIMEOUT = 0x102;
    const int ERROR_IO_PENDING = 997;

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr CreateEvent(IntPtr sec, bool manualReset, bool initialState, IntPtr name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool ResetEvent(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(IntPtr h, IntPtr buf, uint toRead, IntPtr read, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(IntPtr h, IntPtr buf, uint toWrite, IntPtr written, IntPtr overlapped);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetOverlappedResult(IntPtr h, IntPtr overlapped, out uint transferred, bool wait);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CancelIoEx(IntPtr h, IntPtr overlapped);

    readonly IntPtr _h;
    readonly IntPtr _readEvent, _writeEvent, _readOv, _writeOv, _readBuf, _writeBuf;
    bool _closed;

    public int InputReportLength { get; }
    public int OutputReportLength { get; }
    public bool CanWrite { get; }

    internal HidStream(IntPtr handle, int inLen, int outLen, bool canWrite)
    {
        _h = handle;
        InputReportLength = Math.Max(inLen, 1);
        OutputReportLength = Math.Max(outLen, 1);
        CanWrite = canWrite;

        _readEvent = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        _writeEvent = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        _readOv = Marshal.AllocHGlobal(IntPtr.Size * 4);   // OVERLAPPED は x64 で 32 バイト
        _writeOv = Marshal.AllocHGlobal(IntPtr.Size * 4);
        _readBuf = Marshal.AllocHGlobal(InputReportLength);
        _writeBuf = Marshal.AllocHGlobal(OutputReportLength);
    }

    /// <summary>OVERLAPPED を毎回ゼロ埋めし直し、末尾の hEvent だけ入れる。</summary>
    static void PrepareOv(IntPtr ov, IntPtr evt)
    {
        for (int i = 0; i < 4; i++) Marshal.WriteIntPtr(ov, IntPtr.Size * i, IntPtr.Zero);
        Marshal.WriteIntPtr(ov, IntPtr.Size * 3, evt);
    }

    /// <summary>
    /// レポートを 1 件読む。先頭バイトはレポート ID。
    /// 戻り値: 読めたバイト数 / 0 = タイムアウト / -1 = 失敗（切断など）。
    /// </summary>
    public int Read(byte[] dest, int timeoutMs)
    {
        if (_closed) return -1;
        ResetEvent(_readEvent);
        PrepareOv(_readOv, _readEvent);

        uint n;
        if (!ReadFile(_h, _readBuf, (uint)InputReportLength, IntPtr.Zero, _readOv))
        {
            if (Marshal.GetLastWin32Error() != ERROR_IO_PENDING) return -1;
            var w = WaitForSingleObject(_readEvent, timeoutMs < 0 ? INFINITE : (uint)timeoutMs);
            if (w != WAIT_OBJECT_0)
            {
                CancelIoEx(_h, _readOv);
                // 取り消しと完了が競ることがある。既に届いていたならその内容を活かす。
                if (!GetOverlappedResult(_h, _readOv, out n, true) || n == 0) return 0;
                Copy(dest, n);
                return (int)n;
            }
        }
        if (!GetOverlappedResult(_h, _readOv, out n, false)) return -1;
        Copy(dest, n);
        return (int)n;
    }

    void Copy(byte[] dest, uint n)
    {
        int len = (int)Math.Min(n, (uint)Math.Min(dest.Length, InputReportLength));
        if (len > 0) Marshal.Copy(_readBuf, dest, 0, len);
    }

    /// <summary>
    /// レポートを 1 件書く。Windows は OutputReportByteLength と
    /// 完全に同じ長さでないと ERROR_INVALID_PARAMETER になるので、
    /// 足りない分はゼロ埋めし、超える分は切り捨てる。
    /// </summary>
    public bool Write(byte[] src, int timeoutMs = 1000)
    {
        if (_closed || !CanWrite) return false;
        for (int i = 0; i < OutputReportLength; i++)
            Marshal.WriteByte(_writeBuf, i, i < src.Length ? src[i] : (byte)0);

        ResetEvent(_writeEvent);
        PrepareOv(_writeOv, _writeEvent);

        if (!WriteFile(_h, _writeBuf, (uint)OutputReportLength, IntPtr.Zero, _writeOv))
        {
            if (Marshal.GetLastWin32Error() != ERROR_IO_PENDING) return false;
            if (WaitForSingleObject(_writeEvent, timeoutMs < 0 ? INFINITE : (uint)timeoutMs) != WAIT_OBJECT_0)
            {
                CancelIoEx(_h, _writeOv);
                GetOverlappedResult(_h, _writeOv, out _, true);
                return false;
            }
        }
        return GetOverlappedResult(_h, _writeOv, out var n, false) && n > 0;
    }

    public void Dispose()
    {
        if (_closed) return;
        _closed = true;
        CancelIoEx(_h, IntPtr.Zero);      // このハンドルの保留中 I/O をすべて取り消す
        WinHid.CloseHandle(_h);
        WinHid.CloseHandle(_readEvent);
        WinHid.CloseHandle(_writeEvent);
        Marshal.FreeHGlobal(_readOv);
        Marshal.FreeHGlobal(_writeOv);
        Marshal.FreeHGlobal(_readBuf);
        Marshal.FreeHGlobal(_writeBuf);
    }
}
