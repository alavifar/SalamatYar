param([switch]$Minimized, [switch]$SelfTest, [string]$TestDir, [string]$Lang, [switch]$LangTest, [string]$Page, [string]$SwitchTo, [string]$Demo)
# سلامت‌یار — یادآور سلامت هنگام کار با کامپیوتر
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms, System.Drawing

$Root = $PSScriptRoot
$ScriptPath = $PSCommandPath
$DataDir = $Root
if ($SelfTest) { $DataDir = $TestDir; if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Force $DataDir | Out-Null } }
$SoundDir = Join-Path $Root 'sounds'
$CfgFile = Join-Path $DataDir 'settings.json'
$StatsFile = Join-Path $DataDir 'stats.json'
$LogFile = Join-Path $DataDir 'salamatyar.log'
function Log($m) { try { Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# ---------- فقط یک نسخه ----------
$mutexName = 'Local\SalamatYar_Single'
if ($SelfTest) { $mutexName = 'Local\SalamatYar_SelfTest' }
$Mutex = New-Object Threading.Mutex($false, $mutexName)
$AlreadyRunning = -not $Mutex.WaitOne(0)
$ResumeFile = Join-Path $DataDir 'resume.json'

# ---------- کد کمکی: زمان بی‌کاری و ساخت صدا ----------
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Runtime.InteropServices;

public static class IdleInfo {
  [StructLayout(LayoutKind.Sequential)] struct LII { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LII p);
  public static double Seconds() {
    LII l = new LII(); l.cbSize = (uint)Marshal.SizeOf(typeof(LII));
    if (!GetLastInputInfo(ref l)) return 0;
    uint d = unchecked((uint)Environment.TickCount - l.dwTime);
    return d / 1000.0;
  }
}

public static class Synth {
  const int SR = 32000;
  static double M(double midi) { return 440.0 * Math.Pow(2.0, (midi - 69.0) / 12.0); }

  static void Bell(float[] b, double start, double midi, double amp, double decay, bool wrap) {
    double f = M(midi); int n = b.Length; int s0 = (int)(start * SR);
    int len = (int)(SR * Math.Min(6.0, 7.0 / decay));
    for (int i = 0; i < len; i++) {
      double t = (double)i / SR;
      double e = Math.Min(1.0, t / 0.006) * Math.Exp(-t * decay);
      double v = Math.Sin(2 * Math.PI * f * t)
               + 0.35 * Math.Exp(-t * decay) * Math.Sin(4 * Math.PI * f * t)
               + 0.12 * Math.Exp(-2 * t * decay) * Math.Sin(6 * Math.PI * f * t);
      int k = s0 + i; if (k >= n) { if (!wrap) break; k %= n; }
      b[k] += (float)(amp * e * v);
    }
  }

  static void Pad(float[] b, double start, double midi, double dur, double amp, bool wrap) {
    double f = M(midi); int n = b.Length; int s0 = (int)(start * SR);
    double a = 1.6, r = 2.4; int len = (int)((dur + r) * SR);
    for (int i = 0; i < len; i++) {
      double t = (double)i / SR;
      double e = t < a ? t / a : (t < dur ? 1.0 : Math.Max(0.0, 1.0 - (t - dur) / r));
      e = e * e * (3 - 2 * e);
      double v = Math.Sin(2 * Math.PI * f * t)
               + 0.6 * Math.Sin(2 * Math.PI * f * 1.004 * t)
               + 0.6 * Math.Sin(2 * Math.PI * f * 0.996 * t)
               + 0.22 * Math.Sin(4 * Math.PI * f * t) * (0.5 + 0.5 * Math.Sin(2 * Math.PI * 0.13 * t));
      int k = s0 + i; if (k >= n) { if (!wrap) break; k %= n; }
      b[k] += (float)(amp * e * v);
    }
  }

  static void Kick(float[] b, double start, double amp, bool wrap) {
    int n = b.Length; int s0 = (int)(start * SR); int len = (int)(0.24 * SR); double ph = 0;
    for (int i = 0; i < len; i++) {
      double t = (double)i / SR;
      double f = 48 + 95 * Math.Exp(-t * 32);
      ph += 2 * Math.PI * f / SR;
      double e = Math.Min(1.0, t / 0.003) * Math.Exp(-t * 17);
      int k = s0 + i; if (k >= n) { if (!wrap) break; k %= n; }
      b[k] += (float)(amp * e * Math.Sin(ph));
    }
  }

  static void Hat(float[] b, double start, double amp, Random rnd, bool wrap) {
    int n = b.Length; int s0 = (int)(start * SR); int len = (int)(0.045 * SR); double prev = 0;
    for (int i = 0; i < len; i++) {
      double t = (double)i / SR; double x = rnd.NextDouble() * 2 - 1;
      double v = (x - prev) * 0.5; prev = x;
      int k = s0 + i; if (k >= n) { if (!wrap) break; k %= n; }
      b[k] += (float)(amp * Math.Exp(-t * 85) * v);
    }
  }

  static float[] Echo(float[] b, double delay, double fb, bool wrap) {
    int n = b.Length, d = (int)(delay * SR); float[] o = new float[n];
    int passes = wrap ? 2 : 1;
    for (int p = 0; p < passes; p++)
      for (int i = 0; i < n; i++) {
        int j = i - d;
        float prev = j >= 0 ? o[j] : ((wrap && p > 0) ? o[j + n] : 0f);
        o[i] = b[i] + (float)(fb * prev);
      }
    return o;
  }

  static void Save(float[] b, string path, double peak, double fadeOut) {
    int n = b.Length; float mx = 1e-9f;
    for (int i = 0; i < n; i++) mx = Math.Max(mx, Math.Abs(b[i]));
    double g = peak / mx; int fo = (int)(fadeOut * SR);
    using (FileStream fs = new FileStream(path, FileMode.Create))
    using (BinaryWriter w = new BinaryWriter(fs)) {
      w.Write(Encoding.ASCII.GetBytes("RIFF")); w.Write(36 + n * 2);
      w.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); w.Write(16);
      w.Write((short)1); w.Write((short)1); w.Write(SR); w.Write(SR * 2);
      w.Write((short)2); w.Write((short)16);
      w.Write(Encoding.ASCII.GetBytes("data")); w.Write(n * 2);
      for (int i = 0; i < n; i++) {
        double v = b[i] * g;
        if (fo > 0 && i > n - fo) v *= (double)(n - i) / fo;
        w.Write((short)(v * 32767));
      }
    }
  }

  // موسیقی آرام برای استراحت چشم
  public static void Calm(string path) {
    double cd = 6.0; int[] roots = { 48, 45, 41, 43, 40, 45, 38, 43 };
    int[][] tones = {
      new[]{60,64,67,71}, new[]{57,60,64,67}, new[]{53,57,60,64}, new[]{55,59,62,64},
      new[]{52,55,59,62}, new[]{57,60,64,67}, new[]{57,60,62,65}, new[]{55,60,62,67} };
    int[] pat = { 0, 2, 1, 3, 2, 3, 1, 2 };
    float[] b = new float[(int)(cd * roots.Length * SR)];
    for (int c = 0; c < roots.Length; c++) {
      double t0 = c * cd;
      Pad(b, t0, roots[c], cd, 0.50, true);
      for (int k = 0; k < 4; k++) Pad(b, t0, tones[c][k], cd, 0.20, true);
      for (int k = 0; k < 8; k++) Bell(b, t0 + k * 0.75, tones[c][pat[k]] + 12, 0.17, 2.0, true);
      Bell(b, t0, tones[c][3] + 24, 0.07, 1.2, true);
    }
    b = Echo(b, 0.5625, 0.38, true);
    Save(b, path, 0.72, 0);
  }

  // موسیقی پرتحرک‌تر برای زمان حرکت
  public static void Active(string path) {
    double beat = 0.6; int[] roots = { 48, 43, 45, 41, 48, 43, 41, 43 };
    int[][] tr = {
      new[]{60,64,67}, new[]{59,62,67}, new[]{60,64,69}, new[]{60,65,69},
      new[]{60,64,67}, new[]{59,62,67}, new[]{60,65,69}, new[]{59,62,67} };
    int[] pat = { 0, 1, 2, 1, 0, 2, 1, 2 };
    float[] b = new float[(int)(beat * 8 * roots.Length * SR)];
    Random rnd = new Random(7);
    for (int c = 0; c < roots.Length; c++) {
      double t0 = c * 8 * beat;
      for (int k = 0; k < 3; k++) Pad(b, t0, tr[c][k], 8 * beat - 1.0, 0.10, true);
      for (int bt = 0; bt < 8; bt++) {
        double tb = t0 + bt * beat;
        Kick(b, tb, 0.50, true);
        if (bt % 2 == 0) Bell(b, tb, roots[c], 0.50, 3.0, true);
        if (bt % 4 == 3) Bell(b, tb + beat / 2, roots[c] + 7, 0.28, 4.0, true);
        for (int e = 0; e < 2; e++)
          Bell(b, tb + e * beat / 2, tr[c][pat[(bt * 2 + e) % 8]] + 12, 0.16, 5.0, true);
        Hat(b, tb + beat / 2, 0.05, rnd, true);
      }
      Bell(b, t0, tr[c][2] + 24, 0.10, 2.0, true);
      Bell(b, t0 + 4 * beat, tr[c][1] + 24, 0.10, 2.0, true);
    }
    b = Echo(b, 0.45, 0.25, true);
    Save(b, path, 0.72, 0);
  }

  // زنگ‌ها: 0 شروع استراحت، 1 پایان استراحت، 2 پیام
  public static void Chime(string path, int kind) {
    float[] b;
    if (kind == 0) {
      b = new float[(int)(2.4 * SR)];
      Bell(b, 0.00, 76, 0.6, 3.2, false); Bell(b, 0.16, 79, 0.6, 3.2, false); Bell(b, 0.32, 84, 0.7, 2.8, false);
    } else if (kind == 1) {
      b = new float[(int)(2.8 * SR)];
      Bell(b, 0.00, 72, 0.5, 3.5, false); Bell(b, 0.11, 76, 0.5, 3.5, false);
      Bell(b, 0.22, 79, 0.5, 3.5, false); Bell(b, 0.33, 84, 0.6, 3.0, false); Bell(b, 0.55, 88, 0.45, 2.6, false);
    } else {
      b = new float[(int)(1.6 * SR)];
      Bell(b, 0.00, 81, 0.6, 4.5, false); Bell(b, 0.10, 88, 0.5, 4.5, false);
    }
    b = Echo(b, 0.21, 0.22, false);
    Save(b, path, 0.75, 0.08);
  }
}
'@

# ---------- ساخت فایل‌های صدا (فقط بار اول) ----------
if (-not (Test-Path $SoundDir)) { New-Item -ItemType Directory -Force $SoundDir | Out-Null }
$Snd = @{
    start  = Join-Path $SoundDir 'chime_start_v1.wav'
    end    = Join-Path $SoundDir 'chime_end_v1.wav'
    notify = Join-Path $SoundDir 'chime_notify_v1.wav'
    calm   = Join-Path $SoundDir 'music_calm_v1.wav'
    active = Join-Path $SoundDir 'music_active_v1.wav'
}
if (-not (Test-Path $Snd.start)) { [Synth]::Chime($Snd.start, 0) }
if (-not (Test-Path $Snd.end)) { [Synth]::Chime($Snd.end, 1) }
if (-not (Test-Path $Snd.notify)) { [Synth]::Chime($Snd.notify, 2) }
if (-not (Test-Path $Snd.calm)) { [Synth]::Calm($Snd.calm) }
if (-not (Test-Path $Snd.active)) { [Synth]::Active($Snd.active) }

# ---------- تنظیمات ----------
# پیش‌فرض‌ها بر پایه‌ی توصیه‌های منتشرشده (صفحه‌ی «راهنمای سلامت» در برنامه)
$Defaults = [ordered]@{
    EyeInterval = 20; EyeDuration = 20      # قانون ۲۰-۲۰-۲۰
    MoveInterval = 30; MoveDuration = 120   # شکستن نشستن هر ۳۰ دقیقه، ۲ دقیقه حرکت
    WaterInterval = 60
    IdleReset = 5; IdleDetect = $true
    Sound = $true; Music = $true; Volume = 60
    MusicEye = ''; MusicMove = ''           # مسیر آهنگ دلخواه؛ خالی یعنی آهنگ خود برنامه
    Theme = 'dark'                          # dark | light | auto
    BreakMode = 'full'                      # full | window | tray
    Lang = ''                               # fa | en | ar | ru | zh
}
$Cfg = [ordered]@{}
foreach ($k in $Defaults.Keys) { $Cfg[$k] = $Defaults[$k] }
if (Test-Path $CfgFile) {
    try {
        $o = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $Defaults.Keys) {
            if ($o.PSObject.Properties[$k]) {
                if ($Defaults[$k] -is [bool]) { $Cfg[$k] = [bool]$o.$k }
                elseif ($Defaults[$k] -is [string]) { $Cfg[$k] = [string]$o.$k }
                else { $Cfg[$k] = [int]$o.$k }
            }
        }
    } catch { Log "settings: $_" }
}
if ('dark', 'light', 'auto' -notcontains $Cfg.Theme) { $Cfg.Theme = 'dark' }
if ('full', 'window', 'tray' -notcontains $Cfg.BreakMode) { $Cfg.BreakMode = 'full' }
function Save-Cfg { try { $Cfg | ConvertTo-Json | Set-Content $CfgFile -Encoding UTF8 } catch { Log "save cfg: $_" } }

function New-Stats { @{ Date = (Get-Date).ToString('yyyy-MM-dd'); Work = 0.0; Eye = 0; Move = 0; Water = 0; Skipped = 0 } }
$Stats = New-Stats
if (Test-Path $StatsFile) {
    try {
        $o = Get-Content $StatsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($o.Date -eq $Stats.Date) {
            $Stats.Work = [double]$o.Work; $Stats.Eye = [int]$o.Eye; $Stats.Move = [int]$o.Move
            $Stats.Water = [int]$o.Water; $Stats.Skipped = [int]$o.Skipped
        }
    } catch { Log "stats: $_" }
}
function Save-Stats { try { $Stats | ConvertTo-Json | Set-Content $StatsFile -Encoding UTF8 } catch { Log "save stats: $_" } }

# ---------- زبان ----------
$LangNames = [ordered]@{ fa = 'فارسی'; en = 'English'; ar = 'العربية'; ru = 'Русский'; zh = '中文' }
function Detect-Lang {
    $codes = @($LangNames.Keys)
    foreach ($ci in @([Globalization.CultureInfo]::CurrentUICulture, [Globalization.CultureInfo]::CurrentCulture)) {
        $two = $ci.TwoLetterISOLanguageName
        if ($two -ne 'en' -and $codes -contains $two) { return $two }
    }
    try { $inp = @([Windows.Forms.InputLanguage]::InstalledInputLanguages | ForEach-Object { $_.Culture.TwoLetterISOLanguageName }) } catch { $inp = @() }
    foreach ($k in 'fa', 'ar', 'ru', 'zh') { if ($inp -contains $k) { return $k } }
    'en'
}
if ($Lang) { $Cfg.Lang = $Lang }
if (@($LangNames.Keys) -notcontains $Cfg.Lang) { $Cfg.Lang = Detect-Lang; if (-not $SelfTest) { Save-Cfg } }
$LangCode = [string]$Cfg.Lang
$IsRtl = ($LangCode -eq 'fa' -or $LangCode -eq 'ar')
$L = @{}
try {
    $lj = [IO.File]::ReadAllText((Join-Path $Root 'lang.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
    $li = [array]::IndexOf(@($lj._order), $LangCode)
    foreach ($p in $lj.strings.PSObject.Properties) { $L[$p.Name] = [string]$p.Value[$li] }
} catch {
    [void][Windows.MessageBox]::Show('lang.json is missing or damaged. Please extract the whole folder again.', 'SalamatYar')
    exit
}
function T($k) { if ($L.ContainsKey($k)) { $L[$k] } else { Log "missing text: $k"; "[$k]" } }
function Localize($xaml) {
    $x = [regex]::Replace($xaml, '\[\[(\w+)\]\]', { param($m) [Security.SecurityElement]::Escape((T $m.Groups[1].Value)) })
    $flow = 'LeftToRight'; if ($IsRtl) { $flow = 'RightToLeft' }
    $font = 'Segoe UI'; if ($IsRtl) { $font = 'Vazirmatn, Segoe UI' } elseif ($LangCode -eq 'zh') { $font = 'Microsoft YaHei UI, Segoe UI' }
    $x.Replace('@FLOW@', $flow).Replace('@FONT@', $font)
}
if ($AlreadyRunning) {
    [void][Windows.MessageBox]::Show((T 'alreadyRunning'), (T 'appName'))
    exit
}

# ---------- کمکی‌ها ----------
function ValText($k, $v) {
    if ($k -eq 'Volume') { if ($LangCode -eq 'fa') { (Fa "$v") + '٪' } else { "$v%" } }
    else { Fa "$v $($Units[$k])" }
}
function Fa($s) {
    if ($LangCode -ne 'fa') { return [string]$s }
    $sb = New-Object Text.StringBuilder
    foreach ($ch in ([string]$s).ToCharArray()) {
        $n = [int]$ch
        if ($n -ge 48 -and $n -le 57) { [void]$sb.Append([char](0x06F0 + $n - 48)) } else { [void]$sb.Append($ch) }
    }
    $sb.ToString()
}
function Fmt($sec) {
    $t = [int][math]::Max(0, [math]::Ceiling($sec))
    Fa ('{0:00}:{1:00}' -f [int][math]::Floor($t / 60), ($t % 60))
}
# ---------- پوسته ----------
# رنگ‌های رابط در حالت تاریک نوشته شده‌اند؛ این جدول معادل روشن هر رنگ است.
$LightMap = @{
    '0F1524' = 'F4F6FB'; '222C44' = 'D5DBE8'; '161E31' = 'FFFFFF'; '212B45' = 'DFE4EE'; '131A2B' = 'FFFFFF'; '1E2740' = 'DFE4EE'
    '1B2438' = 'EEF1F7'; '2B3757' = 'CBD3E1'; '243150' = 'E2E7F0'; '2B3A5E' = 'D5DCE9'; '22304D' = 'DDE4F0'; '232D47' = 'E3E8F1'
    '1C2540' = 'DFE4EE'; '0B101C' = 'E9EDF5'; '1D2640' = 'DDE3EE'; 'F20A0F1C' = 'F2F4F6FB'; '0A0F1C' = 'F4F6FB'
    'F2F5FB' = '111827'; 'F5F7FC' = '111827'; 'FFFFFF' = '111827'; 'D5DBEA' = '374151'; 'C5CDE0' = '374151'; 'E6EAF4' = '374151'
    '8A96B2' = '6B7280'; '7683A0' = '6B7280'; '6C7894' = '7B8598'; '5E6A86' = '7B8598'
    '2DD4BF' = '0D9488'; '06221E' = 'FFFFFF'; 'FBBF24' = 'D97706'; '60A5FA' = '2563EB'; '081A33' = 'FFFFFF'
    'C4B5FD' = '7C3AED'; 'F9A8D4' = 'DB2777'; 'F87171' = 'DC2626'; '34D399' = '059669'
}
$ColorKeys = @{}; foreach ($k in $LightMap.Keys) { $ColorKeys[$k] = $true }
$Th = @{ Current = ''; Poll = 0.0 }
function Themify($xaml) {
    [regex]::Replace($xaml, '"#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6})"', {
            param($m) $k = $m.Groups[1].Value.ToUpper(); $ColorKeys[$k] = $true; '"{DynamicResource c' + $k + '}"' })
}
function Resolve-Theme {
    if ($Cfg.Theme -ne 'auto') { return $Cfg.Theme }
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme
        if ($v -eq 1) { 'light' } else { 'dark' }
    } catch { 'dark' }
}
function Apply-Theme {
    $eff = Resolve-Theme
    if ($eff -eq $Th.Current) { return }
    $Th.Current = $eff
    foreach ($k in @($ColorKeys.Keys)) {
        $hex = $k; if ($eff -eq 'light' -and $LightMap.ContainsKey($k)) { $hex = $LightMap[$k] }
        $b = [Windows.Media.BrushConverter]::new().ConvertFromString("#$hex"); $b.Freeze()
        $App.Resources["c$k"] = $b
    }
}
function Br($hex) {
    $r = $App.Resources['c' + $hex.TrimStart('#').ToUpper()]
    if ($r) { $r } else { [Windows.Media.BrushConverter]::new().ConvertFromString($hex) }
}
function Set-Arc($path, $frac, $c, $r) {
    $frac = [math]::Min(0.9999, [math]::Max(0.0, [double]$frac))
    if ($frac -le 0.002) { $path.Data = $null; return }
    $ang = 2 * [math]::PI * $frac
    $x = [math]::Round($c + $r * [math]::Sin($ang), 3)
    $y = [math]::Round($c - $r * [math]::Cos($ang), 3)
    $large = 0; if ($frac -gt 0.5) { $large = 1 }
    $path.Data = [Windows.Media.Geometry]::Parse("M $c,$($c - $r) A $r,$r 0 $large 1 $x,$y")
}

$COL = @{ eye = '#2DD4BF'; move = '#FBBF24'; water = '#60A5FA' }

# ---------- شناسنامه و نشان برنامه ----------
$AppVersion = '1.3'
$AuthorName = (T 'authorName')
$AuthorLink = 'https://t.me/ShrAlavifar'
$Signature = "$(T 'sigPrefix') $AuthorName — Telegram: $([char]0x200E)@ShrAlavifar"
$IcoFile = Join-Path $Root 'SalamatYar.ico'

function Draw-Logo([int]$s) {
    $b = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'; $g.Clear([Drawing.Color]::Transparent)
    $m = [single]($s * 0.03); $w = [single]($s - 2 * $m); $d = [single]($s * 0.46)
    $gp = New-Object Drawing.Drawing2D.GraphicsPath
    $gp.AddArc($m, $m, $d, $d, [single]180, [single]90)
    $gp.AddArc([single]($m + $w - $d), $m, $d, $d, [single]270, [single]90)
    $gp.AddArc([single]($m + $w - $d), [single]($m + $w - $d), $d, $d, [single]0, [single]90)
    $gp.AddArc($m, [single]($m + $w - $d), $d, $d, [single]90, [single]90)
    $gp.CloseFigure()
    $rect = New-Object Drawing.RectangleF 0, 0, $s, $s
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, ([Drawing.Color]::FromArgb(255, 45, 212, 191)), ([Drawing.Color]::FromArgb(255, 14, 116, 144)), ([single]45)
    $g.FillPath($br, $gp)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), ([single]($s * 0.105))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $in = [single]($s * 0.25); $aw = [single]($s - 2 * $in)
    $g.DrawArc($pen, $in, $in, $aw, $aw, [single]-90, [single]285)
    $dd = [single]($s * 0.17); $dp = [single](($s - $dd) / 2)
    $g.FillEllipse([Drawing.Brushes]::White, $dp, $dp, $dd, $dd)
    $g.Dispose(); $pen.Dispose(); $br.Dispose(); $gp.Dispose()
    $b
}
function Png-Bytes($bmp) { $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); , $ms.ToArray() }
function Save-Ico($path) {
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $pngs = @(); foreach ($s in $sizes) { $bm = Draw-Logo $s; $pngs += , (Png-Bytes $bm); $bm.Dispose() }
    $fs = [IO.File]::Create($path); $w = New-Object IO.BinaryWriter $fs
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $off = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = [byte]($sizes[$i] % 256)
        $w.Write($dim); $w.Write($dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$off)
        $off += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write([byte[]]$p) }
    $w.Close(); $fs.Close()
}
function To-Src($bmp) {
    $ms = New-Object IO.MemoryStream (, (Png-Bytes $bmp))
    $bi = New-Object Windows.Media.Imaging.BitmapImage
    $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.StreamSource = $ms; $bi.EndInit(); $bi.Freeze()
    $bi
}
if (-not (Test-Path $IcoFile)) { try { Save-Ico $IcoFile } catch { Log "ico: $_" } }

# ---------- رابط کاربری ----------
$ResXaml = @'
<Style x:Key="Btn" TargetType="Button">
  <Setter Property="Background" Value="#2DD4BF"/><Setter Property="Foreground" Value="#06221E"/>
  <Setter Property="FontSize" Value="13.5"/><Setter Property="FontWeight" Value="SemiBold"/>
  <Setter Property="Padding" Value="20,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="b" CornerRadius="10" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.86"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="Ghost" TargetType="Button">
  <Setter Property="Foreground" Value="#D5DBEA"/><Setter Property="FontSize" Value="13.5"/>
  <Setter Property="Padding" Value="20,9"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Focusable" Value="False"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button">
    <Border x:Name="b" CornerRadius="10" Background="#1B2438" BorderBrush="#2B3757" BorderThickness="1" Padding="{TemplateBinding Padding}">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#243150"/></Trigger>
      <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#2B3A5E"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
<Style x:Key="Nav" TargetType="RadioButton">
  <Setter Property="Foreground" Value="#8A96B2"/><Setter Property="FontSize" Value="14"/><Setter Property="Cursor" Value="Hand"/>
  <Setter Property="Focusable" Value="False"/><Setter Property="Margin" Value="3,0"/>
  <Setter Property="Template"><Setter.Value><ControlTemplate TargetType="RadioButton">
    <Border x:Name="b" CornerRadius="10" Padding="18,8" Background="Transparent">
      <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
    <ControlTemplate.Triggers>
      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1B2438"/></Trigger>
      <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#22304D"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
    </ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter>
</Style>
'@

$CardTpl = @'
<Border Background="#161E31" CornerRadius="16" Padding="20,18" Margin="7" BorderBrush="#212B45" BorderThickness="1">
  <StackPanel>
    <StackPanel Orientation="Horizontal">
      <Ellipse Width="10" Height="10" Fill="@C@" VerticalAlignment="Center"/>
      <TextBlock Text="@T@" Foreground="#F2F5FB" FontSize="17" FontWeight="SemiBold" Margin="10,0,0,0"/>
    </StackPanel>
    <TextBlock x:Name="@ID@Desc" Foreground="#8A96B2" FontSize="12.5" Margin="0,6,0,0"/>
    <Grid Width="170" Height="170" Margin="0,16,0,16">
      <Ellipse Stroke="#232D47" StrokeThickness="10" Margin="5"/>
      <Canvas><Path x:Name="@ID@Arc" Stroke="@C@" StrokeThickness="10" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas>
      <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
        <TextBlock x:Name="@ID@Time" FlowDirection="LeftToRight" FontSize="34" FontWeight="SemiBold" Foreground="#F2F5FB" HorizontalAlignment="Center"/>
        <TextBlock Text="[[untilNext]]" Foreground="#8A96B2" FontSize="12" HorizontalAlignment="Center" Margin="0,2,0,0"/>
      </StackPanel>
    </Grid>
    <Button x:Name="@ID@Now" Content="@B@" Style="{StaticResource Ghost}"/>
  </StackPanel>
</Border>
'@
function Card($id, $title, $color, $btn) { $CardTpl.Replace('@ID@', $id).Replace('@T@', $title).Replace('@C@', $color).Replace('@B@', $btn) }

$TileTpl = @'
<Border Background="#131A2B" CornerRadius="14" Padding="16,12" Margin="7,0" BorderBrush="#1E2740" BorderThickness="1">
  <StackPanel>
    <TextBlock x:Name="@ID@" FlowDirection="LeftToRight" HorizontalAlignment="Left" Text="0" Foreground="@C@" FontSize="24" FontWeight="SemiBold"/>
    <TextBlock Text="@T@" Foreground="#8A96B2" FontSize="12" Margin="0,2,0,0" TextWrapping="Wrap"/>
  </StackPanel>
</Border>
'@
function Tile($id, $title, $color) { $TileTpl.Replace('@ID@', $id).Replace('@T@', $title).Replace('@C@', $color) }

$SliderTpl = @'
<Grid Margin="0,8">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
  <TextBlock Text="@L@" Foreground="#D5DBEA" FontSize="13.5"/>
  <TextBlock x:Name="@K@Val" Grid.Column="1" Foreground="@C@" FontSize="13.5" FontWeight="SemiBold"/>
  <Slider x:Name="@K@Sl" Tag="@K@" Grid.Row="1" Grid.ColumnSpan="2" Minimum="@MIN@" Maximum="@MAX@" TickFrequency="@STEP@" IsSnapToTickEnabled="True" Margin="0,6,0,0" Focusable="False"/>
</Grid>
'@
$SliderDefs = @(
    @{ K = 'EyeInterval'; L = (T 'slEyeInt'); Min = 10; Max = 40; Step = 5; U = (T 'unitMin'); C = $COL.eye },
    @{ K = 'EyeDuration'; L = (T 'slEyeDur'); Min = 20; Max = 60; Step = 5; U = (T 'unitSec'); C = $COL.eye },
    @{ K = 'MoveInterval'; L = (T 'slMoveInt'); Min = 20; Max = 90; Step = 5; U = (T 'unitMin'); C = $COL.move },
    @{ K = 'MoveDuration'; L = (T 'slMoveDur'); Min = 60; Max = 600; Step = 30; U = (T 'unitSec'); C = $COL.move },
    @{ K = 'WaterInterval'; L = (T 'slWaterInt'); Min = 30; Max = 120; Step = 10; U = (T 'unitMin'); C = $COL.water },
    @{ K = 'IdleReset'; L = (T 'slIdle'); Min = 3; Max = 15; Step = 1; U = (T 'unitMin'); C = '#C4B5FD' },
    @{ K = 'Volume'; L = (T 'slVolume'); Min = 0; Max = 100; Step = 5; U = '%'; C = '#C4B5FD' }
)
$Units = @{}; foreach ($d in $SliderDefs) { $Units[$d.K] = $d.U }
function SliderRow($k) {
    $d = $SliderDefs | Where-Object { $_.K -eq $k }
    $SliderTpl.Replace('@K@', $d.K).Replace('@L@', $d.L).Replace('@C@', $d.C).Replace('@MIN@', [string]$d.Min).Replace('@MAX@', [string]$d.Max).Replace('@STEP@', [string]$d.Step)
}

$GuideTpl = @'
<Border Background="#161E31" CornerRadius="14" Padding="18,14" Margin="7" BorderBrush="#212B45" BorderThickness="1">
  <StackPanel>
    <StackPanel Orientation="Horizontal"><Ellipse Width="9" Height="9" Fill="@C@" VerticalAlignment="Center"/>
      <TextBlock Text="@T@" Foreground="#F2F5FB" FontSize="15" FontWeight="SemiBold" Margin="9,0,0,0"/></StackPanel>
    <TextBlock Text="@B@" Foreground="#C5CDE0" FontSize="13" TextWrapping="Wrap" LineHeight="22" Margin="0,8,0,0"/>
    <TextBlock Text="@S@" Foreground="#7683A0" FontSize="11.5" TextWrapping="Wrap" Margin="0,8,0,0"/>
  </StackPanel>
</Border>
'@
$Guide = @(
    @{ T = (T 'g1t'); C = $COL.eye; B = (T 'g1b'); S = (T 'g1s') },
    @{ T = (T 'g2t'); C = $COL.move; B = (T 'g2b'); S = (T 'g2s') },
    @{ T = (T 'g3t'); C = '#C4B5FD'; B = (T 'g3b'); S = (T 'g3s') },
    @{ T = (T 'g4t'); C = '#C4B5FD'; B = (T 'g4b'); S = (T 'g3s') },
    @{ T = (T 'g5t'); C = '#F9A8D4'; B = (T 'g5b'); S = (T 'g3s') },
    @{ T = (T 'g6t'); C = $COL.water; B = (T 'g6b'); S = (T 'g6s') }
)
$GuideXaml = ($Guide | ForEach-Object { $GuideTpl.Replace('@T@', $_.T).Replace('@B@', $_.B).Replace('@S@', $_.S).Replace('@C@', $_.C) }) -join "`n"

$NS = 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"'

$MainXaml = @'
<Window @NS@ Title="[[appName]]" Width="1010" Height="734" WindowStartupLocation="CenterScreen" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize" FlowDirection="@FLOW@"
        FontFamily="@FONT@" UseLayoutRounding="True">
  <Window.Resources>@RES@</Window.Resources>
  <Border Margin="14" CornerRadius="18" Background="#0F1524" BorderBrush="#222C44" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="4" Opacity="0.45" Color="Black"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="68"/><RowDefinition Height="*"/><RowDefinition Height="62"/><RowDefinition Height="30"/></Grid.RowDefinitions>

      <!-- سربرگ -->
      <Border x:Name="Header" Background="Transparent" Padding="22,0,14,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Image x:Name="LogoImg" Width="36" Height="36" FlowDirection="LeftToRight" RenderOptions.BitmapScalingMode="HighQuality"/>
            <StackPanel Margin="12,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="[[appName]]" Foreground="#F2F5FB" FontSize="17" FontWeight="Bold"/>
              <TextBlock Text="[[subtitle]]" Foreground="#7683A0" FontSize="11.5"/>
            </StackPanel>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
            <RadioButton x:Name="NavDash" Content="[[navDash]]" Style="{StaticResource Nav}" GroupName="nav" IsChecked="True"/>
            <RadioButton x:Name="NavSettings" Content="[[navSettings]]" Style="{StaticResource Nav}" GroupName="nav"/>
            <RadioButton x:Name="NavGuide" Content="[[navGuide]]" Style="{StaticResource Nav}" GroupName="nav"/>
            <RadioButton x:Name="NavAbout" Content="[[navAbout]]" Style="{StaticResource Nav}" GroupName="nav"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnLang" Style="{StaticResource Ghost}" Padding="12,5" Margin="0,0,6,0" ToolTip="[[langTooltip]]"/>
            <Popup x:Name="LangPop" PlacementTarget="{Binding ElementName=BtnLang}" Placement="Bottom" StaysOpen="False" AllowsTransparency="True">
              <Border Background="#161E31" BorderBrush="#2B3757" BorderThickness="1" CornerRadius="12" Padding="6" Margin="0,6,0,0">
                <StackPanel>
                  <Button x:Name="LgFa" Tag="fa" Style="{StaticResource Ghost}" Margin="0,2" MinWidth="130" Padding="14,7"/>
                  <Button x:Name="LgEn" Tag="en" Style="{StaticResource Ghost}" Margin="0,2" MinWidth="130" Padding="14,7"/>
                  <Button x:Name="LgAr" Tag="ar" Style="{StaticResource Ghost}" Margin="0,2" MinWidth="130" Padding="14,7"/>
                  <Button x:Name="LgRu" Tag="ru" Style="{StaticResource Ghost}" Margin="0,2" MinWidth="130" Padding="14,7"/>
                  <Button x:Name="LgZh" Tag="zh" Style="{StaticResource Ghost}" Margin="0,2" MinWidth="130" Padding="14,7"/>
                </StackPanel>
              </Border>
            </Popup>
            <Button x:Name="BtnMin" Content="—" Style="{StaticResource Ghost}" Padding="12,5" Margin="0,0,6,0" ToolTip="[[ttMin]]"/>
            <Button x:Name="BtnClose" Content="✕" Style="{StaticResource Ghost}" Padding="12,5" ToolTip="[[ttClose]]"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- داشبورد -->
      <Grid x:Name="PageDash" Grid.Row="1" Margin="15,2,15,0">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
        <UniformGrid Columns="3">@CARDS@</UniformGrid>
        <UniformGrid Grid.Row="1" Columns="5" Margin="0,8,0,0">@TILES@</UniformGrid>
        <Border Grid.Row="2" Background="#131A2B" CornerRadius="14" Margin="7,14,7,6" Padding="18,0" BorderBrush="#1E2740" BorderThickness="1">
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="[[tipLabel]]" Foreground="#2DD4BF" FontSize="13" FontWeight="SemiBold"/>
            <TextBlock x:Name="TipText" Foreground="#C5CDE0" FontSize="13" Margin="12,0,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- تنظیمات -->
      <Grid x:Name="PageSettings" Grid.Row="1" Margin="15,2,15,0" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
        <Border Background="#161E31" CornerRadius="16" Padding="22,16" Margin="7" BorderBrush="#212B45" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="[[setTiming]]" Foreground="#F2F5FB" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
            @SL_TIME@
            <CheckBox x:Name="CkIdle" Tag="IdleDetect" Foreground="#D5DBEA" FontSize="13.5" Margin="0,8,0,0" Focusable="False">
              <TextBlock Text="[[ckIdle]]" TextWrapping="Wrap"/>
            </CheckBox>
            @SL_IDLE@
            <Button x:Name="BtnDefaults" Content="[[btnDefaults]]" Style="{StaticResource Ghost}" Margin="0,8,0,0"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Background="#161E31" CornerRadius="16" Padding="22,16" Margin="7" BorderBrush="#212B45" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="[[setSound]]" Foreground="#F2F5FB" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,6"/>
            @SL_SOUND@
            <Grid Margin="0,8,0,0">
              <CheckBox x:Name="CkSound" Tag="Sound" Content="[[ckSound]]" Foreground="#D5DBEA" FontSize="13.5" VerticalAlignment="Center" Focusable="False"/>
              <Button x:Name="BtnTestChime" Content="[[btnPlay]]" Style="{StaticResource Ghost}" Padding="14,6" HorizontalAlignment="Right"/>
            </Grid>
            <CheckBox x:Name="CkMusic" Tag="Music" Content="[[ckMusic]]" Foreground="#D5DBEA" FontSize="13.5" Margin="0,10,0,0" Focusable="False"/>
            @MUSIC_ROWS@
            <Border Height="1" Background="#232D47" Margin="0,16,0,12"/>
            <Grid>
              <TextBlock Text="[[themeLabel]]" Foreground="#D5DBEA" FontSize="13.5" VerticalAlignment="Center"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <RadioButton x:Name="ThDark" Tag="dark" Content="[[thDark]]" Style="{StaticResource Nav}" GroupName="theme"/>
                <RadioButton x:Name="ThLight" Tag="light" Content="[[thLight]]" Style="{StaticResource Nav}" GroupName="theme"/>
                <RadioButton x:Name="ThAuto" Tag="auto" Content="[[thAuto]]" Style="{StaticResource Nav}" GroupName="theme" ToolTip="[[ttThAuto]]"/>
              </StackPanel>
            </Grid>
            <Grid Margin="0,6,0,0">
              <TextBlock Text="[[dispLabel]]" Foreground="#D5DBEA" FontSize="13.5" VerticalAlignment="Center"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <RadioButton x:Name="DispFull" Tag="full" Content="[[dispFull]]" Style="{StaticResource Nav}" GroupName="disp" ToolTip="[[ttDispFull]]"/>
                <RadioButton x:Name="DispWindow" Tag="window" Content="[[dispWindow]]" Style="{StaticResource Nav}" GroupName="disp" ToolTip="[[ttDispWindow]]"/>
                <RadioButton x:Name="DispTray" Tag="tray" Content="[[dispTray]]" Style="{StaticResource Nav}" GroupName="disp" ToolTip="[[ttDispTray]]"/>
              </StackPanel>
            </Grid>
            <Border Height="1" Background="#232D47" Margin="0,12,0,4"/>
            <CheckBox x:Name="CkAuto" Content="[[ckAuto]]" Foreground="#D5DBEA" FontSize="13.5" Margin="0,12,0,0" Focusable="False"/>
            <Button x:Name="BtnShortcut" Content="[[btnShortcut]]" Style="{StaticResource Ghost}" Margin="0,14,0,0"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- راهنما -->
      <Grid x:Name="PageGuide" Grid.Row="1" Margin="15,2,15,0" Visibility="Collapsed">
        <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <ScrollViewer VerticalScrollBarVisibility="Auto"><UniformGrid Columns="2" VerticalAlignment="Top">@GUIDE@</UniformGrid></ScrollViewer>
        <TextBlock Grid.Row="1" Text="[[guideFoot]]" Foreground="#7683A0" FontSize="12" Margin="10,8,10,4"/>
      </Grid>

      <!-- درباره -->
      <Grid x:Name="PageAbout" Grid.Row="1" Margin="15,2,15,0" Visibility="Collapsed">
        <Grid.ColumnDefinitions><ColumnDefinition Width="5*"/><ColumnDefinition Width="7*"/></Grid.ColumnDefinitions>
        <Border Background="#161E31" CornerRadius="16" Padding="24,22" Margin="7" BorderBrush="#212B45" BorderThickness="1">
          <StackPanel>
            <Image x:Name="AboutLogo" Width="88" Height="88" HorizontalAlignment="Left" FlowDirection="LeftToRight" RenderOptions.BitmapScalingMode="HighQuality"/>
            <TextBlock Text="[[appName]]" Foreground="#F2F5FB" FontSize="25" FontWeight="Bold" Margin="0,14,0,0"/>
            <TextBlock x:Name="AboutVer" Foreground="#2DD4BF" FontSize="13" FontWeight="SemiBold" Margin="0,2,0,0"/>
            <TextBlock Foreground="#C5CDE0" FontSize="13" TextWrapping="Wrap" LineHeight="23" Margin="0,12,0,0"
                       Text="[[aboutDesc]]"/>
            <Border Height="1" Background="#232D47" Margin="0,16,0,14"/>
            <TextBlock Foreground="#C5CDE0" FontSize="13" TextWrapping="Wrap" LineHeight="23"
                       Text="[[aboutFree]]"/>
            <TextBlock Foreground="#7683A0" FontSize="12" TextWrapping="Wrap" Margin="0,12,0,0"
                       Text="[[aboutDisclaimer]]"/>
          </StackPanel>
        </Border>
        <Border Grid.Column="1" Background="#161E31" CornerRadius="16" Padding="26,22" Margin="7" BorderBrush="#212B45" BorderThickness="1">
          <StackPanel>
            <TextBlock Text="[[aboutMaker]]" Foreground="#2DD4BF" FontSize="13" FontWeight="SemiBold"/>
            <TextBlock x:Name="AboutName" Foreground="#F2F5FB" FontSize="24" FontWeight="Bold" Margin="0,6,0,0"/>
            <TextBlock Text="[[aboutRole]]" Foreground="#8A96B2" FontSize="13" Margin="0,4,0,0" TextWrapping="Wrap"/>
            <TextBlock Foreground="#C5CDE0" FontSize="13.5" TextWrapping="Wrap" LineHeight="23" Margin="0,12,0,0"
                       Text="[[aboutP1]]"/>
            <TextBlock Foreground="#C5CDE0" FontSize="13.5" TextWrapping="Wrap" LineHeight="23" Margin="0,8,0,0"
                       Text="[[aboutP2]]"/>
            <TextBlock Foreground="#C5CDE0" FontSize="13.5" TextWrapping="Wrap" LineHeight="23" Margin="0,8,0,0"
                       Text="[[aboutP3]]"/>
            <WrapPanel Margin="0,12,0,0">@CHIPS@</WrapPanel>
            <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
              <Button x:Name="BtnTelegram" Content="[[aboutTelegram]] &#x200E;@ShrAlavifar" Style="{StaticResource Btn}"/>
            </StackPanel>
          </StackPanel>
        </Border>
      </Grid>

      <!-- نوار پایین -->
      <Border Grid.Row="2" BorderBrush="#1C2540" BorderThickness="0,1,0,0" Padding="22,0">
        <Grid>
          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#34D399"/>
            <TextBlock x:Name="StatusText" Foreground="#C5CDE0" FontSize="13" Margin="10,0,0,0"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <Button x:Name="BtnReset" Content="[[btnReset]]" Style="{StaticResource Ghost}" Margin="0,0,8,0"/>
            <Button x:Name="BtnPause" Content="[[btnPause]]" Style="{StaticResource Btn}" MinWidth="120"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- خط امضا -->
      <Border Grid.Row="3" Background="#0B101C" CornerRadius="0,0,17,17">
        <TextBlock x:Name="SigMain" Foreground="#6C7894" FontSize="11.5" HorizontalAlignment="Center" VerticalAlignment="Center" Cursor="Hand" ToolTip="[[ttSig]]"/>
      </Border>
    </Grid>
  </Border>
</Window>
'@
$cards = (Card 'Eye' (T 'cardEye') $COL.eye (T 'btnEyeNow')) + (Card 'Move' (T 'cardMove') $COL.move (T 'btnMoveNow')) + (Card 'Water' (T 'cardWater') $COL.water (T 'btnDrank'))
$tiles = (Tile 'StWork' (T 'tileWork') '#F2F5FB') + (Tile 'StEye' (T 'cardEye') $COL.eye) + (Tile 'StMove' (T 'tileMove') $COL.move) + (Tile 'StWater' (T 'tileWater') $COL.water) + (Tile 'StSkip' (T 'tileSkipped') '#F87171')
$slTime = (SliderRow 'EyeInterval') + (SliderRow 'EyeDuration') + (SliderRow 'MoveInterval') + (SliderRow 'MoveDuration') + (SliderRow 'WaterInterval')
$chips = ('Python', 'JavaScript', 'MQL5', (T 'chipBot'), (T 'chipData'), (T 'chipPdf'), (T 'chipRtl') | ForEach-Object {
        '<Border Background="#1B2438" BorderBrush="#2B3757" BorderThickness="1" CornerRadius="8" Padding="11,4" Margin="0,0,7,7"><TextBlock Text="' + $_ + '" Foreground="#C5CDE0" FontSize="12"/></Border>' }) -join ''
$MusicRowTpl = @'
<Grid Margin="0,10,0,0">
  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
  <StackPanel VerticalAlignment="Center">
    <TextBlock Text="@L@" Foreground="#D5DBEA" FontSize="13"/>
    <TextBlock x:Name="@ID@Name" Foreground="#8A96B2" FontSize="11.5" TextTrimming="CharacterEllipsis" Margin="0,2,8,0"/>
  </StackPanel>
  <Button x:Name="@ID@Play" Tag="@SLOT@" Content="[[btnPlay]]" Style="{StaticResource Ghost}" Padding="12,6" Grid.Column="1" Margin="0,0,6,0"/>
  <Button x:Name="@ID@Pick" Tag="@KEY@" Content="[[btnPick]]" Style="{StaticResource Ghost}" Padding="12,6" Grid.Column="2" Margin="0,0,6,0"/>
  <Button x:Name="@ID@Def" Tag="@KEY@" Content="[[btnDefault]]" Style="{StaticResource Ghost}" Padding="12,6" Grid.Column="3"/>
</Grid>
'@
$musicRows = $MusicRowTpl.Replace('@ID@', 'MuEye').Replace('@L@', (T 'muEye')).Replace('@KEY@', 'MusicEye').Replace('@SLOT@', 'calm') +
$MusicRowTpl.Replace('@ID@', 'MuMove').Replace('@L@', (T 'muMove')).Replace('@KEY@', 'MusicMove').Replace('@SLOT@', 'active')
$MainXaml = $MainXaml.Replace('@MUSIC_ROWS@', $musicRows)
$MainXaml = $MainXaml.Replace('@CHIPS@', $chips)
$MainXaml = $MainXaml.Replace('@NS@', $NS).Replace('@RES@', $ResXaml).Replace('@CARDS@', $cards).Replace('@TILES@', $tiles).Replace('@SL_TIME@', $slTime).Replace('@SL_SOUND@', (SliderRow 'Volume')).Replace('@SL_IDLE@', (SliderRow 'IdleReset')).Replace('@GUIDE@', $GuideXaml)

$OvXaml = @'
<Window @NS@ Title="[[ovTitleWin]]" WindowStyle="None" AllowsTransparency="True" Background="#F20A0F1C" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" WindowStartupLocation="Manual" ResizeMode="NoResize"
        FlowDirection="@FLOW@" FontFamily="@FONT@" UseLayoutRounding="True">
  <Window.Resources>@RES@</Window.Resources>
  <Grid>
    <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" MaxWidth="860">
      <TextBlock x:Name="OvKicker" FontSize="15" FontWeight="SemiBold" HorizontalAlignment="Center"/>
      <TextBlock x:Name="OvTitle" FontSize="44" FontWeight="Bold" Foreground="#F5F7FC" HorizontalAlignment="Center" Margin="0,8,0,0"/>
      <TextBlock x:Name="OvInstr" FontSize="19" Foreground="#C5CDE0" TextWrapping="Wrap" TextAlignment="Center" Margin="0,14,0,0"/>
      <Grid Width="280" Height="280" Margin="0,34,0,30">
        <Ellipse Stroke="#1D2640" StrokeThickness="12" Margin="8"/>
        <Canvas><Path x:Name="OvArc" StrokeThickness="12" StrokeStartLineCap="Round" StrokeEndLineCap="Round"/></Canvas>
        <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center">
          <TextBlock x:Name="OvTime" FlowDirection="LeftToRight" FontSize="62" FontWeight="SemiBold" Foreground="#F5F7FC" HorizontalAlignment="Center"/>
          <TextBlock Text="[[remaining]]" Foreground="#8A96B2" FontSize="14" HorizontalAlignment="Center"/>
        </StackPanel>
      </Grid>
      <Border Background="#161E31" CornerRadius="14" Padding="26,14" HorizontalAlignment="Center" BorderBrush="#212B45" BorderThickness="1">
        <TextBlock x:Name="OvTip" FontSize="17" Foreground="#E6EAF4" TextWrapping="Wrap" TextAlignment="Center"/>
      </Border>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,30,0,0">
        <Button x:Name="OvDone" Content="[[btnDone]]" Style="{StaticResource Btn}" Margin="5,0" MinWidth="120"/>
        <Button x:Name="OvLater" Content="[[btnLater]]" Style="{StaticResource Ghost}" Margin="5,0" MinWidth="120"/>
        <Button x:Name="OvSkip" Content="[[btnSkip]]" Style="{StaticResource Ghost}" Margin="5,0" MinWidth="120"/>
      </StackPanel>
    </StackPanel>
    <TextBlock x:Name="OvSig" VerticalAlignment="Bottom" HorizontalAlignment="Center" Margin="0,0,0,26" Foreground="#5E6A86" FontSize="12.5"/>
  </Grid>
</Window>
'@
$OvXaml =$OvXaml.Replace('@NS@', $NS).Replace('@RES@', $ResXaml)

$ToastXaml = @'
<Window @NS@ Title="[[toastWin]]" Width="390" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        FlowDirection="@FLOW@" FontFamily="@FONT@" UseLayoutRounding="True">
  <Window.Resources>@RES@</Window.Resources>
  <Border Margin="8" CornerRadius="14" Background="#161E31" BorderBrush="#2B3757" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.45"/></Border.Effect>
    <Grid>
      <Grid.ColumnDefinitions><ColumnDefinition Width="6"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
      <Border x:Name="ToastBar" CornerRadius="3" Margin="0,14" Background="#60A5FA" Width="4" HorizontalAlignment="Right"/>
      <StackPanel Grid.Column="1" Margin="14,12,16,12">
        <TextBlock x:Name="ToastTitle" Foreground="#F2F5FB" FontSize="15" FontWeight="SemiBold"/>
        <TextBlock x:Name="ToastText" Foreground="#C5CDE0" FontSize="13" TextWrapping="Wrap" Margin="0,5,0,0"/>
        <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
          <Button x:Name="ToastOk" Content="[[btnDrank]]" Style="{StaticResource Btn}" Padding="16,6" Background="#60A5FA" Foreground="#081A33" Margin="0,0,8,0"/>
          <Button x:Name="ToastClose" Content="[[btnClose]]" Style="{StaticResource Ghost}" Padding="16,6"/>
        </StackPanel>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@
$ToastXaml = $ToastXaml.Replace('@NS@', $NS).Replace('@RES@', $ResXaml)

# پنجره‌ی کوچک یادآور (حالت «پنجره»)
$MiniXaml = @'
<Window @NS@ Title="[[ovTitleWin]]" Width="420" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        FlowDirection="@FLOW@" FontFamily="@FONT@" UseLayoutRounding="True">
  <Window.Resources>@RES@</Window.Resources>
  <Border Margin="8" CornerRadius="14" Background="#161E31" BorderBrush="#2B3757" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="3" Opacity="0.45"/></Border.Effect>
    <StackPanel Margin="18,14,18,14">
      <Grid>
        <StackPanel Margin="0,0,96,0">
          <TextBlock x:Name="MnKicker" FontSize="12" FontWeight="SemiBold"/>
          <TextBlock x:Name="MnTitle" Foreground="#F2F5FB" FontSize="17" FontWeight="SemiBold" Margin="0,2,0,0" TextWrapping="Wrap"/>
        </StackPanel>
        <TextBlock x:Name="MnTime" FlowDirection="LeftToRight" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#F2F5FB" FontSize="28" FontWeight="SemiBold"/>
      </Grid>
      <Grid Height="5" Margin="0,10,0,0">
        <Grid.ColumnDefinitions><ColumnDefinition x:Name="MnColA" Width="1*"/><ColumnDefinition x:Name="MnColB" Width="0*"/></Grid.ColumnDefinitions>
        <Border Grid.ColumnSpan="2" Background="#232D47" CornerRadius="2.5"/>
        <Border x:Name="MnFill" CornerRadius="2.5"/>
      </Grid>
      <TextBlock x:Name="MnInstr" Foreground="#C5CDE0" FontSize="13" TextWrapping="Wrap" Margin="0,10,0,0"/>
      <TextBlock x:Name="MnTip" Foreground="#E6EAF4" FontSize="13" TextWrapping="Wrap" LineHeight="21" Margin="0,6,0,0"/>
      <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
        <Button x:Name="MnDone" Content="[[btnDone]]" Style="{StaticResource Btn}" Padding="14,6" Margin="0,0,8,0"/>
        <Button x:Name="MnLater" Content="[[btnLater]]" Style="{StaticResource Ghost}" Padding="14,6" Margin="0,0,8,0"/>
        <Button x:Name="MnSkip" Content="[[btnSkip]]" Style="{StaticResource Ghost}" Padding="14,6"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
$MiniXaml = $MiniXaml.Replace('@NS@', $NS).Replace('@RES@', $ResXaml)

$ConfirmXaml = @'
<Window @NS@ Title="[[confirmWin]]" Width="450" SizeToContent="Height" WindowStartupLocation="CenterOwner" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ShowInTaskbar="False" ResizeMode="NoResize"
        FlowDirection="@FLOW@" FontFamily="@FONT@" UseLayoutRounding="True">
  <Window.Resources>@RES@</Window.Resources>
  <Border Margin="14" CornerRadius="16" Background="#161E31" BorderBrush="#2B3757" BorderThickness="1" Padding="24,20">
    <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
    <StackPanel>
      <TextBlock x:Name="CfTitle" Foreground="#F2F5FB" FontSize="17" FontWeight="SemiBold"/>
      <TextBlock x:Name="CfText" Foreground="#C5CDE0" FontSize="13.5" TextWrapping="Wrap" LineHeight="24" Margin="0,10,0,0"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0">
        <Button x:Name="CfNo" Content="[[btnCancel]]" Style="{StaticResource Ghost}" Margin="0,0,8,0" MinWidth="100" IsCancel="True"/>
        <Button x:Name="CfYes" Style="{StaticResource Btn}" MinWidth="100"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
$ConfirmXaml = $ConfirmXaml.Replace('@NS@', $NS).Replace('@RES@', $ResXaml)

$MainXaml = Themify (Localize $MainXaml); $OvXaml = Themify (Localize $OvXaml)
$ToastXaml = Themify (Localize $ToastXaml); $ConfirmXaml = Themify (Localize $ConfirmXaml)
$MiniXaml = Themify (Localize $MiniXaml)

$App = New-Object Windows.Application
$App.ShutdownMode = 'OnExplicitShutdown'
$App.add_DispatcherUnhandledException({ param($s, $e) Log "error: $($e.Exception)"; $e.Handled = $true })
Apply-Theme

$script:ConfirmWin = $null
function Ask-Confirm($title, $text, $yes) {
    $d = [Windows.Markup.XamlReader]::Parse($ConfirmXaml)
    $d.FindName('CfTitle').Text = $title; $d.FindName('CfText').Text = $text; $d.FindName('CfYes').Content = $yes
    $d.FindName('CfYes').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $true })
    $d.FindName('CfNo').add_Click({ param($s, $e) [Windows.Window]::GetWindow($s).DialogResult = $false })
    if ($Win.IsVisible) { $d.Owner = $Win } else { $d.WindowStartupLocation = 'CenterScreen' }
    if ($SelfTest) { $d.Topmost = $true }
    $script:ConfirmWin = $d
    $r = $d.ShowDialog()
    $script:ConfirmWin = $null
    [bool]$r
}

$Win = [Windows.Markup.XamlReader]::Parse($MainXaml)
$Ov = [Windows.Markup.XamlReader]::Parse($OvXaml)
$Toast = [Windows.Markup.XamlReader]::Parse($ToastXaml)
$Mini = [Windows.Markup.XamlReader]::Parse($MiniXaml)
if ($SelfTest) { $Ov.Background = Br '#0A0F1C'; $Win.Topmost = $true }

$C = @{}
$names = 'Header', 'NavDash', 'NavSettings', 'NavGuide', 'BtnMin', 'BtnClose', 'PageDash', 'PageSettings', 'PageGuide',
'EyeArc', 'EyeTime', 'EyeDesc', 'EyeNow', 'MoveArc', 'MoveTime', 'MoveDesc', 'MoveNow', 'WaterArc', 'WaterTime', 'WaterDesc', 'WaterNow',
'StWork', 'StEye', 'StMove', 'StWater', 'StSkip', 'TipText', 'StatusDot', 'StatusText', 'BtnReset', 'BtnPause',
'BtnDefaults', 'CkSound', 'CkMusic', 'CkIdle', 'CkAuto', 'BtnTestChime',
'MuEyeName', 'MuEyePlay', 'MuEyePick', 'MuEyeDef', 'MuMoveName', 'MuMovePlay', 'MuMovePick', 'MuMoveDef', 'ThDark', 'ThLight', 'ThAuto',
'BtnLang', 'LangPop', 'LgFa', 'LgEn', 'LgAr', 'LgRu', 'LgZh',
'NavAbout', 'PageAbout', 'LogoImg', 'AboutLogo', 'AboutVer', 'AboutName', 'BtnTelegram', 'SigMain', 'BtnShortcut'
foreach ($n in $names) { $C[$n] = $Win.FindName($n) }
$C['OvSig'] = $Ov.FindName('OvSig')
foreach ($d in $SliderDefs) { $C["$($d.K)Sl"] = $Win.FindName("$($d.K)Sl"); $C["$($d.K)Val"] = $Win.FindName("$($d.K)Val") }
foreach ($n in 'OvKicker', 'OvTitle', 'OvInstr', 'OvArc', 'OvTime', 'OvTip', 'OvDone', 'OvLater', 'OvSkip') { $C[$n] = $Ov.FindName($n) }
foreach ($n in 'ToastBar', 'ToastTitle', 'ToastText', 'ToastOk', 'ToastClose') { $C[$n] = $Toast.FindName($n) }
foreach ($n in 'MnKicker', 'MnTitle', 'MnTime', 'MnColA', 'MnColB', 'MnFill', 'MnInstr', 'MnTip', 'MnDone', 'MnLater', 'MnSkip') { $C[$n] = $Mini.FindName($n) }
foreach ($n in 'DispFull', 'DispWindow', 'DispTray') { $C[$n] = $Win.FindName($n) }
foreach ($k in $C.Keys) { if ($null -eq $C[$k]) { throw "control not found: $k" } }

# ---------- نشان برنامه ----------
$bmp = Draw-Logo 32
$hIcon = $bmp.GetHicon()
$Icon = [Drawing.Icon]::FromHandle($hIcon)
$LogoSrc = To-Src (Draw-Logo 256)
$Win.Icon = $LogoSrc; $C.LogoImg.Source = $LogoSrc; $C.AboutLogo.Source = $LogoSrc
$verShown = $AppVersion; if ($LangCode -eq 'fa') { $verShown = $AppVersion.Replace('.', '٫') }
$C.AboutVer.Text = Fa ((T 'verFmt') -f $verShown)
$C.BtnLang.Content = "$($LangNames[$LangCode])  ▾"
$C.LgFa.Content = $LangNames.fa; $C.LgEn.Content = $LangNames.en; $C.LgAr.Content = $LangNames.ar; $C.LgRu.Content = $LangNames.ru; $C.LgZh.Content = $LangNames.zh
$C.AboutName.Text = $AuthorName
$C.SigMain.Text = $Signature; $C.OvSig.Text = $Signature

# ---------- صدا ----------
$Players = @{}
foreach ($k in $Snd.Keys) {
    $p = New-Object Windows.Media.MediaPlayer
    if ($SelfTest) {
        $p.add_MediaOpened({ Log 'media opened' })
        $p.add_MediaFailed({ param($s, $e) Log "media FAILED: $($e.ErrorException.Message)" })
    }
    $Players[$k] = $p
}
$MusicKey = @{ calm = 'MusicEye'; active = 'MusicMove' }
function Music-Path($name) {
    $mp = [string]$Cfg[$MusicKey[$name]]
    if ($mp -and (Test-Path -LiteralPath $mp)) { $mp } else { $Snd[$name] }
}
function Update-MusicNames {
    foreach ($n in 'calm', 'active') {
        $mp = [string]$Cfg[$MusicKey[$n]]
        if ($n -eq 'calm') { $tb = $C.MuEyeName; $def = (T 'muDefCalm') } else { $tb = $C.MuMoveName; $def = (T 'muDefActive') }
        if ($mp -and (Test-Path -LiteralPath $mp)) { $tb.Text = [IO.Path]::GetFileName($mp); $tb.ToolTip = $mp } else { $tb.Text = $def; $tb.ToolTip = $null }
    }
}
function Reload-Music($name) {
    $p = $Players[$name]
    if ($Au.Current -eq $p) { $Au.Current = $null }
    if ($Au.Fading -eq $p) { $Au.Fading = $null }
    $p.Stop(); $p.Close(); $p.Open([Uri](Music-Path $name))
    Update-MusicNames
}
foreach ($k in 'start', 'end', 'notify') { $Players[$k].Open([Uri]$Snd[$k]) }
foreach ($k in 'calm', 'active') {
    $Players[$k].add_MediaEnded({ param($s, $e) $s.Position = [TimeSpan]::Zero; $s.Play() })
    # اگر فایل دلخواه پخش‌شدنی نبود، به آهنگ خود برنامه برمی‌گردد
    $Players[$k].add_MediaFailed({ param($s, $e)
            $n = 'calm'; if ($s -eq $Players['active']) { $n = 'active' }
            Log "music failed ($n): $($e.ErrorException.Message)"
            if ($Cfg[$MusicKey[$n]]) { $Cfg[$MusicKey[$n]] = ''; $St.Dirty = $true; Reload-Music $n }
        })
    $Players[$k].Open([Uri](Music-Path $k))
}
$Au = @{ Current = $null; Fading = $null; TestLeft = 0.0 }
function Vol { if ($SelfTest) { 0.0 } else { [double]$Cfg.Volume / 100.0 } }
function Play-Fx($name) {
    if (-not $Cfg.Sound) { return }
    $p = $Players[$name]; $p.Stop(); $p.Position = [TimeSpan]::Zero; $p.Volume = (Vol); $p.Play()
}
function Start-Music($name) {
    if (-not $Cfg.Music) { return }
    if ($Au.Fading) { $Au.Fading.Stop(); $Au.Fading = $null }
    $p = $Players[$name]; $p.Stop(); $p.Position = [TimeSpan]::Zero; $p.Volume = (Vol) * 0.85; $p.Play()
    $Au.Current = $p
}
$FadeTimer = New-Object Windows.Threading.DispatcherTimer
$FadeTimer.Interval = [TimeSpan]::FromMilliseconds(70)
$FadeTimer.add_Tick({
        $p = $Au.Fading
        if ($null -eq $p) { $FadeTimer.Stop(); return }
        $v = $p.Volume - 0.04
        if ($v -le 0.01) { $p.Stop(); $Au.Fading = $null; $FadeTimer.Stop() } else { $p.Volume = $v }
    })
function Stop-Music {
    if ($Au.Current) { $Au.Fading = $Au.Current; $Au.Current = $null; $FadeTimer.Start() }
}

# ---------- متن‌ها ----------
# هر گروه فعالیت از کلیدهای شماره‌دار lang.json خوانده می‌شود (eyeTip1، eyeTip2، ...)
function Pool($prefix) {
    $a = @(); $i = 1
    while ($L.ContainsKey("$prefix$i")) { $a += $L["$prefix$i"]; $i++ }
    , $a
}
$EyeTips = Pool 'eyeTip'; $MoveTips = Pool 'moveTip'; $WaterTips = Pool 'waterTip'; $DashTips = Pool 'dashTip'
# فعالیت‌ها به ترتیب تصادفی و بدون تکرار داده می‌شوند تا همه‌ی گروه یک دور دیده شود
$Decks = @{}
function Next-Tips($name, $pool, $count) {
    $out = @()
    for ($n = 0; $n -lt $count; $n++) {
        if (-not $Decks[$name] -or $Decks[$name].Count -eq 0) {
            $Decks[$name] = New-Object Collections.ArrayList (, @($pool | Get-Random -Count $pool.Count))
        }
        $out += $Decks[$name][0]; $Decks[$name].RemoveAt(0)
    }
    , $out
}
function Tips-Text($tips) { if ($tips.Count -gt 1) { ($tips | ForEach-Object { "• $_" }) -join "`n" } else { [string]$tips[0] } }

# ---------- وضعیت ----------
$St = @{ Eye = 0.0; Move = 0.0; Water = 0.0; Paused = $false; Break = $null; Last = [DateTime]::UtcNow
    Away = $false; Toast = 0.0; SaveAcc = 0.0; TipAcc = 0.0; TipIdx = 0; Dirty = $false; Loading = $true; Exiting = $false; HintShown = $false
}

function Start-Break($type, $preview) {
    if ($St.Break) { return }
    $Toast.Hide(); $St.Toast = 0
    if ($type -eq 'eye') {
        $dur = $Cfg.EyeDuration; $col = $COL.eye; $pool = $EyeTips; $music = 'calm'; $doneVis = 'Collapsed'
        $kicker = (T 'ovEyeKicker'); $title = (T 'ovEyeTitle'); $instr = (T 'ovEyeInstr')
    } else {
        $dur = $Cfg.MoveDuration; $col = $COL.move; $pool = $MoveTips; $music = 'active'; $doneVis = 'Visible'
        $kicker = (T 'ovMoveKicker'); $title = (T 'ovMoveTitle'); $instr = (T 'ovMoveInstr')
    }
    # در استراحت کوتاه یک فعالیت و در استراحت بلندتر دو فعالیت یادآوری می‌شود
    $count = 2; if ($dur -lt 30) { $count = 1 }
    # پیش‌نمایش تنظیمات: چند ثانیه نمونه، بدون اثر روی آمار و زمان‌سنج‌ها
    if ($preview) { $dur = 8; $count = 2; $kicker = "$(T 'previewTag') · $kicker" }
    $mode = [string]$Cfg.BreakMode
    $St.Break = @{ Type = $type; Total = [double]$dur; Left = [double]$dur; Pool = $pool; Count = $count; TipAcc = 0.0; Mode = $mode; Preview = [bool]$preview
        TipsText = (Tips-Text (Next-Tips $type $pool $count))
    }
    $brush = Br $col
    if ($mode -eq 'full') {
        $C.OvKicker.Text = $kicker; $C.OvTitle.Text = $title; $C.OvInstr.Text = $instr; $C.OvDone.Visibility = $doneVis
        $C.OvKicker.Foreground = $brush; $C.OvArc.Stroke = $brush; $C.OvDone.Background = $brush
        $C.OvTip.Text = $St.Break.TipsText
        Update-Overlay
        if ($SelfTest) { $Ov.Background = Br '#0A0F1C' }
        $Ov.Left = 0; $Ov.Top = 0
        $Ov.Width = [Windows.SystemParameters]::PrimaryScreenWidth; $Ov.Height = [Windows.SystemParameters]::PrimaryScreenHeight
        $Ov.Show()
    } elseif ($mode -eq 'window') {
        $C.MnKicker.Text = $kicker; $C.MnTitle.Text = $title; $C.MnInstr.Text = $instr; $C.MnDone.Visibility = $doneVis
        $C.MnKicker.Foreground = $brush; $C.MnFill.Background = $brush; $C.MnDone.Background = $brush
        $C.MnTip.Text = $St.Break.TipsText
        Update-Overlay
        $wa = [Windows.SystemParameters]::WorkArea
        $Mini.Left = $wa.Right - $Mini.Width - 10; $Mini.Top = $wa.Bottom - 260
        $Mini.Show(); Place-Mini
    } else {
        # فقط اعلان کنار ساعت؛ استراحت بی‌صدا در پس‌زمینه شمرده می‌شود و پایانش با زنگ اعلام می‌شود
        if ($script:Tray) { $script:Tray.ShowBalloonTip(10000, $title, ($instr + "`n" + $St.Break.TipsText), 'None') }
    }
    Play-Fx 'start'
    if ($mode -ne 'tray') { Start-Music $music }
    Update-UI
}
function Place-Mini {
    $Mini.UpdateLayout()
    $wa = [Windows.SystemParameters]::WorkArea
    $Mini.Top = $wa.Bottom - $Mini.ActualHeight - 10
}
function Update-Overlay {
    $b = $St.Break; if (-not $b) { return }
    $frac = [math]::Max(0.0, [math]::Min(1.0, $b.Left / $b.Total))
    if ($b.Mode -eq 'full') {
        Set-Arc $C.OvArc $frac 140 126
        $C.OvTime.Text = Fmt $b.Left
    } elseif ($b.Mode -eq 'window') {
        $C.MnTime.Text = Fmt $b.Left
        $C.MnColA.Width = New-Object Windows.GridLength ($frac, [Windows.GridUnitType]::Star)
        $C.MnColB.Width = New-Object Windows.GridLength ((1.0 - $frac), [Windows.GridUnitType]::Star)
    }
}
function End-Break($how) {
    $b = $St.Break; if (-not $b) { return }
    $St.Break = $null; $Ov.Hide(); $Mini.Hide(); Stop-Music
    if ($b.Preview) { $St.Last = [DateTime]::UtcNow; Update-UI; return }
    if ($how -eq 'later') {
        if ($b.Type -eq 'eye') { $St.Eye = [math]::Max(0, $Cfg.EyeInterval * 60 - 300) } else { $St.Move = [math]::Max(0, $Cfg.MoveInterval * 60 - 300) }
    } else {
        if ($how -eq 'done') {
            if ($b.Type -eq 'eye') { $Stats.Eye++ } else { $Stats.Move++ }
            Play-Fx 'end'
        } else { $Stats.Skipped++ }
        $St.Eye = 0.0
        if ($b.Type -eq 'move') { $St.Move = 0.0 }
    }
    $St.Last = [DateTime]::UtcNow
    Save-Stats; Update-UI
}
function Show-WaterToast {
    $wtip = [string](Next-Tips 'water' $WaterTips 1)[0]
    if ($Cfg.BreakMode -eq 'tray') {
        if ($script:Tray) { $script:Tray.ShowBalloonTip(8000, (T 'toastWaterTitle'), ((T 'toastWaterText') + "`n" + $wtip), 'None') }
        Play-Fx 'notify'; return
    }
    $C.ToastTitle.Text = (T 'toastWaterTitle')
    $C.ToastText.Text = (T 'toastWaterText') + "`n" + $wtip
    $wa =[Windows.SystemParameters]::WorkArea
    $Toast.Left = $wa.Right - $Toast.Width - 10; $Toast.Top = $wa.Bottom - 200
    $Toast.Show(); $Toast.UpdateLayout()
    $Toast.Top = $wa.Bottom - $Toast.ActualHeight - 10; $St.Toast = 14.0
    Play-Fx 'notify'
}
function Drink { $Stats.Water++; $St.Water = 0.0; $Toast.Hide(); $St.Toast = 0; Save-Stats; Update-UI }

function Update-UI {
    $eyeT = $Cfg.EyeInterval * 60; $moveT = $Cfg.MoveInterval * 60; $watT = $Cfg.WaterInterval * 60
    Set-Arc $C.EyeArc ($St.Eye / $eyeT) 85 75; $C.EyeTime.Text = Fmt ($eyeT - $St.Eye)
    Set-Arc $C.MoveArc ($St.Move / $moveT) 85 75; $C.MoveTime.Text = Fmt ($moveT - $St.Move)
    Set-Arc $C.WaterArc ($St.Water / $watT) 85 75; $C.WaterTime.Text = Fmt ($watT - $St.Water)
    $wm = [int][math]::Floor($Stats.Work / 60)
    $C.StWork.Text = Fa ('{0}:{1:00}' -f [int][math]::Floor($wm / 60), ($wm % 60))
    $C.StEye.Text = Fa $Stats.Eye; $C.StMove.Text = Fa $Stats.Move; $C.StWater.Text = Fa $Stats.Water; $C.StSkip.Text = Fa $Stats.Skipped
    if ($St.Break) { $txt = (T 'stBreak'); $dot = '#60A5FA' }
    elseif ($St.Paused) { $txt = (T 'stPaused'); $dot = '#F87171' }
    elseif ($St.Away) { $txt = (T 'stAway'); $dot = '#FBBF24' }
    else { $txt = (T 'stWorking'); $dot = '#34D399' }
    $C.StatusText.Text = $txt; $C.StatusDot.Fill = Br $dot
    if ($St.Paused) { $C.BtnPause.Content = (T 'btnResume') } else { $C.BtnPause.Content = (T 'btnPause') }
    if ($script:Tray) {
        if ($St.Paused) { $script:Tray.Text = (T 'trayPaused') }
        else {
            $tt = "$(T 'appName') — $(T 'trayEye') $(Fmt ($eyeT - $St.Eye)) | $(T 'tileMove') $(Fmt ($moveT - $St.Move))"
            if ($tt.Length -gt 63) { $tt = $tt.Substring(0, 63) }
            $script:Tray.Text = $tt
        }
        if ($script:MiPause) { if ($St.Paused) { $script:MiPause.Text = (T 'btnResume') } else { $script:MiPause.Text = (T 'btnPause') } }
    }
}
function Update-Desc {
    $C.EyeDesc.Text = Fa ((T 'descEye') -f $Cfg.EyeInterval, $Cfg.EyeDuration)
    $C.MoveDesc.Text = Fa ((T 'descMove') -f $Cfg.MoveInterval, $Cfg.MoveDuration)
    $C.WaterDesc.Text = Fa ((T 'descWater') -f $Cfg.WaterInterval)
}
function Load-Controls {
    $St.Loading = $true
    foreach ($d in $SliderDefs) {
        $C["$($d.K)Sl"].Value = $Cfg[$d.K]
        $C["$($d.K)Val"].Text = ValText $d.K $Cfg[$d.K]
    }
    $C.CkSound.IsChecked = $Cfg.Sound; $C.CkMusic.IsChecked = $Cfg.Music; $C.CkIdle.IsChecked = $Cfg.IdleDetect
    $C.ThDark.IsChecked = ($Cfg.Theme -eq 'dark'); $C.ThLight.IsChecked = ($Cfg.Theme -eq 'light'); $C.ThAuto.IsChecked = ($Cfg.Theme -eq 'auto')
    $C.DispFull.IsChecked = ($Cfg.BreakMode -eq 'full'); $C.DispWindow.IsChecked = ($Cfg.BreakMode -eq 'window'); $C.DispTray.IsChecked = ($Cfg.BreakMode -eq 'tray')
    Update-MusicNames
    $St.Loading = $false
    Update-Desc
}

function Tick {
    $now = [DateTime]::UtcNow; $dt = ($now - $St.Last).TotalSeconds; $St.Last = $now
    if ($dt -lt 0) { $dt = 0 }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    if ($Stats.Date -ne $today) { $n = New-Stats; foreach ($k in @($n.Keys)) { $Stats[$k] = $n[$k] } }
    if ($St.Dirty) { $St.Dirty = $false; Save-Cfg }
    if ($Cfg.Theme -eq 'auto') { $Th.Poll += $dt; if ($Th.Poll -ge 4) { $Th.Poll = 0; Apply-Theme } }
    if ($St.Toast -gt 0) { $St.Toast -= $dt; if ($St.Toast -le 0) { $Toast.Hide() } }
    if ($Au.TestLeft -gt 0) { $Au.TestLeft -= $dt; if ($Au.TestLeft -le 0 -and -not $St.Break) { Stop-Music } }

    if ($St.Break) {
        $b = $St.Break
        $b.Left -= [math]::Min($dt, 5); $b.TipAcc += $dt
        if ($b.TipAcc -ge 30 -and $b.Left -gt 12 -and $b.Mode -ne 'tray') {
            $b.TipAcc = 0; $b.TipsText = Tips-Text (Next-Tips $b.Type $b.Pool $b.Count)
            if ($b.Mode -eq 'full') { $C.OvTip.Text = $b.TipsText } else { $C.MnTip.Text = $b.TipsText; Place-Mini }
        }
        if ($b.Left -le 0) { End-Break 'done' } else { Update-Overlay }
        return
    }
    if (-not $St.Paused) {
        $limit = $Cfg.IdleReset * 60
        $idle = 0.0; if ($Cfg.IdleDetect) { $idle = [IdleInfo]::Seconds() }
        if ($dt -ge $limit -or $idle -ge $limit) {
            $St.Eye = 0.0; $St.Move = 0.0; $St.Away = ($idle -ge $limit)
        } else {
            $St.Away = $false
            $St.Eye += $dt; $St.Move += $dt; $St.Water += $dt; $Stats.Work += $dt
        }
        if ($St.Move -ge $Cfg.MoveInterval * 60) { Start-Break 'move'; return }
        if ($St.Eye -ge $Cfg.EyeInterval * 60) { Start-Break 'eye'; return }
        if ($St.Water -ge $Cfg.WaterInterval * 60) { $St.Water = 0.0; Show-WaterToast }
    }
    $St.SaveAcc += $dt; if ($St.SaveAcc -ge 60) { $St.SaveAcc = 0; Save-Stats }
    $St.TipAcc += $dt
    if ($St.TipAcc -ge 45) { $St.TipAcc = 0; $St.TipIdx = ($St.TipIdx + 1) % $DashTips.Count; $C.TipText.Text = $DashTips[$St.TipIdx] }
    Update-UI
}

# ---------- اجرای خودکار با ویندوز ----------
$LnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'SalamatYar.lnk'
function New-Lnk($path, $extra) {
    $sh = New-Object -ComObject WScript.Shell
    $l = $sh.CreateShortcut($path)
    $l.TargetPath = Join-Path $PSHOME 'powershell.exe'
    $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`"$extra"
    $l.WorkingDirectory = $Root; $l.WindowStyle = 7; $l.Description = 'SalamatYar'
    if (Test-Path $IcoFile) { $l.IconLocation = "$IcoFile,0" }
    $l.Save()
}
function Set-Autostart($on) {
    if ($on) { New-Lnk $LnkPath ' -Minimized' }
    elseif (Test-Path $LnkPath) { Remove-Item $LnkPath -Force }
}
# میان‌بر آیکون‌دار کنار خود برنامه؛ در هر اجرا با مسیر فعلی تازه می‌شود
if (-not $SelfTest) {
    try { New-Lnk (Join-Path $Root 'SalamatYar.lnk') ''; if (Test-Path $LnkPath) { New-Lnk $LnkPath ' -Minimized' } } catch { Log "lnk: $_" }
}

# ---------- رویدادها ----------
function Show-Main { $Win.Show(); $Win.WindowState = 'Normal'; [void]$Win.Activate() }
function Toggle-Pause { $St.Paused = -not $St.Paused; $St.Last = [DateTime]::UtcNow; Update-UI }
function Quit-App {
    $St.Exiting = $true; Save-Stats; Save-Cfg
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose() }
    foreach ($p in $Players.Values) { $p.Stop(); $p.Close() }
    $App.Shutdown()
}

$C.Header.add_MouseLeftButtonDown({ try { $Win.DragMove() } catch {} })
$C.BtnMin.add_Click({ $Win.WindowState = 'Minimized' })
$C.BtnClose.add_Click({ $Win.Close() })
$Win.add_Closing({ param($s, $e)
        if (-not $St.Exiting) {
            $e.Cancel = $true; $Win.Hide()
            if (-not $St.HintShown -and $script:Tray) {
                $St.HintShown = $true
                $script:Tray.ShowBalloonTip(4000, (T 'balloonTitle'), (T 'balloonText'), 'Info')
            }
        }
    })
function Set-Page($name) {
    foreach ($pg in 'PageDash', 'PageSettings', 'PageGuide', 'PageAbout') { if ($pg -eq $name) { $C[$pg].Visibility = 'Visible' } else { $C[$pg].Visibility = 'Collapsed' } }
}
$C.NavDash.add_Checked({ Set-Page 'PageDash' })
$C.NavSettings.add_Checked({ Set-Page 'PageSettings' })
$C.NavGuide.add_Checked({ Set-Page 'PageGuide' })
$C.NavAbout.add_Checked({ Set-Page 'PageAbout' })
# تغییر زبان: تنظیم ذخیره می‌شود و برنامه با همان صفحه و همان زمان‌سنج‌ها دوباره بالا می‌آید
function Set-Lang($code) {
    $C.LangPop.IsOpen = $false
    if ($code -eq $LangCode) { return }
    $Cfg.Lang = $code; Save-Cfg; Save-Stats
    if ($SelfTest) { return }
    $page = 'PageDash'; foreach ($pg in 'PageSettings', 'PageGuide', 'PageAbout') { if ($C[$pg].Visibility -eq 'Visible') { $page = $pg } }
    try { @{ Eye = $St.Eye; Move = $St.Move; Water = $St.Water; Paused = $St.Paused; At = [DateTime]::UtcNow.Ticks } | ConvertTo-Json | Set-Content $ResumeFile -Encoding UTF8 } catch { Log "resume: $_" }
    $St.Exiting = $true
    if ($script:Tray) { $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:Tray = $null }
    try { $Mutex.ReleaseMutex() } catch {}
    Start-Process (Join-Path $PSHOME 'powershell.exe') -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -Page $page"
    $App.Shutdown()
}
$C.BtnLang.add_Click({ $C.LangPop.IsOpen = -not $C.LangPop.IsOpen })
foreach ($n in 'LgFa', 'LgEn', 'LgAr', 'LgRu', 'LgZh') { $C[$n].add_Click({ param($s, $e) Set-Lang ([string]$s.Tag) }) }
$C.BtnTelegram.add_Click({ try { Start-Process $AuthorLink } catch { Log "link: $_" } })
$C.SigMain.add_MouseLeftButtonUp({ try { Start-Process $AuthorLink } catch { Log "link: $_" } })
$C.BtnShortcut.add_Click({
        try {
            New-Lnk (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SalamatYar.lnk') ''
            $C.BtnShortcut.Content = (T 'shortcutDone')
        } catch { Log "desktop lnk: $_"; $C.BtnShortcut.Content = (T 'shortcutFail') }
    })

$C.EyeNow.add_Click({ Start-Break 'eye' })
$C.MoveNow.add_Click({ Start-Break 'move' })
$C.WaterNow.add_Click({ Drink })
$C.BtnPause.add_Click({ Toggle-Pause })
$C.BtnReset.add_Click({
        if (Ask-Confirm (T 'btnReset') (T 'confirmResetText') (T 'confirmYes')) {
            $St.Eye = 0.0; $St.Move = 0.0; $St.Water = 0.0; $St.Last = [DateTime]::UtcNow; Update-UI
        }
    })
$themeHandler = { param($s, $e)
    if ($St.Loading) { return }
    $Cfg.Theme = [string]$s.Tag; $St.Dirty = $true; Apply-Theme; Update-UI
}
foreach ($n in 'ThDark', 'ThLight', 'ThAuto') { $C[$n].add_Checked($themeHandler) }
$dispHandler = { param($s, $e)
    if ($St.Loading) { return }
    $Cfg.BreakMode = [string]$s.Tag; $St.Dirty = $true
    # همان لحظه یک نمونه‌ی چندثانیه‌ای در حالت انتخاب‌شده نشان داده می‌شود
    if ($St.Break -and $St.Break.Preview) { End-Break 'skip' }
    Start-Break 'move' $true
}
# پیش‌نمایش صدا: کمی پس از رها کردن لغزنده‌ی بلندی صدا، زنگ با همان بلندی پخش می‌شود
$VolTimer = New-Object Windows.Threading.DispatcherTimer
$VolTimer.Interval = [TimeSpan]::FromMilliseconds(350)
$VolTimer.add_Tick({ $VolTimer.Stop(); $p = $Players['notify']; $p.Stop(); $p.Position = [TimeSpan]::Zero; $p.Volume = (Vol); $p.Play() })
function Play-Sample($slot, $seconds) {
    if ($St.Break) { return }
    $m = $Cfg.Music; $Cfg.Music = $true; Start-Music $slot; $Cfg.Music = $m; $Au.TestLeft = [double]$seconds
}
foreach ($n in 'DispFull', 'DispWindow', 'DispTray') { $C[$n].add_Checked($dispHandler) }
$C.MnDone.add_Click({ End-Break 'done' })
$C.MnLater.add_Click({ End-Break 'later' })
$C.MnSkip.add_Click({ End-Break 'skip' })
$playHandler = { param($s, $e)
    if ($Au.Current) { Stop-Music; $Au.TestLeft = 0 }
    else { $m = $Cfg.Music; $Cfg.Music = $true; Start-Music ([string]$s.Tag); $Cfg.Music = $m; $Au.TestLeft = 15.0 }
}
$pickHandler = { param($s, $e)
    $key = [string]$s.Tag
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = (T 'pickTitle')
    $dlg.Filter = "$(T 'filterAudio')|*.mp3;*.wav;*.wma;*.m4a;*.aac|$(T 'filterAll')|*.*"
    if ($dlg.ShowDialog($Win)) {
        $Cfg[$key] = $dlg.FileName; $St.Dirty = $true
        if ($key -eq 'MusicEye') { Reload-Music 'calm'; Play-Sample 'calm' 10 } else { Reload-Music 'active'; Play-Sample 'active' 10 }
    }
}
$defHandler = { param($s, $e)
    $key = [string]$s.Tag; $Cfg[$key] = ''; $St.Dirty = $true
    if ($key -eq 'MusicEye') { Reload-Music 'calm'; Play-Sample 'calm' 8 } else { Reload-Music 'active'; Play-Sample 'active' 8 }
}
foreach ($n in 'MuEyePlay', 'MuMovePlay') { $C[$n].add_Click($playHandler) }
foreach ($n in 'MuEyePick', 'MuMovePick') { $C[$n].add_Click($pickHandler) }
foreach ($n in 'MuEyeDef', 'MuMoveDef') { $C[$n].add_Click($defHandler) }

$C.OvDone.add_Click({ End-Break 'done' })
$C.OvLater.add_Click({ End-Break 'later' })
$C.OvSkip.add_Click({ End-Break 'skip' })
$C.ToastOk.add_Click({ Drink })
$C.ToastClose.add_Click({ $Toast.Hide(); $St.Toast = 0 })

$sliderHandler = { param($s, $e)
    if ($St.Loading) { return }
    $k = [string]$s.Tag; $v = [int]$s.Value
    $Cfg[$k] = $v; $C["${k}Val"].Text = ValText $k $v
    $St.Dirty = $true
    if ($k -eq 'Volume') {
        if ($Au.Current) { $Au.Current.Volume = (Vol) * 0.85 } else { $VolTimer.Stop(); $VolTimer.Start() }
    }
    Update-Desc; Update-UI
}
foreach ($d in $SliderDefs) { $C["$($d.K)Sl"].add_ValueChanged($sliderHandler) }
$checkHandler = { param($s, $e)
    if ($St.Loading) { return }
    $tag = [string]$s.Tag
    $Cfg[$tag] = [bool]$s.IsChecked; $St.Dirty = $true
    if (-not $Cfg.Music) { Stop-Music }
    # پیش‌نمایش: با روشن‌کردن هر گزینه، نمونه‌ی همان صدا پخش می‌شود
    if ($tag -eq 'Sound' -and $Cfg.Sound) { Play-Fx 'notify' }
    if ($tag -eq 'Music' -and $Cfg.Music) { Play-Sample 'calm' 6 }
}
foreach ($ck in 'CkSound', 'CkMusic', 'CkIdle') { $C[$ck].add_Click($checkHandler) }
$C.CkAuto.IsChecked = (Test-Path $LnkPath)
$C.CkAuto.add_Click({ param($s, $e)
        try { Set-Autostart ([bool]$s.IsChecked) } catch { Log "autostart: $_"; $s.IsChecked = (Test-Path $LnkPath) }
    })
$C.BtnDefaults.add_Click({
        foreach ($k in 'EyeInterval', 'EyeDuration', 'MoveInterval', 'MoveDuration', 'WaterInterval', 'IdleReset') { $Cfg[$k] = $Defaults[$k] }
        Load-Controls; $St.Dirty = $true; Update-UI
    })
$C.BtnTestChime.add_Click({ $p = $Players['start']; $p.Stop(); $p.Position = [TimeSpan]::Zero; $p.Volume = (Vol); $p.Play() })

# ---------- نشان کنار ساعت ----------
$script:Tray = $null; $script:MiPause = $null
if (-not $SelfTest) {
    $script:Tray = New-Object Windows.Forms.NotifyIcon
    $script:Tray.Icon = $Icon; $script:Tray.Text = (T 'appName'); $script:Tray.Visible = $true
    $menu = New-Object Windows.Forms.ContextMenuStrip
    if ($IsRtl) { $menu.RightToLeft = 'Yes' }
    $miShow = $menu.Items.Add((T 'miShow')); $miShow.add_Click({ Show-Main })
    $script:MiPause = $menu.Items.Add((T 'btnPause')); $script:MiPause.add_Click({ Toggle-Pause })
    $miEye = $menu.Items.Add((T 'miEye')); $miEye.add_Click({ Start-Break 'eye' })
    $miMove = $menu.Items.Add((T 'miMove')); $miMove.add_Click({ Start-Break 'move' })
    [void]$menu.Items.Add('-')
    $miExit = $menu.Items.Add((T 'miExit')); $miExit.add_Click({ Quit-App })
    $script:Tray.ContextMenuStrip = $menu
    $script:Tray.add_MouseDoubleClick({ Show-Main })
}

# ---------- اجرا ----------
Load-Controls
$St.TipIdx = Get-Random -Maximum $DashTips.Count
$C.TipText.Text = $DashTips[$St.TipIdx]
if ($Page -and $C.ContainsKey($Page.Replace('Page', 'Nav'))) { $C[$Page.Replace('Page', 'Nav')].IsChecked = $true }
if (Test-Path $ResumeFile) {
    try {
        $rs = Get-Content $ResumeFile -Raw -Encoding UTF8 | ConvertFrom-Json; Remove-Item $ResumeFile -Force
        if (([DateTime]::UtcNow.Ticks - [int64]$rs.At) / 1e7 -lt 180) {
            $St.Eye = [double]$rs.Eye; $St.Move = [double]$rs.Move; $St.Water = [double]$rs.Water; $St.Paused = [bool]$rs.Paused
            Log "resumed after language change: lang=$LangCode eye=$([int]$St.Eye) page=$Page"
        }
    } catch { Log "resume read: $_" }
}
if ($SelfTest) { $St.Eye = 700.0; $St.Move = 1500.0; $St.Water = 900.0; $Stats.Work = 8100.0; $Stats.Eye = 5; $Stats.Move = 3; $Stats.Water = 2; $Stats.Skipped = 1; $St.Paused = $true }
Update-UI

$Timer =New-Object Windows.Threading.DispatcherTimer
$Timer.Interval = [TimeSpan]::FromMilliseconds(500)
$Timer.add_Tick({ try { Tick } catch { Log "tick: $_ $($_.ScriptStackTrace)" } })
$St.Last = [DateTime]::UtcNow
$Timer.Start()
if ($Demo) {
    # ابزار آزمون: چند ثانیه پس از اجرا یک استراحت چشم را در حالت نمایش خواسته‌شده نشان می‌دهد (تنظیم ذخیره نمی‌شود)
    $DemoTimer = New-Object Windows.Threading.DispatcherTimer
    $DemoTimer.Interval = [TimeSpan]::FromMilliseconds(3000)
    $DemoTimer.add_Tick({ $DemoTimer.Stop(); $prev = $Cfg.BreakMode; $Cfg.BreakMode = $Demo; Start-Break 'eye'; $Cfg.BreakMode = $prev })
    $DemoTimer.Start()
}
if ($SwitchTo) {
    # ابزار آزمون: چند ثانیه پس از اجرا زبان را عوض می‌کند تا مسیر راه‌اندازی دوباره سنجیده شود
    $SwTimer = New-Object Windows.Threading.DispatcherTimer
    $SwTimer.Interval = [TimeSpan]::FromMilliseconds(2500)
    $SwTimer.add_Tick({ $SwTimer.Stop(); $St.Eye = 333.0; Set-Lang $SwitchTo })
    $SwTimer.Start()
}

if ($SelfTest) {
    function Shot($w, $file) {
        $src = [Windows.PresentationSource]::FromVisual($w); $m = $src.CompositionTarget.TransformToDevice
        if ($w.WindowState -eq 'Maximized') { $sb = [Windows.Forms.Screen]::PrimaryScreen.Bounds; $x = $sb.X; $y = $sb.Y; $ww = $sb.Width; $hh = $sb.Height }
        else { $x = [int]($w.Left * $m.M11); $y = [int]($w.Top * $m.M22); $ww = [int]($w.ActualWidth * $m.M11); $hh = [int]($w.ActualHeight * $m.M22) }
        $b = New-Object Drawing.Bitmap $ww, $hh; $gg = [Drawing.Graphics]::FromImage($b)
        $gg.CopyFromScreen($x, $y, 0, 0, $b.Size); $b.Save((Join-Path $TestDir $file), [Drawing.Imaging.ImageFormat]::Png)
        $gg.Dispose(); $b.Dispose(); Log "shot $file ${ww}x${hh}"
    }
    foreach ($k in $Snd.Keys) { Log ("wav {0} {1} bytes" -f $k, (Get-Item $Snd[$k]).Length) }
    $strip = New-Object Drawing.Bitmap 420, 256
    $sg = [Drawing.Graphics]::FromImage($strip); $sg.Clear([Drawing.Color]::FromArgb(255, 200, 205, 215)); $sx = 0
    foreach ($z in 256, 64, 48, 32, 16) { $lb = Draw-Logo $z; $sg.DrawImageUnscaled($lb, $sx, 0); $sx += $z + 2 }
    $sg.Dispose(); $strip.Save((Join-Path $TestDir '0-icon.png'), [Drawing.Imaging.ImageFormat]::Png)
    Log ("ico {0} bytes" -f (Get-Item $IcoFile).Length)
    $script:TS = 0
    $Steps = @(
        { Shot $Win '1-dashboard.png' },
        { $C.NavSettings.IsChecked = $true },
        { Shot $Win '2-settings.png' },
        { $C.NavGuide.IsChecked = $true },
        { Shot $Win '3-guide.png' },
        { $C.NavAbout.IsChecked = $true },
        { Shot $Win '3b-about.png' },
        { $Win.Hide(); Start-Break 'eye' },
        { Shot $Ov '4-eye-break.png' },
        { End-Break 'done'; Start-Break 'move' },
        { $St.Break.Left = 75.0 },
        { Shot $Ov '5-move-break.png' },
        { End-Break 'skip'; Show-WaterToast },
        { Shot $Toast '6-toast.png' },
        { $Toast.Hide(); $Win.Show(); $C.NavDash.IsChecked = $true; $C.ThLight.IsChecked = $true },
        { Shot $Win '7-light-dashboard.png' },
        { $C.NavSettings.IsChecked = $true },
        { Shot $Win '8-light-settings.png' },
        { $C.NavGuide.IsChecked = $true },
        { Shot $Win '9-light-guide.png' },
        { $C.NavAbout.IsChecked = $true },
        { Shot $Win '10-light-about.png' },
        { $C.NavDash.IsChecked = $true; $St.Eye = 700.0; [void]$Win.Dispatcher.BeginInvoke([Action] { $C.BtnReset.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))); Log "after cancel eye=$($St.Eye)" }) },
        { },
        { Shot $script:ConfirmWin '11-light-confirm.png'; $script:ConfirmWin.DialogResult = $false },
        { $C.ThDark.IsChecked = $true; [void]$Win.Dispatcher.BeginInvoke([Action] { $C.BtnReset.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))); Log "after yes eye=$($St.Eye)" }) },
        { },
        { Shot $script:ConfirmWin '12-dark-confirm.png'; $script:ConfirmWin.DialogResult = $true },
        { },
        { $C.ThLight.IsChecked = $true; $Win.Hide(); Start-Break 'move' },
        { Shot $Ov '13-light-break.png' },
        { End-Break 'skip'; $Cfg.MusicEye = (Join-Path $SoundDir 'chime_end_v1.wav'); Reload-Music 'calm'; Log "custom music name=$($C.MuEyeName.Text) path=$(Music-Path 'calm')" },
        { $Cfg.MusicEye = 'C:\no-such-file.mp3'; Reload-Music 'calm'; Log "missing music name=$($C.MuEyeName.Text) path=$(Music-Path 'calm')" },
        { Log ("theme saved=" + $Cfg.Theme) },
        { Log ("stats eye={0} move={1} skipped={2}" -f $Stats.Eye, $Stats.Move, $Stats.Skipped); Log 'selftest done'; Quit-App }
    )
    if ($LangTest) {
        $Steps = @(
            { Shot $Win 'a-dash.png' },
            { $C.NavSettings.IsChecked = $true },
            { Shot $Win 'b-settings.png' },
            { $C.NavGuide.IsChecked = $true },
            { Shot $Win 'c-guide.png' },
            { $C.NavAbout.IsChecked = $true },
            { Shot $Win 'd-about.png' },
            { $C.NavDash.IsChecked = $true; [void]$Win.Activate(); $C.LangPop.IsOpen = $true },
            { Shot $Win 'e-lang.png'; $C.LangPop.IsOpen = $false },
            { [void]$Win.Dispatcher.BeginInvoke([Action] { $C.BtnReset.RaiseEvent((New-Object Windows.RoutedEventArgs ([Windows.Controls.Button]::ClickEvent))) }) },
            { },
            { Shot $script:ConfirmWin 'f-confirm.png'; $script:ConfirmWin.DialogResult = $false },
            { $Win.Hide(); Start-Break 'move' },
            { Shot $Ov 'g-move.png' },
            { End-Break 'skip'; Start-Break 'eye' },
            { Shot $Ov 'h-eye.png' },
            { End-Break 'skip'; $Cfg.BreakMode = 'window'; Start-Break 'move' },
            { Shot $Mini 'j-mini-move.png' },
            { End-Break 'skip'; Start-Break 'eye' },
            { Shot $Mini 'k-mini-eye.png' },
            { End-Break 'skip'; $Cfg.BreakMode = 'tray'; Start-Break 'eye'; Log "tray mode: break=$([bool]$St.Break) overlay=$($Ov.IsVisible) mini=$($Mini.IsVisible) tips=[$($St.Break.TipsText)]" },
            { End-Break 'done'; Log "tray break ended: eyeStat=$($Stats.Eye)"; $St.Eye = 444.0; $Win.Show(); $C.NavSettings.IsChecked = $true; $C.DispWindow.IsChecked = $true; Log "preview started: preview=$($St.Break.Preview) mode=$($St.Break.Mode) total=$($St.Break.Total) cfg=$($Cfg.BreakMode)" },
            { Shot $Mini 'l-preview.png' },
            { End-Break 'done'; Log "preview ended: eyeStat=$($Stats.Eye) moveStat=$($Stats.Move) skipped=$($Stats.Skipped) eyeTimer=$([int]$St.Eye) break=$([bool]$St.Break)"; $Win.Hide(); $Cfg.BreakMode = 'full'; Show-WaterToast },
            { Shot $Toast 'i-toast.png' },
            { Log "pools eye=$($EyeTips.Count) move=$($MoveTips.Count) water=$($WaterTips.Count) dash=$($DashTips.Count)"; $seen = @{}; for ($q = 0; $q -lt $MoveTips.Count; $q++) { $seen[[string](Next-Tips 'probe' $MoveTips 1)[0]] = 1 }; Log "deck: $($seen.Count) distinct of $($MoveTips.Count) in one round" },
            { Log "lang=$LangCode missing-check done"; Log 'selftest done'; Quit-App }
        )
    }
    $TT = New-Object Windows.Threading.DispatcherTimer
    $TT.Interval = [TimeSpan]::FromMilliseconds(900)
    $TT.add_Tick({
            try { $i = $script:TS; $script:TS++; if ($i -lt $Steps.Count) { & $Steps[$i] } }
            catch { Log "selftest step $($script:TS): $_ $($_.ScriptStackTrace)"; $St.Exiting = $true; $App.Shutdown() }
        })
    $TT.Start()
}

if ($Minimized) { [void]$App.Run() } else { [void]$App.Run($Win) }
try { $Mutex.ReleaseMutex() } catch {}
