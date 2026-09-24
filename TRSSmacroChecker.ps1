<#
    TRSS Mouse Macro Checker v2
    ---------------------------------------------------------------
    - Tüm kullanıcı profillerini tarar (admin olarak çalıştırınca yanlış profile bakma sorunu yok)
    - Makro / sürücü yazılımlarının dosyalarını, süreçlerini ve kurulum kayıtlarını kontrol eder
    - NTFS USN Journal ile zaman damgası oynamasını ve silinen dosyaları yakalar
    - Tarayıcı geçmişi / indirmeler / WebHID izinleri (sqlite3 veya Python gerektirmez)
    - Bağlı mouse sayısı, sonradan takılan / çıkarılan cihazlar, şüpheli VID'ler
    - Mouse testi penceresi: anlık CPS + tüm tuşların tek tek kontrolü (basılan tuş çizimde yanar)

    ÖNEMLİ: Buradaki bulgular kesin kanıt değildir, ekran paylaşımında (SS)
    değerlendirmeye yardımcı olan göstergelerdir.
#>

$TRSSSurum = 'v2.2 (2026-09-24)'
$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# ------------------------------- Ayarlar -------------------------------
$EsikDakika        = 20        # bu süre içindeki değişiklikler KIRMIZI
$GunlukEsikDakika  = 24 * 60   # bu süre içindekiler SARI
$ListeLimit        = 5         # her klasörde listelenecek en yeni dosya sayısı
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
using System.Drawing.Drawing2D;
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

    public class MouseTestForm : Form
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

        public static readonly Color Cizgi   = Color.FromArgb(62, 110, 140);
        public static readonly Color Turuncu = Color.FromArgb(232, 96, 28);
        public static readonly Color Yesil   = Color.FromArgb(198, 236, 208);
        public static readonly Color YesilKoyu = Color.FromArgb(110, 196, 132);
        public static readonly Color Zemin   = Color.FromArgb(250, 250, 250);

        // Sonuclar (PowerShell okur)
        public List<ClickEvent> ClickEvents = new List<ClickEvent>();   // CPS alanindaki sol tik olaylari
        public Dictionary<long, DeviceStat> Devices = new Dictionary<long, DeviceStat>();
        public int TotalMoves = 0;
        public int InjectedMoves = 0;
        public int InjectedClicks = 0;
        public bool Started = false;
        public bool Finished = false;
        public bool RawOk = false;
        public bool HookOk = false;
        public int MaxCps = 0;
        // 0 sol, 1 sag, 2 orta, 3 geri (X1), 4 ileri (X2), 5 tekerlek yukari, 6 tekerlek asagi, 7 egim sol, 8 egim sag
        public int[] ButtonCounts = new int[9];

        internal bool[] Pressed = new bool[9];
        internal double[] FlashUntil = new double[9];
        internal Stopwatch Clock = Stopwatch.StartNew();

        static readonly string[] Names = { "Sol", "Sa\u011f", "Orta", "Geri", "\u0130leri", "Tekerlek yukar\u0131", "Tekerlek a\u015fa\u011f\u0131", "E\u011fim sol", "E\u011fim sa\u011f" };

        int durationMs;
        Stopwatch sw = new Stopwatch();
        List<double> downs = new List<double>();
        HookProc proc;
        IntPtr hook = IntPtr.Zero;
        Label lblCps, lblCpsCap, lblStats, lblArea, lblTuslar;
        Panel area;
        MouseDrawing drawing;
        System.Windows.Forms.Timer timer;

        public MouseTestForm(int seconds)
        {
            durationMs = seconds * 1000;
            Text = "TRSS Mouse Test";
            ClientSize = new Size(920, 620);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            TopMost = true;
            KeyPreview = true;
            BackColor = Zemin;
            Font = new Font("Segoe UI", 10f);

            Label title = new Label();
            title.Text = "MOUSE TEST";
            title.Font = new Font("Segoe UI", 28f, FontStyle.Bold);
            title.ForeColor = Turuncu;
            title.AutoSize = true;
            title.Location = new Point(18, 8);
            Controls.Add(title);

            Label sub = new Label();
            sub.Text = "Solda h\u0131zl\u0131 t\u0131klama (CPS) testi, sa\u011fda tu\u015f kontrol\u00fc: mouse'unuzdaki t\u00fcm tu\u015flara tek tek bas\u0131n, tekerle\u011fi \u00e7evirin.";
            sub.ForeColor = Cizgi;
            sub.Size = new Size(890, 24);
            sub.Location = new Point(22, 66);
            Controls.Add(sub);

            // ---- CPS testi ----
            Header("T\u0131klama testi (CPS)", 22, 100);

            lblCps = new Label();
            lblCps.Font = new Font("Segoe UI", 56f, FontStyle.Bold);
            lblCps.ForeColor = Turuncu;
            lblCps.Size = new Size(440, 108);
            lblCps.Location = new Point(14, 116);
            lblCps.TextAlign = ContentAlignment.MiddleLeft;
            Controls.Add(lblCps);

            lblCpsCap = new Label();
            lblCpsCap.ForeColor = Cizgi;
            lblCpsCap.Font = new Font("Segoe UI", 12f);
            lblCpsCap.AutoSize = true;
            lblCpsCap.Location = new Point(24, 226);
            Controls.Add(lblCpsCap);

            lblStats = new Label();
            lblStats.ForeColor = Cizgi;
            lblStats.Size = new Size(450, 24);
            lblStats.Location = new Point(24, 252);
            Controls.Add(lblStats);

            area = new Panel();
            area.Location = new Point(22, 282);
            area.Size = new Size(440, 244);
            area.BackColor = Color.FromArgb(232, 241, 247);
            area.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(area);

            lblArea = new Label();
            lblArea.Dock = DockStyle.Fill;
            lblArea.TextAlign = ContentAlignment.MiddleCenter;
            lblArea.ForeColor = Cizgi;
            lblArea.Font = new Font("Segoe UI", 14f, FontStyle.Bold);
            area.Controls.Add(lblArea);

            Button btnReset = new Button();
            btnReset.Text = "Yeniden";
            btnReset.Size = new Size(120, 34);
            btnReset.Location = new Point(22, 540);
            btnReset.Click += delegate { ResetCps(); };
            Controls.Add(btnReset);

            // ---- Tus kontrolu ----
            Header("Tu\u015f kontrol\u00fc", 500, 100);

            drawing = new MouseDrawing(this);
            drawing.Location = new Point(490, 128);
            drawing.Size = new Size(410, 392);
            Controls.Add(drawing);

            lblTuslar = new Label();
            lblTuslar.ForeColor = Cizgi;
            lblTuslar.Size = new Size(410, 48);
            lblTuslar.Location = new Point(500, 524);
            Controls.Add(lblTuslar);

            Button btnEnd = new Button();
            btnEnd.Text = "Bitir";
            btnEnd.Size = new Size(120, 34);
            btnEnd.Location = new Point(780, 576);
            btnEnd.Click += delegate { Close(); };
            Controls.Add(btnEnd);

            timer = new System.Windows.Forms.Timer();
            timer.Interval = 40;
            timer.Tick += OnTick;

            ResetCps();
            UpdateButtons();
        }

        Label Header(string text, int x, int y)
        {
            Label l = new Label();
            l.Text = text;
            l.Font = new Font("Segoe UI", 13f, FontStyle.Bold);
            l.ForeColor = Cizgi;
            l.AutoSize = true;
            l.Location = new Point(x, y);
            Controls.Add(l);
            return l;
        }

        void ResetCps()
        {
            ClickEvents.Clear();
            downs.Clear();
            Started = false;
            Finished = false;
            MaxCps = 0;
            sw.Reset();
            lblCps.Text = "0";
            lblCpsCap.Text = "CPS (anl\u0131k)";
            lblArea.Text = "BURAYA SOL TIKLA\n\nTest ilk t\u0131kla ba\u015flar (" + (durationMs / 1000) + " sn)";
            UpdateStats(0, durationMs);
        }

        void UpdateStats(int n, double leftMs)
        {
            lblStats.Text = string.Format("En y\u00fcksek: {0} CPS      Toplam: {1} t\u0131k      Kalan: {2:0.0} sn", MaxCps, n, Math.Max(0.0, leftMs) / 1000.0);
        }

        void UpdateButtons()
        {
            int ok = 0;
            List<string> eksik = new List<string>();
            for (int i = 0; i < 9; i++) { if (ButtonCounts[i] > 0) ok++; else eksik.Add(Names[i]); }
            string t = "Test edilen tu\u015f: " + ok + " / 9";
            if (eksik.Count > 0) t += "\nBas\u0131lmayan: " + string.Join(", ", eksik.ToArray());
            if (lblTuslar.Text != t) lblTuslar.Text = t;
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
            timer.Start();
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            Activate();
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            if (e.KeyCode == Keys.Escape) Close();
            base.OnKeyDown(e);
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
            if (Started && !Finished)
            {
                double t = sw.Elapsed.TotalMilliseconds;
                int live = 0;
                foreach (double x in downs) if (x > t - 1000.0) live++;
                if (live > MaxCps) MaxCps = live;
                lblCps.Text = live.ToString();
                UpdateStats(downs.Count, durationMs - t);
                if (t >= durationMs)
                {
                    Finished = true;
                    double avg = downs.Count / (durationMs / 1000.0);
                    lblCps.Text = avg.ToString("0.0");
                    lblCpsCap.Text = "CPS (ortalama)";
                    lblArea.Text = "Test bitti\n\nTekrar i\u00e7in \"Yeniden\"";
                    UpdateStats(downs.Count, 0);
                }
            }
            UpdateButtons();
            drawing.Invalidate();
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
                    int hi = (int)((s.mouseData >> 16) & 0xFFFF);
                    short delta = unchecked((short)hi);
                    switch (msg)
                    {
                        case 0x200: TotalMoves++; if (inj) InjectedMoves++; break;
                        case 0x201: Btn(0, true, inj, lower); break;
                        case 0x202: Btn(0, false, inj, lower); break;
                        case 0x204: Btn(1, true, inj, lower); break;
                        case 0x205: Btn(1, false, inj, lower); break;
                        case 0x207: Btn(2, true, inj, lower); break;
                        case 0x208: Btn(2, false, inj, lower); break;
                        case 0x20B: Btn(hi == 2 ? 4 : 3, true, inj, lower); break;
                        case 0x20C: Btn(hi == 2 ? 4 : 3, false, inj, lower); break;
                        case 0x20A: Flash(delta > 0 ? 5 : 6, inj); break;
                        case 0x20E: Flash(delta > 0 ? 8 : 7, inj); break;
                    }
                }
            }
            catch { }
            return CallNextHookEx(hook, nCode, w, l);
        }

        void Btn(int i, bool down, bool inj, bool lower)
        {
            Pressed[i] = down;
            if (down) { ButtonCounts[i]++; if (inj) InjectedClicks++; }
            if (i == 0) CpsEvent(down, inj, lower);
        }

        void Flash(int i, bool inj)
        {
            ButtonCounts[i]++;
            FlashUntil[i] = Clock.Elapsed.TotalMilliseconds + 180;
            if (inj) InjectedClicks++;
        }

        void CpsEvent(bool down, bool inj, bool lower)
        {
            if (Finished) return;
            if (!Started)
            {
                if (!down || !InArea()) return;
                Started = true;
                sw.Restart();
                lblArea.Text = "T\u0131klamaya devam!";
            }
            double t = sw.Elapsed.TotalMilliseconds;
            if (t > durationMs) return;
            if (down && !InArea()) return;
            ClickEvent c = new ClickEvent();
            c.T = t; c.Button = 0; c.Down = down; c.Injected = inj; c.LowerIlInjected = lower;
            ClickEvents.Add(c);
            if (down) downs.Add(t);
        }

        bool InArea()
        {
            Point p = area.PointToClient(Cursor.Position);
            return area.ClientRectangle.Contains(p);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x00FF) HandleRaw(m.LParam);
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

    // Tus kontrolu icin mouse cizimi: basili tus turuncu, daha once basilmis tus yesil
    public class MouseDrawing : Panel
    {
        MouseTestForm f;

        public MouseDrawing(MouseTestForm form)
        {
            f = form;
            DoubleBuffered = true;
            BackColor = MouseTestForm.Zemin;
        }

        Color Fill(int i)
        {
            if (f.Pressed[i] || f.Clock.Elapsed.TotalMilliseconds < f.FlashUntil[i]) return MouseTestForm.Turuncu;
            if (f.ButtonCounts[i] > 0) return i >= 2 ? MouseTestForm.YesilKoyu : MouseTestForm.Yesil;
            return Color.White;
        }

        static GraphicsPath Rounded(Rectangle r, int rad)
        {
            GraphicsPath p = new GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        void Shape(Graphics g, Pen pen, GraphicsPath p, int i)
        {
            using (Brush b = new SolidBrush(Fill(i))) g.FillPath(b, p);
            g.DrawPath(pen, p);
        }

        void Arrow(Graphics g, Pen pen, Point[] pts, int i)
        {
            using (Brush b = new SolidBrush(Fill(i))) g.FillPolygon(b, pts);
            g.DrawPolygon(pen, pts);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            base.OnPaint(e);
            Graphics g = e.Graphics;
            g.SmoothingMode = SmoothingMode.AntiAlias;

            int bx = 140, by = 8, bw = 220, cx = bx + bw / 2, split = 170;

            using (Pen pen = new Pen(MouseTestForm.Cizgi, 3f))
            using (Pen thin = new Pen(MouseTestForm.Cizgi, 2f))
            using (Brush textBrush = new SolidBrush(MouseTestForm.Cizgi))
            using (Font fnt = new Font("Segoe UI", 10f, FontStyle.Bold))
            using (StringFormat far = new StringFormat())
            using (GraphicsPath body = new GraphicsPath())
            {
                far.Alignment = StringAlignment.Far;
                far.LineAlignment = StringAlignment.Center;

                body.AddArc(bx, by, bw, 200, 180, 180);
                body.AddLine(bx + bw, by + 100, bx + bw, 280);
                body.AddArc(bx, 180, bw, 200, 0, 180);
                body.CloseFigure();

                g.FillPath(Brushes.White, body);

                using (Region sol = new Region(body))
                {
                    sol.Intersect(new Rectangle(bx, by, cx - bx, split - by));
                    using (Brush b = new SolidBrush(Fill(0))) g.FillRegion(b, sol);
                }
                using (Region sag = new Region(body))
                {
                    sag.Intersect(new Rectangle(cx, by, bx + bw - cx, split - by));
                    using (Brush b = new SolidBrush(Fill(1))) g.FillRegion(b, sag);
                }
                g.DrawPath(pen, body);
                g.DrawLine(pen, cx, by, cx, split);
                g.DrawLine(pen, bx, split, bx + bw, split);

                g.DrawString("Sol", fnt, textBrush, bx + 30, 124);
                g.DrawString("Sa\u011f", fnt, textBrush, cx + 45, 124);

                // Tekerlek (orta tus)
                Rectangle wr = new Rectangle(cx - 14, 62, 28, 60);
                using (GraphicsPath wp = Rounded(wr, 10)) Shape(g, thin, wp, 2);
                for (int y = wr.Y + 10; y < wr.Bottom - 6; y += 8) g.DrawLine(thin, wr.X + 6, y, wr.Right - 6, y);

                // Tekerlek yukari / asagi
                Arrow(g, thin, new Point[] { new Point(cx, 24), new Point(cx - 12, 50), new Point(cx + 12, 50) }, 5);
                Arrow(g, thin, new Point[] { new Point(cx, 160), new Point(cx - 12, 134), new Point(cx + 12, 134) }, 6);

                // Tekerlek egim sol / sag
                Arrow(g, thin, new Point[] { new Point(cx - 42, 92), new Point(cx - 24, 80), new Point(cx - 24, 104) }, 7);
                Arrow(g, thin, new Point[] { new Point(cx + 42, 92), new Point(cx + 24, 80), new Point(cx + 24, 104) }, 8);

                // Yan tuslar
                Rectangle ileri = new Rectangle(bx - 10, 196, 18, 44);
                Rectangle geri  = new Rectangle(bx - 10, 248, 18, 44);
                using (GraphicsPath p = Rounded(ileri, 7)) Shape(g, thin, p, 4);
                using (GraphicsPath p = Rounded(geri, 7)) Shape(g, thin, p, 3);
                g.DrawString("\u0130leri", fnt, textBrush, new RectangleF(0, ileri.Y, bx - 18, ileri.Height), far);
                g.DrawString("Geri", fnt, textBrush, new RectangleF(0, geri.Y, bx - 18, geri.Height), far);
            }
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

Bolum "TRSS Mouse Macro Checker $TRSSSurum"
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
            'Local'       { $bazlar = @($script:Profiller | Where-Object { $_.Yol } | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = (Join-Path $_.Yol 'AppData\Local') } }) }
            'Roaming'     { $bazlar = @($script:Profiller | Where-Object { $_.Yol } | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = (Join-Path $_.Yol 'AppData\Roaming') } }) }
            'Kullanici'   { $bazlar = @($script:Profiller | Where-Object { $_.Yol } | ForEach-Object { [pscustomobject]@{ Profil = $_.Ad; Yol = $_.Yol } }) }
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
        foreach ($y in ($script:KuruluYazilimlar | Where-Object { $_.Ad -match $KayitDeseni })) {
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
    Bolum '4) USN Journal (dosya değişiklik günlüğü)'
    if (-not $Admin)   { Aciklama 'Yönetici yetkisi gerekiyor, atlandı.' 'Yellow'; return }
    if (-not $CsHazir) { Aciklama 'Yardımcı kod derlenemediği için atlandı.' 'Yellow'; return }
    Aciklama 'Dosya tarihi elle değiştirilse bile bu günlükte kayıt kalır.'

    $harita = @{}
    foreach ($k in $UsnKlasorleri) {
        $id = [TRSS2.Native]::GetFileId($k.Yol)
        if ($id -ne 0 -and -not $harita.ContainsKey($id)) { $harita[$id] = $k }
    }

    $uzantilar = [string[]]@('.ahk', '.ahk2', '.amc2', '.mgn2', '.bwp', '.bmc', '.bwd', '.mcf', '.dct', '.cuecfg', '.cueprofile')
    $icerenler = [string[]]@('autohotkey', 'tinytask', 'bloody', 'lghub', 'macro', 'xmousebutton', 'by-combo', 'glorious')
    $surucular = @(@($UsnKlasorleri | ForEach-Object { [IO.Path]::GetPathRoot($_.Yol) }) + "$env:SystemDrive\" | Where-Object { $_ } | Sort-Object -Unique)

    foreach ($s in $surucular) {
        $parents = [uint64[]]@($harita.Keys | Where-Object { [IO.Path]::GetPathRoot($harita[$_].Yol) -eq $s })
        $kayitlar = [TRSS2.Usn]::Read($s, $parents, $uzantilar, $icerenler)
        if ($null -eq $kayitlar) { Aciklama "Sürücü $s : $([TRSS2.Usn]::LastError)" 'Yellow'; continue }

        $bas = [TRSS2.Usn]::EarliestTime
        AltBaslik ("Sürücü {0}   (günlük {1} tarihinden beri)" -f $s, (Zaman $bas))
        if (((Get-Date) - $bas).TotalHours -lt 1) {
            Bulgu 'SARI' 'USN' "Sürücü $s günlüğü çok kısa ($([math]::Round(((Get-Date) - $bas).TotalMinutes)) dk) - silinmiş/sıfırlanmış olabilir"
        }

        $hedefKayit = @($kayitlar | Where-Object { $harita.ContainsKey($_.Parent) -and -not $_.IsDir })
        $digerKayit = @($kayitlar | Where-Object { -not $harita.ContainsKey($_.Parent) })

        # --- Yazılım klasörleri: tek satır özet ---
        foreach ($grup in ($hedefKayit | Group-Object { $harita[$_.Parent].Hedef } | Sort-Object Name)) {
            $veri    = @($grup.Group | Where-Object { $_.VeriDegisti -or $_.YeniAd -or $_.Olusturuldu } | Sort-Object Time -Descending)
            $silinen = @($grup.Group | Where-Object { $_.Silindi } | Sort-Object Time -Descending)
            $metin = if ($veri.Count) { "son yazma: $(Zaman $veri[0].Time) ($(Once $veri[0].Time)) - $($veri[0].Name)" } else { 'yazma yok' }
            if ($silinen.Count) { $metin += "   | $($silinen.Count) silme" }
            $yeni = $veri.Count -and ((Get-Date) - $veri[0].Time).TotalMinutes -le $EsikDakika
            Write-Host ("  {0,-34} {1}" -f $grup.Name, $metin) -ForegroundColor $(if ($yeni) { 'Red' } else { 'Gray' })

            # Zaman damgası oynanmış mı?
            foreach ($ad in ($veri | Group-Object Name)) {
                $son = $ad.Group | Select-Object -First 1
                $dosya = Join-Path $harita[$son.Parent].Yol $ad.Name
                if (-not (Test-Path -LiteralPath $dosya)) { continue }
                $f = Get-Item -LiteralPath $dosya -Force
                if (($son.Time - $f.LastWriteTime).TotalMinutes -gt 2) {
                    Bulgu 'KIRMIZI' 'USN' ("{0}: günlüğe göre {1} tarihinde yazılmış ama dosya {2} gösteriyor - tarih geri alınmış ya da dosya kopyalanmış" -f $ad.Name, (Zaman $son.Time), (Zaman $f.LastWriteTime))
                }
            }
            if ($yeni) {
                $sev = if ($harita[$veri[0].Parent].SurecAcik) { 'SARI' } else { 'KIRMIZI' }
                Bulgu $sev 'USN' "$($grup.Name): $($veri[0].Name) son $EsikDakika dk içinde yazılmış ($(Once $veri[0].Time))"
            }
            if ($silinen.Count) { [void](Yakinlik-Bulgu $silinen[0].Time 'USN' "$($grup.Name) klasöründen dosya silinmiş: $($silinen[0].Name)") }
        }

        # --- Diğer konumlar: sadece oluşturma / silme, en fazla 10 satır ---
        $onemli = @($digerKayit | Where-Object { $_.Olusturuldu -or $_.Silindi } | Sort-Object Time -Descending)
        if ($onemli.Count) {
            Write-Host '  Diğer konumlarda makro / yazılım dosyaları (son 10):' -ForegroundColor DarkCyan
            $yolOnbellek = @{}
            foreach ($r in ($onemli | Select-Object -First 10)) {
                if (-not $yolOnbellek.ContainsKey($r.Parent)) { $yolOnbellek[$r.Parent] = [TRSS2.Usn]::ResolvePath($s, $r.Parent) }
                $ust = $yolOnbellek[$r.Parent]
                if (-not $ust) { $ust = 'klasör artık yok' }
                $tur = if ($r.Silindi) { 'SİLİNDİ' } else { 'OLUŞTU' }
                Write-Host ("    {0}  {1,-8} {2}  ({3})" -f (Zaman $r.Time), $tur, $r.Name, $ust) -ForegroundColor $(if ($r.Silindi) { 'Yellow' } else { 'Gray' })
            }
            foreach ($r in $onemli) {
                $ln = $r.Name.ToLowerInvariant()
                if ($r.IsDir -and $r.Silindi -and $ln -match 'lghub|bloody|by-combo|glorious|autohotkey|xmousebutton|tinytask') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Yazılım klasörü silinmiş: $($r.Name)")
                } elseif ($r.Olusturuldu -and $ln -match '\.(ahk2?)$|tinytask|autohotkey') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Makro aracı / script oluşturulmuş: $($r.Name)")
                } elseif ($r.Silindi -and $ln -match '\.(ahk2?|amc2|mgn2|bwp|bmc|mcf|dct|cuecfg|cueprofile)$|tinytask') {
                    [void](Yakinlik-Bulgu $r.Time 'USN' "Makro dosyası silinmiş: $($r.Name)")
                }
            }
        }
        if ($hedefKayit.Count -eq 0 -and $onemli.Count -eq 0) { Aciklama 'İlgili kayıt yok.' 'Green' }
    }
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

# =========================== 7) Mouse testi ============================

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

function Mouse-Testi {
    Bolum '7) Mouse testi (CPS + tuş kontrolü)'
    if (-not $CsHazir) { Aciklama 'Yardımcı kod derlenemediği için atlandı.' 'Yellow'; return }
    if (-not [Environment]::UserInteractive) { Aciklama 'Etkileşimsiz oturum, atlandı.'; return }

    Aciklama "Açılan pencerede: solda $TestSuresiSn sn hızlı tıklama (anlık CPS), sağda tuş kontrolü."
    Aciklama 'Oyuncu tüm tuşlara tek tek basar, tekerleği çevirir, sonra "Bitir"e basar.'
    $cevap = Read-Host '  Mouse testi açılsın mı? [E/h]'
    if ($cevap -match '^\s*(h|n)') { Aciklama 'Test atlandı.'; return }

    $f = New-Object TRSS2.MouseTestForm -ArgumentList $TestSuresiSn
    [void]$f.ShowDialog()
    if (-not $f.HookOk) { Aciklama 'Mouse hook kurulamadı; test verisi eksik olabilir.' 'Yellow' }

    # ---------------- CPS ----------------
    AltBaslik 'Tıklama testi (CPS)'
    $sol   = @($f.ClickEvents | Sort-Object T)
    $downs = @($sol | Where-Object { $_.Down })
    $n = $downs.Count
    if ($n -lt 2) {
        Aciklama 'CPS testi yapılmadı.'
    } else {
        $araliklar = New-Object System.Collections.Generic.List[double]
        for ($i = 1; $i -lt $n; $i++) { $araliklar.Add($downs[$i].T - $downs[$i - 1].T) }
        $tutmalar = New-Object System.Collections.Generic.List[double]
        $bekleyen = $null
        foreach ($e in $sol) {
            if ($e.Down) { $bekleyen = $e.T }
            elseif ($null -ne $bekleyen) { $tutmalar.Add($e.T - $bekleyen); $bekleyen = $null }
        }
        $cps = ($n - 1) / (($downs[$n - 1].T - $downs[0].T) / 1000)
        $ia = Istatistik $araliklar.ToArray()
        $th = Istatistik $tutmalar.ToArray()

        Write-Host ("  Tıklama: {0}    Ortalama CPS: {1:0.0}    En yüksek CPS: {2}" -f $n, $cps, $f.MaxCps)
        if ($ia -and $n -ge 20) {
            $yorum = if ($ia.CV -lt 0.10) { 'ŞÜPHELİ - makro gibi düzenli' } elseif ($ia.CV -lt 0.15) { 'oldukça düzenli' } else { 'normal (insan gibi)' }
            $renk  = if ($ia.CV -lt 0.10) { 'Red' } elseif ($ia.CV -lt 0.15) { 'Yellow' } else { 'Green' }
            Write-Host ("  Düzenlilik (CV): {0:0.000}  ->  {1}" -f $ia.CV, $yorum) -ForegroundColor $renk
        } elseif ($n -lt 20) {
            Aciklama 'Düzenlilik analizi için en az 20 tıklama gerekir.'
        }

        if ($n -ge 20 -and $ia) {
            if ($ia.CV -lt 0.10)     { Bulgu 'KIRMIZI' 'Mouse testi' ('Tıklama aralıkları insan için fazla düzenli (CV={0:0.000}) - makro olasılığı yüksek' -f $ia.CV) }
            elseif ($ia.CV -lt 0.15) { Bulgu 'SARI' 'Mouse testi' ('Tıklama aralıkları oldukça düzenli (CV={0:0.000})' -f $ia.CV) }
        }
        if ($th -and $th.N -ge 20 -and $th.SS -lt 2) { Bulgu 'SARI' 'Mouse testi' ('Basılı tutma süresi neredeyse sabit (sapma {0:0.0} ms) - makro deseni olabilir' -f $th.SS) }
        if ($cps -gt 20 -and $n -ge 20) { Bulgu 'SARI' 'Mouse testi' ('Çok yüksek CPS ({0:0.0})' -f $cps) }
        $cokKisa = @($araliklar | Where-Object { $_ -lt 15 }).Count
        if ($cokKisa -gt 0) { Bulgu 'SARI' 'Mouse testi' "$cokKisa tıklama arası 15 ms altında - makro ya da switch'te çift tıklama arızası olabilir" }
    }

    # ---------------- Tuşlar ----------------
    AltBaslik 'Tuş kontrolü'
    $adlar = @('Sol', 'Sağ', 'Orta', 'Geri', 'İleri', 'Tekerlek yukarı', 'Tekerlek aşağı', 'Eğim sol', 'Eğim sağ')
    $parca = for ($i = 0; $i -lt 9; $i++) {
        $c = $f.ButtonCounts[$i]
        if ($c -gt 0) { "$($adlar[$i]) [OK]" } else { "$($adlar[$i]) [--]" }
    }
    Write-Host ('  ' + (($parca[0..4]) -join '   '))
    Write-Host ('  ' + (($parca[5..8]) -join '   '))
    Aciklama 'Not: Bastığınız halde yanmayan tuş, mouse yazılımında klavye tuşuna / makroya atanmış olabilir. Eğim sadece destekleyen mouse''larda vardır.'

    # ---------------- Yazılımla üretilen girdi / ikinci cihaz ----------------
    if ($f.InjectedClicks -gt 0) { Bulgu 'KIRMIZI' 'Mouse testi' "$($f.InjectedClicks) tıklama yazılımla üretilmiş (INJECTED) - AutoHotkey / yazılım makrosu" }
    if ($f.InjectedMoves -gt 0)  { Bulgu 'KIRMIZI' 'Mouse testi' "$($f.InjectedMoves) mouse hareketi yazılımla üretilmiş (INJECTED)" }
    $cihazlar = @($f.Devices.Values)
    if (@($cihazlar | Where-Object { $_.Handle -eq '0x0' -and ($_.Clicks + $_.Moves) -gt 0 }).Count) {
        Bulgu 'KIRMIZI' 'Mouse testi' 'Fiziksel bir cihaza ait olmayan mouse girdisi alındı - yazılımla üretilmiş girdi'
    }
    $aktif = @($cihazlar | Where-Object { $_.Handle -ne '0x0' -and ($_.Clicks -gt 0 -or $_.Moves -gt 20) })
    Satir 'Girdi gönderen cihaz' $aktif.Count $(if ($aktif.Count -gt 1) { 'Yellow' } else { 'Gray' })
    if ($aktif.Count -gt 1) {
        foreach ($c in $aktif) { Aciklama ("- {0}  (tık {1}, hareket {2})" -f $c.Name, $c.Clicks, $c.Moves) }
        Bulgu 'SARI' 'Mouse testi' "Test sırasında $($aktif.Count) farklı cihazdan mouse girdisi geldi - ikinci cihaz (KMBox/Arduino) olabilir"
    }
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
Mouse-Testi

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
