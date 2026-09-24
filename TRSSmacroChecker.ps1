<#
    TRSS Mouse Macro Checker v2
    ---------------------------------------------------------------
    - Tüm kullanıcı profillerini tarar (admin olarak çalıştırınca yanlış profile bakma sorunu yok)
    - Makro / sürücü yazılımlarının dosyalarını, süreçlerini ve kurulum kayıtlarını kontrol eder
    - NTFS USN Journal ile zaman damgası oynamasını ve silinen dosyaları yakalar
    - Tarayıcı geçmişi / indirmeler / WebHID izinleri (sqlite3 veya Python gerektirmez)
    - Bağlı mouse sayısı, sonradan takılan / çıkarılan cihazlar, şüpheli VID'ler
    - Opsiyonel tıklama testi: yazılımla üretilmiş (injected) girdi + aralık düzenliliği analizi

    ÖNEMLİ: Buradaki bulgular kesin kanıt değildir, ekran paylaşımında (SS)
    değerlendirmeye yardımcı olan göstergelerdir.
#>

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# ------------------------------- Ayarlar -------------------------------
$EsikDakika        = 20        # bu süre içindeki değişiklikler KIRMIZI
$GunlukEsikDakika  = 24 * 60   # bu süre içindekiler SARI
$ListeLimit        = 8         # her klasörde listelenecek en yeni dosya sayısı
$TestSuresiSn      = 10        # tıklama testi süresi
# -----------------------------------------------------------------------

try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
Clear-Host

$BaslangicZamani = Get-Date
$RaporYolu = Join-Path $env:TEMP ("TRSS_rapor_{0:yyyyMMdd_HHmmss}.txt" -f $BaslangicZamani)
$TranscriptAcik = $false
try { Start-Transcript -Path $RaporYolu -Force | Out-Null; $TranscriptAcik = $true } catch {}

$Bulgular = New-Object System.Collections.Generic.List[object]

# ============================ Yardımcılar ==============================

function Bolum([string]$Baslik) {
    Write-Host ""
    Write-Host ("=" * 90) -ForegroundColor DarkGray
    Write-Host " $Baslik" -ForegroundColor Cyan
    Write-Host ("=" * 90) -ForegroundColor DarkGray
}

function AltBaslik([string]$Metin) {
    Write-Host ""
    Write-Host "[$Metin]" -ForegroundColor Magenta
}

function Satir([string]$Ad, $Deger, [string]$Renk = 'Gray') {
    if ($null -eq $Deger -or "$Deger" -eq '') { $Deger = '-' }
    Write-Host ("  {0,-26}: {1}" -f $Ad, $Deger) -ForegroundColor $Renk
}

function Aciklama([string]$Metin, [string]$Renk = 'DarkGray') {
    Write-Host "  $Metin" -ForegroundColor $Renk
}

function Bulgu {
    param(
        [ValidateSet('KIRMIZI', 'SARI')][string]$Seviye,
        [string]$Kategori,
        [string]$Mesaj
    )
    $Bulgular.Add([pscustomobject]@{ Seviye = $Seviye; Kategori = $Kategori; Mesaj = $Mesaj })
    $renk = if ($Seviye -eq 'KIRMIZI') { 'Red' } else { 'Yellow' }
    Write-Host ("  [{0}] {1}" -f $Seviye, $Mesaj) -ForegroundColor $renk
}

function Zaman($t) {
    if ($null -eq $t) { return '-' }
    return ([datetime]$t).ToString('yyyy-MM-dd HH:mm:ss')
}

function Once($t) {
    if ($null -eq $t) { return '-' }
    $f = (Get-Date) - [datetime]$t
    if ($f.TotalMinutes -lt -1) { return 'GELECEKTE!' }
    if ($f.TotalMinutes -lt 60) { return ('{0:0.0} dk önce' -f [math]::Max(0, $f.TotalMinutes)) }
    if ($f.TotalHours -lt 48)   { return ('{0:0.0} saat önce' -f $f.TotalHours) }
    return ('{0:0} gün önce' -f $f.TotalDays)
}

function Boyut([long]$b) {
    if ($b -ge 1MB) { return ('{0:0.0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:0.0} KB' -f ($b / 1KB)) }
    return "$b B"
}

# Zamana göre KIRMIZI / SARI bulgu üretir. Bulgu üretildiyse $true döner.
function Yakinlik-Bulgu($t, [string]$Kategori, [string]$Mesaj, [bool]$SadeceSari = $false) {
    if ($null -eq $t) { return $false }
    $dk = ((Get-Date) - [datetime]$t).TotalMinutes
    if ($dk -le $EsikDakika) {
        $sev = if ($SadeceSari) { 'SARI' } else { 'KIRMIZI' }
        Bulgu $sev $Kategori "$Mesaj ($(Once $t))"
        return $true
    }
    if ($dk -le $GunlukEsikDakika) {
        Bulgu 'SARI' $Kategori "$Mesaj ($(Once $t))"
        return $true
    }
    return $false
}

function DGet($Sozluk, [string]$Anahtar) {
    if ($null -ne $Sozluk -and $Sozluk -is [System.Collections.IDictionary] -and $Sozluk.ContainsKey($Anahtar)) { return $Sozluk[$Anahtar] }
    return $null
}

# ======================= Yerel (C#) yardımcı kod =======================
# Sadece ASCII karakter kullanılır; Türkçe metinler PowerShell tarafından verilir.

$CsKod = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace TRSS2
{
    public static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public uint CreationLow, CreationHigh;
            public uint AccessLow, AccessHigh;
            public uint WriteLow, WriteHigh;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        internal static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(IntPtr h, out BY_HANDLE_FILE_INFORMATION info);
        [DllImport("kernel32.dll")]
        internal static extern bool CloseHandle(IntPtr h);

        internal static readonly IntPtr Invalid = new IntPtr(-1);

        // NTFS dosya referans numarasi (USN kayitlarindaki ParentFileReferenceNumber ile ayni)
        public static ulong GetFileId(string path)
        {
            IntPtr h = CreateFileW(path, 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (h == IntPtr.Zero || h == Invalid) return 0;
            try
            {
                BY_HANDLE_FILE_INFORMATION i;
                if (!GetFileInformationByHandle(h, out i)) return 0;
                return ((ulong)i.FileIndexHigh << 32) | i.FileIndexLow;
            }
            finally { CloseHandle(h); }
        }

        // Tarayicinin kilitledigi dosyalari paylasimli okuma ile kopyalar
        public static bool CopyShared(string src, string dst)
        {
            try
            {
                using (FileStream s = new FileStream(src, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (FileStream d = new FileStream(dst, FileMode.Create, FileAccess.Write, FileShare.None))
                {
                    s.CopyTo(d);
                }
                return true;
            }
            catch { return false; }
        }

        // Dosya icinde (ASCII/Latin1 ve UTF-16) anahtar kelime gecis sayisi
        public static int CountKeyword(string path, string keyword, int maxBytes)
        {
            try
            {
                byte[] b;
                using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    int n = (int)Math.Min(fs.Length, (long)maxBytes);
                    b = new byte[n];
                    int r = 0;
                    while (r < n)
                    {
                        int x = fs.Read(b, r, n - r);
                        if (x <= 0) break;
                        r += x;
                    }
                }
                string k = keyword.ToLowerInvariant();
                string a = Encoding.GetEncoding(28591).GetString(b).ToLowerInvariant();
                string u = Encoding.Unicode.GetString(b).ToLowerInvariant();
                return Count(a, k) + Count(u, k);
            }
            catch { return -1; }
        }

        static int Count(string s, string k)
        {
            int c = 0, i = 0;
            while ((i = s.IndexOf(k, i, StringComparison.Ordinal)) >= 0) { c++; i += k.Length; }
            return c;
        }
    }

    public static class Sqlite
    {
        const string L = "winsqlite3.dll";
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open_v2(byte[] fn, out IntPtr db, int flags, IntPtr vfs);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close_v2(IntPtr db);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr stmt, IntPtr tail);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_count(IntPtr stmt);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text(IntPtr stmt, int i);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_column_bytes(IntPtr stmt, int i);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
        [DllImport(L, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg(IntPtr db);

        static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

        static string S(IntPtr p, int n)
        {
            if (p == IntPtr.Zero) return null;
            byte[] b = new byte[n];
            Marshal.Copy(p, b, 0, n);
            return Encoding.UTF8.GetString(b);
        }

        static string Err(IntPtr db)
        {
            IntPtr p = sqlite3_errmsg(db);
            if (p == IntPtr.Zero) return "";
            int n = 0;
            while (Marshal.ReadByte(p, n) != 0) n++;
            return S(p, n);
        }

        public static List<string[]> Query(string path, string sql)
        {
            IntPtr db;
            int rc = sqlite3_open_v2(Z(path), out db, 0x02, IntPtr.Zero);
            if (rc != 0)
            {
                string m = Err(db);
                sqlite3_close_v2(db);
                throw new Exception("sqlite open: " + m);
            }
            try
            {
                IntPtr st;
                rc = sqlite3_prepare_v2(db, Z(sql), -1, out st, IntPtr.Zero);
                if (rc != 0) throw new Exception("sqlite prepare: " + Err(db));
                List<string[]> rows = new List<string[]>();
                try
                {
                    int cols = sqlite3_column_count(st);
                    while (true)
                    {
                        rc = sqlite3_step(st);
                        if (rc == 100)
                        {
                            string[] r = new string[cols];
                            for (int i = 0; i < cols; i++)
                            {
                                IntPtr p = sqlite3_column_text(st, i);
                                r[i] = (p == IntPtr.Zero) ? null : S(p, sqlite3_column_bytes(st, i));
                            }
                            rows.Add(r);
                        }
                        else if (rc == 101) break;
                        else throw new Exception("sqlite step: " + Err(db));
                    }
                }
                finally { sqlite3_finalize(st); }
                return rows;
            }
            finally { sqlite3_close_v2(db); }
        }
    }

    public class UsnKayit
    {
        public ulong FileRef;
        public ulong Parent;
        public string Name;
        public DateTime Time;
        public uint Reason;
        public bool IsDir;
        public bool VeriDegisti { get { return (Reason & 0x7u) != 0; } }
        public bool Olusturuldu { get { return (Reason & 0x100u) != 0; } }
        public bool Silindi     { get { return (Reason & 0x200u) != 0; } }
        public bool EskiAd      { get { return (Reason & 0x1000u) != 0; } }
        public bool YeniAd      { get { return (Reason & 0x2000u) != 0; } }
        public bool TemelBilgi  { get { return (Reason & 0x8000u) != 0; } }
    }

    public static class Usn
    {
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, int inSize, byte[] outBuf, int outSize, out int returned, IntPtr ov);

        [StructLayout(LayoutKind.Explicit)]
        struct FILE_ID_DESCRIPTOR
        {
            [FieldOffset(0)] public uint dwSize;
            [FieldOffset(4)] public int Type;
            [FieldOffset(8)] public long FileId;
            [FieldOffset(8)] public Guid ObjectId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenFileById(IntPtr hint, ref FILE_ID_DESCRIPTOR id, uint access, uint share, IntPtr sec, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(IntPtr h, StringBuilder sb, uint n, uint flags);

        public static string LastError = "";
        public static DateTime EarliestTime = DateTime.MinValue;
        public static long RecordCount = 0;

        public static List<UsnKayit> Read(string drive, ulong[] parents, string[] exts, string[] contains)
        {
            LastError = "";
            EarliestTime = DateTime.MinValue;
            RecordCount = 0;
            Dictionary<ulong, bool> set = new Dictionary<ulong, bool>();
            foreach (ulong p in parents) set[p] = true;

            IntPtr h = Native.CreateFileW("\\\\.\\" + drive.TrimEnd('\\'), 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
            if (h == IntPtr.Zero || h == Native.Invalid)
            {
                LastError = "Birim acilamadi (hata " + Marshal.GetLastWin32Error() + ")";
                return null;
            }
            List<UsnKayit> res = new List<UsnKayit>();
            try
            {
                byte[] q = new byte[80];
                int ret;
                if (!DeviceIoControl(h, 0x000900f4, null, 0, q, q.Length, out ret, IntPtr.Zero))
                {
                    LastError = "USN journal sorgulanamadi (hata " + Marshal.GetLastWin32Error() + ")";
                    return null;
                }
                ulong jid = BitConverter.ToUInt64(q, 0);
                long start = BitConverter.ToInt64(q, 8);
                long next = BitConverter.ToInt64(q, 16);

                byte[] inb = new byte[40];
                byte[] outb = new byte[1 << 16];
                bool first = true;
                while (start < next)
                {
                    Array.Copy(BitConverter.GetBytes(start), 0, inb, 0, 8);
                    Array.Copy(BitConverter.GetBytes(0xFFFFFFFFu), 0, inb, 8, 4);
                    Array.Copy(BitConverter.GetBytes(jid), 0, inb, 32, 8);
                    if (!DeviceIoControl(h, 0x000900bb, inb, inb.Length, outb, outb.Length, out ret, IntPtr.Zero))
                    {
                        LastError = "USN okuma hatasi (hata " + Marshal.GetLastWin32Error() + ")";
                        break;
                    }
                    if (ret <= 8) break;
                    long nu = BitConverter.ToInt64(outb, 0);
                    int off = 8;
                    while (off + 60 <= ret)
                    {
                        int len = BitConverter.ToInt32(outb, off);
                        if (len <= 0) break;
                        ushort major = BitConverter.ToUInt16(outb, off + 4);
                        if (major == 2)
                        {
                            RecordCount++;
                            if (first)
                            {
                                EarliestTime = DateTime.FromFileTimeUtc(BitConverter.ToInt64(outb, off + 32)).ToLocalTime();
                                first = false;
                            }
                            ulong parent = BitConverter.ToUInt64(outb, off + 16);
                            int nl = BitConverter.ToUInt16(outb, off + 56);
                            int no = BitConverter.ToUInt16(outb, off + 58);
                            string name = Encoding.Unicode.GetString(outb, off + no, nl);
                            bool match = set.ContainsKey(parent);
                            if (!match)
                            {
                                string ln = name.ToLowerInvariant();
                                foreach (string e in exts) { if (ln.EndsWith(e)) { match = true; break; } }
                                if (!match) foreach (string c in contains) { if (ln.Contains(c)) { match = true; break; } }
                            }
                            if (match)
                            {
                                UsnKayit k = new UsnKayit();
                                k.FileRef = BitConverter.ToUInt64(outb, off + 8);
                                k.Parent = parent;
                                k.Name = name;
                                k.Time = DateTime.FromFileTimeUtc(BitConverter.ToInt64(outb, off + 32)).ToLocalTime();
                                k.Reason = BitConverter.ToUInt32(outb, off + 40);
                                k.IsDir = (BitConverter.ToUInt32(outb, off + 52) & 0x10u) != 0;
                                res.Add(k);
                            }
                        }
                        off += len;
                    }
                    if (nu <= start) break;
                    start = nu;
                }
            }
            finally { Native.CloseHandle(h); }
            return res;
        }

        // Dosya referans numarasindan tam yol (klasor silinmisse null)
        public static string ResolvePath(string drive, ulong fileRef)
        {
            IntPtr hint = Native.CreateFileW(drive.TrimEnd('\\') + "\\", 0x80, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
            if (hint == IntPtr.Zero || hint == Native.Invalid) return null;
            try
            {
                FILE_ID_DESCRIPTOR d = new FILE_ID_DESCRIPTOR();
                d.dwSize = (uint)Marshal.SizeOf(typeof(FILE_ID_DESCRIPTOR));
                d.Type = 0;
                d.FileId = unchecked((long)fileRef);
                IntPtr h = OpenFileById(hint, ref d, 0x80, 7, IntPtr.Zero, 0x02000000);
                if (h == IntPtr.Zero || h == Native.Invalid) return null;
                try
                {
                    StringBuilder sb = new StringBuilder(1024);
                    uint n = GetFinalPathNameByHandleW(h, sb, 1024, 0);
                    if (n == 0 || n >= 1024) return null;
                    string s = sb.ToString();
                    if (s.StartsWith("\\\\?\\")) s = s.Substring(4);
                    return s;
                }
                finally { Native.CloseHandle(h); }
            }
            finally { Native.CloseHandle(hint); }
        }
    }

    public class ClickEvent
    {
        public double T;
        public int Button;
        public bool Down;
        public bool Injected;
        public bool LowerIlInjected;
    }

    public class DeviceStat
    {
        public string Handle;
        public string Name;
        public int Clicks;
        public int Moves;
    }

    public class ClickTestForm : Form
    {
        delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int x; public int y; }
        [StructLayout(LayoutKind.Sequential)] struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct RAWINPUTDEVICE { public ushort page; public ushort usage; public uint flags; public IntPtr target; }

        [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint tid);
        [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterRawInputDevices(RAWINPUTDEVICE[] d, uint n, uint sz);
        [DllImport("user32.dll")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint hdr);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint GetRawInputDeviceInfo(IntPtr h, uint cmd, StringBuilder data, ref uint size);

        public List<ClickEvent> ClickEvents = new List<ClickEvent>();
        public Dictionary<long, DeviceStat> Devices = new Dictionary<long, DeviceStat>();
        public int TotalMoves = 0;
        public int InjectedMoves = 0;
        public bool Started = false;
        public bool RawOk = false;
        public bool HookOk = false;

        int durationMs;
        int waitMs = 60000;
        string progressFormat;
        Stopwatch sw = new Stopwatch();
        Stopwatch waitSw = new Stopwatch();
        HookProc proc;
        IntPtr hook = IntPtr.Zero;
        Label lbl;
        System.Windows.Forms.Timer timer;

        public ClickTestForm(int seconds, string intro, string progress)
        {
            durationMs = seconds * 1000;
            progressFormat = progress;
            Text = "TRSS";
            Width = 620; Height = 340;
            TopMost = true;
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            BackColor = Color.FromArgb(24, 24, 28);
            lbl = new Label();
            lbl.Dock = DockStyle.Fill;
            lbl.ForeColor = Color.White;
            lbl.Font = new Font("Segoe UI", 14f);
            lbl.TextAlign = ContentAlignment.MiddleCenter;
            lbl.Text = intro;
            Controls.Add(lbl);
            timer = new System.Windows.Forms.Timer();
            timer.Interval = 50;
            timer.Tick += OnTick;
        }

        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
            d[0].page = 1; d[0].usage = 2; d[0].flags = 0x100; d[0].target = this.Handle;
            RawOk = RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
            proc = new HookProc(HookCb);
            hook = SetWindowsHookEx(14, proc, GetModuleHandle("user32.dll"), 0);
            HookOk = hook != IntPtr.Zero;
            waitSw.Start();
            timer.Start();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Activate();
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            timer.Stop();
            if (hook != IntPtr.Zero) { UnhookWindowsHookEx(hook); hook = IntPtr.Zero; }
            RAWINPUTDEVICE[] d = new RAWINPUTDEVICE[1];
            d[0].page = 1; d[0].usage = 2; d[0].flags = 0x1; d[0].target = IntPtr.Zero;
            RegisterRawInputDevices(d, 1, (uint)Marshal.SizeOf(typeof(RAWINPUTDEVICE)));
            base.OnFormClosed(e);
        }

        void OnTick(object s, EventArgs e)
        {
            if (!Started)
            {
                if (waitSw.ElapsedMilliseconds > waitMs) Close();
                return;
            }
            long left = durationMs - sw.ElapsedMilliseconds;
            if (left <= 0) { Close(); return; }
            int n = 0;
            foreach (ClickEvent c in ClickEvents) if (c.Button == 0 && c.Down) n++;
            lbl.Text = string.Format(progressFormat, left / 1000.0, n);
        }

        IntPtr HookCb(int nCode, IntPtr w, IntPtr l)
        {
            try
            {
                if (nCode >= 0)
                {
                    int msg = w.ToInt32();
                    MSLLHOOKSTRUCT s = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(l, typeof(MSLLHOOKSTRUCT));
                    bool inj = (s.flags & 1u) != 0;
                    bool lower = (s.flags & 2u) != 0;
                    if (msg == 0x200)
                    {
                        if (Started) { TotalMoves++; if (inj) InjectedMoves++; }
                    }
                    else
                    {
                        int b = -1; bool down = false;
                        switch (msg)
                        {
                            case 0x201: b = 0; down = true; break;
                            case 0x202: b = 0; break;
                            case 0x204: b = 1; down = true; break;
                            case 0x205: b = 1; break;
                            case 0x207: b = 2; down = true; break;
                            case 0x208: b = 2; break;
                            case 0x20B: b = 3; down = true; break;
                            case 0x20C: b = 3; break;
                        }
                        if (b >= 0)
                        {
                            if (!Started && b == 0 && down) { Started = true; sw.Start(); }
                            if (Started)
                            {
                                ClickEvent c = new ClickEvent();
                                c.T = sw.Elapsed.TotalMilliseconds;
                                c.Button = b; c.Down = down; c.Injected = inj; c.LowerIlInjected = lower;
                                ClickEvents.Add(c);
                            }
                        }
                    }
                }
            }
            catch { }
            return CallNextHookEx(hook, nCode, w, l);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x00FF && Started) HandleRaw(m.LParam);
            base.WndProc(ref m);
        }

        void HandleRaw(IntPtr hRaw)
        {
            uint hs = (uint)(8 + 2 * IntPtr.Size);
            uint size = 0;
            GetRawInputData(hRaw, 0x10000003, IntPtr.Zero, ref size, hs);
            if (size == 0) return;
            IntPtr buf = Marshal.AllocHGlobal((int)size);
            try
            {
                if (GetRawInputData(hRaw, 0x10000003, buf, ref size, hs) == unchecked((uint)-1)) return;
                if (Marshal.ReadInt32(buf, 0) != 0) return;
                IntPtr dev = Marshal.ReadIntPtr(buf, 8);
                int o = (int)hs;
                ushort bf = (ushort)Marshal.ReadInt16(buf, o + 4);
                int lx = Marshal.ReadInt32(buf, o + 12);
                int ly = Marshal.ReadInt32(buf, o + 16);
                long key = dev.ToInt64();
                DeviceStat st;
                if (!Devices.TryGetValue(key, out st))
                {
                    st = new DeviceStat();
                    st.Handle = "0x" + key.ToString("X");
                    st.Name = DevName(dev);
                    Devices[key] = st;
                }
                if ((bf & 0x0155) != 0) st.Clicks++;
                if (lx != 0 || ly != 0) st.Moves++;
            }
            finally { Marshal.FreeHGlobal(buf); }
        }

        static string DevName(IntPtr dev)
        {
            if (dev == IntPtr.Zero) return "";
            uint n = 0;
            GetRawInputDeviceInfo(dev, 0x20000007, null, ref n);
            if (n == 0) return "?";
            StringBuilder sb = new StringBuilder((int)n + 1);
            GetRawInputDeviceInfo(dev, 0x20000007, sb, ref n);
            return sb.ToString();
        }
    }
}
'@

$CsHazir = [bool]('TRSS2.Native' -as [type])
if (-not $CsHazir) {
    try {
        Add-Type -TypeDefinition $CsKod -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        $CsHazir = $true
    } catch {
        Write-Host "Yardımcı kod derlenemedi, bazı kontroller atlanacak: $($_.Exception.Message)" -ForegroundColor Red
    }
}
try { Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop } catch {}

# ========================= Ortam / profiller ===========================

$Admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Profilleri-Getir {
    $sonuc = @()
    try {
        $sonuc = @(Get-CimInstance Win32_UserProfile -ErrorAction Stop |
            Where-Object { -not $_.Special -and $_.LocalPath -and ($_.LocalPath -notlike "$env:windir*") -and (Test-Path -LiteralPath $_.LocalPath) } |
            ForEach-Object {
                [pscustomobject]@{ Ad = (Split-Path $_.LocalPath -Leaf); Yol = $_.LocalPath; SID = $_.SID; SonKullanim = $_.LastUseTime }
            })
    } catch {}

    if ($sonuc.Count -eq 0) {
        $sonuc = @(Get-ChildItem -LiteralPath (Split-Path $env:USERPROFILE -Parent) -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users') } |
            ForEach-Object { [pscustomobject]@{ Ad = $_.Name; Yol = $_.FullName; SID = $null; SonKullanim = $null } })
    }

    if (-not ($sonuc | Where-Object { $_.Yol -eq $env:USERPROFILE })) {
        $sonuc += [pscustomobject]@{ Ad = $env:USERNAME; Yol = $env:USERPROFILE; SID = $null; SonKullanim = $null }
    }
    return $sonuc
}

function Kurulu-Yazilimlari-Topla {
    $yollar = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($h in (Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-5-21-[\d-]+$' })) {
        $yollar += "Registry::HKEY_USERS\$($h.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
    }
    foreach ($y in $yollar) {
        Get-ItemProperty -Path $y -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | ForEach-Object {
            $tarih = $null
            if ($_.InstallDate -match '^\d{8}$') {
                try { $tarih = [datetime]::ParseExact($_.InstallDate, 'yyyyMMdd', $null) } catch {}
            }
            [pscustomobject]@{
                Ad            = $_.DisplayName
                Surum         = $_.DisplayVersion
                Yayinci       = $_.Publisher
                KurulumTarihi = $tarih
                Konum         = $_.InstallLocation
                Ikon          = $_.DisplayIcon
            }
        }
    }
}

$Profiller        = @(Profilleri-Getir)
$KuruluYazilimlar = @(Kurulu-Yazilimlari-Topla)
$CalisanSurecler  = @(Get-Process -ErrorAction SilentlyContinue)
$UsnKlasorleri    = New-Object System.Collections.Generic.List[object]

$MarkaRegex = 'Logitech|G ?HUB|Razer|Synapse|Corsair|iCUE|SteelSeries|HyperX|NGENUITY|ROCCAT|Swarm|Turtle ?Beach|Glorious|Bloody|A4Tech|Oscar|Redragon|Rampage|Cooler ?Master|MasterPlus|Armoury|\bROG\b|MSI Center|Dragon Center|Endgame|Pulsar|Xtrfy|Zowie|Lamzu|Keychron|Fantech|Marvo|Rapoo|OMEN Gaming|Alienware Command|AutoHotkey|X-?Mouse|TinyTask|Macro(?!media)|Pulover|Jitbit'
$SurecRegex = 'lghub|LCore|Razer|Synapse|iCUE|Corsair|SteelSeries|NGenuity|HyperX|Swarm|ROCCAT|Glorious|BY-COMBO|Bloody|Oscar|ArmouryCrate|MasterPlus|AutoHotkey|XMouseButtonControl|TinyTask|Macro|Pulover|Jitbit'
$YazilimMakroRegex = 'AutoHotkey|TinyTask|Pulover|Jitbit|Macro ?Recorder|MacroGamer|XMouseButtonControl|X-?Mouse Button'

# ============================== Başlık =================================

Bolum 'TRSS Mouse Macro Checker v2'
Satir 'Tarih' (Zaman $BaslangicZamani)
Satir 'Bilgisayar' $env:COMPUTERNAME
Satir 'Çalıştıran kullanıcı' "$env:USERDOMAIN\$env:USERNAME"
Satir 'Yönetici yetkisi' $(if ($Admin) { 'Evet' } else { 'HAYIR - USN ve diğer kullanıcı profilleri kontrol edilemez' }) $(if ($Admin) { 'Green' } else { 'Yellow' })
Satir 'Yardımcı kod' $(if ($CsHazir) { 'Hazır' } else { 'Derlenemedi' })
Satir 'Kırmızı eşik' "$EsikDakika dakika"
AltBaslik 'Taranan kullanıcı profilleri'
foreach ($p in $Profiller) {
    Write-Host ("  {0,-20} {1,-40} son kullanım: {2}" -f $p.Ad, $p.Yol, (Zaman $p.SonKullanim))
}

# ======================= 1) Çalışan süreçler ===========================

function Surec-Kontrol {
    Bolum '1) Çalışan mouse / makro yazılımları'
    $eslesen = @($CalisanSurecler | Where-Object { $_.ProcessName -match $SurecRegex } | Sort-Object ProcessName)
    if ($eslesen.Count -eq 0) { Aciklama 'İlgili çalışan süreç yok.' 'Green'; return }

    foreach ($p in $eslesen) {
        $yol = $null; $bas = $null
        try { $yol = $p.Path } catch {}
        try { $bas = $p.StartTime } catch {}
        Write-Host ("  {0,-28} PID {1,-7} başlama: {2,-20} {3}" -f $p.ProcessName, $p.Id, (Zaman $bas), $yol)
        if ($p.ProcessName -match $YazilimMakroRegex) {
            Bulgu 'SARI' 'Süreç' "Yazılım tabanlı makro / otomasyon aracı çalışıyor: $($p.ProcessName)"
        }
        if ($bas) { [void](Yakinlik-Bulgu $bas 'Süreç' "$($p.ProcessName) kısa süre önce başlatılmış" $true) }
    }
    Aciklama 'Not: Derlenmiş AutoHotkey scriptleri farklı isimle çalışabilir; tıklama testi bunu ayrıca yakalar.'
}

# ======================= 2) Kurulu yazılımlar ==========================

function Kurulum-Kontrol {
    Bolum '2) Kurulu mouse / makro yazılımları (kayıt defteri)'
    $es = @($KuruluYazilimlar | Where-Object { $_.Ad -match $MarkaRegex } | Sort-Object Ad, Surum -Unique)
    if ($es.Count -eq 0) { Aciklama 'İlgili kurulu yazılım bulunamadı.' 'Green'; return }

    foreach ($y in $es) {
        Write-Host ("  {0,-45} {1,-16} kurulum: {2,-10}  {3}" -f $y.Ad, $y.Surum, $(if ($y.KurulumTarihi) { $y.KurulumTarihi.ToString('yyyy-MM-dd') } else { '-' }), $y.Konum)
        if ($y.Ad -match $YazilimMakroRegex) {
            Bulgu 'SARI' 'Kurulum' "Yazılım tabanlı makro aracı kurulu: $($y.Ad)"
        }
        if ($y.KurulumTarihi -and ((Get-Date).Date - $y.KurulumTarihi).TotalDays -le 1) {
            Bulgu 'SARI' 'Kurulum' "$($y.Ad) bugün/dün kurulmuş ($($y.KurulumTarihi.ToString('yyyy-MM-dd')))"
        }
    }
}

# ===================== 3) Yazılım dosya kontrolleri ====================

# Kok:Alt biçimindeki yolları tüm profiller için çözer (joker karakter destekli)
function Klasorleri-Coz([string[]]$Altlar, [string]$KayitDeseni) {
    $sonuc = New-Object System.Collections.Generic.List[object]

    $ekle = {
        param($profil, $yol)
        foreach ($mevcut in $sonuc) {
            if ($yol -eq $mevcut.Yol -or $yol.StartsWith($mevcut.Yol.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
        }
        $sonuc.Add([pscustomobject]@{ Profil = $profil; Yol = $yol })
    }

    foreach ($a in $Altlar) {
        $parca = $a.Split(':', 2)
        $kok = $parca[0]; $alt = $parca[1]
        $bazlar = @()
        switch ($kok) {
            'Local'       { $bazlar = @($Profiller | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = (Join-Path $_.Yol 'AppData\Local') } }) }
            'Roaming'     { $bazlar = @($Profiller | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = (Join-Path $_.Yol 'AppData\Roaming') } }) }
            'Kullanici'   { $bazlar = @($Profiller | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = $_.Yol } }) }
            'ProgramData' { $bazlar = @([pscustomobject]@{ Profil = '(sistem)'; Yol = $env:ProgramData }) }
            'ProgramFiles' {
                $bazlar = @(@($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432) | Where-Object { $_ } | Select-Object -Unique |
                    ForEach-Object { [pscustomobject]@{ Profil = '(sistem)'; Yol = $_ } })
            }
        }
        foreach ($b in $bazlar) {
            $tam = Join-Path $b.Yol $alt
            foreach ($i in @(Get-Item -Path $tam -Force -ErrorAction SilentlyContinue)) {
                if ($i.PSIsContainer) { & $ekle $b.Profil $i.FullName }
            }
        }
    }

    # Farklı diske / klasöre kurulmuş olabilir: kayıt defterindeki kurulum konumu
    if ($KayitDeseni) {
        foreach ($y in ($KuruluYazilimlar | Where-Object { $_.Ad -match $KayitDeseni })) {
            $konum = $y.Konum
            if (-not $konum -and $y.Ikon) {
                try { $konum = Split-Path ($y.Ikon.Trim('"').Split(',')[0]) -Parent } catch {}
            }
            if ($konum -and (Test-Path -LiteralPath $konum)) {
                & $ekle '(kayıt defteri)' ((Get-Item -LiteralPath $konum -Force).FullName.TrimEnd('\'))
            }
        }
    }
    return $sonuc
}

$Hedefler = @(
    @{ Ad = 'Logitech G HUB'; Alt = @('Local:LGHUB'); Desen = @('*.db', '*.json'); Recurse = $false; Surec = '^lghub' }
    @{ Ad = 'Logitech Gaming Software (eski)'; Alt = @('Local:Logitech\Logitech Gaming Software'); Desen = @('*.xml', '*.json'); Recurse = $true; Surec = '^LCore' }
    @{ Ad = 'Glorious Core'; Alt = @('Roaming:Glorious Core'); Desen = @('*.json'); Recurse = $true; Surec = 'Glorious' }
    @{ Ad = 'Glorious Model O / Model D yazılımı (BY-COMBO)'; Alt = @('Local:BY-COMBO*'); Desen = @('*'); Recurse = $true; Surec = 'Glorious|BY-COMBO|Model' }
    @{ Ad = 'ROCCAT SWARM (eski)'; Alt = @('Roaming:ROCCAT\SWARM'); Desen = @('*'); Recurse = $true; Surec = 'ROCCAT|Swarm' }
    @{ Ad = 'Turtle Beach SWARM II'; Alt = @('Roaming:Turtle*Beach\*SWARM*'); Desen = @('*'); Recurse = $true; Surec = 'Swarm' }
    @{ Ad = 'Corsair iCUE'; Alt = @('Roaming:Corsair\CUE*'); Desen = @('*'); Recurse = $true; Surec = 'iCUE|Corsair' }
    @{ Ad = 'Razer Synapse 4 (AppEngine)'; Alt = @('Local:Razer\RazerAppEngine\User Data\Logs', 'Local:Razer\RazerAppEngine\User Data\Default\IndexedDB\*razer*'); Desen = @('*'); Recurse = $true; Surec = 'RazerAppEngine|Razer' }
    @{ Ad = 'Razer Synapse 3'; Alt = @('Local:Razer\Synapse3', 'ProgramData:Razer\Synapse3'); Desen = @('*'); Recurse = $true; Surec = 'Razer|Synapse' }
    @{ Ad = 'Razer Synapse 2 (eski)'; Alt = @('ProgramData:Razer\Synapse'); Desen = @('*'); Recurse = $true; Surec = 'Razer|Synapse' }
    @{ Ad = 'SteelSeries GG / Engine'; Alt = @('ProgramData:SteelSeries\GG', 'ProgramData:SteelSeries\SteelSeries Engine 3'); Desen = @('*.db*', '*.json'); Recurse = $true; Surec = 'SteelSeries' }
    @{ Ad = 'HyperX NGENUITY'; Alt = @('Local:Packages\*NGENUITY*\LocalState'); Desen = @('*'); Recurse = $true; Surec = 'NGenuity|HyperX' }
    @{ Ad = 'Bloody / A4Tech'; Alt = @('ProgramFiles:Bloody*', 'ProgramFiles:A4Tech*'); Desen = @('*.amc2', '*.mgn2', '*.bwp', '*.bmc', '*.bwd', '*.amc', '*.mgn', '*.ini', '*.cfg'); Recurse = $true; Surec = 'Bloody|Oscar'; KayitDeseni = 'Bloody|A4Tech|Oscar'; MakroUzanti = '^\.(amc2|mgn2|bwp|bmc|bwd|amc|mgn)$' }
    @{ Ad = 'X-Mouse Button Control'; Alt = @('Roaming:Highresolution Enterprises\XMouseButtonControl'); Desen = @('*.xml'); Recurse = $false; Surec = 'XMouseButtonControl' }
    @{ Ad = 'AutoHotkey / TinyTask / makro kaydediciler (Masaüstü, İndirilenler, Belgeler)'; Alt = @('Kullanici:Desktop', 'Kullanici:Downloads', 'Kullanici:Documents', 'Kullanici:OneDrive\Desktop', 'Kullanici:OneDrive\Documents'); Desen = @('*.ahk', '*.ahk2', '*tinytask*', '*macro*', '*AutoHotkey*'); Recurse = $true; Derinlik = 2; Surec = 'AutoHotkey|TinyTask|Macro|Pulover|Jitbit'; VarlikBulgu = $true }
)

function Hedef-Kontrol($H) {
    AltBaslik $H.Ad
    $klasorler = @(Klasorleri-Coz $H.Alt $H.KayitDeseni)

    $acik = @()
    if ($H.Surec) { $acik = @($CalisanSurecler | Where-Object { $_.ProcessName -match $H.Surec }) }
    if ($acik.Count) { Satir 'Şu an çalışan süreç' (($acik | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') 'Yellow' }

    if ($klasorler.Count -eq 0) {
        Aciklama 'Klasör bulunamadı. (Kurulu değil ya da kaldırılmış/silinmiş olabilir - USN bölümüne bakın.)'
        return
    }

    foreach ($k in $klasorler) {
        Write-Host ""
        Satir 'Klasör' ("{0}   [{1}]" -f $k.Yol, $k.Profil)
        $UsnKlasorleri.Add([pscustomobject]@{ Hedef = $H.Ad; Yol = $k.Yol; SurecAcik = ($acik.Count -gt 0) })

        $hatalar = $null
        $gci = @{ LiteralPath = $k.Yol; File = $true; Force = $true; ErrorAction = 'SilentlyContinue'; ErrorVariable = 'hatalar' }
        if ($H.Recurse) {
            $gci.Recurse = $true
            if ($H.Derinlik) { $gci.Depth = $H.Derinlik }
        }
        $dosyalar = @(Get-ChildItem @gci | Where-Object {
            $ad = $_.Name
            @($H.Desen | Where-Object { $ad -like $_ }).Count -gt 0
        })

        if ($H.Recurse) {
            $alt = @{ LiteralPath = $k.Yol; Directory = $true; Recurse = $true; Force = $true; ErrorAction = 'SilentlyContinue' }
            if ($H.Derinlik) { $alt.Depth = $H.Derinlik }
            Get-ChildItem @alt | Select-Object -First 300 | ForEach-Object {
                $UsnKlasorleri.Add([pscustomobject]@{ Hedef = $H.Ad; Yol = $_.FullName; SurecAcik = ($acik.Count -gt 0) })
            }
        }

        if ($hatalar) {
            $erisim = @($hatalar | Where-Object { $_.Exception -is [UnauthorizedAccessException] }).Count
            if ($erisim) { Bulgu 'SARI' $H.Ad "Erişim reddedildi ($erisim öğe): $($k.Yol) - yönetici olarak çalıştırın" }
        }

        if ($dosyalar.Count -eq 0) { Aciklama 'Eşleşen dosya yok.'; continue }

        $sirali = @($dosyalar | Sort-Object LastWriteTime -Descending)
        Satir 'Eşleşen dosya sayısı' $dosyalar.Count
        Aciklama 'Son değiştirilme         Ne zaman            Boyut  Dosya'

        $yuvarlak = @()
        foreach ($d in ($sirali | Select-Object -First $ListeLimit)) {
            $isaret = @()
            $dk = ((Get-Date) - $d.LastWriteTime).TotalMinutes
            if ($dk -le $EsikDakika) { $isaret += 'YENİ' }
            if ($dk -lt -5) { $isaret += 'GELECEK-ZAMAN' }
            if ($d.CreationTime -gt $d.LastWriteTime.AddSeconds(2)) { $isaret += 'KOPYALANMIŞ?' }
            if (($d.LastWriteTime.Ticks % 10000000) -eq 0 -and ($d.CreationTime.Ticks % 10000000) -ne 0) {
                $isaret += 'YUVARLAK-ZAMAN'
                $yuvarlak += $d
            }
            $rel = $d.FullName.Substring([math]::Min($k.Yol.Length, $d.FullName.Length)).TrimStart('\')
            $renk = if ($isaret -contains 'YENİ' -or $isaret -contains 'GELECEK-ZAMAN') { 'Red' } elseif ($isaret.Count) { 'Yellow' } else { 'Gray' }
            $ek = if ($isaret.Count) { '[' + ($isaret -join ',') + ']' } else { '' }
            Write-Host ("  {0}  {1,-18} {2,9}  {3} {4}" -f (Zaman $d.LastWriteTime), (Once $d.LastWriteTime), (Boyut $d.Length), $rel, $ek) -ForegroundColor $renk
        }

        if ($H.VarlikBulgu) {
            Bulgu 'SARI' $H.Ad "$($dosyalar.Count) adet makro script / aracı bulundu (en yenisi: $($sirali[0].Name), $(Once $sirali[0].LastWriteTime))"
        }

        # Yakın zamanda değişiklik
        $enYeni = $sirali[0]
        $dkEnYeni = ((Get-Date) - $enYeni.LastWriteTime).TotalMinutes
        if ($dkEnYeni -le $EsikDakika) {
            if ($acik.Count) {
                Bulgu 'SARI' $H.Ad "$($enYeni.Name) son $EsikDakika dk içinde değişmiş - yazılım AÇIK, program kendisi yazmış olabilir ($(Once $enYeni.LastWriteTime))"
            } else {
                Bulgu 'KIRMIZI' $H.Ad "$($enYeni.Name) son $EsikDakika dk içinde değişmiş ve yazılım şu an KAPALI ($(Once $enYeni.LastWriteTime))"
            }
        }
        if ($dkEnYeni -lt -5) { Bulgu 'KIRMIZI' $H.Ad "$($enYeni.Name) gelecekteki bir tarih gösteriyor - sistem saati ya da zaman damgası oynanmış" }
        if ($yuvarlak.Count) {
            Bulgu 'SARI' $H.Ad "Saniye-altı kısmı tam sıfır olan değiştirilme zamanı ($($yuvarlak[0].Name)) - zaman damgası elle ayarlanmış olabilir, USN bölümüne bakın"
        }

        # İçerikte "macro" geçişi (bilgi amaçlı)
        if ($CsHazir) {
            $sayimlar = @()
            foreach ($d in ($sirali | Where-Object { $_.Length -gt 0 -and $_.Length -lt 50MB } | Select-Object -First 3)) {
                $c = [TRSS2.Native]::CountKeyword($d.FullName, 'macro', 20MB)
                if ($c -gt 0) { $sayimlar += "$($d.Name)=$c" }
            }
            if ($sayimlar.Count) { Satir "İçerikte 'macro' geçişi" ($sayimlar -join ', ') 'DarkCyan' }
        }

        # Bloody: kurulumdan sonra eklenen makro dosyaları
        if ($H.MakroUzanti) {
            $makrolar = @($dosyalar | Where-Object { $_.Extension -match $H.MakroUzanti })
            $kokTarih = (Get-Item -LiteralPath $k.Yol -Force).CreationTime
            $sonradan = @($makrolar | Where-Object { $_.CreationTime -gt $kokTarih.AddHours(1) } | Sort-Object CreationTime -Descending)
            Satir 'Makro dosyası (toplam)' $makrolar.Count
            Satir 'Kurulum klasörü tarihi' (Zaman $kokTarih)
            if ($sonradan.Count) {
                Satir 'Kurulumdan sonra eklenen' $sonradan.Count 'Yellow'
                foreach ($d in ($sonradan | Select-Object -First 10)) {
                    Write-Host ("    + {0}  {1}" -f (Zaman $d.CreationTime), $d.FullName.Substring($k.Yol.Length).TrimStart('\')) -ForegroundColor Yellow
                }
                Bulgu 'SARI' $H.Ad "Kurulumdan sonra eklenmiş/içe aktarılmış $($sonradan.Count) makro dosyası var (en yenisi: $($sonradan[0].Name), $(Once $sonradan[0].CreationTime))"
                [void](Yakinlik-Bulgu $sonradan[0].CreationTime $H.Ad "Yeni makro dosyası eklenmiş: $($sonradan[0].Name)")
            }
        }
    }
}

# ========================= 4) USN Journal ==============================

function Usn-Analizi {
    Bolum '4) NTFS USN Journal (değişiklik günlüğü - zaman damgası oynansa da kayıt kalır)'
    if (-not $Admin)   { Aciklama 'Yönetici yetkisi gerekiyor, atlandı.' 'Yellow'; return }
    if (-not $CsHazir) { Aciklama 'Yardımcı kod derlenemediği için atlandı.' 'Yellow'; return }

    # Hedef klasörlerin dosya referans numaraları
    $harita = @{}
    foreach ($k in $UsnKlasorleri) {
        $id = [TRSS2.Native]::GetFileId($k.Yol)
        if ($id -ne 0 -and -not $harita.ContainsKey($id)) { $harita[$id] = $k }
    }

    $uzantilar = [string[]]@('.ahk', '.ahk2', '.amc2', '.mgn2', '.bwp', '.bmc', '.bwd', '.mcf', '.dct', '.cuecfg', '.cueprofile')
    $icerenler = [string[]]@('autohotkey', 'tinytask', 'bloody', 'lghub', 'macro', 'xmousebutton', 'by-combo', 'glorious')
    $surucular = @(@($UsnKlasorleri | ForEach-Object { [IO.Path]::GetPathRoot($_.Yol) }) + "$env:SystemDrive\" | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($s in $surucular) {
        AltBaslik "Sürücü $s"
        $parents = [uint64[]]@($harita.Keys | Where-Object { [IO.Path]::GetPathRoot($harita[$_].Yol) -eq $s })
        Aciklama 'Journal okunuyor (birkaç saniye sürebilir)...'
        $kayitlar = [TRSS2.Usn]::Read($s, $parents, $uzantilar, $icerenler)
        if ($null -eq $kayitlar) { Aciklama ([TRSS2.Usn]::LastError) 'Yellow'; continue }
        if ([TRSS2.Usn]::LastError) { Aciklama ([TRSS2.Usn]::LastError) 'Yellow' }

        Satir 'Okunan kayıt' ([TRSS2.Usn]::RecordCount)
        Satir 'Journal kapsamı' ("{0} tarihinden bu yana ({1})" -f (Zaman ([TRSS2.Usn]::EarliestTime)), (Once ([TRSS2.Usn]::EarliestTime)))
        $kapsamSaat = ((Get-Date) - [TRSS2.Usn]::EarliestTime).TotalHours
        if ($kapsamSaat -lt 1) {
            Bulgu 'SARI' 'USN' "Sürücü $s journal kapsamı çok kısa ($([math]::Round($kapsamSaat * 60)) dk) - journal silinmiş/sıfırlanmış olabilir"
        }

        $hedefKayit = @($kayitlar | Where-Object { $harita.ContainsKey($_.Parent) })
        $digerKayit = @($kayitlar | Where-Object { -not $harita.ContainsKey($_.Parent) })

        # --- a) Hedef klasörlerdeki olaylar ---
        foreach ($grup in ($hedefKayit | Group-Object { $harita[$_.Parent].Hedef })) {
            Write-Host ""
            Write-Host "  > $($grup.Name)" -ForegroundColor DarkCyan
            $kayitlarG = @($grup.Group | Sort-Object Time -Descending)
            foreach ($r in ($kayitlarG | Where-Object { -not $_.IsDir } | Select-Object -First 8)) {
                $renk = if ($r.Silindi) { 'Yellow' } elseif (((Get-Date) - $r.Time).TotalMinutes -le $EsikDakika) { 'Red' } else { 'Gray' }
                Write-Host ("    {0}  {1,-18} {2,-40} {3}" -f (Zaman $r.Time), (Once $r.Time), $r.Name, (Usn-Neden $r)) -ForegroundColor $renk
            }

            # Zaman damgası karşılaştırması
            $veri = @($kayitlarG | Where-Object { -not $_.IsDir -and ($_.VeriDegisti -or $_.YeniAd -or $_.Olusturuldu) })
            foreach ($ad in ($veri | Group-Object Name)) {
                $sonUsn = ($ad.Group | Sort-Object Time -Descending | Select-Object -First 1)
                $klasor = $harita[$sonUsn.Parent].Yol
                $dosya = Join-Path $klasor $ad.Name
                if (-not (Test-Path -LiteralPath $dosya)) { continue }
                $f = Get-Item -LiteralPath $dosya -Force
                if (($sonUsn.Time - $f.LastWriteTime).TotalMinutes -gt 2) {
                    Bulgu 'KIRMIZI' 'USN' ("{0}: USN'e göre içerik {1} tarihinde yazılmış ama dosya {2} gösteriyor - zaman damgası geri alınmış ya da dosya başka yerden kopyalanmış" -f $ad.Name, (Zaman $sonUsn.Time), (Zaman $f.LastWriteTime))
                }
            }

            # Yakın zamanda değişiklik (dosya zamanından bağımsız)
            $sonVeri = $veri | Sort-Object Time -Descending | Select-Object -First 1
            if ($sonVeri -and ((Get-Date) - $sonVeri.Time).TotalMinutes -le $EsikDakika) {
                $sev = if ($harita[$sonVeri.Parent].SurecAcik) { 'SARI' } else { 'KIRMIZI' }
                Bulgu $sev 'USN' "$($grup.Name): $($sonVeri.Name) son $EsikDakika dk içinde yazılmış ($(Once $sonVeri.Time))"
            }

            $silinen = @($kayitlarG | Where-Object { $_.Silindi })
            if ($silinen.Count) {
                $s0 = $silinen[0]
                [void](Yakinlik-Bulgu $s0.Time 'USN' "$($grup.Name) klasöründen dosya silinmiş: $($s0.Name)")
            }
            $zamanDegisimi = @($kayitlarG | Where-Object { $_.TemelBilgi -and -not $_.VeriDegisti -and -not $_.Olusturuldu -and -not $_.IsDir })
            if ($zamanDegisimi.Count) {
                Aciklama ("Zaman/öznitelik değişimi kaydı: {0} adet (en yenisi {1} - {2})" -f $zamanDegisimi.Count, $zamanDegisimi[0].Name, (Zaman $zamanDegisimi[0].Time)) 'DarkYellow'
            }
        }

        # --- b) Hedef klasörler dışında isme/uzantıya göre eşleşenler ---
        $onemli = @($digerKayit | Where-Object { $_.Olusturuldu -or $_.Silindi -or $_.YeniAd } | Sort-Object Time -Descending)
        if ($onemli.Count) {
            Write-Host ""
            Write-Host "  > Diğer konumlarda makro/yazılım ile ilgili oluşturma, silme, yeniden adlandırma" -ForegroundColor DarkCyan
            $yolOnbellek = @{}
            foreach ($r in ($onemli | Select-Object -First 25)) {
                if (-not $yolOnbellek.ContainsKey($r.Parent)) { $yolOnbellek[$r.Parent] = [TRSS2.Usn]::ResolvePath($s, $r.Parent) }
                $ust = $yolOnbellek[$r.Parent]
                if (-not $ust) { $ust = '(klasör artık yok)' }
                $tur = if ($r.IsDir) { '[KLASÖR] ' } else { '' }
                $renk = if ($r.Silindi) { 'Yellow' } else { 'Gray' }
                Write-Host ("    {0}  {1,-18} {2}{3}  <- {4}  [{5}]" -f (Zaman $r.Time), (Once $r.Time), $tur, $r.Name, $ust, (Usn-Neden $r)) -ForegroundColor $renk
            }

            foreach ($r in $onemli) {
                $ln = $r.Name.ToLowerInvariant()
                if ($r.IsDir -and $r.Silindi -and $ln -match 'lghub|bloody|by-combo|glorious|autohotkey|xmousebutton|tinytask') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Yazılım klasörü silinmiş: $($r.Name) (kaldırılmış olabilir)")
                } elseif ($r.Olusturuldu -and $ln -match '\.(ahk2?)$|tinytask|autohotkey') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Makro aracı / script oluşturulmuş: $($r.Name)")
                } elseif ($r.Silindi -and $ln -match '\.(ahk2?|amc2|mgn2|bwp|bmc|mcf|dct|cuecfg|cueprofile)$|tinytask') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Makro dosyası silinmiş: $($r.Name)")
                }
            }
        }
    }
}

function Usn-Neden($r) {
    $l = @()
    if ($r.Olusturuldu) { $l += 'oluşturma' }
    if (($r.Reason -band 1) -ne 0) { $l += 'üzerine yazma' }
    if (($r.Reason -band 2) -ne 0) { $l += 'genişleme' }
    if (($r.Reason -band 4) -ne 0) { $l += 'kırpma' }
    if ($r.Silindi) { $l += 'SİLME' }
    if ($r.EskiAd) { $l += 'eski ad' }
    if ($r.YeniAd) { $l += 'yeni ad' }
    if ($r.TemelBilgi) { $l += 'zaman/öznitelik' }
    return ($l -join ', ')
}

# =========================== 5) Tarayıcılar ============================

$WebHedefler = @(
    @{ Isim = 'LAMZU Web Hub';               Alanlar = @('lamzu.net', 'lamzu.com') }
    @{ Isim = 'Keychron Launcher';           Alanlar = @('launcher.keychron.com') }
    @{ Isim = 'WLmouse Web Hub';             Alanlar = @('wlmouse.com/pages/web-hub', 'gm.wlmouse.gg', 'chn.wlmouse.com') }
    @{ Isim = 'Corsair Web Hub';             Alanlar = @('corsair.com/web-hub', 'corsair.com/sabre-web-hub') }
    @{ Isim = 'Razer (web tabanlı)';         Alanlar = @('synapse.razer.com', 'razer.com/synapse-4') }
    @{ Isim = 'Genel "web hub" adresleri';   Alanlar = @('webhub', 'web-hub', 'web_hub') }
)
$IndirmeKelimeleri = @('bloody', 'lghub', 'g hub', 'ghub', 'synapse', 'razer', 'icue', 'glorious', 'swarm', 'steelseries', 'ngenuity', 'autohotkey', '.ahk', 'tinytask', 'x-mouse', 'xmouse', 'macro', 'oscar')

$ChromiumKokleri = @(
    @{ Ad = 'Google Chrome';  Alt = 'Local:Google\Chrome\User Data' }
    @{ Ad = 'Chrome Beta';    Alt = 'Local:Google\Chrome Beta\User Data' }
    @{ Ad = 'Microsoft Edge'; Alt = 'Local:Microsoft\Edge\User Data' }
    @{ Ad = 'Brave';          Alt = 'Local:BraveSoftware\Brave-Browser\User Data' }
    @{ Ad = 'Vivaldi';        Alt = 'Local:Vivaldi\User Data' }
    @{ Ad = 'Yandex';         Alt = 'Local:Yandex\YandexBrowser\User Data' }
    @{ Ad = 'Chromium';       Alt = 'Local:Chromium\User Data' }
    @{ Ad = 'Opera';          Alt = 'Roaming:Opera Software\Opera Stable' }
    @{ Ad = 'Opera GX';       Alt = 'Roaming:Opera Software\Opera GX Stable' }
)
$FirefoxKokleri = @('Roaming:Mozilla\Firefox\Profiles\*', 'Roaming:Waterfox\Profiles\*', 'Roaming:LibreWolf\Profiles\*', 'Roaming:zen\Profiles\*')

function Chromium-Zaman($us) {
    try { $v = [long]$us; if ($v -le 0) { return $null }; return [DateTime]::FromFileTimeUtc($v * 10).ToLocalTime() } catch { return $null }
}
function Firefox-Zaman($us) {
    try { $v = [long]$us; if ($v -le 0) { return $null }; return [DateTimeOffset]::FromUnixTimeMilliseconds([long]($v / 1000)).LocalDateTime } catch { return $null }
}
function Sql-Kacis([string]$s) { return $s.Replace("'", "''") }

function Gecici-Kopya([string]$Kaynak, [string]$Klasor) {
    $hedef = Join-Path $Klasor ([IO.Path]::GetFileName($Kaynak))
    if (-not [TRSS2.Native]::CopyShared($Kaynak, $hedef)) { return $null }
    foreach ($ek in '-wal', '-journal') {
        if (Test-Path -LiteralPath ($Kaynak + $ek)) { [void][TRSS2.Native]::CopyShared($Kaynak + $ek, $hedef + $ek) }
    }
    return $hedef
}

function Sql([string]$Db, [string]$Sorgu) {
    try {
        $r = [TRSS2.Sqlite]::Query($Db, $Sorgu)
        return , $r
    } catch {
        $m = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Aciklama "SQLite hatası: $m" 'Yellow'
        return , $null
    }
}

function Gecmis-Sonucu([string]$Tarayici, [string]$Isim, $Satir, [string]$ZamanTuru) {
    if ($null -eq $Satir -or [string]::IsNullOrEmpty($Satir[0]) -or $Satir[2] -eq '0') { return }
    $t = if ($ZamanTuru -eq 'chromium') { Chromium-Zaman $Satir[1] } else { Firefox-Zaman $Satir[1] }
    Write-Host ("    {0,-28} son ziyaret: {1}  ({2}, toplam {3} ziyaret)" -f $Isim, (Zaman $t), (Once $t), $Satir[2])
    Write-Host ("      {0}" -f $Satir[0]) -ForegroundColor DarkGray
    [void](Yakinlik-Bulgu $t 'Tarayıcı' "$Tarayici - $Isim ziyaret edilmiş")
}

function Chromium-Profil-Kontrol([string]$Tarayici, [string]$Profil) {
    $etiket = "$Tarayici / $(Split-Path $Profil -Leaf)"
    $history = Join-Path $Profil 'History'
    $bulunan = $false

    if (Test-Path -LiteralPath $history) {
        $tmp = Join-Path $env:TEMP ("trss_" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $kopya = Gecici-Kopya $history $tmp
            if (-not $kopya) { Aciklama "$etiket : History kopyalanamadı" 'Yellow' }
            else {
                Write-Host "  $etiket" -ForegroundColor White
                foreach ($h in $WebHedefler) {
                    $kosul = ($h.Alanlar | ForEach-Object { "u.url LIKE '%$(Sql-Kacis $_)%'" }) -join ' OR '
                    $rows = Sql $kopya "SELECT u.url, MAX(v.visit_time), COUNT(*) FROM urls u JOIN visits v ON u.id = v.url WHERE ($kosul);"
                    if ($rows -and $rows.Count) { Gecmis-Sonucu $etiket $h.Isim $rows[0] 'chromium' }
                }
                $kosul = ($IndirmeKelimeleri | ForEach-Object { "lower(target_path) LIKE '%$(Sql-Kacis $_)%'" }) -join ' OR '
                $rows = Sql $kopya "SELECT target_path, start_time, tab_url FROM downloads WHERE ($kosul) ORDER BY start_time DESC LIMIT 10;"
                if ($rows -and $rows.Count) {
                    Aciklama 'İlgili indirmeler:' 'DarkCyan'
                    foreach ($r in $rows) {
                        $t = Chromium-Zaman $r[1]
                        Write-Host ("    {0}  {1,-18} {2}" -f (Zaman $t), (Once $t), $r[0])
                        [void](Yakinlik-Bulgu $t 'İndirme' "$etiket - indirilmiş: $([IO.Path]::GetFileName($r[0]))" $true)
                    }
                }
                $bulunan = $true
            }
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # WebHID / WebUSB / WebSerial izinleri (geçmiş silinse bile kalır)
    $pref = Join-Path $Profil 'Preferences'
    if (Test-Path -LiteralPath $pref) {
        try {
            $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $ser.MaxJsonLength = [int]::MaxValue
            $ser.RecursionLimit = 1000
            $fs = [IO.File]::Open($pref, 'Open', 'Read', 'ReadWrite, Delete')
            try { $metin = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
            $j = $ser.DeserializeObject($metin)
            $exc = DGet (DGet (DGet $j 'profile') 'content_settings') 'exceptions'
            foreach ($tur in 'hid_chooser_data', 'usb_chooser_data', 'serial_chooser_data') {
                $d = DGet $exc $tur
                if ($null -eq $d -or $d.Count -eq 0) { continue }
                if (-not $bulunan) { Write-Host "  $etiket" -ForegroundColor White; $bulunan = $true }
                $turAd = switch ($tur) { 'hid_chooser_data' { 'WebHID' } 'usb_chooser_data' { 'WebUSB' } default { 'WebSerial' } }
                foreach ($site in @($d.Keys)) {
                    $v = $d[$site]
                    $t = Chromium-Zaman (DGet $v 'last_modified')
                    $js = $ser.Serialize((DGet $v 'setting'))
                    $cihazlar = @([regex]::Matches($js, '"name":"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }) -join '; '
                    Write-Host ("    {0} izni: {1,-40} {2}  {3}" -f $turAd, $site.Split(',')[0], (Zaman $t), $cihazlar) -ForegroundColor Yellow
                    [void](Yakinlik-Bulgu $t 'Tarayıcı' "$etiket - $($site.Split(',')[0]) sitesine $turAd cihaz izni verilmiş/güncellenmiş")
                }
            }
        } catch {
            Aciklama "$etiket : Preferences okunamadı ($($_.Exception.Message))" 'DarkYellow'
        }
    }

    # Site verisi (IndexedDB) - geçmiş silinse bile kalabilir
    $idb = Join-Path $Profil 'IndexedDB'
    if (Test-Path -LiteralPath $idb) {
        $hostlar = @($WebHedefler | ForEach-Object { $_.Alanlar } | Where-Object { $_ -match '\.' } | ForEach-Object { $_.Split('/')[0] } | Select-Object -Unique)
        foreach ($d in @(Get-ChildItem -LiteralPath $idb -Directory -Force -ErrorAction SilentlyContinue)) {
            $h = $hostlar | Where-Object { $d.Name -like "*$_*" } | Select-Object -First 1
            if (-not $h) { continue }
            $son = Get-ChildItem -LiteralPath $d.FullName -File -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $t = if ($son) { $son.LastWriteTime } else { $d.LastWriteTime }
            if (-not $bulunan) { Write-Host "  $etiket" -ForegroundColor White; $bulunan = $true }
            Write-Host ("    Site verisi (IndexedDB): {0,-45} son yazma: {1}  ({2})" -f $d.Name, (Zaman $t), (Once $t))
            [void](Yakinlik-Bulgu $t 'Tarayıcı' "$etiket - $h site verisi güncellenmiş")
        }
    }
}

function Firefox-Profil-Kontrol([string]$Profil) {
    $places = Join-Path $Profil 'places.sqlite'
    if (-not (Test-Path -LiteralPath $places)) { return }
    $etiket = "Firefox tabanlı / $(Split-Path $Profil -Leaf)"
    $tmp = Join-Path $env:TEMP ("trss_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $kopya = Gecici-Kopya $places $tmp   # -wal dosyası da kopyalanır (son ziyaretler oradadır)
        if (-not $kopya) { Aciklama "$etiket : places.sqlite kopyalanamadı" 'Yellow'; return }
        Write-Host "  $etiket" -ForegroundColor White
        foreach ($h in $WebHedefler) {
            $kosul = ($h.Alanlar | ForEach-Object { "p.url LIKE '%$(Sql-Kacis $_)%'" }) -join ' OR '
            $rows = Sql $kopya "SELECT p.url, MAX(v.visit_date), COUNT(*) FROM moz_places p JOIN moz_historyvisits v ON p.id = v.place_id WHERE ($kosul);"
            if ($rows -and $rows.Count) { Gecmis-Sonucu $etiket $h.Isim $rows[0] 'firefox' }
        }
        $kosul = ($IndirmeKelimeleri | ForEach-Object { "lower(a.content) LIKE '%$(Sql-Kacis $_)%'" }) -join ' OR '
        $rows = Sql $kopya "SELECT a.content, a.dateAdded FROM moz_annos a JOIN moz_anno_attributes n ON a.anno_attribute_id = n.id WHERE n.name = 'downloads/destinationFileURI' AND ($kosul) ORDER BY a.dateAdded DESC LIMIT 10;"
        if ($rows -and $rows.Count) {
            Aciklama 'İlgili indirmeler:' 'DarkCyan'
            foreach ($r in $rows) {
                $t = Firefox-Zaman $r[1]
                Write-Host ("    {0}  {1,-18} {2}" -f (Zaman $t), (Once $t), [uri]::UnescapeDataString($r[0]))
                [void](Yakinlik-Bulgu $t 'İndirme' "$etiket - indirilmiş: $([IO.Path]::GetFileName([uri]::UnescapeDataString($r[0])))" $true)
            }
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Tarayici-Kontrol {
    Bolum '5) Tarayıcılar: web hub ziyaretleri, indirmeler, WebHID izinleri'
    if (-not $CsHazir) { Aciklama 'Yardımcı kod derlenemediği için atlandı.' 'Yellow'; return }
    Aciklama 'Not: Gizli sekmede yapılan ziyaretler geçmişe yazılmaz; WebHID izinleri ve site verisi ise çoğu zaman kalır.'

    $herhangi = $false
    foreach ($c in $ChromiumKokleri) {
        foreach ($kok in @(Klasorleri-Coz @($c.Alt) $null)) {
            # DİKKAT: $Profiller ile aynı ad kullanılmamalı (PowerShell değişken adları büyük/küçük harf duyarsız)
            $tarayiciProfilleri = @($kok.Yol) + @(Get-ChildItem -LiteralPath $kok.Yol -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            foreach ($p in $tarayiciProfilleri) {
                if ((Test-Path -LiteralPath (Join-Path $p 'History')) -or (Test-Path -LiteralPath (Join-Path $p 'Preferences'))) {
                    $herhangi = $true
                    Chromium-Profil-Kontrol "$($c.Ad) [$($kok.Profil)]" $p
                }
            }
        }
    }
    foreach ($kok in @(Klasorleri-Coz $FirefoxKokleri $null)) {
        $herhangi = $true
        Firefox-Profil-Kontrol $kok.Yol
    }
    if (-not $herhangi) { Aciklama 'Desteklenen tarayıcı profili bulunamadı.' 'Yellow' }
}

# ============================ 6) Mouse / HID ===========================

$SupheliVid = @{
    '2341' = 'Arduino'
    '2A03' = 'Arduino (arduino.org)'
    '1B4F' = 'SparkFun (Pro Micro)'
    '239A' = 'Adafruit'
    '16C0' = 'Teensy / V-USB'
    '2E8A' = 'Raspberry Pi (Pico / RP2040)'
    '1A86' = 'WCH (CH340 / CH9329 - KMBox tarzı cihazlarda sık, ama ucuz çevre birimlerinde de olabilir)'
}

function Pnp-Ozellik([string]$Id, [string]$Anahtar) {
    try { return (Get-PnpDeviceProperty -InstanceId $Id -KeyName $Anahtar -ErrorAction Stop).Data } catch { return $null }
}

function Vid-Pid([string]$Id) {
    $v = $null; $p = $null
    if ($Id -match 'VID_([0-9A-F]{4})') { $v = $Matches[1].ToUpper() }
    elseif ($Id -match 'VID&[0-9A-F]{4}([0-9A-F]{4})') { $v = $Matches[1].ToUpper() }   # Bluetooth
    if ($Id -match 'PID_([0-9A-F]{4})') { $p = $Matches[1].ToUpper() }
    elseif ($Id -match 'PID&([0-9A-F]{4})') { $p = $Matches[1].ToUpper() }
    return [pscustomobject]@{ VID = $v; PID = $p }
}

function Urun-Adi([string]$Id) {
    $cur = $Id
    for ($i = 0; $i -lt 4 -and $cur; $i++) {
        $d = Pnp-Ozellik $cur 'DEVPKEY_Device_BusReportedDeviceDesc'
        if ($d) { return $d }
        $cur = Pnp-Ozellik $cur 'DEVPKEY_Device_Parent'
    }
    return $null
}

function Mouse-Kontrol {
    Bolum '6) Bağlı mouse / HID cihazları'
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) { Aciklama 'Get-PnpDevice bulunamadı (Windows 10+ gerekir).' 'Yellow'; return }

    $simdiki = @(Get-PnpDevice -Class Mouse -PresentOnly -ErrorAction SilentlyContinue)
    $kayitlar = foreach ($m in $simdiki) {
        $vp = Vid-Pid $m.InstanceId
        $tur = if ($vp.VID) { 'Harici' } elseif ($m.InstanceId -match '^(ACPI|HID\\VEN_|HID\\(ELAN|SYNA|MSFT))') { 'Dahili' } else { 'Sanal' }
        [pscustomobject]@{
            Ad        = $m.FriendlyName
            Urun      = Urun-Adi $m.InstanceId
            VID       = $vp.VID
            PID       = $vp.PID
            Container = [string](Pnp-Ozellik $m.InstanceId 'DEVPKEY_Device_ContainerId')
            Takilma   = Pnp-Ozellik $m.InstanceId 'DEVPKEY_Device_LastArrivalDate'
            Tur       = $tur
            Id        = $m.InstanceId
        }
    }
    $kayitlar = @($kayitlar)

    $harici = @($kayitlar | Where-Object { $_.Tur -eq 'Harici' })
    $gruplar = @($harici | Group-Object { if ($_.Container -and $_.Container -notmatch 'ffffffffffff') { $_.Container } else { $_.Id } })

    Satir 'Mouse arayüzü (toplam)' $kayitlar.Count
    Satir 'Fiziksel harici mouse' $gruplar.Count $(if ($gruplar.Count -gt 1) { 'Yellow' } else { 'Green' })
    Satir 'Dahili (touchpad / PS2)' @($kayitlar | Where-Object { $_.Tur -eq 'Dahili' }).Count
    Satir 'Sanal (RDP vb.)' @($kayitlar | Where-Object { $_.Tur -eq 'Sanal' }).Count
    Aciklama 'Bir oyuncu faresi Windows''ta genelde 2-3 "HID-compliant mouse" arayüzü açar; bu yüzden fiziksel sayı ContainerId''ye göre hesaplanır.'
    Aciklama 'Kablosuz alıcı (dongle) tek bir fiziksel cihaz olarak sayılır.'

    $i = 0
    foreach ($g in $gruplar) {
        $i++
        $ilk = $g.Group[0]
        $urun = ($g.Group | Where-Object { $_.Urun } | Select-Object -First 1).Urun
        if (-not $urun) { $urun = $ilk.Ad }
        $takilma = ($g.Group | Where-Object { $_.Takilma } | Sort-Object Takilma -Descending | Select-Object -First 1).Takilma
        AltBaslik "Mouse #$i - $urun"
        Satir 'VID:PID' "$($ilk.VID):$($ilk.PID)"
        Satir 'Arayüz sayısı' $g.Count
        Satir 'Son takılma' ("{0}  ({1})" -f (Zaman $takilma), (Once $takilma))
        Satir 'Instance' $ilk.Id 'DarkGray'
        if ($SupheliVid.ContainsKey($ilk.VID)) {
            Bulgu 'KIRMIZI' 'Cihaz' "Mouse olarak görünen cihazın VID'i $($ilk.VID) = $($SupheliVid[$ilk.VID]) (mikrodenetleyici / spoof cihaz olabilir)"
        }
        if ($takilma) { [void](Yakinlik-Bulgu $takilma 'Cihaz' "Mouse '$urun' kısa süre önce takılmış" $true) }
    }

    if ($gruplar.Count -gt 1) {
        Bulgu 'SARI' 'Cihaz' "Aynı anda $($gruplar.Count) fiziksel harici mouse bağlı - ikinci cihaz (KMBox/Arduino/makro cihazı) olabilir, kontrol edin"
    }
    $ayni = @($gruplar | ForEach-Object { "$($_.Group[0].VID):$($_.Group[0].PID)" } | Group-Object | Where-Object { $_.Count -gt 1 })
    foreach ($a in $ayni) {
        Bulgu 'SARI' 'Cihaz' "Aynı VID:PID ($($a.Name)) iki farklı fiziksel cihazda görünüyor - klon/spoof cihaz olabilir"
    }

    # Sonradan çıkarılan mouse'lar
    AltBaslik 'Daha önce bağlanmış, şu an bağlı olmayan mouse''lar (en son çıkarılanlar)'
    $simdikiIdler = @($simdiki | ForEach-Object { $_.InstanceId })
    $eski = @(Get-PnpDevice -Class Mouse -ErrorAction SilentlyContinue | Where-Object { $simdikiIdler -notcontains $_.InstanceId } | ForEach-Object {
        [pscustomobject]@{
            Ad       = $_.FriendlyName
            Urun     = Urun-Adi $_.InstanceId
            VP       = (Vid-Pid $_.InstanceId)
            Cikarma  = Pnp-Ozellik $_.InstanceId 'DEVPKEY_Device_LastRemovalDate'
            Id       = $_.InstanceId
        }
    } | Sort-Object Cikarma -Descending)
    if ($eski.Count -eq 0) { Aciklama 'Kayıt yok.' }
    foreach ($e in ($eski | Select-Object -First 10)) {
        $urun = if ($e.Urun) { $e.Urun } else { $e.Ad }
        Write-Host ("  {0}  {1,-18} {2}:{3}  {4}" -f (Zaman $e.Cikarma), (Once $e.Cikarma), $e.VP.VID, $e.VP.PID, $urun)
    }
    foreach ($e in $eski) {
        if ($e.Cikarma) {
            $urun = if ($e.Urun) { $e.Urun } else { $e.Ad }
            if (Yakinlik-Bulgu $e.Cikarma 'Cihaz' "Mouse '$urun' ($($e.VP.VID):$($e.VP.PID)) kısa süre önce çıkarılmış" $true) { }
        }
    }

    # Tüm cihazlarda şüpheli VID taraması (COM port olarak görünen Arduino vb.)
    AltBaslik 'Şüpheli üretici kimliği (VID) taraması - tüm cihaz sınıfları'
    $vidDesen = 'VID_(' + (($SupheliVid.Keys) -join '|') + ')'
    $supheli = @(Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match $vidDesen })
    if ($supheli.Count -eq 0) { Aciklama 'Şüpheli VID bulunamadı.' 'Green' }
    $gorulen = @{}
    foreach ($d in $supheli) {
        $vp = Vid-Pid $d.InstanceId
        $bagli = ($d.Status -eq 'OK')
        Write-Host ("  {0,-6} {1}:{2}  {3,-10} {4}  ({5})" -f $(if ($bagli) { 'BAĞLI' } else { 'geçmiş' }), $vp.VID, $vp.PID, $d.Class, $d.FriendlyName, $SupheliVid[$vp.VID]) -ForegroundColor $(if ($bagli) { 'Yellow' } else { 'DarkGray' })
        $anahtar = "$($vp.VID):$($vp.PID):$bagli"
        if ($bagli -and -not $gorulen.ContainsKey($anahtar)) {
            $gorulen[$anahtar] = $true
            Bulgu 'SARI' 'Cihaz' "Bağlı cihaz: $($d.FriendlyName) [$($vp.VID):$($vp.PID)] - $($SupheliVid[$vp.VID])"
        }
    }
    Aciklama 'Not: KMBox gibi cihazlar çoğu zaman gerçek bir farenin VID/PID''ini kopyalar; bu yüzden VID temiz olsa bile fiziksel mouse sayısı ve tıklama testi önemlidir.'
}

# ========================== 7) Tıklama testi ===========================

function Istatistik([double[]]$x) {
    if (-not $x -or $x.Count -lt 2) { return $null }
    $ort = ($x | Measure-Object -Average).Average
    $toplam = 0.0
    foreach ($v in $x) { $toplam += ($v - $ort) * ($v - $ort) }
    $ss = [math]::Sqrt($toplam / ($x.Count - 1))
    $cv = 0
    if ($ort -gt 0) { $cv = $ss / $ort }
    return [pscustomobject]@{
        N   = $x.Count
        Ort = $ort
        SS  = $ss
        CV  = $cv
        Min = ($x | Measure-Object -Minimum).Minimum
        Max = ($x | Measure-Object -Maximum).Maximum
    }
}

function Tiklama-Testi {
    Bolum '7) Tıklama testi (makro davranış analizi)'
    if (-not $CsHazir) { Aciklama 'Yardımcı kod derlenemediği için atlandı.' 'Yellow'; return }
    if (-not [Environment]::UserInteractive) { Aciklama 'Etkileşimsiz oturum, atlandı.'; return }

    Aciklama "Oyuncu açılan pencerenin içine $TestSuresiSn saniye boyunca SOL tık ile olabildiğince hızlı tıklar."
    Aciklama 'Makro tuşu varsa (yan tuş vb.) testin ikinci yarısında ona da basması istenebilir.'
    $cevap = Read-Host '  Tıklama testi yapılsın mı? [E/h]'
    if ($cevap -match '^\s*(h|n)') { Aciklama 'Test atlandı.'; return }

    $giris = "Bu pencerenin içine SOL tık ile olabildiğince hızlı tıklayın.`n`nSüre ilk tıkla başlar ($TestSuresiSn sn)."
    $f = New-Object TRSS2.ClickTestForm -ArgumentList $TestSuresiSn, $giris, "Kalan: {0:0.0} sn`n`nSol tık: {1}"
    [void]$f.ShowDialog()

    if (-not $f.HookOk) { Aciklama 'Mouse hook kurulamadı; injected kontrolü yapılamadı.' 'Yellow' }
    if (-not $f.RawOk)  { Aciklama 'Raw Input kaydı yapılamadı; cihaz bazlı analiz yapılamadı.' 'Yellow' }
    if (-not $f.Started) { Aciklama 'Tıklama algılanmadı, test iptal.' 'Yellow'; $f.Dispose(); return }

    $limit = $TestSuresiSn * 1000
    $olaylar = @($f.ClickEvents | Where-Object { $_.T -le $limit })
    $sol = @($olaylar | Where-Object { $_.Button -eq 0 } | Sort-Object T)
    $downs = @($sol | Where-Object { $_.Down })
    $n = $downs.Count

    $araliklar = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $n; $i++) { $araliklar.Add($downs[$i].T - $downs[$i - 1].T) }

    $tutmalar = New-Object System.Collections.Generic.List[double]
    $bekleyen = $null
    foreach ($e in $sol) {
        if ($e.Down) { $bekleyen = $e.T }
        elseif ($null -ne $bekleyen) { $tutmalar.Add($e.T - $bekleyen); $bekleyen = $null }
    }

    $sure = if ($n -gt 1) { ($downs[$n - 1].T - $downs[0].T) / 1000 } else { 0 }
    $cps = if ($sure -gt 0) { ($n - 1) / $sure } else { 0 }
    $ia = Istatistik $araliklar.ToArray()
    $th = Istatistik $tutmalar.ToArray()

    AltBaslik 'Sol tık istatistikleri'
    Satir 'Tıklama sayısı' $n
    Satir 'Ortalama CPS' ('{0:0.0}' -f $cps)
    if ($ia) {
        Satir 'Aralık ort / sapma' ('{0:0.0} ms / {1:0.0} ms' -f $ia.Ort, $ia.SS)
        Satir 'Aralık min / max' ('{0:0.0} ms / {1:0.0} ms' -f $ia.Min, $ia.Max)
        Satir 'Değişkenlik (CV)' ('{0:0.000}  (insan tıklamasında genelde 0.15+)' -f $ia.CV)
    }
    if ($th) { Satir 'Basılı tutma ort / sapma' ('{0:0.0} ms / {1:0.0} ms' -f $th.Ort, $th.SS) }

    $modPay = 0
    if ($araliklar.Count -ge 10) {
        $mod = $araliklar | ForEach-Object { [math]::Round($_) } | Group-Object | Sort-Object Count -Descending | Select-Object -First 1
        $modDeger = [double]$mod.Name
        $modPay = @($araliklar | Where-Object { [math]::Abs($_ - $modDeger) -le 1 }).Count / $araliklar.Count
        Satir 'En sık aralık (±1 ms)' ('{0} ms  (%{1:0} tıklama)' -f $modDeger, ($modPay * 100))
    }
    $cokKisa = @($araliklar | Where-Object { $_ -lt 15 }).Count
    Satir '15 ms altı aralık' $cokKisa

    $digerTuslar = @($olaylar | Where-Object { $_.Down -and $_.Button -ne 0 } | Group-Object Button)
    foreach ($g in $digerTuslar) {
        $ad = switch ([int]$g.Name) { 1 { 'Sağ tık' } 2 { 'Orta tuş' } default { 'Yan tuş (X)' } }
        Satir $ad "$($g.Count) basış"
    }

    # --- Değerlendirme ---
    AltBaslik 'Değerlendirme'
    $injTik = @($olaylar | Where-Object { $_.Injected }).Count
    if ($injTik -gt 0) {
        Bulgu 'KIRMIZI' 'Tıklama testi' "$injTik tıklama olayı yazılımla üretilmiş (INJECTED bayrağı) - AutoHotkey / SendInput / yazılım makrosu"
    }
    if ($f.InjectedMoves -gt 0) {
        Bulgu 'KIRMIZI' 'Tıklama testi' "$($f.InjectedMoves) / $($f.TotalMoves) mouse hareketi yazılımla üretilmiş (INJECTED)"
    }
    if ($n -ge 20 -and $ia) {
        if ($ia.CV -lt 0.10) { Bulgu 'KIRMIZI' 'Tıklama testi' ('Tıklama aralıkları insan için fazla düzenli (CV={0:0.000}) - makro olasılığı yüksek' -f $ia.CV) }
        elseif ($ia.CV -lt 0.15) { Bulgu 'SARI' 'Tıklama testi' ('Tıklama aralıkları oldukça düzenli (CV={0:0.000})' -f $ia.CV) }
        if ($modPay -gt 0.5) { Bulgu 'SARI' 'Tıklama testi' ('Tıklamaların %{0:0}''ı aynı aralıkta (±1 ms) - sabit gecikmeli makro deseni' -f ($modPay * 100)) }
    }
    if ($th -and $th.N -ge 20 -and $th.SS -lt 2) {
        Bulgu 'SARI' 'Tıklama testi' ('Basılı tutma süresi neredeyse sabit (sapma {0:0.0} ms) - makro deseni olabilir' -f $th.SS)
    }
    if ($cps -gt 20 -and $n -ge 20) { Bulgu 'SARI' 'Tıklama testi' ('Çok yüksek CPS ({0:0.0})' -f $cps) }
    if ($cokKisa -gt 0) { Bulgu 'SARI' 'Tıklama testi' "$cokKisa tıklama arası 15 ms altında - makro ya da switch'te çift tıklama arızası olabilir" }

    # --- Cihaz bazlı (Raw Input) ---
    AltBaslik 'Test sırasında girdi gönderen cihazlar (Raw Input)'
    $cihazlar = @($f.Devices.Values)
    if ($cihazlar.Count -eq 0) { Aciklama 'Raw Input verisi yok.' }
    foreach ($c in $cihazlar) {
        $ad = if ($c.Name) { $c.Name } else { '(cihazsız - yazılımla üretilmiş girdi)' }
        Write-Host ("  {0,-12} tık: {1,-5} hareket: {2,-6} {3}" -f $c.Handle, $c.Clicks, $c.Moves, $ad)
    }
    if (@($cihazlar | Where-Object { $_.Handle -eq '0x0' -and ($_.Clicks + $_.Moves) -gt 0 }).Count) {
        Bulgu 'KIRMIZI' 'Tıklama testi' 'Fiziksel bir cihaza ait olmayan (hDevice=0) mouse girdisi alındı - yazılımla üretilmiş girdi'
    }
    $aktif = @($cihazlar | Where-Object { $_.Handle -ne '0x0' -and ($_.Clicks -gt 0 -or $_.Moves -gt 20) })
    if ($aktif.Count -gt 1) {
        Bulgu 'SARI' 'Tıklama testi' "Test sırasında $($aktif.Count) farklı fiziksel cihazdan mouse girdisi geldi - ikinci cihaz (KMBox/Arduino) olabilir"
    }
    Aciklama 'Not: Farenin kendi hafızasındaki (onboard) makrolar INJECTED görünmez; onları ancak aralık/tutma düzenliliği ele verir.'
    $f.Dispose()
}

# ============================ Çalıştırma ===============================

Surec-Kontrol
Kurulum-Kontrol

Bolum '3) Mouse yazılımlarının profil / makro dosyaları'
Aciklama 'Bayraklar: YENİ = eşik içinde değişmiş, KOPYALANMIŞ? = oluşturulma > değiştirilme, YUVARLAK-ZAMAN = elle ayarlanmış olabilir'
foreach ($h in $Hedefler) { Hedef-Kontrol $h }

Usn-Analizi
Tarayici-Kontrol
Mouse-Kontrol
Tiklama-Testi

# =============================== Özet ==================================

Bolum 'ÖZET'
$kirmizi = @($Bulgular | Where-Object { $_.Seviye -eq 'KIRMIZI' })
$sari    = @($Bulgular | Where-Object { $_.Seviye -eq 'SARI' })
Satir 'Kırmızı bulgu' $kirmizi.Count $(if ($kirmizi.Count) { 'Red' } else { 'Green' })
Satir 'Sarı bulgu' $sari.Count $(if ($sari.Count) { 'Yellow' } else { 'Green' })
Write-Host ""
foreach ($b in $kirmizi) { Write-Host ("  [KIRMIZI] {0,-14} {1}" -f $b.Kategori, $b.Mesaj) -ForegroundColor Red }
foreach ($b in $sari)    { Write-Host ("  [SARI]    {0,-14} {1}" -f $b.Kategori, $b.Mesaj) -ForegroundColor Yellow }
if ($Bulgular.Count -eq 0) { Aciklama 'Belirgin bir bulgu yok.' 'Green' }

Write-Host ""
Aciklama 'Hatırlatma: Dosya kontrolleri farenin kendi hafızasına yazılmış makroları göstermez;'
Aciklama 'yazılım kapatılıp kaldırılsa bile makro çalışmaya devam edebilir. Tıklama testi bu yüzden önemlidir.'
Aciklama 'Bulgular kesin kanıt değil, SS sırasında değerlendirmeye yardımcı göstergelerdir.'

if ($TranscriptAcik) {
    try { Stop-Transcript | Out-Null } catch {}
    Write-Host ""
    Write-Host "Rapor kaydedildi: $RaporYolu" -ForegroundColor Cyan
}
Write-Host "Tamamlandı." -ForegroundColor Cyan
